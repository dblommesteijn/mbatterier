package smartcharge

import (
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// osascriptPath is absolute, as everywhere else here: never resolved via $PATH.
const osascriptPath = "/usr/bin/osascript"

// script is the JavaScript osascript runs: with "state" it reads PowerUI's
// UI state, with a selector it calls that override on the client. Either
// way it prints one JSON line for parseReply. PowerUI is private, so it is
// loaded by path and its class looked up by name; the bridge's Ref() takes
// the C out-parameters.
const script = `
function run(argv) {
  ObjC.import('Foundation');
  function reply(o) { return JSON.stringify(o); }
  if (!$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/PowerUI.framework').load) {
    return reply({ok: false, error: "PowerUI could not be loaded"});
  }
  var cls = $.NSClassFromString('PowerUISmartChargeClient');
  if (!cls) return reply({ok: false, error: "PowerUI has no smart charge client"});
  var c = cls.alloc.initWithClientName('mbatterier');
  var err = Ref();
  if (argv[0] === 'state') {
    var st = Ref(), limit = Ref(), allowed = Ref();
    if (!c.smartChargingUIStateChargeLimitChargingOverrideAllowedWithError(st, limit, allowed, err)) {
      return reply({ok: false, error: err[0] ? ObjC.unwrap(err[0].localizedDescription) : "smartChargingUIState failed"});
    }
    return reply({ok: true, state: st[0], mclLimit: c.getMCLLimitWithError(Ref())});
  }
  if (!c[argv[0]](err)) {
    return reply({ok: false, error: err[0] ? ObjC.unwrap(err[0].localizedDescription) : argv[0] + " failed"});
  }
  return reply({ok: true});
}
`

// Read returns PowerUI's smart charging UI state and the manual limit.
func Read() (Reading, error) {
	return run("state")
}

// Perform lets the charge through as Offer decided.
func Perform(a Action) error {
	switch a {
	case LiftLimit:
		_, err := run("temporarilyDisableMCL")
		return err
	case ChargeNow:
		_, err := run("temporarilyEnableCharging")
		return err
	}
	return errors.New("nothing holds the charge back")
}

func run(arg string) (Reading, error) {
	out, err := exec.Command(osascriptPath, "-l", "JavaScript", "-e", script, arg).Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && len(exit.Stderr) > 0 {
			return Reading{}, fmt.Errorf("osascript: %s", strings.TrimSpace(string(exit.Stderr)))
		}
		return Reading{}, fmt.Errorf("osascript: %w", err)
	}
	return parseReply(out)
}

// parseReply reads the script's JSON line. The bridge hands C integers over
// as strings ("14") or numbers, so both are taken.
func parseReply(out []byte) (Reading, error) {
	var r struct {
		OK       bool            `json:"ok"`
		Error    string          `json:"error"`
		State    json.RawMessage `json:"state"`
		MCLLimit json.RawMessage `json:"mclLimit"`
	}
	if err := json.Unmarshal(out, &r); err != nil {
		return Reading{}, fmt.Errorf("PowerUI reply %q: %w", strings.TrimSpace(string(out)), err)
	}
	if !r.OK {
		return Reading{}, fmt.Errorf("PowerUI: %s", r.Error)
	}
	state, err := number(r.State)
	if err != nil {
		return Reading{}, fmt.Errorf("PowerUI state: %w", err)
	}
	limit, err := number(r.MCLLimit)
	if err != nil {
		return Reading{}, fmt.Errorf("PowerUI limit: %w", err)
	}
	return Reading{State: UIState(state), MCLLimit: limit}, nil
}

// number reads an integer the bridge gave as a number or a string; absent
// is 0.
func number(raw json.RawMessage) (int, error) {
	if len(raw) == 0 {
		return 0, nil
	}
	return strconv.Atoi(strings.Trim(string(raw), `"`))
}
