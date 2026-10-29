package main

import (
	"reflect"
	"testing"

	"mbatterier/internal/pmset"
)

func TestBandOf(t *testing.T) {
	tests := []struct {
		pct  int
		want band
	}{
		{0, bandLow},
		{19, bandLow},
		{20, bandMiddle}, // the low threshold itself is not below it
		{50, bandMiddle},
		{79, bandMiddle},
		{80, bandHigh}, // the high threshold is inclusive
		{81, bandHigh},
		{100, bandHigh},
	}
	for _, tt := range tests {
		if got := bandOf(tt.pct, defaultLow, defaultHigh); got != tt.want {
			t.Errorf("bandOf(%d, %d, %d) = %v, want %v", tt.pct, defaultLow, defaultHigh, got, tt.want)
		}
	}
}

func TestWatchStep(t *testing.T) {
	tests := []struct {
		name     string
		last     band
		pct      int
		wantNext band
		wantMode pmset.Mode
		wantAct  bool
	}{
		{"first reading above high", bandUnknown, 95, bandHigh, pmset.High, true},
		{"first reading exactly at high", bandUnknown, 80, bandHigh, pmset.High, true},
		{"first reading exactly at low", bandUnknown, 20, bandUnknown, 0, false},
		{"first reading one under low", bandUnknown, 19, bandLow, pmset.Low, true},
		{"first reading below low", bandUnknown, 5, bandLow, pmset.Low, true},
		{"first reading in the middle", bandUnknown, 50, bandUnknown, 0, false},
		{"already high", bandHigh, 95, bandHigh, 0, false},
		{"already low", bandLow, 5, bandLow, 0, false},
		{"high to low", bandHigh, 5, bandLow, pmset.Low, true},
		{"low to high", bandLow, 95, bandHigh, pmset.High, true},
		// The middle band keeps last, so the mode is left alone there.
		{"high drifts into the middle", bandHigh, 50, bandHigh, 0, false},
		{"low drifts into the middle", bandLow, 50, bandLow, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			next, m, act := watchStep(tt.last, tt.pct, defaultLow, defaultHigh)
			if next != tt.wantNext || act != tt.wantAct || (act && m != tt.wantMode) {
				t.Errorf("watchStep(%v, %d) = %v, %v, %v, want %v, %v, %v",
					tt.last, tt.pct, next, m, act, tt.wantNext, tt.wantMode, tt.wantAct)
			}
		})
	}
}

// TestWatchStepHysteresis walks a discharge and a recharge through the
// watcher, which is where the middle band earns its keep: the mode is set
// once per crossing, not once per reading.
func TestWatchStepHysteresis(t *testing.T) {
	// 80% acts (the high threshold is inclusive), 79% is already the middle
	// band, and 20% is too: only 19% crosses the low threshold.
	charges := []int{95, 90, 81, 80, 79, 60, 25, 20, 19, 10, 30, 70, 79, 80, 90}
	var acted []string
	last := bandUnknown
	for _, pct := range charges {
		next, m, act := watchStep(last, pct, defaultLow, defaultHigh)
		last = next
		if act {
			acted = append(acted, m.String())
		}
	}
	// High once at 95%, Low once at 19%, High again only on reaching 80%.
	want := []string{"high", "low", "high"}
	if !reflect.DeepEqual(acted, want) {
		t.Errorf("walking %v acted %v, want %v", charges, acted, want)
	}
}

func TestParseWatchArgs(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want watchArgs
	}{
		{"defaults", nil, watchArgs{low: 20, high: 80}},
		{"detach", []string{"-d"}, watchArgs{low: 20, high: 80, detach: true}},
		{"long detach", []string{"--detach"}, watchArgs{low: 20, high: 80, detach: true}},
		{"separate values", []string{"--high", "90", "--low", "15"}, watchArgs{low: 15, high: 90}},
		{"equals values", []string{"--high=90", "--low=15"}, watchArgs{low: 15, high: 90}},
		{"any order", []string{"-d", "--low", "5", "--high=70"}, watchArgs{low: 5, high: 70, detach: true}},
		{"edges", []string{"--low", "0", "--high", "100"}, watchArgs{low: 0, high: 100}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseWatchArgs(tt.args)
			if err != nil {
				t.Fatalf("parseWatchArgs(%q) error: %v", tt.args, err)
			}
			if got != tt.want {
				t.Errorf("parseWatchArgs(%q) = %+v, want %+v", tt.args, got, tt.want)
			}
		})
	}
}

func TestParseWatchArgsErrors(t *testing.T) {
	tests := []struct {
		name string
		args []string
	}{
		{"low above high", []string{"--low", "90", "--high", "10"}},
		{"low equals high", []string{"--low", "50", "--high", "50"}},
		{"over 100", []string{"--high", "101"}},
		{"negative", []string{"--low", "-5"}},
		{"not a number", []string{"--high", "lots"}},
		{"missing value", []string{"--high"}},
		{"value on detach", []string{"--detach=yes"}},
		{"unknown flag", []string{"--medium", "50"}},
		{"stray duration", []string{"1h"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got, err := parseWatchArgs(tt.args); err == nil {
				t.Errorf("parseWatchArgs(%q) = %+v, want an error", tt.args, got)
			}
		})
	}
}

// TestWatchArgsRoundTrip checks that the command line a detached watcher is
// started with parses back to the same thresholds.
func TestWatchArgsRoundTrip(t *testing.T) {
	for _, wa := range []watchArgs{
		{low: 20, high: 80},
		{low: 5, high: 95},
		{low: 0, high: 100},
	} {
		args := wa.args()
		if args[0] != "watch" {
			t.Fatalf("args() = %q, want it to start with watch", args)
		}
		got, err := parseWatchArgs(args[1:])
		if err != nil {
			t.Fatalf("parseWatchArgs(%q) error: %v", args[1:], err)
		}
		if got != wa {
			t.Errorf("round trip of %+v = %+v", wa, got)
		}
	}
}
