// Package runstate tracks the running boost and the running battery watcher,
// so that only one of each runs at a time and other commands can stop it or
// show its deadline.
//
// Each holder takes an exclusive flock on its lock file for its whole
// lifetime and writes its PID and deadline to its state file. The OS releases
// the flock when the process dies, even on kill -9, so a crashed boost never
// blocks the next one. Boost and Watch have separate files, so a watcher and
// a boost can run at the same time: the watcher stands back while a boost
// holds the boost lock.
package runstate

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// Dir holds the lock and state files. /var/run is root-owned, so other users
// can't plant files there for the root process to follow.
var Dir = "/var/run"

// Kind is what a lock covers. Each kind has its own lock and state file, so
// the two never block each other.
type Kind string

// The lock kinds, named after the file pair they use in Dir.
const (
	Boost Kind = "mbatterier"
	Watch Kind = "mbatterier.watch"
)

// stop asks the running boost to exit. Tests replace it.
var stop = func(pid int) error { return syscall.Kill(pid, syscall.SIGTERM) }

// StandDown asks the running holder of kind k to exit and leave the power mode
// exactly as it is, instead of reverting to Low Power the way SIGTERM does. It
// is for when the user has taken over — switched the mode in macOS — and
// whatever mbatterier did next would undo their choice. It reports whether
// there was a holder to ask.
func StandDown(k Kind) bool {
	st, ok := Current(k)
	if !ok {
		return false
	}
	return syscall.Kill(st.PID, syscall.SIGUSR1) == nil
}

// Dismiss asks the running holder of kind k to exit and leave the power mode
// as it is, like StandDown, but as a plain stop rather than the user taking
// over: a boost dismissed this way doesn't stand the watcher down with it. It
// reports whether there was a holder to ask.
func Dismiss(k Kind) bool {
	st, ok := Current(k)
	if !ok {
		return false
	}
	return syscall.Kill(st.PID, syscall.SIGUSR2) == nil
}

// WaitGone waits up to takeoverTimeout for the holder of kind k to exit.
func WaitGone(k Kind) error {
	giveUp := time.Now().Add(takeoverTimeout)
	for {
		if _, running := Current(k); !running {
			return nil
		}
		if time.Now().After(giveUp) {
			return fmt.Errorf("the running %s didn't stop in time", k.what())
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// takeoverTimeout bounds how long Acquire waits for a running boost to exit.
const takeoverTimeout = 10 * time.Second

// State describes the running boost or watcher. A watcher has no Deadline;
// its Label holds its thresholds.
type State struct {
	PID int `json:"pid"`
	// Deadline is when a boost ends. Zero means it has none.
	Deadline time.Time `json:"deadline"`
	Label    string    `json:"label"`
	// UntilUnplug means the boost has no deadline and ends on unplug.
	UntilUnplug bool `json:"until_unplug,omitempty"`
	// Always means the boost has no deadline and runs until stopped.
	Always bool `json:"always,omitempty"`
}

// Lock is a held lock of one kind.
type Lock struct {
	kind Kind
	f    *os.File
}

func lockPath(k Kind) string  { return filepath.Join(Dir, string(k)+".lock") }
func statePath(k Kind) string { return filepath.Join(Dir, string(k)+".json") }

// Acquire takes the lock of kind k. If a process holds it, Acquire sends it
// SIGTERM, so it reverts to Low Power, and waits for it to exit. stopped
// reports whether a running holder was stopped. It needs root.
func Acquire(k Kind) (l *Lock, stopped bool, err error) {
	f, err := os.OpenFile(lockPath(k), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, false, err
	}
	giveUp := time.Now().Add(takeoverTimeout)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			// Drop state left behind by a holder that crashed.
			os.Remove(statePath(k))
			return &Lock{kind: k, f: f}, stopped, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			f.Close()
			return nil, false, fmt.Errorf("lock %s: %w", lockPath(k), err)
		}
		if time.Now().After(giveUp) {
			f.Close()
			return nil, stopped, fmt.Errorf("the running %s didn't stop in time", k.what())
		}
		// The holder writes its state right after locking, so retry until
		// its PID shows up.
		if !stopped {
			if st, err := read(k); err == nil && st.PID > 0 && stop(st.PID) == nil {
				stopped = true
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// Save records st as the running holder, with the current process as its PID.
func (l *Lock) Save(st State) error {
	st.PID = os.Getpid()
	b, err := json.Marshal(st)
	if err != nil {
		return err
	}
	tmp := statePath(l.kind) + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, statePath(l.kind))
}

// Release removes the state and releases the lock.
func (l *Lock) Release() {
	os.Remove(statePath(l.kind))
	l.f.Close()
}

// Current returns the running holder of kind k, if any. It doesn't need root.
func Current(k Kind) (State, bool) {
	st, err := read(k)
	if err != nil || expired(st, time.Now()) {
		return State{}, false
	}
	// EPERM means the process exists but belongs to root.
	if err := syscall.Kill(st.PID, 0); err != nil && !errors.Is(err, syscall.EPERM) {
		return State{}, false
	}
	return st, true
}

// expired reports whether st names a boost whose deadline has passed. A
// watcher and a `boost unplug` have no deadline, so they never expire: only
// the PID check in Current retires those.
func expired(st State, now time.Time) bool {
	if st.UntilUnplug || st.Deadline.IsZero() {
		return false
	}
	return !now.Before(st.Deadline)
}

// what names the kind in an error message.
func (k Kind) what() string {
	if k == Watch {
		return "watcher"
	}
	return "boost"
}

func read(k Kind) (State, error) {
	b, err := os.ReadFile(statePath(k))
	if err != nil {
		return State{}, err
	}
	var st State
	if err := json.Unmarshal(b, &st); err != nil {
		return State{}, fmt.Errorf("parse %s: %w", statePath(k), err)
	}
	return st, nil
}
