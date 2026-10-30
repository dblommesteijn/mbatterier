// Package smartcharge offers and performs macOS's "Charge to Full Now": the
// Battery menu's way past a charge that is held short of full, by the charge
// limit set in System Settings or by Optimized Battery Charging.
//
// It asks PowerUI's smart charge client, the private framework Control
// Center itself uses for this item (its binary references the client,
// smartChargingUIState, temporarilyDisableMCL and temporarilyEnableCharging).
// The client is reached through osascript's JavaScript bridge, so the CLI
// stays plain Go. None of it needs root.
package smartcharge

// UIState is PowerUI's smart charging state, the one Control Center decides
// the item from. The names are PowerUI's own, from
// PowerUISmartChargeUtilities' stringForSmartChargingUIState (macOS 27; the
// misspelt "Optimzed" is theirs). MCL is the manual charge limit set in
// System Settings, OBC Optimized Battery Charging.
type UIState int

const (
	Undefined                         UIState = 0
	NotEngaged                        UIState = 1
	ChargingToFull                    UIState = 2
	ChargingToFullDueToUserOverride   UIState = 3
	ChargingToFullAfterEngagement     UIState = 4
	ChargingToOBC                     UIState = 5
	PausedForOBC                      UIState = 6
	CloakingForOBC                    UIState = 7
	DischargingToOBC                  UIState = 8
	ChargingToOptimizedLimit          UIState = 9
	PausedForOptimizedLimit           UIState = 10
	CloakingForOptimizedLimit         UIState = 11
	DischargingToOptimizedLimit       UIState = 12
	ChargingToMCL                     UIState = 13
	PausedForMCL                      UIState = 14
	CloakingForMCL                    UIState = 15
	DischargingToMCL                  UIState = 16
	NotEngagedButPrimedForChargeLimit UIState = 17
	ChargingUpForGauging              UIState = 18
)

// Reading is what PowerUI says: the UI state, and the manual charge limit
// in percent (100 while it is off or overridden).
type Reading struct {
	State    UIState
	MCLLimit int
}

// isMCL is a state of the manual charge limit.
func (st UIState) isMCL() bool {
	return st >= ChargingToMCL && st <= DischargingToMCL
}

// ShownLimit is the limit the Battery menu's line names, in percent, or 0
// for none. While the manual limit is engaged it is PowerUI's: 100 after
// Charge to Full Now, which macOS's menu shows as "Charging to 100% Limit",
// and with no lag behind the switch. Otherwise it is the one powerd's
// policy file holds (policyLimit, from package charging).
func ShownLimit(r Reading, policyLimit int) int {
	if r.State.isMCL() && r.MCLLimit > 0 {
		return r.MCLLimit
	}
	return policyLimit
}

// Action is how a charge held short of full is let through.
type Action int

const (
	// None: nothing holds the charge back, so there is nothing to offer.
	None Action = iota
	// LiftLimit overrides the charge limit set in System Settings until it
	// is next engaged: PowerUI's temporarilyDisableMCL. Verified: from
	// PausedForMCL the state went to ChargingToMCL with the limit at 100,
	// and the battery started charging within a minute.
	LiftLimit
	// ChargeNow overrides Optimized Battery Charging: PowerUI's
	// temporarilyEnableCharging. Unverified: chosen because Control Center
	// references it next to temporarilyDisableMCL, not yet seen working.
	ChargeNow
)

// Offer decides whether the Battery menu shows "Charge to Full Now", and
// what it does, from the state as Control Center does.
//
// Checked against macOS's own menu on 2026-10-30: shown in PausedForMCL
// (held at an 80% limit) and DischargingToMCL (99% with an 80% limit), not
// in ChargingToMCL after the limit was lifted ("Charging to 100% Limit").
// The cloaking states and the OBC and optimized-limit ones follow the same
// pattern unverified. A charge still climbing to a limit (ChargingToMCL,
// ChargingToOBC, ChargingToOptimizedLimit) is not offered: macOS's menu
// wasn't seen in that state with a limit below 100, and ChargingToMCL is
// also the state right after the override.
func Offer(st UIState) Action {
	switch st {
	case PausedForMCL, CloakingForMCL, DischargingToMCL:
		return LiftLimit
	case PausedForOBC, CloakingForOBC, DischargingToOBC,
		PausedForOptimizedLimit, CloakingForOptimizedLimit, DischargingToOptimizedLimit:
		return ChargeNow
	}
	return None
}
