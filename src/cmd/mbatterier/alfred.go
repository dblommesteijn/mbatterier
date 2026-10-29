package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"mbatterier/internal/pmset"
	"mbatterier/internal/runstate"
)

// alfredItem is one row of Alfred Script Filter JSON.
type alfredItem struct {
	UID          string               `json:"uid,omitempty"`
	Title        string               `json:"title"`
	Subtitle     string               `json:"subtitle,omitempty"`
	Arg          string               `json:"arg,omitempty"`
	Autocomplete string               `json:"autocomplete,omitempty"`
	Valid        bool                 `json:"valid"`
	Mods         map[string]alfredMod `json:"mods,omitempty"`
	Icon         *alfredIcon          `json:"icon,omitempty"`
}

// alfredIcon is the per-row icon. Alfred resolves a relative Path against the
// workflow bundle, which is where `make alfred` puts the generated PNGs. A row
// without one falls back to the workflow's own icon.png.
type alfredIcon struct {
	Path string `json:"path"`
}

// iconFor names one of the PNGs that tools/icon.py renders into alfred/.
// TestAlfredItemIconsExist checks every name used here is really shipped.
func iconFor(name string) *alfredIcon {
	return &alfredIcon{Path: name + ".png"}
}

// alfredMod is what a row does when a modifier key is held. It's how the
// flags reach Alfred: every boost row offers its -k, -b and -c variants.
type alfredMod struct {
	Arg      string `json:"arg"`
	Subtitle string `json:"subtitle"`
	Valid    bool   `json:"valid"`
}

// mod builds the modifier variant that runs ba.
func mod(ba boostArgs, subtitle string) alfredMod {
	return alfredMod{
		Arg:      strings.Join(append(ba.args(), "--detach"), " "),
		Subtitle: subtitle,
		Valid:    true,
	}
}

// boostMods offers the flags ba doesn't already use, so every option is
// reachable from Alfred without typing it.
func boostMods(ba boostArgs) map[string]alfredMod {
	mods := map[string]alfredMod{}
	// --keep is pointless for a battery-only boost and contradicts unplug.
	if ba.src != pmset.Battery && !ba.keep && !ba.untilUnplug {
		keep := ba
		keep.keep = true
		mods["cmd"] = mod(keep, "Keep it for the full time, ignoring plugging and unplugging")
	}
	if ba.src != pmset.Battery && !ba.untilUnplug {
		battery := ba
		battery.src, battery.label, battery.keep = pmset.Battery, "battery", false
		mods["alt"] = mod(battery, "Battery only, leaving the adapter on Low Power")
	}
	if ba.src != pmset.AC {
		ac := ba
		ac.src, ac.label = pmset.AC, "adapter"
		mods["ctrl"] = mod(ac, "Adapter only, leaving battery on Low Power")
	}
	if len(mods) == 0 {
		return nil
	}
	return mods
}

type alfredOutput struct {
	// Rerun makes Alfred re-run the filter every Rerun seconds, which keeps
	// the countdown live.
	Rerun float64      `json:"rerun,omitempty"`
	Items []alfredItem `json:"items"`
}

// presets are the boosts offered for an empty query.
var presets = []time.Duration{30 * time.Minute, time.Hour, 2 * time.Hour}

func alfred(query string) error {
	st, running := runstate.Current(runstate.Boost)
	ws, watching := runstate.Current(runstate.Watch)
	modes, err := pmset.Get()
	if err != nil {
		// Alfred still gets its presets; only the status row needs the modes.
		modes = nil
	}
	return json.NewEncoder(os.Stdout).Encode(alfredItems(query, st, running, ws, watching, time.Now(), modes))
}

// alfredItems builds the Script Filter result for query. The arg of each
// item is the command line the workflow's Run Script passes to mbatterier.
func alfredItems(query string, st runstate.State, running bool, ws runstate.State, watching bool, now time.Time, modes map[pmset.Source]pmset.Mode) alfredOutput {
	var out alfredOutput
	if running {
		out.Rerun = 1
		title := fmt.Sprintf("High Power — %s left", formatRemaining(st.Deadline.Sub(now)))
		until := st.Deadline.Format("15:04")
		if st.UntilUnplug {
			title, until = "High Power — until unplugged", "unplugged"
		}
		out.Items = append(out.Items, alfredItem{
			UID:      "running",
			Title:    title,
			Subtitle: fmt.Sprintf("%s until %s · ↩ stop now and go to Low Power", st.Label, until),
			Arg:      "low",
			Valid:    true,
			Icon:     iconFor("stop"),
		})
	}

	if watching {
		out.Items = append(out.Items, alfredItem{
			UID:      "watching",
			Title:    "Watching the battery",
			Subtitle: ws.Label + " · ↩ stop watching and go to Low Power",
			Arg:      "low",
			Valid:    true,
			Icon:     iconFor("stop"),
		})
	}

	q := strings.TrimSpace(query)
	lowItem := alfredItem{
		UID:      "low",
		Title:    "Low Power now",
		Subtitle: "Battery + adapter",
		Arg:      "low",
		Valid:    true,
		Icon:     iconFor("low"),
	}
	switch {
	case q == "":
		for _, d := range presets {
			out.Items = append(out.Items, boostItem(boostArgs{dur: d, label: "battery + adapter"}, now))
		}
		out.Items = append(out.Items, boostItem(boostArgs{untilUnplug: true, label: "battery + adapter"}, now))
		if !watching {
			out.Items = append(out.Items, watchItem(watchArgs{low: defaultLow, high: defaultHigh}))
		}
		if !running {
			out.Items = append(out.Items, lowItem)
		}
		out.Items = append(out.Items, statusItem(modes))
	case strings.HasPrefix("low", q) || strings.HasPrefix("stop", q):
		if !running {
			out.Items = append(out.Items, lowItem)
		}
	case strings.HasPrefix("watch", q):
		if !watching {
			out.Items = append(out.Items, watchItem(watchArgs{low: defaultLow, high: defaultHigh}))
		}
	case strings.HasPrefix("status", q):
		out.Items = append(out.Items, statusItem(modes))
	default:
		ba, err := parseBoostArgs(strings.Fields(q))
		if err != nil {
			out.Items = append(out.Items, alfredItem{
				Title:    "Usage: mbat 1h|unplug [-b|-c]",
				Subtitle: err.Error(),
				Valid:    false,
			})
			break
		}
		out.Items = append(out.Items, boostItem(ba, now))
	}
	return out
}

// watchItem offers the battery watcher. It detaches, like the boost rows,
// since Alfred has no terminal to hold a long-running process.
func watchItem(wa watchArgs) alfredItem {
	return alfredItem{
		UID:          "watch",
		Title:        "Watch the battery",
		Subtitle:     wa.label() + ", left alone in between",
		Arg:          strings.Join(append(wa.args(), "--detach"), " "),
		Autocomplete: "watch",
		Valid:        true,
		Icon:         iconFor("watch"),
	}
}

func boostItem(ba boostArgs, now time.Time) alfredItem {
	if ba.always {
		return alfredItem{
			UID:          "boost-always",
			Title:        "High Power until stopped",
			Subtitle:     ba.label + ", unplugging or not, until mbat low or boost stop",
			Arg:          strings.Join(append(ba.args(), "--detach"), " "),
			Autocomplete: "always",
			Valid:        true,
			Icon:         iconFor("boost"),
		}
	}
	if ba.untilUnplug {
		mods := boostMods(ba)
		return alfredItem{
			UID:          "boost-unplug",
			Title:        "High Power until unplugged",
			Subtitle:     ba.label + " until the adapter is unplugged, then back to Low Power" + modHint(mods),
			Arg:          strings.Join(append(ba.args(), "--detach"), " "),
			Autocomplete: "unplug",
			Valid:        true,
			Mods:         mods,
			Icon:         iconFor("unplug"),
		}
	}
	d := formatDuration(ba.dur)
	mods := boostMods(ba)
	// A battery-only boost and --keep aren't ended by unplugging.
	until := now.Add(ba.dur).Format("15:04")
	if ba.src != pmset.Battery && !ba.keep {
		until += " or until unplugged"
	}
	return alfredItem{
		UID:          "boost-" + d,
		Title:        "High Power for " + d,
		Subtitle:     fmt.Sprintf("%s until %s, then back to Low Power%s", ba.label, until, modHint(mods)),
		Arg:          strings.Join(append(ba.args(), "--detach"), " "),
		Autocomplete: d,
		Valid:        true,
		Mods:         mods,
		Icon:         iconFor("boost"),
	}
}

// modHint lists the modifier variants a row offers, so they're visible in the
// subtitle instead of hidden behind the keys.
func modHint(mods map[string]alfredMod) string {
	var hints []string
	for _, h := range []struct{ key, label string }{
		{"cmd", "⌘ keep"},
		{"alt", "⌥ battery"},
		{"ctrl", "⌃ adapter"},
	} {
		if _, ok := mods[h.key]; ok {
			hints = append(hints, h.label)
		}
	}
	if len(hints) == 0 {
		return ""
	}
	return " · " + strings.Join(hints, ", ")
}

// statusItem shows the current mode per source, the `mbat status` output as a
// row. It runs nothing, so it isn't valid.
func statusItem(modes map[pmset.Source]pmset.Mode) alfredItem {
	sub := "pmset didn't report the current modes"
	if modes != nil {
		sub = fmt.Sprintf("Battery: %s · Adapter: %s", modeLabel(modes, pmset.Battery), modeLabel(modes, pmset.AC))
	}
	return alfredItem{
		UID:          "status",
		Title:        "Current power mode",
		Subtitle:     sub,
		Autocomplete: "status",
		Valid:        false,
		Icon:         iconFor("status"),
	}
}

func modeLabel(modes map[pmset.Source]pmset.Mode, src pmset.Source) string {
	if m, ok := modes[src]; ok {
		return m.String()
	}
	return "n/a"
}
