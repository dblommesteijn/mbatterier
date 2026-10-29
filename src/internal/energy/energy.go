// Package energy finds the apps using significant energy, approximating the
// list in macOS's Battery menu.
//
// Apple does not document that list, so the rule here is fitted from
// observation and is an approximation, not Apple's logic (see Threshold). The
// figure is the Energy Impact of powermetrics(1), the metric of Activity
// Monitor's Energy tab, summed per coalition so that the processes an app
// starts (a terminal's children, an editor's helpers) count for the app.
// powermetrics needs root and takes 15 seconds to sample, so this is read on
// demand and never from the 15 s status poll.
package energy

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	// Threshold is the coalition Energy Impact from which an app counts as
	// using significant energy. It is a rough fit, not Apple's number: Apple
	// dropped VS Code, which idles at about 450 (mean 457), while a fresh reading
	// was 498, and listed it after readings of 580 and 811, so the line is above
	// 500. We take one 15 s sample (a 3 s one flickered between none, Code and
	// Xcode within ten seconds); Hold supplies the memory Apple's list has.
	Threshold = 550.0
	// MaxApps is how many apps are listed, highest first.
	MaxApps = 2
	// sampleMillis is how long powermetrics samples. Energy Impact over 3 s
	// jumped between "none", Code and Xcode within ten seconds, so the one sample
	// covers 15 s, which smooths out bursts without a sampler between calls.
	sampleMillis = 15000
)

// App is an app and the Energy Impact of all its processes together.
type App struct {
	Name   string  `json:"name"`
	Impact float64 `json:"impact"`
}

// coalition is one group of tasks in powermetrics' output, which is how macOS
// accounts a parent and the processes it launched together.
type coalition struct {
	name   string
	impact float64
	pids   []int
}

// proc is what ps knows about a process.
type proc struct {
	uid  int
	path string
}

// bundle is what an app's Info.plist says about it.
type bundle struct {
	name string
	// gui is false for background-only apps (LSUIElement, LSBackgroundOnly):
	// agents and daemons with no Dock icon or windows.
	gui bool
}

// Read samples powermetrics and returns the invoking user's GUI apps that
// reached Threshold in this sample or within Hold before it, highest first. The
// slice is empty, not nil, when there is none. It must run as root, which powermetrics insists on.
func Read() ([]App, error) {
	if os.Geteuid() != 0 {
		return nil, fmt.Errorf("powermetrics needs root")
	}
	out, err := exec.Command("/usr/bin/powermetrics", "--samplers", "tasks",
		"--show-process-energy", "--show-process-coalition",
		"-n", "1", "-i", strconv.Itoa(sampleMillis)).Output()
	if err != nil {
		return nil, fmt.Errorf("powermetrics: %w", err)
	}
	cs := parseCoalitions(string(out))
	if len(cs) == 0 {
		return nil, fmt.Errorf("powermetrics: no coalitions in its output")
	}
	// Only the few coalitions over the threshold need owners and paths, so ps
	// is asked about those processes alone.
	var pids []string
	for _, c := range cs {
		if c.impact >= Threshold {
			for _, p := range c.pids {
				pids = append(pids, strconv.Itoa(p))
			}
		}
	}
	procs := map[int]proc{}
	if len(pids) > 0 {
		// A process that exited since the sample makes ps exit 1 while still
		// listing the rest.
		psOut, err := exec.Command("/bin/ps", "-o", "pid=,uid=,comm=", "-p", strings.Join(pids, ",")).Output()
		if err != nil && len(psOut) == 0 {
			return nil, fmt.Errorf("ps: %w", err)
		}
		procs = parsePS(string(psOut))
	}
	ranked := Rank(cs, procs, invokerUID(os.Geteuid(), os.Getenv("SUDO_UID")), readBundle)
	kept, next := Merge(loadState(StatePath), ranked, time.Now(), Hold)
	// Not remembering is not an error: the list is still right, only without
	// the hold.
	_ = saveState(StatePath, next)
	return kept, nil
}

// invokerUID is the user whose apps are listed: whoever ran sudo, since the
// command itself runs as root. Without sudo it is the user running it.
func invokerUID(euid int, sudoUID string) int {
	if euid == 0 {
		if n, err := strconv.Atoi(sudoUID); err == nil {
			return n
		}
	}
	return euid
}

// taskColumns is how many numeric columns end a task row: ID, CPU ms/s, User%,
// two Deadlines, two Wakeups and Energy Impact.
const taskColumns = 8

// coalitionColumns is how many fields end a coalition row: ID, CPU ms/s, two
// Wakeups and Energy Impact.
const coalitionColumns = 5

// parseCoalitions returns the coalitions of the "Running tasks" table with
// their process ids. A coalition row sits at the left margin and its tasks are
// indented beneath it. Names are read from the right-hand end because tasks
// can have spaces in theirs. Rows that are not a coalition with an ID, such as
// DEAD_TASKS_COALITION, are skipped together with their tasks.
func parseCoalitions(out string) []coalition {
	var cs []coalition
	inTable := false
	cur := -1
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "*** Running tasks"):
			inTable = true
			continue
		case strings.HasPrefix(line, "***"):
			inTable = false
			continue
		}
		if !inTable || strings.TrimSpace(line) == "" {
			continue
		}
		f := strings.Fields(line)
		if line[0] == ' ' {
			if cur < 0 || len(f) <= taskColumns {
				continue
			}
			if pid, err := strconv.Atoi(f[len(f)-taskColumns]); err == nil && pid > 0 {
				cs[cur].pids = append(cs[cur].pids, pid)
			}
			continue
		}
		cur = -1
		if len(f) <= coalitionColumns {
			continue
		}
		if _, err := strconv.Atoi(f[len(f)-coalitionColumns]); err != nil {
			continue
		}
		impact, err := strconv.ParseFloat(f[len(f)-1], 64)
		if err != nil {
			continue
		}
		cs = append(cs, coalition{name: strings.Join(f[:len(f)-coalitionColumns], " "), impact: impact})
		cur = len(cs) - 1
	}
	return cs
}

// parsePS maps each pid in `ps -o pid=,uid=,comm=` output to its owner and
// executable path.
func parsePS(out string) map[int]proc {
	procs := map[int]proc{}
	for _, line := range strings.Split(out, "\n") {
		pid, rest, _ := strings.Cut(strings.TrimSpace(line), " ")
		uid, path, ok := strings.Cut(strings.TrimSpace(rest), " ")
		p, err1 := strconv.Atoi(pid)
		u, err2 := strconv.Atoi(uid)
		if !ok || err1 != nil || err2 != nil {
			continue
		}
		// The path is the rest of the line and may itself hold spaces.
		procs[p] = proc{u, strings.TrimSpace(path)}
	}
	return procs
}

// bundleRoot is the outermost app bundle an executable path lives in, so a
// helper inside Visual Studio Code.app belongs to Visual Studio Code.app. ok is
// false for anything outside an app, such as a system daemon.
func bundleRoot(path string) (root string, ok bool) {
	i := strings.Index(path, ".app/")
	if i < 0 {
		return "", false
	}
	return path[:i+len(".app")], true
}

// truthy reads a plist boolean, which apps write as a bool, a number or a
// string ("1", "true", "YES").
func truthy(v any) bool {
	switch v := v.(type) {
	case bool:
		return v
	case float64:
		return v != 0
	case string:
		switch strings.ToLower(v) {
		case "1", "true", "yes":
			return true
		}
	}
	return false
}

// parseInfo reads from a bundle's Info.plist, converted to JSON, whether it is
// a GUI app. Its name is not read from the plist: Visual Studio Code's
// CFBundleName and CFBundleDisplayName are both just "Code", while Apple's menu
// and Finder say "Visual Studio Code", so the app is named by fallback, the
// bundle's folder name.
func parseInfo(data []byte, fallback string) (bundle, error) {
	var info map[string]any
	if err := json.Unmarshal(data, &info); err != nil {
		return bundle{}, err
	}
	return bundle{name: fallback, gui: !truthy(info["LSUIElement"]) && !truthy(info["LSBackgroundOnly"])}, nil
}

// readBundle reads an app's Info.plist by plutil, by absolute path.
func readBundle(root string) (bundle, bool) {
	out, err := exec.Command("/usr/bin/plutil", "-convert", "json", "-o", "-", "--",
		root+"/Contents/Info.plist").Output()
	if err != nil {
		return bundle{}, false
	}
	b, err := parseInfo(out, strings.TrimSuffix(root[strings.LastIndex(root, "/")+1:], ".app"))
	return b, err == nil
}

// Rank turns powermetrics' coalitions into the list. A coalition counts when
// its Energy Impact reaches Threshold and one of its processes, owned by uid,
// lives in a GUI app bundle: Activity Monitor's default view is "My
// Processes", and Apple's list shows apps with a Dock presence, not root
// security daemons or agents such as MenuBarAgent. lookup reads a bundle's
// Info.plist. The result is highest first and not capped: Merge holds apps over
// time and caps the final list.
func Rank(cs []coalition, procs map[int]proc, uid int, lookup func(root string) (bundle, bool)) []App {
	apps := []App{}
	for _, c := range cs {
		if c.impact < Threshold {
			continue
		}
		for _, pid := range c.pids {
			p, ok := procs[pid]
			if !ok || p.uid != uid {
				continue
			}
			root, ok := bundleRoot(p.path)
			if !ok {
				continue
			}
			if b, ok := lookup(root); ok && b.gui {
				apps = append(apps, App{b.name, c.impact})
			}
			break
		}
	}
	sort.Slice(apps, func(i, j int) bool {
		if apps[i].Impact != apps[j].Impact {
			return apps[i].Impact > apps[j].Impact
		}
		return apps[i].Name < apps[j].Name
	})
	return apps
}
