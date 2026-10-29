package runstate

import (
	"os"
	"testing"
	"time"
)

func setup(t *testing.T) {
	t.Helper()
	Dir = t.TempDir()
	orig := stop
	t.Cleanup(func() { stop = orig })
}

func TestSaveCurrentRelease(t *testing.T) {
	setup(t)
	if _, ok := Current(Boost); ok {
		t.Fatal("Current(Boost) reports a boost before any was saved")
	}

	l, stopped, err := Acquire(Boost)
	if err != nil {
		t.Fatalf("Acquire(Boost) error: %v", err)
	}
	if stopped {
		t.Error("Acquire(Boost) stopped a boost, but none was running")
	}
	want := State{Deadline: time.Now().Add(time.Hour).Round(0), Label: "battery"}
	if err := l.Save(want); err != nil {
		t.Fatalf("Save() error: %v", err)
	}

	got, ok := Current(Boost)
	if !ok {
		t.Fatal("Current(Boost) reports no boost after Save")
	}
	if got.PID != os.Getpid() || got.Label != want.Label || !got.Deadline.Equal(want.Deadline) {
		t.Errorf("Current(Boost) = %+v, want PID %d and %+v", got, os.Getpid(), want)
	}

	l.Release()
	if _, ok := Current(Boost); ok {
		t.Error("Current(Boost) reports a boost after Release")
	}
}

func TestCurrentIgnoresPastDeadline(t *testing.T) {
	setup(t)
	l, _, err := Acquire(Boost)
	if err != nil {
		t.Fatalf("Acquire(Boost) error: %v", err)
	}
	defer l.Release()
	if err := l.Save(State{Deadline: time.Now().Add(-time.Second)}); err != nil {
		t.Fatalf("Save() error: %v", err)
	}
	if _, ok := Current(Boost); ok {
		t.Error("Current(Boost) reports a boost whose deadline has passed")
	}
}

func TestAcquireStopsRunningBoost(t *testing.T) {
	setup(t)
	held, _, err := Acquire(Boost)
	if err != nil {
		t.Fatalf("Acquire(Boost) error: %v", err)
	}
	if err := held.Save(State{Deadline: time.Now().Add(time.Hour)}); err != nil {
		t.Fatalf("Save() error: %v", err)
	}

	// The running boost exits when it's asked to stop.
	var stoppedPID int
	stop = func(pid int) error {
		stoppedPID = pid
		held.Release()
		return nil
	}

	l, stopped, err := Acquire(Boost)
	if err != nil {
		t.Fatalf("second Acquire(Boost) error: %v", err)
	}
	defer l.Release()
	if !stopped || stoppedPID != os.Getpid() {
		t.Errorf("second Acquire(Boost) stopped = %v (pid %d), want true (pid %d)", stopped, stoppedPID, os.Getpid())
	}
}

// TestKindsAreIndependent checks that a watcher and a boost can hold their
// locks at the same time, which is what lets the watcher stand back during a
// boost instead of being killed by it.
func TestKindsAreIndependent(t *testing.T) {
	setup(t)
	stop = func(pid int) error { t.Fatalf("one kind stopped the other (pid %d)", pid); return nil }

	boost, stopped, err := Acquire(Boost)
	if err != nil {
		t.Fatalf("Acquire(Boost) error: %v", err)
	}
	defer boost.Release()
	if stopped {
		t.Error("Acquire(Boost) stopped something, but nothing was running")
	}
	watch, stopped, err := Acquire(Watch)
	if err != nil {
		t.Fatalf("Acquire(Watch) error: %v", err)
	}
	defer watch.Release()
	if stopped {
		t.Error("Acquire(Watch) stopped the boost, but the kinds are separate")
	}

	if err := boost.Save(State{Deadline: time.Now().Add(time.Hour), Label: "battery + adapter"}); err != nil {
		t.Fatalf("Boost Save() error: %v", err)
	}
	if err := watch.Save(State{Label: "High Power from 80%, Low Power below 20%"}); err != nil {
		t.Fatalf("Watch Save() error: %v", err)
	}
	b, ok := Current(Boost)
	if !ok || b.Label != "battery + adapter" {
		t.Errorf("Current(Boost) = %+v, %v, want the boost", b, ok)
	}
	w, ok := Current(Watch)
	if !ok || w.Label != "High Power from 80%, Low Power below 20%" {
		t.Errorf("Current(Watch) = %+v, %v, want the watcher", w, ok)
	}

	// Releasing one leaves the other alone.
	watch.Release()
	if _, ok := Current(Watch); ok {
		t.Error("Current(Watch) reports a watcher after Release")
	}
	if _, ok := Current(Boost); !ok {
		t.Error("releasing the watch lock dropped the boost state")
	}
}

func TestExpired(t *testing.T) {
	now := time.Date(2026, 10, 27, 14, 0, 0, 0, time.Local)
	tests := []struct {
		name string
		st   State
		want bool
	}{
		{"deadline passed", State{Deadline: now.Add(-time.Second)}, true},
		{"deadline ahead", State{Deadline: now.Add(time.Minute)}, false},
		// A watcher has no deadline, and neither has `boost unplug`.
		{"no deadline", State{Label: "watching"}, false},
		{"until unplug", State{Deadline: now.Add(-time.Hour), UntilUnplug: true}, false},
	}
	for _, tt := range tests {
		if got := expired(tt.st, now); got != tt.want {
			t.Errorf("%s: expired(%+v) = %v, want %v", tt.name, tt.st, got, tt.want)
		}
	}
}
