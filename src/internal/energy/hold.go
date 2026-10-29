package energy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// Hold is how long an app stays listed after it last reached Threshold.
// Watching the real menu, an app that stopped using energy was still listed
// 102 s later and gone 181 s later (another run: listed at 20 s, gone by 155 s),
// while a new burst showed up within 12 s. Apple's list is therefore a peak
// hold, not a long average: seen above the line in the last two minutes or so.
const Hold = 2 * time.Minute

// StatePath remembers when each app was last seen at or above Threshold. It is
// in /var/run, which only root writes, like the runstate files.
var StatePath = "/var/run/mbatterier.energy.json"

// seen is an app's latest Energy Impact at or above Threshold and when it was
// taken, in Unix seconds.
type seen struct {
	Impact float64 `json:"impact"`
	At     int64   `json:"at"`
}

// Merge adds the apps sampled now to those remembered in prev, drops the ones
// last seen more than hold ago, and returns the list highest first, at most
// MaxApps of it, together with the state to remember. An app sampled again
// replaces its entry. An entry stamped in the future, from a clock that went
// backwards, is dropped rather than held for good.
func Merge(prev map[string]seen, cur []App, now time.Time, hold time.Duration) ([]App, map[string]seen) {
	next := map[string]seen{}
	for name, s := range prev {
		if age := now.Sub(time.Unix(s.At, 0)); age >= 0 && age <= hold {
			next[name] = s
		}
	}
	for _, a := range cur {
		next[a.Name] = seen{Impact: a.Impact, At: now.Unix()}
	}
	apps := []App{}
	for name, s := range next {
		apps = append(apps, App{name, s.Impact})
	}
	sort.Slice(apps, func(i, j int) bool {
		if apps[i].Impact != apps[j].Impact {
			return apps[i].Impact > apps[j].Impact
		}
		return apps[i].Name < apps[j].Name
	})
	if len(apps) > MaxApps {
		apps = apps[:MaxApps]
	}
	return apps, next
}

// loadState reads the remembered apps. A missing or unreadable file is an
// empty memory, never an error: the worst outcome is a list without the hold.
func loadState(path string) map[string]seen {
	var m map[string]seen
	if b, err := os.ReadFile(path); err != nil || json.Unmarshal(b, &m) != nil {
		return map[string]seen{}
	}
	return m
}

// saveState replaces the state file atomically, so a reader never sees half of
// one.
func saveState(path string, m map[string]seen) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".mbatterier.energy.*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
