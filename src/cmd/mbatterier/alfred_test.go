package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"mbatterier/internal/pmset"

	"mbatterier/internal/runstate"
)

var now = time.Date(2026, 10, 27, 14, 0, 0, 0, time.Local)

func itemArgs(out alfredOutput) []string {
	var a []string
	for _, it := range out.Items {
		a = append(a, it.Arg)
	}
	return a
}

func TestAlfredItems(t *testing.T) {
	tests := []struct {
		query string
		want  []string
	}{
		{"", []string{"boost 30m --detach", "boost 1h --detach", "boost 2h --detach", "boost unplug --detach", "watch --high 80 --low 20 --detach", "low", ""}},
		{"status", []string{""}},
		{"stat", []string{""}},
		{"unplug", []string{"boost unplug --detach"}},
		{"always", []string{"boost always --detach"}},
		{"always -b", []string{"boost always -b --detach"}},
		{"always 1h", []string{""}}, // invalid: one usage row, no arg
		{"unplug -b", []string{""}}, // invalid: one usage row, no arg
		{"90m", []string{"boost 1h30m --detach"}},
		{"2h -b", []string{"boost 2h -b --detach"}},
		{"2h -k", []string{"boost 2h -k --detach"}},
		{"lo", []string{"low"}},
		{"watch", []string{"watch --high 80 --low 20 --detach"}},
		{"w", []string{"watch --high 80 --low 20 --detach"}},
		{"stop", []string{"low"}},
	}
	for _, tt := range tests {
		out := alfredItems(tt.query, runstate.State{}, false, runstate.State{}, false, now, nil)
		if got := itemArgs(out); !equal(got, tt.want) {
			t.Errorf("alfredItems(%q) args = %q, want %q", tt.query, got, tt.want)
		}
		if out.Rerun != 0 {
			t.Errorf("alfredItems(%q) rerun = %v without a running boost", tt.query, out.Rerun)
		}
	}
}

func TestAlfredItemsInvalid(t *testing.T) {
	out := alfredItems("nope; rm -rf /", runstate.State{}, false, runstate.State{}, false, now, nil)
	if len(out.Items) != 1 || out.Items[0].Valid || out.Items[0].Arg != "" {
		t.Errorf("alfredItems(invalid) = %+v, want one invalid item without arg", out.Items)
	}
}

func TestAlfredItemsRunning(t *testing.T) {
	st := runstate.State{Deadline: now.Add(47*time.Minute + 12*time.Second), Label: "battery"}
	out := alfredItems("", st, true, runstate.State{}, false, now, nil)
	if out.Rerun != 1 {
		t.Errorf("rerun = %v, want 1 while a boost runs", out.Rerun)
	}
	first := out.Items[0]
	if first.Title != "High Power — 47:12 left" || first.Arg != "low" {
		t.Errorf("first item = %+v, want the running countdown that stops on ↩", first)
	}
	// The countdown item already offers Low Power, so no separate low item.
	want := []string{"low", "boost 30m --detach", "boost 1h --detach", "boost 2h --detach", "boost unplug --detach", "watch --high 80 --low 20 --detach", ""}
	if got := itemArgs(out); !equal(got, want) {
		t.Errorf("args = %q, want %q", got, want)
	}
}

func TestBoostItem(t *testing.T) {
	ba, err := parseBoostArgs([]string{"90m", "-c"})
	if err != nil {
		t.Fatal(err)
	}
	it := boostItem(ba, now)
	if it.Title != "High Power for 1h30m" || it.Subtitle != "adapter until 15:30 or until unplugged, then back to Low Power · ⌘ keep, ⌥ battery" {
		t.Errorf("boostItem() = %+v", it)
	}
}

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestAlfredItemsRunningUnplug(t *testing.T) {
	st := runstate.State{Label: "battery + adapter", UntilUnplug: true}
	first := alfredItems("", st, true, runstate.State{}, false, now, nil).Items[0]
	if first.Title != "High Power — until unplugged" || first.Arg != "low" {
		t.Errorf("first item = %+v, want the unplug boost that stops on ↩", first)
	}
}

func TestBoostItemBatteryOnly(t *testing.T) {
	ba, err := parseBoostArgs([]string{"1h", "-b"})
	if err != nil {
		t.Fatal(err)
	}
	// Unplugging doesn't end a battery-only boost, so don't claim it does.
	if it := boostItem(ba, now); strings.Contains(it.Subtitle, "unplug") {
		t.Errorf("boostItem(-b).Subtitle = %q, want no unplug mention", it.Subtitle)
	}
}

func TestBoostItemKeep(t *testing.T) {
	ba, err := parseBoostArgs([]string{"2h", "-k"})
	if err != nil {
		t.Fatal(err)
	}
	// --keep ignores the adapter, so don't promise an unplug revert.
	if it := boostItem(ba, now); strings.Contains(it.Subtitle, "unplug") {
		t.Errorf("boostItem(-k).Subtitle = %q, want no unplug mention", it.Subtitle)
	}
}

// Every boost flag must be reachable from Alfred without typing it.
func TestBoostModsCoverEveryFlag(t *testing.T) {
	ba, err := parseBoostArgs([]string{"1h"})
	if err != nil {
		t.Fatal(err)
	}
	mods := boostMods(ba)
	want := map[string]string{
		"cmd":  "boost 1h -k --detach",
		"alt":  "boost 1h -b --detach",
		"ctrl": "boost 1h -c --detach",
	}
	for key, arg := range want {
		m, ok := mods[key]
		if !ok || m.Arg != arg || !m.Valid || m.Subtitle == "" {
			t.Errorf("boostMods()[%q] = %+v, want arg %q", key, m, arg)
		}
	}
}

// --keep is meaningless for a battery-only boost and contradicts unplug, so
// those rows must not offer it.
func TestBoostModsOmitPointlessKeep(t *testing.T) {
	for _, args := range [][]string{{"1h", "-b"}, {"unplug"}} {
		ba, err := parseBoostArgs(args)
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := boostMods(ba)["cmd"]; ok {
			t.Errorf("boostMods(%q) offers --keep", args)
		}
	}
}

func TestStatusItem(t *testing.T) {
	it := statusItem(map[pmset.Source]pmset.Mode{pmset.Battery: pmset.Low, pmset.AC: pmset.High})
	if it.Valid || it.Subtitle != "Battery: low · Adapter: high" {
		t.Errorf("statusItem() = %+v, want an invalid row naming both modes", it)
	}
	if it := statusItem(nil); it.Valid || it.Subtitle == "" {
		t.Errorf("statusItem(nil) = %+v, want an invalid row with a fallback subtitle", it)
	}
}

// TestAlfredItemsWatching checks that a running watcher gets its own row and
// that the row offering to start one is gone.
func TestAlfredItemsWatching(t *testing.T) {
	ws := runstate.State{Label: "High Power from 80%, Low Power below 20%"}
	out := alfredItems("", runstate.State{}, false, ws, true, now, nil)
	got := itemArgs(out)
	want := []string{"low", "boost 30m --detach", "boost 1h --detach", "boost 2h --detach", "boost unplug --detach", "low", ""}
	if !equal(got, want) {
		t.Fatalf("alfredItems(\"\") while watching args = %q, want %q", got, want)
	}
	first := out.Items[0]
	if first.UID != "watching" || !first.Valid || first.Arg != "low" {
		t.Errorf("first item = %+v, want the watching row stopping with low", first)
	}
	if !strings.Contains(first.Subtitle, ws.Label) {
		t.Errorf("watching subtitle = %q, want it to name the thresholds", first.Subtitle)
	}
	// Typing the keyword must not offer a second watcher either.
	if got := itemArgs(alfredItems("watch", runstate.State{}, false, ws, true, now, nil)); len(got) != 1 || got[0] != "low" {
		t.Errorf("alfredItems(\"watch\") while watching args = %q, want just the watching row", got)
	}
}

// TestWatchItemArgParses checks the Alfred row runs a command line the
// binary accepts, so the row can't drift away from the parser.
func TestWatchItemArgParses(t *testing.T) {
	wa := watchArgs{low: defaultLow, high: defaultHigh}
	fields := strings.Fields(watchItem(wa).Arg)
	if fields[0] != "watch" {
		t.Fatalf("watchItem arg = %q, want it to start with watch", fields)
	}
	got, err := parseWatchArgs(fields[1:])
	if err != nil {
		t.Fatalf("parseWatchArgs(%q) error: %v", fields[1:], err)
	}
	if got.low != wa.low || got.high != wa.high || !got.detach {
		t.Errorf("parsed %+v, want %+v detached", got, wa)
	}
}

// TestAlfredItemIconsExist checks every icon a row asks for is really shipped
// in alfred/. Alfred silently falls back to the workflow icon for a missing
// path, so without this a typo or a renamed glyph would only show up by
// eyeballing the result list.
func TestAlfredItemIconsExist(t *testing.T) {
	boosting := runstate.State{Deadline: now.Add(time.Hour), Label: "battery + adapter"}
	unplugging := runstate.State{Label: "battery + adapter", UntilUnplug: true}
	watching := runstate.State{Label: "High Power from 80%, Low Power below 20%"}

	var outs []alfredOutput
	for _, q := range []string{"", "watch", "status", "low", "2h", "unplug", "2h -b", "90m"} {
		outs = append(outs,
			alfredItems(q, runstate.State{}, false, runstate.State{}, false, now, nil),
			alfredItems(q, boosting, true, runstate.State{}, false, now, nil),
			alfredItems(q, unplugging, true, watching, true, now, nil),
			alfredItems(q, runstate.State{}, false, watching, true, now, nil),
		)
	}

	seen := map[string]bool{}
	for _, out := range outs {
		for _, it := range out.Items {
			if it.Icon == nil {
				continue
			}
			if seen[it.Icon.Path] {
				continue
			}
			seen[it.Icon.Path] = true
			// The path is relative to the workflow bundle, which is alfred/.
			if _, err := os.Stat(filepath.Join("..", "..", "..", "alfred", it.Icon.Path)); err != nil {
				t.Errorf("row %q wants icon %q, which isn't in alfred/: %v", it.Title, it.Icon.Path, err)
			}
		}
	}
	if len(seen) == 0 {
		t.Fatal("no row carried an icon")
	}
	t.Logf("icons referenced: %d", len(seen))
}

// TestAlfredEveryValidRowHasAnIcon keeps the result list from going
// half-illustrated: anything the user can actually run should look deliberate.
// The invalid usage row is exempt, since it falls back to the workflow icon.
func TestAlfredEveryValidRowHasAnIcon(t *testing.T) {
	out := alfredItems("", runstate.State{}, false, runstate.State{}, false, now, nil)
	for _, it := range out.Items {
		if it.Icon == nil {
			t.Errorf("row %q has no icon", it.Title)
		}
	}
}
