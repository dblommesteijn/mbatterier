package main

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"mbatterier/internal/pmset"
	"mbatterier/internal/runstate"
)

// The default battery charge thresholds, in percent: High Power from
// defaultHigh up, Low Power below defaultLow, and the mode left alone
// between. The high threshold is inclusive, the low one isn't, so a charge of
// exactly 80% is already High Power while 20% is still the middle band.
const (
	defaultHigh = 80
	defaultLow  = 20
)

// watchEvery is how often the battery charge is checked. The charge moves by
// a percent in minutes, not seconds, so this is much slower than the boost's
// unplug poll.
const watchEvery = time.Minute

// band is where a battery charge sits relative to the thresholds.
type band int

const (
	bandUnknown band = iota // nothing applied yet, so the next reading acts
	bandMiddle              // between the thresholds: the mode is left alone
	bandLow                 // below the low threshold
	bandHigh                // above the high threshold
)

// bandOf places a charge of pct relative to the thresholds. high is
// inclusive and low is not, so the middle band is low <= pct < high.
func bandOf(pct, low, high int) band {
	switch {
	case pct >= high:
		return bandHigh
	case pct < low:
		return bandLow
	}
	return bandMiddle
}

// watchStep applies the threshold rule to one battery reading. last is the
// band the watcher last acted on, and next is what to remember.
//
// The middle band keeps last instead of resetting it, which is what makes the
// rule a hysteresis: a charge drifting high → middle → high doesn't set High
// Power twice, and a mode set by hand in the middle band stays until the
// charge really crosses a threshold.
func watchStep(last band, pct, low, high int) (next band, m pmset.Mode, act bool) {
	cur := bandOf(pct, low, high)
	if cur == bandMiddle || cur == last {
		return last, 0, false
	}
	if cur == bandHigh {
		return cur, pmset.High, true
	}
	return cur, pmset.Low, true
}

// watchArgs is the parsed command line of `watch`.
type watchArgs struct {
	low, high int
	detach    bool
}

// parseWatchArgs parses the thresholds and flags of `watch`, in any order.
// A threshold takes its value as the next argument or after an `=`:
// `--high 85` and `--high=85` are the same.
func parseWatchArgs(args []string) (watchArgs, error) {
	wa := watchArgs{low: defaultLow, high: defaultHigh}
	for i := 0; i < len(args); i++ {
		name, val, hasVal := cutFlag(args[i])
		switch name {
		case "--detach", "-d":
			if hasVal {
				return watchArgs{}, fmt.Errorf("%s takes no value", name)
			}
			wa.detach = true
			continue
		case "--high", "--low":
		default:
			return watchArgs{}, fmt.Errorf("unknown argument %q (use --high N, --low N, --detach)", args[i])
		}
		if !hasVal {
			i++
			if i == len(args) {
				return watchArgs{}, fmt.Errorf("%s needs a percentage", name)
			}
			val = args[i]
		}
		pct, err := strconv.Atoi(val)
		if err != nil || pct < 0 || pct > 100 {
			return watchArgs{}, fmt.Errorf("invalid percentage %q for %s (use 0–100)", val, name)
		}
		if name == "--high" {
			wa.high = pct
		} else {
			wa.low = pct
		}
	}
	if wa.low >= wa.high {
		return watchArgs{}, fmt.Errorf("--low (%d) must be below --high (%d)", wa.low, wa.high)
	}
	return wa, nil
}

// cutFlag splits `--high=85` into its name and value.
func cutFlag(arg string) (name, val string, hasVal bool) {
	name, val, hasVal = strings.Cut(arg, "=")
	return name, val, hasVal
}

// args returns the normalized command line for wa, without --detach.
func (wa watchArgs) args() []string {
	return []string{"watch", "--high", strconv.Itoa(wa.high), "--low", strconv.Itoa(wa.low)}
}

// label describes wa the way `status` and Alfred show it.
func (wa watchArgs) label() string {
	return fmt.Sprintf("High Power from %d%%, Low Power below %d%%", wa.high, wa.low)
}

// readCharge reads the battery charge, treating a Mac without a battery as an
// error: there is nothing to watch, and a desktop shouldn't sit on High Power
// because pmset reported no percentage.
func readCharge() (pmset.PS, error) {
	ps, err := pmset.Read()
	if err != nil {
		return pmset.PS{}, err
	}
	if ps.Percent == pmset.NoBattery {
		return pmset.PS{}, errors.New("pmset reports no battery")
	}
	return ps, nil
}

func watch(args []string) error {
	if len(args) == 1 && args[0] == "stop" {
		requireRoot()
		return unwatch()
	}
	wa, err := parseWatchArgs(args)
	if err != nil {
		return err
	}

	requireRoot()

	if wa.detach {
		return detach(wa.args())
	}
	var n notifier
	if os.Getenv(readyEnv) == "3" {
		n.f = os.NewFile(3, "ready")
	}
	err = runWatch(wa, &n)
	n.done("", err)
	return err
}

// runWatch follows the battery charge and sets the power mode on every
// threshold crossing, until a signal stops it. Like a boost it ends in Low
// Power, so stopping the watcher never leaves High Power on.
func runWatch(wa watchArgs, n *notifier) error {
	// Install the handler before the first switch so an early Ctrl-C reverts.
	sigs := make(chan os.Signal, 1)
	// SIGUSR1 is a boost telling us the user took over the power mode.
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGUSR1)

	lock, stopped, err := runstate.Acquire(runstate.Watch)
	if err != nil {
		return err
	}
	defer lock.Release()

	if err := lock.Save(runstate.State{Label: wa.label()}); err != nil {
		return err
	}
	msg := "watching the battery: " + wa.label()
	if stopped {
		msg += ", replacing the running watcher"
	}
	logf("%s", msg)
	n.done(msg, nil)

	ticker := time.NewTicker(watchEvery)
	defer ticker.Stop()
	modeTicker := time.NewTicker(modeCheckEvery)
	defer modeTicker.Stop()
	// What we last set, so a change by anyone else can be told apart from ours.
	set := expectation{}
	changes, stopChanges, err := pmset.Changes()
	if err != nil {
		// Not fatal: the periodic check below still catches a switch.
		fmt.Fprintln(os.Stderr, "error:", err)
		changes, stopChanges = nil, func() {}
	}
	defer stopChanges()
	// drifted reports whether the user changed the mode since we set it. It
	// says no while a boost runs: the boost changes the mode on purpose, and
	// the mode is only ours to defend again once it has gone.
	drifted := func() (string, bool) {
		if _, boosting := runstate.Current(runstate.Boost); boosting {
			return "", false
		}
		return externalChange(set)
	}
	last := bandUnknown
	readErrors := 0
	reason := ""
	handedOver := false // the user changed the mode, so we leave it alone
loop:
	for {
		// A boost is a deliberate override, so stand back while one runs and
		// re-read the charge from scratch once it's gone.
		if _, boosting := runstate.Current(runstate.Boost); boosting {
			last = bandUnknown
			set.clear()
		} else if ps, err := readCharge(); err != nil {
			readErrors++
			fmt.Fprintln(os.Stderr, "error:", err)
			if readErrors >= maxPollErrors {
				reason = "can't read the battery charge"
				break loop
			}
		} else {
			readErrors = 0
			next, m, act := watchStep(last, ps.Percent, wa.low, wa.high)
			last = next
			if act {
				if err := pmset.Set(pmset.All, m); err != nil {
					return err
				}
				set.set(pmset.All, m)
				logf("battery %d%%: %s power on battery + adapter", ps.Percent, m)
			}
		}
	wait:
		for {
			select {
			case s := <-sigs:
				reason = "got " + s.String()
				handedOver = s == syscall.SIGUSR1
				break loop
			case <-changes:
				if msg, ok := drifted(); ok {
					reason, handedOver = msg, true
					break loop
				}
			case <-modeTicker.C:
				if msg, ok := drifted(); ok {
					reason, handedOver = msg, true
					break loop
				}
			case <-ticker.C:
				break wait
			}
		}
	}

	if handedOver {
		// The user took over. Reverting to Low Power now would undo what they
		// just chose, so the rule that every exit ends in Low Power gives way
		// here, and only here. This is a clean exit, so a LaunchDaemon with
		// SuccessfulExit false leaves the watcher stopped.
		logf("%s: stopped watching, leaving the power mode as it is", reason)
		return nil
	}
	if err := setLow(); err != nil {
		return err
	}
	logf("%s: stopped watching, back to Low Power (battery + adapter)", reason)
	return nil
}

// unwatch stops the running watcher and leaves a boost alone. Unlike every
// other stop it keeps the power mode as it is: turning watching off is not a
// request for Low Power, so the watcher is asked to stand down, the same exit
// it takes when the user switches the mode in macOS.
func unwatch() error {
	if !runstate.StandDown(runstate.Watch) {
		fmt.Println("No watcher running")
		return nil
	}
	// Wait for it to go before returning, so a status read straight after
	// doesn't still see it. Acquire is not used for this: on a lock it can't
	// take it sends SIGTERM, which is the revert to Low Power.
	if err := runstate.WaitGone(runstate.Watch); err != nil {
		return err
	}
	fmt.Println("Stopped the watcher, power mode left as it is")
	return nil
}
