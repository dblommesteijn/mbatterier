// Package charging reads what macOS's Battery menu says about charging that
// pmset(1) doesn't: the charge limit and whether the charger is a slow one.
package charging

import (
	"bytes"
	"encoding/base64"
	"encoding/xml"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// Absolute paths, as everywhere else here: never resolve them via $PATH.
const (
	plutilPath     = "/usr/bin/plutil"
	notifyutilPath = "/usr/bin/notifyutil"
	// policyPath is where powerd keeps its charging policies. It is
	// world-readable, so reading it needs no root.
	policyPath = "/Library/Preferences/com.apple.powerd.charging.plist"
	// slowChargerKey is the notification PerfPowerServices posts when its
	// slow-charger verdict changes; its state is the verdict, as Control
	// Center reads it for "Slow Charger".
	slowChargerKey = "com.apple.PerfPowerServices.slowChargerUpdatedNotification"
	// manualReason is the policy reason for the limit set in System
	// Settings > Battery > Charging. Optimized Battery Charging uses its own
	// reasons and is not a limit the user chose.
	manualReason = "manualChargeLimit"
)

// State is what the Battery menu shows about charging.
type State struct {
	// Limit is the charge limit in percent, or 0 when none is set.
	Limit int
	Slow  bool
}

// Read returns the charging state. Either half that cannot be read counts as
// absent: neither is worth failing a status reading over.
func Read() State {
	var st State
	if limit, err := readLimit(); err == nil {
		st.Limit = limit
	}
	if slow, err := readSlow(); err == nil {
		st.Slow = slow
	}
	return st
}

func readLimit() (int, error) {
	// The policies are an NSKeyedArchiver blob inside the plist. plutil
	// prints that blob as base64, then turns it into XML for parseLimit.
	out, err := exec.Command(plutilPath, "-extract", "policies", "raw", "-o", "-", policyPath).Output()
	if err != nil {
		return 0, fmt.Errorf("plutil -extract policies: %w", err)
	}
	blob, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(out)))
	if err != nil {
		return 0, fmt.Errorf("charging policies: %w", err)
	}
	cmd := exec.Command(plutilPath, "-convert", "xml1", "-o", "-", "-")
	cmd.Stdin = bytes.NewReader(blob)
	doc, err := cmd.Output()
	if err != nil {
		return 0, fmt.Errorf("plutil -convert xml1: %w", err)
	}
	return parseLimit(doc), nil
}

// parseLimit finds a manual charge limit in the XML form of powerd's keyed
// archive, or returns 0. The archive's references are not followed: a
// manual-limit reason anywhere in it, next to a soclimit, is enough, and a
// policy that has been terminated doesn't count.
func parseLimit(doc []byte) int {
	dec := xml.NewDecoder(bytes.NewReader(doc))
	var limit int
	var manual, terminated bool
	var key, elem string
	for {
		tok, err := dec.Token()
		if err != nil {
			break
		}
		switch t := tok.(type) {
		case xml.StartElement:
			elem = t.Name.Local
			if key == "terminated" && elem == "true" {
				terminated = true
			}
		case xml.CharData:
			text := strings.TrimSpace(string(t))
			switch {
			case elem == "key":
				key = text
				continue
			case elem == "string" && text == manualReason:
				manual = true
			case elem == "integer" && key == "soclimit":
				limit, _ = strconv.Atoi(text)
			}
		case xml.EndElement:
			if t.Name.Local != "key" {
				key = ""
			}
			elem = ""
		}
	}
	// 100% is no limit at all.
	if !manual || terminated || limit <= 0 || limit >= 100 {
		return 0
	}
	return limit
}

func readSlow() (bool, error) {
	out, err := exec.Command(notifyutilPath, "-g", slowChargerKey).Output()
	if err != nil {
		return false, fmt.Errorf("notifyutil -g: %w", err)
	}
	return parseSlow(out)
}

// parseSlow reads `notifyutil -g` output: the key, then its state.
func parseSlow(out []byte) (bool, error) {
	fields := strings.Fields(string(out))
	if len(fields) != 2 {
		return false, fmt.Errorf("notifyutil: unexpected output %q", out)
	}
	n, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return false, fmt.Errorf("notifyutil: %w", err)
	}
	return n != 0, nil
}
