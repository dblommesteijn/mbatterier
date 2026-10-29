package main

import (
	"fmt"
	"time"

	"mbatterier/internal/pmset"
)

// modeCheckEvery is how often a running boost or watcher looks at the power
// mode even when nothing prompted it. pmset.Changes is the fast path, but it
// watches a directory for a side effect of a mode switch rather than for the
// switch itself, so this bounds how long a switch can go unnoticed if that
// ever stops firing. One pmset exec every few seconds is cheap.
const modeCheckEvery = 3 * time.Second

// modeSettle is how long a suspected change has to hold before it counts.
// Setting both sources is more than one write, and a boost replacing another
// reverts and raises the mode in quick succession; reading in the middle of
// either would see a change that is entirely our own.
const modeSettle = 400 * time.Millisecond

// expectation is the power mode a boost or watcher last set on each source, so
// it can tell its own writes from anyone else's. A source it has not set is
// not checked: it has no opinion about that one.
type expectation map[pmset.Source]pmset.Mode

// sources expands src into the sources it covers.
func sources(src pmset.Source) []pmset.Source {
	if src == pmset.All {
		return []pmset.Source{pmset.Battery, pmset.AC}
	}
	return []pmset.Source{src}
}

// set records that mode m was just set on src.
func (e expectation) set(src pmset.Source, m pmset.Mode) {
	for _, s := range sources(src) {
		e[s] = m
	}
}

// clear forgets everything, for when another holder takes over the mode.
func (e expectation) clear() {
	for s := range e {
		delete(e, s)
	}
}

// drift reports the first source whose mode is no longer what was set, which
// means something else changed it: macOS itself (Control Center, System
// Settings) or another tool. A source pmset does not report is not drift, so a
// failed or partial read can never look like a user's choice.
func (e expectation) drift(got map[pmset.Source]pmset.Mode) (src pmset.Source, was, now pmset.Mode, ok bool) {
	for _, s := range []pmset.Source{pmset.Battery, pmset.AC} {
		want, set := e[s]
		have, reported := got[s]
		if set && reported && have != want {
			return s, want, have, true
		}
	}
	return "", 0, 0, false
}

// describe renders a drift for the log.
func describe(src pmset.Source, was, now pmset.Mode) string {
	name := map[pmset.Source]string{pmset.Battery: "battery", pmset.AC: "adapter"}[src]
	return fmt.Sprintf("%s power mode changed outside mbatterier (%s → %s)", name, was, now)
}

// externalChange reads the power mode and reports a drift from e. A read
// error is not drift: with the mode unknown there is nothing to conclude.
//
// A drift is only reported if it is still there modeSettle later, so the
// common false alarms — a half-finished write of our own, a boost handing over
// to another — settle back into what was expected and are ignored.
func externalChange(e expectation) (string, bool) {
	if _, _, _, ok := currentDrift(e); !ok {
		return "", false
	}
	time.Sleep(modeSettle)
	src, was, now, ok := currentDrift(e)
	if !ok {
		return "", false
	}
	return describe(src, was, now), true
}

// currentDrift is one reading of the mode compared with e.
func currentDrift(e expectation) (src pmset.Source, was, now pmset.Mode, ok bool) {
	if len(e) == 0 {
		return "", 0, 0, false
	}
	got, err := pmset.Get()
	if err != nil {
		return "", 0, 0, false
	}
	return e.drift(got)
}
