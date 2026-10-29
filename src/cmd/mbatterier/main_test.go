package main

import (
	"strings"
	"testing"
	"time"

	"mbatterier/internal/charging"
	"mbatterier/internal/pmset"
	"mbatterier/internal/runstate"
)

func TestParseBoostArgs(t *testing.T) {
	tests := []struct {
		args    []string
		dur     time.Duration
		src     pmset.Source
		wantErr bool
	}{
		{args: nil, dur: time.Hour, src: pmset.All},
		{args: []string{"2h"}, dur: 2 * time.Hour, src: pmset.All},
		{args: []string{"90m", "--battery"}, dur: 90 * time.Minute, src: pmset.Battery},
		{args: []string{"-b", "30m"}, dur: 30 * time.Minute, src: pmset.Battery},
		{args: []string{"--ac"}, dur: time.Hour, src: pmset.AC},
		{args: []string{"-b", "-c", "1h"}, dur: time.Hour, src: pmset.All},
		{args: []string{"2h", "--detach"}, dur: 2 * time.Hour, src: pmset.All},
		{args: []string{"-d", "-c"}, dur: time.Hour, src: pmset.AC},
		{args: []string{"0s"}, wantErr: true},
		{args: []string{"-5m"}, wantErr: true},
		{args: []string{"nope"}, wantErr: true},
		{args: []string{"--for", "1h"}, wantErr: true},
		{args: []string{"-u"}, src: pmset.All},
		{args: []string{"unplug", "1h"}, wantErr: true},
		{args: []string{"unplug", "-b"}, wantErr: true},
		{args: []string{"unplug", "-b", "-c"}, src: pmset.All},
		{args: []string{"2h", "-k"}, dur: 2 * time.Hour, src: pmset.All},
		{args: []string{"unplug", "--keep"}, wantErr: true},
	}
	for _, tt := range tests {
		got, err := parseBoostArgs(tt.args)
		if tt.wantErr {
			if err == nil {
				t.Errorf("parseBoostArgs(%q) = %+v, want error", tt.args, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("parseBoostArgs(%q) error: %v", tt.args, err)
			continue
		}
		if got.dur != tt.dur || got.src != tt.src {
			t.Errorf("parseBoostArgs(%q) = {%v %s}, want {%v %s}", tt.args, got.dur, got.src, tt.dur, tt.src)
		}
	}
}

func TestFormatRemaining(t *testing.T) {
	tests := []struct {
		d    time.Duration
		want string
	}{
		{59 * time.Second, "00:59"},
		{47*time.Minute + 12*time.Second, "47:12"},
		{time.Hour, "1:00:00"},
		{2*time.Hour + 5*time.Minute + 3*time.Second, "2:05:03"},
		{1500 * time.Millisecond, "00:02"},
	}
	for _, tt := range tests {
		if got := formatRemaining(tt.d); got != tt.want {
			t.Errorf("formatRemaining(%v) = %q, want %q", tt.d, got, tt.want)
		}
	}
}

func TestParseBoostArgsDetach(t *testing.T) {
	for _, args := range [][]string{{"--detach"}, {"1h", "-d"}} {
		ba, err := parseBoostArgs(args)
		if err != nil || !ba.detach {
			t.Errorf("parseBoostArgs(%q) = %+v, %v, want detach", args, ba, err)
		}
	}
	if ba, _ := parseBoostArgs([]string{"1h"}); ba.detach {
		t.Error(`parseBoostArgs(["1h"]) sets detach`)
	}
}

func TestBoostArgsArgs(t *testing.T) {
	tests := []struct {
		in   []string
		want string
	}{
		{nil, "boost 1h"},
		{[]string{"90m", "--detach"}, "boost 1h30m"},
		{[]string{"-b", "45m"}, "boost 45m -b"},
		{[]string{"--ac", "2h"}, "boost 2h -c"},
		{[]string{"-u", "-c", "-d"}, "boost unplug -c"},
		{[]string{"-k", "2h"}, "boost 2h -k"},
	}
	for _, tt := range tests {
		ba, err := parseBoostArgs(tt.in)
		if err != nil {
			t.Fatalf("parseBoostArgs(%q) error: %v", tt.in, err)
		}
		if got := strings.Join(ba.args(), " "); got != tt.want {
			t.Errorf("args() for %q = %q, want %q", tt.in, got, tt.want)
		}
	}
}

func TestFormatDuration(t *testing.T) {
	tests := []struct {
		d    time.Duration
		want string
	}{
		{time.Hour, "1h"},
		{90 * time.Minute, "1h30m"},
		{45 * time.Minute, "45m"},
		{90 * time.Second, "1m30s"},
		{2*time.Hour + 30*time.Second, "2h0m30s"},
	}
	for _, tt := range tests {
		if got := formatDuration(tt.d); got != tt.want {
			t.Errorf("formatDuration(%v) = %q, want %q", tt.d, got, tt.want)
		}
	}
}

func TestUnplugStep(t *testing.T) {
	base := time.Date(2026, 10, 27, 12, 0, 0, 0, time.Local)
	tests := []struct {
		name     string
		seenAC   bool
		offSince time.Time
		ac       bool
		now      time.Time
		wantSeen bool
		wantOff  time.Time
		wantEnd  bool
	}{
		{name: "arms on the adapter", ac: true, now: base, wantSeen: true},
		{name: "stays on the adapter", seenAC: true, ac: true, now: base, wantSeen: true},
		{name: "unplugged, grace starts", seenAC: true, now: base, wantSeen: true, wantOff: base},
		{name: "unplugged, within grace", seenAC: true, offSince: base, now: base.Add(59 * time.Second),
			wantSeen: true, wantOff: base},
		{name: "unplugged, grace over", seenAC: true, offSince: base, now: base.Add(time.Minute),
			wantSeen: true, wantOff: base, wantEnd: true},
		{name: "plugged back in within grace", seenAC: true, offSince: base, ac: true, now: base.Add(30 * time.Second),
			wantSeen: true},
		{name: "started on battery, waits for the adapter", now: base},
	}
	for _, tt := range tests {
		seen, off, end := unplugStep(tt.seenAC, tt.offSince, tt.ac, tt.now, time.Minute)
		if seen != tt.wantSeen || !off.Equal(tt.wantOff) || end != tt.wantEnd {
			t.Errorf("%s: unplugStep(%v, %v, %v, %v) = %v, %v, %v, want %v, %v, %v", tt.name,
				tt.seenAC, tt.offSince, tt.ac, tt.now, seen, off, end, tt.wantSeen, tt.wantOff, tt.wantEnd)
		}
	}
}

// Unplugging and plugging back in repeatedly, faster than the grace period,
// must never end the boost.
func TestUnplugStepFlapping(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.Local)
	seen, off := true, time.Time{}
	for i := 0; i < 20; i++ {
		for _, ac := range []bool{false, false, true} { // ~40s off, then back on
			var end bool
			seen, off, end = unplugStep(seen, off, ac, now, time.Minute)
			if end {
				t.Fatalf("iteration %d: boost ended on a brief unplug", i)
			}
			now = now.Add(20 * time.Second)
		}
	}
}

func TestParseBoostArgsKeep(t *testing.T) {
	for _, args := range [][]string{{"2h", "--keep"}, {"-k", "2h"}} {
		ba, err := parseBoostArgs(args)
		if err != nil || !ba.keep {
			t.Errorf("parseBoostArgs(%q) = %+v, %v, want keep", args, ba, err)
		}
	}
	if ba, _ := parseBoostArgs([]string{"2h"}); ba.keep {
		t.Error(`parseBoostArgs(["2h"]) sets keep`)
	}
}

func TestStatusJSONDoc(t *testing.T) {
	now := time.Date(2026, 10, 27, 14, 0, 0, 0, time.UTC)
	modes := map[pmset.Source]pmset.Mode{pmset.Battery: pmset.Low, pmset.AC: pmset.High}

	t.Run("on battery with an estimate", func(t *testing.T) {
		ps := pmset.PS{Percent: 87, Remaining: 2*time.Hour + 41*time.Minute}
		doc := statusJSONDoc(ps, charging.State{}, modes, runstate.State{}, runstate.State{}, false, false, now)
		if doc.Percent != 87 || doc.OnAC || doc.Charging || doc.RemainingMinutes != 161 {
			t.Errorf("got %+v, want 87%%, on battery, not charging, 161 minutes", doc)
		}
		if doc.Modes["battery"] != "low" || doc.Modes["ac"] != "high" {
			t.Errorf("Modes = %v, want battery low and ac high", doc.Modes)
		}
		if doc.Boost != nil || doc.Watch != nil {
			t.Errorf("Boost = %+v, Watch = %+v, want both nil", doc.Boost, doc.Watch)
		}
	})

	t.Run("on the adapter, not charging", func(t *testing.T) {
		ps := pmset.PS{Percent: 80, OnAC: true}
		doc := statusJSONDoc(ps, charging.State{}, modes, runstate.State{}, runstate.State{}, false, false, now)
		if !doc.OnAC || doc.Charging || doc.RemainingMinutes != 0 {
			t.Errorf("got %+v, want on the adapter, not charging, no estimate", doc)
		}
	})

	t.Run("charging", func(t *testing.T) {
		ps := pmset.PS{Percent: 87, OnAC: true, Charging: true, Remaining: 38 * time.Minute}
		doc := statusJSONDoc(ps, charging.State{}, modes, runstate.State{}, runstate.State{}, false, false, now)
		if !doc.OnAC || !doc.Charging || doc.RemainingMinutes != 38 {
			t.Errorf("got %+v, want on the adapter, charging, 38 minutes", doc)
		}
	})

	t.Run("charge limit and slow charger on the adapter", func(t *testing.T) {
		ps := pmset.PS{Percent: 31, OnAC: true, Charging: true}
		doc := statusJSONDoc(ps, charging.State{Limit: 80, Slow: true}, modes, runstate.State{}, runstate.State{}, false, false, now)
		if doc.ChargeLimit != 80 || !doc.SlowCharger {
			t.Errorf("ChargeLimit = %d, SlowCharger = %v, want 80 and true", doc.ChargeLimit, doc.SlowCharger)
		}
	})

	t.Run("no slow charger on battery", func(t *testing.T) {
		ps := pmset.PS{Percent: 31}
		doc := statusJSONDoc(ps, charging.State{Limit: 80, Slow: true}, modes, runstate.State{}, runstate.State{}, false, false, now)
		if doc.SlowCharger || doc.ChargeLimit != 80 {
			t.Errorf("SlowCharger = %v, ChargeLimit = %d, want false and 80", doc.SlowCharger, doc.ChargeLimit)
		}
	})

	t.Run("no battery", func(t *testing.T) {
		ps := pmset.PS{Percent: pmset.NoBattery, OnAC: true}
		doc := statusJSONDoc(ps, charging.State{}, modes, runstate.State{}, runstate.State{}, false, false, now)
		if doc.Percent != -1 {
			t.Errorf("Percent = %d, want -1", doc.Percent)
		}
	})

	t.Run("a source pmset does not report is missing", func(t *testing.T) {
		doc := statusJSONDoc(pmset.PS{}, charging.State{}, map[pmset.Source]pmset.Mode{pmset.AC: pmset.Low},
			runstate.State{}, runstate.State{}, false, false, now)
		if _, ok := doc.Modes["battery"]; ok {
			t.Errorf("Modes = %v, want no battery key", doc.Modes)
		}
	})

	t.Run("a running watcher", func(t *testing.T) {
		watch := runstate.State{Label: "High Power from 80%, Low Power below 20%"}
		doc := statusJSONDoc(pmset.PS{}, charging.State{}, modes, runstate.State{}, watch, false, true, now)
		if doc.Watch == nil || doc.Watch.Label != watch.Label {
			t.Fatalf("Watch = %+v, want the thresholds label", doc.Watch)
		}
		// A watcher has no deadline, so it never carries a countdown.
		if doc.Watch.RemainingSeconds != 0 {
			t.Errorf("Watch.RemainingSeconds = %d, want 0", doc.Watch.RemainingSeconds)
		}
	})

	t.Run("a running boost with a deadline", func(t *testing.T) {
		boost := runstate.State{Label: "battery + adapter", Deadline: now.Add(47*time.Minute + 12*time.Second)}
		doc := statusJSONDoc(pmset.PS{}, charging.State{}, modes, boost, runstate.State{}, true, false, now)
		if doc.Boost == nil || doc.Boost.RemainingSeconds != 2832 || doc.Boost.UntilUnplug {
			t.Errorf("Boost = %+v, want 2832 seconds left and not until_unplug", doc.Boost)
		}
	})

	t.Run("a boost until unplugged has no countdown", func(t *testing.T) {
		boost := runstate.State{Label: "adapter", UntilUnplug: true}
		doc := statusJSONDoc(pmset.PS{}, charging.State{}, modes, boost, runstate.State{}, true, false, now)
		if doc.Boost == nil || !doc.Boost.UntilUnplug || doc.Boost.RemainingSeconds != 0 {
			t.Errorf("Boost = %+v, want until_unplug and no countdown", doc.Boost)
		}
	})

	t.Run("a deadline already passed reports no time left", func(t *testing.T) {
		boost := runstate.State{Label: "battery + adapter", Deadline: now.Add(-time.Minute)}
		doc := statusJSONDoc(pmset.PS{}, charging.State{}, modes, boost, runstate.State{}, true, false, now)
		if doc.Boost == nil || doc.Boost.RemainingSeconds != 0 {
			t.Errorf("Boost = %+v, want no negative countdown", doc.Boost)
		}
	})
}

func TestParseBoostArgsAlways(t *testing.T) {
	ba, err := parseBoostArgs([]string{"always"})
	if err != nil || !ba.always || ba.dur != 0 || ba.src != pmset.All {
		t.Errorf(`parseBoostArgs(["always"]) = %+v, %v, want always on both sources`, ba, err)
	}
	if got := ba.args(); !equal(got, []string{"boost", "always"}) {
		t.Errorf("args() = %q, want boost always", got)
	}
	for _, args := range [][]string{{"always", "1h"}, {"always", "unplug"}} {
		if _, err := parseBoostArgs(args); err == nil {
			t.Errorf("parseBoostArgs(%q) succeeded, want an error", args)
		}
	}
}

func TestStatusJSONDocAlways(t *testing.T) {
	now := time.Date(2026, 10, 27, 14, 0, 0, 0, time.UTC)
	boost := runstate.State{Label: "battery + adapter", Always: true}
	doc := statusJSONDoc(pmset.PS{}, charging.State{}, nil, boost, runstate.State{}, true, false, now)
	if doc.Boost == nil || !doc.Boost.Always || doc.Boost.RemainingSeconds != 0 {
		t.Errorf("Boost = %+v, want always with no countdown", doc.Boost)
	}
}
