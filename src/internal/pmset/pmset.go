// Package pmset reads and sets the macOS power mode through pmset(1).
package pmset

import (
	"bufio"
	"bytes"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Mode is a pmset powermode value.
type Mode int

// Power modes supported by pmset powermode.
const (
	Automatic Mode = 0
	Low       Mode = 1
	High      Mode = 2
)

func (m Mode) String() string {
	switch m {
	case Automatic:
		return "automatic"
	case Low:
		return "low"
	case High:
		return "high"
	}
	return "unknown (" + strconv.Itoa(int(m)) + ")"
}

// Source is a power source, as the pmset flag that selects it.
type Source string

// Power sources.
const (
	Battery Source = "-b"
	AC      Source = "-c"
	All     Source = "-a"
)

// pmsetPath is absolute because callers run as root; never resolve it via $PATH.
const pmsetPath = "/usr/bin/pmset"

// sections maps the section headers of `pmset -g custom` to their source.
var sections = map[string]Source{
	"Battery Power": Battery,
	"AC Power":      AC,
}

// Set sets the power mode for src. It needs root.
func Set(src Source, m Mode) error {
	out, err := exec.Command(pmsetPath, string(src), "powermode", strconv.Itoa(int(m))).CombinedOutput()
	if err != nil {
		return fmt.Errorf("pmset %s powermode %d: %w: %s", src, int(m), err, strings.TrimSpace(string(out)))
	}
	return nil
}

// Get returns the current power mode per source. A source that pmset
// doesn't report is missing from the map.
func Get() (map[Source]Mode, error) {
	out, err := exec.Command(pmsetPath, "-g", "custom").Output()
	if err != nil {
		return nil, fmt.Errorf("pmset -g custom: %w", err)
	}
	return parse(out), nil
}

// parse reads the powermode lines from `pmset -g custom` output.
func parse(out []byte) map[Source]Mode {
	modes := map[Source]Mode{}
	var src Source
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		line := sc.Text()
		if strings.HasSuffix(line, ":") && !strings.HasPrefix(line, " ") {
			src = sections[strings.TrimSuffix(line, ":")]
			continue
		}
		fields := strings.Fields(line)
		if src == "" || len(fields) != 2 || fields[0] != "powermode" {
			continue
		}
		if n, err := strconv.Atoi(fields[1]); err == nil {
			modes[src] = Mode(n)
		}
	}
	return modes
}

// PS is a reading of `pmset -g ps`: the power source and the battery charge.
type PS struct {
	// OnAC reports whether the Mac is drawing from the adapter.
	OnAC bool
	// Percent is the battery charge, or NoBattery when pmset reports none.
	Percent int
	// Charging reports whether the battery is taking charge. It is false
	// while on the adapter at a charge limit, which is the usual state here.
	Charging bool
	// Remaining is the time pmset estimates until empty, or until full while
	// charging. Zero means pmset gave no estimate, which is normal right
	// after plugging in and on a full battery.
	Remaining time.Duration
}

// NoBattery is the Percent of a Mac that pmset reports no battery for.
const NoBattery = -1

// Read returns the current power source and battery charge. It doesn't need root.
func Read() (PS, error) {
	out, err := exec.Command(pmsetPath, "-g", "ps").Output()
	if err != nil {
		return PS{}, fmt.Errorf("pmset -g ps: %w", err)
	}
	return parsePS(out)
}

// OnAC reports whether the Mac is drawing from the adapter.
func OnAC() (bool, error) {
	ps, err := Read()
	return ps.OnAC, err
}

// parsePS reads the power source from the first line of `pmset -g ps` and the
// charge from the battery line under it.
func parsePS(out []byte) (PS, error) {
	first, rest, _ := strings.Cut(string(out), "\n")
	ps := PS{Percent: NoBattery}
	switch {
	case strings.Contains(first, "'AC Power'"):
		ps.OnAC = true
	case strings.Contains(first, "'Battery Power'"), strings.Contains(first, "'UPS Power'"):
		ps.OnAC = false
	default:
		return PS{}, fmt.Errorf("unknown power source %q", strings.TrimSpace(first))
	}
	sc := bufio.NewScanner(strings.NewReader(rest))
	for sc.Scan() {
		if pct, charging, remaining, ok := parseBattery(sc.Text()); ok {
			ps.Percent, ps.Charging, ps.Remaining = pct, charging, remaining
			break
		}
	}
	return ps, nil
}

// chargingStates are the state fields of a battery line that mean the battery
// is taking charge. Every other state (discharging, charged, "AC attached")
// is not: being on the adapter is not the same as charging, and with a charge
// limit in place "AC attached; not charging" is the usual resting state.
var chargingStates = map[string]bool{
	"charging":         true,
	"finishing charge": true,
}

// parseBattery reads the charge, the charging state and the time estimate off a
// battery line of `pmset -g ps`, such as
// " -InternalBattery-0 (id=23920739)\t80%; AC attached; not charging present: true".
// ok is false for a line that carries no percentage. A missing estimate
// ("(no estimate)", and "0:00" on a full battery) comes back as 0: pmset not
// knowing how long is left is a normal state, not an error.
func parseBattery(line string) (pct int, charging bool, remaining time.Duration, ok bool) {
	// The fields are semicolon-separated: "80%; AC attached; not charging".
	// The state is the second one, matched whole rather than searched for,
	// because "not charging" contains "charging".
	fields := strings.Split(line, ";")
	pct, ok = parsePercent(fields[0])
	if !ok {
		return 0, false, 0, false
	}
	if len(fields) > 1 {
		charging = chargingStates[strings.TrimSpace(fields[1])]
	}
	for _, f := range fields[1:] {
		if d, found := parseHM(f); found {
			remaining = d
			break
		}
	}
	return pct, charging, remaining, true
}

// parseHM reads an "H:MM" estimate out of a field such as "2:41 remaining".
func parseHM(field string) (time.Duration, bool) {
	for _, f := range strings.Fields(field) {
		hs, ms, found := strings.Cut(f, ":")
		if !found {
			continue
		}
		h, err := strconv.Atoi(hs)
		if err != nil || h < 0 {
			continue
		}
		m, err := strconv.Atoi(ms)
		if err != nil || m < 0 || m > 59 {
			continue
		}
		return time.Duration(h)*time.Hour + time.Duration(m)*time.Minute, true
	}
	return 0, false
}

// parsePercent reads the charge off a battery line of `pmset -g ps`, such as
// " -InternalBattery-0 (id=23920739)\t80%; discharging; 2:49 remaining present: true".
func parsePercent(line string) (int, bool) {
	for _, f := range strings.Fields(line) {
		s, ok := strings.CutSuffix(strings.TrimSuffix(f, ";"), "%")
		if !ok {
			continue
		}
		if n, err := strconv.Atoi(s); err == nil && n >= 0 && n <= 100 {
			return n, true
		}
	}
	return 0, false
}
