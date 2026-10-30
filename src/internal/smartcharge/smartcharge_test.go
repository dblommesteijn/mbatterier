package smartcharge

import "testing"

func TestOffer(t *testing.T) {
	cases := []struct {
		name string
		st   UIState
		want Action
	}{
		// Seen in macOS's own menu.
		{"held at the limit", PausedForMCL, LiftLimit},
		{"above the limit, draining to it", DischargingToMCL, LiftLimit},
		{"limit lifted", ChargingToMCL, None},
		// The same pattern, unverified.
		{"cloaking for the limit", CloakingForMCL, LiftLimit},
		{"held by OBC", PausedForOBC, ChargeNow},
		{"draining to OBC", DischargingToOBC, ChargeNow},
		{"held at the optimized limit", PausedForOptimizedLimit, ChargeNow},
		{"charging up to OBC", ChargingToOBC, None},
		{"not engaged", NotEngaged, None},
		{"charging to full", ChargingToFull, None},
		{"overridden", ChargingToFullDueToUserOverride, None},
		{"undefined", Undefined, None},
		{"unknown", UIState(19), None},
	}
	for _, c := range cases {
		if got := Offer(c.st); got != c.want {
			t.Errorf("%s: Offer(%d) = %d, want %d", c.name, c.st, got, c.want)
		}
	}
}

func TestShownLimit(t *testing.T) {
	cases := []struct {
		name   string
		r      Reading
		policy int
		want   int
	}{
		{"held at the limit", Reading{PausedForMCL, 80}, 80, 80},
		{"after Charge to Full Now", Reading{ChargingToMCL, 100}, 0, 100},
		{"policy file not yet rewritten", Reading{ChargingToMCL, 100}, 80, 100},
		{"limit just set, file lagging", Reading{DischargingToMCL, 80}, 0, 80},
		{"not the manual limit", Reading{NotEngaged, 100}, 0, 0},
		{"unreadable", Reading{}, 80, 80},
	}
	for _, c := range cases {
		if got := ShownLimit(c.r, c.policy); got != c.want {
			t.Errorf("%s: ShownLimit = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestParseReply(t *testing.T) {
	cases := []struct {
		out     string
		want    Reading
		wantErr bool
	}{
		{`{"ok":true,"state":14,"mclLimit":80}` + "\n", Reading{PausedForMCL, 80}, false},
		{`{"ok":true,"state":"13","mclLimit":"100"}`, Reading{ChargingToMCL, 100}, false},
		{`{"ok":false,"error":"no client"}`, Reading{}, true},
		{`{"ok":true}`, Reading{}, false},
		{`{"ok":true,"state":"x"}`, Reading{}, true},
		{`garbage`, Reading{}, true},
	}
	for _, c := range cases {
		got, err := parseReply([]byte(c.out))
		if (err != nil) != c.wantErr || (err == nil && got != c.want) {
			t.Errorf("parseReply(%q) = %v, %v; want %v, error %v", c.out, got, err, c.want, c.wantErr)
		}
	}
}
