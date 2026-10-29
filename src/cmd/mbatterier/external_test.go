package main

import (
	"testing"

	"mbatterier/internal/pmset"
)

func TestSources(t *testing.T) {
	if got := sources(pmset.All); len(got) != 2 || got[0] != pmset.Battery || got[1] != pmset.AC {
		t.Errorf("sources(All) = %v, want [battery ac]", got)
	}
	if got := sources(pmset.AC); len(got) != 1 || got[0] != pmset.AC {
		t.Errorf("sources(AC) = %v, want [ac]", got)
	}
}

func TestExpectationDrift(t *testing.T) {
	bothLow := map[pmset.Source]pmset.Mode{pmset.Battery: pmset.Low, pmset.AC: pmset.Low}
	tests := []struct {
		name    string
		set     func(expectation)
		got     map[pmset.Source]pmset.Mode
		wantSrc pmset.Source
		wantNow pmset.Mode
		wantOK  bool
	}{
		{
			name: "nothing set means no opinion",
			set:  func(e expectation) {},
			got:  map[pmset.Source]pmset.Mode{pmset.Battery: pmset.High, pmset.AC: pmset.High},
		},
		{
			name: "modes still as set",
			set:  func(e expectation) { e.set(pmset.All, pmset.Low) },
			got:  bothLow,
		},
		{
			name:    "macOS switched both to automatic",
			set:     func(e expectation) { e.set(pmset.All, pmset.Low) },
			got:     map[pmset.Source]pmset.Mode{pmset.Battery: pmset.Automatic, pmset.AC: pmset.Automatic},
			wantSrc: pmset.Battery, wantNow: pmset.Automatic, wantOK: true,
		},
		{
			name:    "only the adapter side changed",
			set:     func(e expectation) { e.set(pmset.All, pmset.High) },
			got:     map[pmset.Source]pmset.Mode{pmset.Battery: pmset.High, pmset.AC: pmset.Low},
			wantSrc: pmset.AC, wantNow: pmset.Low, wantOK: true,
		},
		{
			// A boost for the adapter only has no say over the battery side.
			name: "an unset source is not checked",
			set:  func(e expectation) { e.set(pmset.AC, pmset.High) },
			got:  map[pmset.Source]pmset.Mode{pmset.Battery: pmset.Automatic, pmset.AC: pmset.High},
		},
		{
			// A source pmset leaves out is a failed read, not a user's choice.
			name: "an unreported source is not drift",
			set:  func(e expectation) { e.set(pmset.All, pmset.High) },
			got:  map[pmset.Source]pmset.Mode{pmset.AC: pmset.High},
		},
		{
			name: "an empty reading is not drift",
			set:  func(e expectation) { e.set(pmset.All, pmset.High) },
			got:  map[pmset.Source]pmset.Mode{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			e := expectation{}
			tt.set(e)
			src, _, now, ok := e.drift(tt.got)
			if ok != tt.wantOK || (ok && (src != tt.wantSrc || now != tt.wantNow)) {
				t.Errorf("drift() = %v, %v, %v, want %v, %v, %v", src, now, ok, tt.wantSrc, tt.wantNow, tt.wantOK)
			}
		})
	}
}

func TestExpectationClear(t *testing.T) {
	e := expectation{}
	e.set(pmset.All, pmset.High)
	e.clear()
	if len(e) != 0 {
		t.Errorf("after clear() = %v, want empty", e)
	}
	got := map[pmset.Source]pmset.Mode{pmset.Battery: pmset.Low, pmset.AC: pmset.Low}
	if _, _, _, ok := e.drift(got); ok {
		t.Error("a cleared expectation reported drift")
	}
}

func TestDescribe(t *testing.T) {
	got := describe(pmset.AC, pmset.High, pmset.Low)
	want := "adapter power mode changed outside mbatterier (high → low)"
	if got != want {
		t.Errorf("describe() = %q, want %q", got, want)
	}
}
