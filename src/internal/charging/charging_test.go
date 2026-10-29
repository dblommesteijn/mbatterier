package charging

import "testing"

// policy is powerd's archive as `plutil -convert xml1` prints it, cut down to
// what parseLimit reads.
func policy(limit, reason, terminated string) []byte {
	return []byte(`<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>$objects</key>
	<array>
		<string>$null</string>
		<dict>
			<key>drain</key>
			<true/>
			<key>reason</key>
			<dict>
				<key>CF$UID</key>
				<integer>3</integer>
			</dict>
			<key>soclimit</key>
			<integer>` + limit + `</integer>
			<key>terminated</key>
			<` + terminated + `/>
		</dict>
		<string>` + reason + `</string>
	</array>
</dict>
</plist>`)
}

func TestParseLimit(t *testing.T) {
	cases := []struct {
		name string
		doc  []byte
		want int
	}{
		{"manual limit", policy("80", "manualChargeLimit", "false"), 80},
		{"terminated", policy("80", "manualChargeLimit", "true"), 0},
		{"not the user's limit", policy("80", "obc", "false"), 0},
		{"100% is no limit", policy("100", "manualChargeLimit", "false"), 0},
		{"no policies", []byte(`<plist version="1.0"><dict><key>$objects</key><array/></dict></plist>`), 0},
		{"not XML", []byte("garbage"), 0},
	}
	for _, c := range cases {
		if got := parseLimit(c.doc); got != c.want {
			t.Errorf("%s: parseLimit = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestParseSlow(t *testing.T) {
	cases := []struct {
		out     string
		want    bool
		wantErr bool
	}{
		{slowChargerKey + " 1\n", true, false},
		{slowChargerKey + " 0\n", false, false},
		{"", false, true},
		{slowChargerKey + " yes\n", false, true},
	}
	for _, c := range cases {
		got, err := parseSlow([]byte(c.out))
		if got != c.want || (err != nil) != c.wantErr {
			t.Errorf("parseSlow(%q) = %v, %v, want %v, error %v", c.out, got, err, c.want, c.wantErr)
		}
	}
}
