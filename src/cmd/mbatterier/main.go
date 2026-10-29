// Command mbatterier turns on macOS High Power mode for a set time, then
// switches back to Low Power.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"mbatterier/internal/charging"
	"mbatterier/internal/pmset"
	"mbatterier/internal/runstate"
)

const usage = `mbatterier (alias: mbat) — timed High Power mode, Low Power by default

Usage:
  mbat boost [duration] [--battery|--ac] [--keep] [--detach]
                                                      High Power for a while, then back to Low Power
  mbat boost unplug [--battery|--ac] [--detach]       High Power until the adapter is unplugged
  mbat boost always [--battery|--ac] [--detach]       High Power until stopped, whatever the adapter does
  mbat boost stop                                     Stop the running boost only, leave the power mode as it is
  mbat watch [--high N] [--low N] [--detach]          Follow the battery: High Power from N%, Low Power below N%
  mbat watch stop                                     Stop the running watcher only, leave the power mode as it is
  mbat low                                            Stop a running boost and watcher, Low Power on battery and adapter
  mbat off                                            Stop a running boost and watcher, give the power mode back to macOS (Automatic)
  mbat status [--json]                                Show current power mode, any running boost and watcher
  mbat energy [--json]                                Show your apps using significant energy (needs root)
  mbat alfred [query]                                 Alfred Script Filter output (JSON)

Boost:
  duration       e.g. 30m, 1h, 1h30m, 2h (default 1h)
  unplug, -u     instead of a duration: no time limit, run until unplugged
  always         instead of a duration: no time limit and no unplug guard
  -b, --battery  only boost on battery
  -c, --ac       only boost on adapter
  -k, --keep     run the full duration whatever happens to the adapter
  -d, --detach   run the countdown in the background and return right away

Watch:
  --high N       High Power from N% battery up, inclusive (default 80)
  --low N        Low Power below N% battery (default 20)
  -d, --detach   run the watcher in the background and return right away

Status:
  --json         print one JSON object instead of the usual lines, for scripts
                 and for the menu bar app in menulets/

Energy:
  --json         print one JSON object instead of the usual lines, for scripts
                 and for the menu bar app in menulets/. Lists your apps with a
                 Dock icon (at most 2) whose Energy Impact, the figure in
                 Activity Monitor's Energy tab, is 550 or more, and keeps an
                 app listed for two minutes after it last was. This only
                 approximates the Battery menu's list. Needs root for
                 powermetrics, so it re-runs itself through sudo; sampling takes
                 15 seconds.

Between the two thresholds the watcher leaves the power mode alone, and it
stands back while a boost runs. "mbat low" stops it.

If the power mode is changed outside mbatterier (Control Center, System
Settings), a running boost or watcher notices within seconds, exits and leaves
the mode as you set it, without reverting to Low Power.

Unplugging the adapter ends the boost and goes back to Low Power, unless the
adapter comes back within a minute, the boost is for battery only (-b), or it
was started with --keep.
`

const defaultBoost = time.Hour

// logPath receives the output of detached boosts.
const logPath = "/var/log/mbatterier.log"

// readyEnv tells a detached boost that fd 3 is the pipe to report its start on.
const readyEnv = "MBATTERIER_READY_FD"

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "boost":
		err = boost(os.Args[2:])
	case "watch":
		err = watch(os.Args[2:])
	case "low":
		requireRoot()
		err = low()
	case "off":
		requireRoot()
		err = off()
	case "status":
		err = status(os.Args[2:])
	case "energy":
		err = showEnergy(os.Args[2:])
	case "alfred":
		err = alfred(strings.Join(os.Args[2:], " "))
	case "-h", "--help", "help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", os.Args[1], usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// requireRoot re-runs the current command through sudo when not root.
// The whole process then stays root, so reverting works even after the
// sudo timestamp would have expired. Without a terminal (Alfred), sudo
// runs with -n so it fails instead of waiting for a password.
func requireRoot() {
	if os.Geteuid() == 0 {
		return
	}
	self, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	sudo, err := exec.LookPath("sudo")
	if err != nil {
		fmt.Fprintln(os.Stderr, "error: sudo not found")
		os.Exit(1)
	}
	args := []string{"sudo"}
	if !isTerminal(os.Stdin) {
		args = append(args, "-n")
	}
	args = append(append(args, self), os.Args[1:]...)
	if err := syscall.Exec(sudo, args, os.Environ()); err != nil {
		fmt.Fprintln(os.Stderr, "error: sudo:", err)
		os.Exit(1)
	}
}

func isTerminal(f *os.File) bool {
	fi, err := f.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

// boostArgs is the parsed command line of `boost`.
type boostArgs struct {
	dur         time.Duration
	src         pmset.Source
	label       string
	detach      bool
	untilUnplug bool
	keep        bool
	// always is High Power with no deadline and no unplug guard: it runs
	// until stopped.
	always bool
}

// parseBoostArgs parses the duration and flags of `boost`, in any order:
// `boost 1h --battery` and `boost -b 1h` are the same.
func parseBoostArgs(args []string) (boostArgs, error) {
	ba := boostArgs{dur: defaultBoost}
	battery, ac, hasDur := false, false, false
	for _, a := range args {
		switch a {
		case "--battery", "-b":
			battery = true
		case "--ac", "-c":
			ac = true
		case "--detach", "-d":
			ba.detach = true
		case "unplug", "--until-unplug", "-u":
			ba.untilUnplug = true
		case "--keep", "-k":
			ba.keep = true
		case "always":
			ba.always = true
		default:
			d, err := time.ParseDuration(a)
			if err != nil {
				return boostArgs{}, fmt.Errorf("invalid duration %q (use e.g. 30m, 1h, 1h30m)", a)
			}
			ba.dur, hasDur = d, true
		}
	}
	if ba.always {
		if hasDur || ba.untilUnplug {
			return boostArgs{}, errors.New("always takes no duration and no unplug")
		}
		ba.dur = 0
	} else if ba.untilUnplug {
		if hasDur {
			return boostArgs{}, errors.New("use either a duration or unplug")
		}
		if battery && !ac {
			return boostArgs{}, errors.New("unplug and --battery contradict each other")
		}
		if ba.keep {
			return boostArgs{}, errors.New("unplug and --keep contradict each other")
		}
		ba.dur = 0
	} else if ba.dur <= 0 {
		return boostArgs{}, errors.New("duration must be positive")
	}

	ba.src, ba.label = pmset.All, "battery + adapter"
	switch {
	case battery && !ac:
		ba.src, ba.label = pmset.Battery, "battery"
	case ac && !battery:
		ba.src, ba.label = pmset.AC, "adapter"
	}
	return ba, nil
}

// args returns the normalized command line for ba, without --detach.
func (ba boostArgs) args() []string {
	args := []string{"boost", formatDuration(ba.dur)}
	if ba.untilUnplug {
		args[1] = "unplug"
	}
	if ba.always {
		args[1] = "always"
	}
	switch ba.src {
	case pmset.Battery:
		args = append(args, "-b")
	case pmset.AC:
		args = append(args, "-c")
	}
	if ba.keep {
		args = append(args, "-k")
	}
	return args
}

func boost(args []string) error {
	if len(args) == 1 && args[0] == "stop" {
		requireRoot()
		return stopBoost()
	}
	ba, err := parseBoostArgs(args)
	if err != nil {
		return err
	}

	requireRoot()

	if ba.detach {
		return detach(ba.args())
	}
	var n notifier
	if os.Getenv(readyEnv) == "3" {
		n.f = os.NewFile(3, "ready")
	}
	err = run(ba, &n)
	n.done("", err)
	return err
}

// notifier reports to a waiting `boost --detach` whether the boost started.
// The zero value does nothing.
type notifier struct {
	f *os.File
}

func (n *notifier) done(msg string, err error) {
	if n.f == nil {
		return
	}
	if err != nil {
		fmt.Fprintf(n.f, "-%v", err)
	} else {
		fmt.Fprintf(n.f, "+%s", msg)
	}
	n.f.Close()
	n.f = nil
}

// detach runs args as a background process in its own session, waits until it
// reports that it started, and returns.
func detach(args []string) error {
	self, err := os.Executable()
	if err != nil {
		return err
	}
	logf, err := os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer logf.Close()
	r, w, err := os.Pipe()
	if err != nil {
		return err
	}
	defer r.Close()

	cmd := exec.Command(self, args...)
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.ExtraFiles = []*os.File{w} // fd 3
	cmd.Env = append(os.Environ(), readyEnv+"=3")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	err = cmd.Start()
	w.Close()
	if err != nil {
		return err
	}
	defer cmd.Process.Release()

	msg, _ := io.ReadAll(r)
	switch {
	case len(msg) > 0 && msg[0] == '+':
		fmt.Println(string(msg[1:]))
		return nil
	case len(msg) > 0 && msg[0] == '-':
		return errors.New(string(msg[1:]))
	}
	return fmt.Errorf("%s exited early in the background, see %s", args[0], logPath)
}

// maxPollErrors is how many failed power source checks in a row (so
// maxPollErrors * pollEvery of not knowing) make a boost give up and revert,
// rather than stay on High Power blindly.
const maxPollErrors = 10

// pollEvery is how often the power source is checked. Each check runs pmset
// (~5ms of CPU), so it's kept well below unplugGrace instead of once a second
// like the countdown.
const pollEvery = 5 * time.Second

// unplugGrace is how long the adapter has to stay away before a boost gives
// up. Shorter disconnections (a wiggled cable, swapping docks) leave the boost
// alone, at the cost of up to a minute of High Power on battery.
const unplugGrace = time.Minute

// unplugStep applies the unplug rule to one power source reading. The guard
// arms on the first adapter sighting, and once armed the boost ends after the
// adapter has been gone for grace. offSince is when the adapter went away, or
// zero while it's there; plugging back in clears it, so repeated plugging and
// unplugging within grace never ends the boost. A boost that started on
// battery just waits for the adapter.
func unplugStep(seenAC bool, offSince time.Time, ac bool, now time.Time, grace time.Duration) (nowSeenAC bool, newOffSince time.Time, end bool) {
	if ac {
		return true, time.Time{}, false
	}
	if !seenAC {
		return false, time.Time{}, false
	}
	if offSince.IsZero() {
		return true, now, false
	}
	return true, offSince, now.Sub(offSince) >= grace
}

// run switches to High Power, blocks until the deadline (or the unplug) or a
// signal, then switches back to Low Power.
func run(ba boostArgs, n *notifier) error {
	// Install the handler before switching modes so an early Ctrl-C still reverts.
	sigs := make(chan os.Signal, 1)
	// SIGUSR1 is another holder telling us the user took over the power mode.
	// SIGUSR2 is `boost stop`: exit and keep the mode, but as a plain stop.
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGUSR1, syscall.SIGUSR2)

	lock, stopped, err := runstate.Acquire(runstate.Boost)
	if err != nil {
		return err
	}
	defer lock.Release()

	// Unplugging ends the boost, but only once the adapter has been seen: a
	// boost started on battery keeps running and arms the guard when it gets
	// plugged in. A battery-only boost never arms it, and --keep turns the
	// whole thing off.
	watchUnplug := ba.src != pmset.Battery && !ba.keep && !ba.always
	onAC := false
	if watchUnplug {
		ac, err := pmset.OnAC()
		if err != nil {
			return err
		}
		if !ac && ba.untilUnplug {
			return errors.New("not on the adapter")
		}
		onAC = ac
	}
	if err := pmset.Set(ba.src, pmset.High); err != nil {
		return err
	}
	// What we set, so a change by anyone else can be told apart from ours.
	set := expectation{}
	set.set(ba.src, pmset.High)
	changes, stopChanges, err := pmset.Changes()
	if err != nil {
		// Not fatal: the periodic check below still catches a switch.
		fmt.Fprintln(os.Stderr, "error:", err)
		changes, stopChanges = nil, func() {}
	}
	defer stopChanges()

	// Round(0) drops the monotonic reading, so remaining time is measured on
	// the wall clock and time spent asleep (lid closed) still counts.
	deadline := time.Now().Add(ba.dur).Round(0)
	saved := runstate.State{Deadline: deadline, Label: ba.label, UntilUnplug: ba.untilUnplug, Always: ba.always}
	if ba.always {
		saved.Deadline = time.Time{}
	}
	if err := lock.Save(saved); err != nil {
		setLow()
		return err
	}
	until := deadline.Format("15:04")
	if ba.untilUnplug {
		until = "unplugged"
	} else if ba.always {
		until = "stopped"
	} else if watchUnplug {
		until += " or until unplugged"
	}
	msg := fmt.Sprintf("High Power on (%s) until %s", ba.label, until)
	if stopped {
		msg += ", replacing the running boost"
	}
	fmt.Printf("%s %s\n", time.Now().Format("2006-01-02 15:04:05"), msg)
	n.done(msg, nil)

	tty := isTerminal(os.Stdout)
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	reason := "time is up"
	pollErrors := 0
	handedOver := false    // the user changed the mode, so we leave it alone
	dismissed := false     // `boost stop`: leave the mode, keep the watcher
	var offSince time.Time // when the adapter went away, zero while it's there
	var nextPoll time.Time // zero, so the first pass checks right away
	nextModeCheck := time.Now().Add(modeCheckEvery)
loop:
	for {
		now := time.Now().Round(0)
		if now.After(nextModeCheck) {
			nextModeCheck = now.Add(modeCheckEvery)
			if msg, ok := externalChange(set); ok {
				reason, handedOver = msg, true
				break loop
			}
		}
		if watchUnplug && !now.Before(nextPoll) {
			nextPoll = now.Add(pollEvery)
			ac, err := pmset.OnAC()
			switch {
			case err != nil:
				pollErrors++
				fmt.Fprintln(os.Stderr, "error:", err)
				if pollErrors >= maxPollErrors {
					reason = "can't read the power source"
					break loop
				}
			default:
				pollErrors = 0
				wasOff := !offSince.IsZero()
				var end bool
				onAC, offSince, end = unplugStep(onAC, offSince, ac, now, unplugGrace)
				switch {
				case end:
					reason = "unplugged"
					break loop
				case !wasOff && !offSince.IsZero():
					logf("unplugged, reverting in %s unless the adapter comes back", formatDuration(unplugGrace))
				case wasOff && offSince.IsZero():
					logf("back on the adapter, boost continues")
				}
			}
		}
		if ba.untilUnplug {
			if tty {
				fmt.Print("\r\033[KHigh Power — until unplugged (Ctrl-C to revert now)")
			}
		} else if ba.always {
			if tty {
				fmt.Print("\r\033[KHigh Power — until stopped (Ctrl-C to revert now)")
			}
		} else {
			remaining := deadline.Sub(now)
			if remaining <= 0 {
				break
			}
			if tty {
				fmt.Printf("\r\033[KHigh Power — %s remaining (Ctrl-C to revert now)", formatRemaining(remaining))
			}
		}
		select {
		case s := <-sigs:
			reason = "got " + s.String()
			handedOver = s == syscall.SIGUSR1
			dismissed = s == syscall.SIGUSR2
			break loop
		case <-changes:
			if msg, ok := externalChange(set); ok {
				reason, handedOver = msg, true
				break loop
			}
		case <-ticker.C:
		}
	}
	if tty {
		fmt.Print("\r\033[K")
	}

	if dismissed {
		// Stopped from the menu's ∞ toggle. Turning the boost off is not a
		// request for Low Power, so the mode stays; a watcher keeps running
		// and takes over from here with its own rules.
		logf("%s: boost stopped, leaving the power mode as it is", reason)
		return nil
	}

	if handedOver {
		// The user took over. Reverting to Low Power now would undo what they
		// just chose, so the one rule that every exit ends in Low Power gives
		// way here, and only here. The watcher stands down too, since it would
		// otherwise set the mode again within a minute.
		runstate.StandDown(runstate.Watch)
		logf("%s: leaving the power mode as it is", reason)
		return nil
	}
	if err := setLow(); err != nil {
		return err
	}
	fmt.Printf("%s %s: back to Low Power (battery + adapter)\n", time.Now().Format("2006-01-02 15:04:05"), reason)
	return nil
}

// logf prints a timestamped line, like the start and revert messages.
func logf(format string, a ...any) {
	fmt.Printf("%s %s\n", time.Now().Format("2006-01-02 15:04:05"), fmt.Sprintf(format, a...))
}

func setLow() error {
	return pmset.Set(pmset.All, pmset.Low)
}

// low stops a running boost and watcher and sets Low Power on both sources.
// The watcher goes first: leaving it running would undo this on its next tick.
func low() error {
	return stopAll(pmset.Low, "Low Power")
}

// stopBoost stops the running boost, keeps the power mode as it is and leaves
// a watcher running, which then applies its own rules again.
func stopBoost() error {
	if !runstate.Dismiss(runstate.Boost) {
		fmt.Println("No boost running")
		return nil
	}
	if err := runstate.WaitGone(runstate.Boost); err != nil {
		return err
	}
	fmt.Println("Stopped the boost, power mode left as it is")
	return nil
}

// off stops a running boost and watcher and hands the power mode back to
// macOS, so that mbatterier no longer manages anything.
func off() error {
	return stopAll(pmset.Automatic, "Automatic")
}

// stopAll stops the running watcher and boost, then sets m on both sources.
// The holders revert to Low Power as they exit, so m is set last and wins.
func stopAll(m pmset.Mode, name string) error {
	watchLock, watcher, err := runstate.Acquire(runstate.Watch)
	if err != nil {
		return err
	}
	defer watchLock.Release()
	lock, boost, err := runstate.Acquire(runstate.Boost)
	if err != nil {
		return err
	}
	defer lock.Release()
	if err := pmset.Set(pmset.All, m); err != nil {
		return err
	}
	var stopped []string
	if boost {
		stopped = append(stopped, "boost")
	}
	if watcher {
		stopped = append(stopped, "watcher")
	}
	if len(stopped) > 0 {
		fmt.Printf("Stopped the running %s. ", strings.Join(stopped, " and the "))
	}
	fmt.Printf("%s on battery + adapter\n", name)
	return nil
}

func status(args []string) error {
	asJSON := false
	for _, a := range args {
		if a != "--json" {
			return fmt.Errorf("unknown argument %q", a)
		}
		asJSON = true
	}
	modes, err := pmset.Get()
	if err != nil {
		return err
	}
	if asJSON {
		return statusJSON(modes)
	}
	for _, s := range []struct {
		src   pmset.Source
		label string
	}{
		{pmset.Battery, "Battery Power"},
		{pmset.AC, "AC Power"},
	} {
		m, ok := modes[s.src]
		if !ok {
			fmt.Printf("%-14s n/a\n", s.label+":")
			continue
		}
		fmt.Printf("%-14s %s\n", s.label+":", m)
	}
	if st, ok := runstate.Current(runstate.Watch); ok {
		fmt.Printf("%-14s %s\n", "Watch:", st.Label)
	}
	if st, ok := runstate.Current(runstate.Boost); ok && st.UntilUnplug {
		fmt.Printf("%-14s %s, until unplugged\n", "Boost:", st.Label)
	} else if ok && st.Always {
		fmt.Printf("%-14s %s, until stopped\n", "Boost:", st.Label)
	} else if ok {
		fmt.Printf("%-14s %s, %s left (until %s)\n", "Boost:", st.Label,
			formatRemaining(time.Until(st.Deadline)), st.Deadline.Format("15:04"))
	}
	return nil
}

// statusDoc is the `mbat status --json` document. It carries everything a UI
// needs in one reading, so that the UI never queries the system itself: the
// power rules here are subtle and tested, and a second copy of them in a GUI
// would drift. Growing the UI means growing this document.
type statusDoc struct {
	// Percent is the battery charge, or -1 on a Mac without a battery.
	Percent  int  `json:"percent"`
	OnAC     bool `json:"on_ac"`
	Charging bool `json:"charging"`
	// RemainingMinutes is 0 when pmset gives no estimate.
	RemainingMinutes int `json:"remaining_minutes"`
	// Modes holds the power mode per source, keyed "battery" and "ac". A
	// source pmset doesn't report is missing.
	Modes map[string]string `json:"modes"`
	// ChargeLimit is the charge limit set in System Settings, in percent, or
	// 0 when there is none.
	ChargeLimit int `json:"charge_limit,omitempty"`
	// SlowCharger is macOS's own verdict on the adapter, the one its Battery
	// menu shows as "Slow Charger". Only ever set on the adapter.
	SlowCharger bool       `json:"slow_charger,omitempty"`
	Boost       *holderDoc `json:"boost,omitempty"`
	Watch       *holderDoc `json:"watch,omitempty"`
}

// holderDoc describes a running boost or watcher. A watcher has no deadline;
// its Label holds its thresholds.
type holderDoc struct {
	Label string `json:"label"`
	// RemainingSeconds is 0 for a holder with no deadline.
	RemainingSeconds int  `json:"remaining_seconds,omitempty"`
	UntilUnplug      bool `json:"until_unplug,omitempty"`
	// Always is a boost that runs until stopped.
	Always bool `json:"always,omitempty"`
}

// jsonSources names the sources in the document, apart from the pmset flags.
var jsonSources = map[pmset.Source]string{pmset.Battery: "battery", pmset.AC: "ac"}

// statusJSONDoc builds the document. now is a parameter so the countdown is
// testable.
func statusJSONDoc(ps pmset.PS, charge charging.State, modes map[pmset.Source]pmset.Mode, boost, watch runstate.State, hasBoost, hasWatch bool, now time.Time) statusDoc {
	doc := statusDoc{
		Percent:          ps.Percent,
		OnAC:             ps.OnAC,
		Charging:         ps.Charging,
		RemainingMinutes: int(ps.Remaining / time.Minute),
		Modes:            map[string]string{},
		ChargeLimit:      charge.Limit,
		// The verdict outlives the adapter it was about, so it counts only
		// while one is plugged in.
		SlowCharger: ps.OnAC && charge.Slow,
	}
	for src, name := range jsonSources {
		if m, ok := modes[src]; ok {
			doc.Modes[name] = m.String()
		}
	}
	if hasBoost {
		doc.Boost = &holderDoc{Label: boost.Label, UntilUnplug: boost.UntilUnplug, Always: boost.Always}
		// A boost until unplugged has no deadline, and a past one counts as
		// no time left rather than a negative countdown.
		if left := boost.Deadline.Sub(now); !boost.UntilUnplug && !boost.Deadline.IsZero() && left > 0 {
			doc.Boost.RemainingSeconds = int(left / time.Second)
		}
	}
	if hasWatch {
		doc.Watch = &holderDoc{Label: watch.Label}
	}
	return doc
}

// statusJSON prints the document. Like status itself it needs no root.
func statusJSON(modes map[pmset.Source]pmset.Mode) error {
	ps, err := pmset.Read()
	if err != nil {
		return err
	}
	boost, hasBoost := runstate.Current(runstate.Boost)
	watch, hasWatch := runstate.Current(runstate.Watch)
	b, err := json.MarshalIndent(statusJSONDoc(ps, charging.Read(), modes, boost, watch, hasBoost, hasWatch, time.Now()), "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}

// formatRemaining renders d as MM:SS, or H:MM:SS from one hour up.
func formatRemaining(d time.Duration) string {
	d = d.Round(time.Second)
	h := int(d / time.Hour)
	m := int(d % time.Hour / time.Minute)
	s := int(d % time.Minute / time.Second)
	if h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, m, s)
	}
	return fmt.Sprintf("%02d:%02d", m, s)
}

// formatDuration renders d like time.Duration.String without zero units:
// 1h, 1h30m, 45m, 90s.
func formatDuration(d time.Duration) string {
	s := d.String()
	if strings.HasSuffix(s, "m0s") {
		s = strings.TrimSuffix(s, "0s")
	}
	if strings.HasSuffix(s, "h0m") {
		s = strings.TrimSuffix(s, "0m")
	}
	return s
}
