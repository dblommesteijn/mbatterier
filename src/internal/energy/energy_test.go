package energy

import (
	"reflect"
	"testing"
)

// tasks is the shape of powermetrics --show-process-coalition output: a
// coalition row at the left margin, its tasks indented beneath it.
const tasks = `Machine model: Mac15,6

*** Sampled system activity (Wed Oct 28 15:33:47 2026 +0100) (5020.17ms elapsed) ***

*** Running tasks ***

Name                               ID     CPU ms/s  User%  Deadlines (<2 ms, 2-5 ms)  Wakeups (Intr, Pkg idle)  Energy Impact
com.apple.WindowServer             377    401.14                                      313.27  1.38              331.15          
  WindowServer                     422    413.36    60.98  50.03   1.19               314.08  1.39              332.28          
DEAD_TASKS_COALITION                      638.26                                      646.01  0.00              63.83           
  DEAD_TASKS                       -1     638.26    62.82  635.08  5.96               646.01  0.00              1193.16         
com.apple.Terminal                 1219   198.04                                      94.47   0.00              11057.97        
  Terminal                         1244   79.81     79.09  10.32   0.00               77.63   0.00              45.17           
  yes                              60001  99.90     99.00  0.00    0.00               0.20    0.00              5500.10         
  yes                              60002  99.90     99.00  0.00    0.00               0.20    0.00              5500.10         
com.apple.MenuBarAgent             833    51.00                                       27.00   0.00              4800.00         
  MenuBarAgent                     946    51.00     70.00  0.00    0.00               27.00   0.00              4800.00         

*** Battery and backlight usage ***

Name                               ID     CPU ms/s  User%  Deadlines (<2 ms, 2-5 ms)  Wakeups (Intr, Pkg idle)  Energy Impact
com.ignored                        1      1.00                                        1.00    1.00              1.00            
  ignored                          99     1.00      1.00   1.00    1.00               1.00    1.00              1.00            
`

func TestParseCoalitions(t *testing.T) {
	got := parseCoalitions(tasks)
	want := []coalition{
		{"com.apple.WindowServer", 331.15, []int{422}},
		{"com.apple.Terminal", 11057.97, []int{1244, 60001, 60002}},
		{"com.apple.MenuBarAgent", 4800, []int{946}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parseCoalitions = %+v\nwant %+v", got, want)
	}
	if got := parseCoalitions("no table here"); len(got) != 0 {
		t.Errorf("parseCoalitions(garbage) = %v, want none", got)
	}
}

func TestParsePS(t *testing.T) {
	out := "  422     0 /System/Library/WindowServer\n32025   501 /Applications/Visual Studio Code.app/Contents/MacOS/Code Helper\nbad\n"
	want := map[int]proc{
		422:   {0, "/System/Library/WindowServer"},
		32025: {501, "/Applications/Visual Studio Code.app/Contents/MacOS/Code Helper"},
	}
	if got := parsePS(out); !reflect.DeepEqual(got, want) {
		t.Errorf("parsePS = %v, want %v", got, want)
	}
}

func TestInvokerUID(t *testing.T) {
	for _, tt := range []struct {
		describe string
		euid     int
		sudoUID  string
		want     int
	}{
		{"root through sudo is the user who ran sudo", 0, "501", 501},
		{"real root", 0, "", 0},
		{"unparsable SUDO_UID", 0, "junk", 0},
		{"SUDO_UID counts only when root", 501, "502", 501},
	} {
		if got := invokerUID(tt.euid, tt.sudoUID); got != tt.want {
			t.Errorf("%s: invokerUID(%d, %q) = %d, want %d", tt.describe, tt.euid, tt.sudoUID, got, tt.want)
		}
	}
}

func TestBundleRoot(t *testing.T) {
	for _, tt := range []struct {
		path, root string
		ok         bool
	}{
		{"/System/Applications/Music.app/Contents/MacOS/Music", "/System/Applications/Music.app", true},
		{"/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "/Applications/Visual Studio Code.app", true},
		{"/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", "", false},
		{"/usr/bin/yes", "", false},
		{"", "", false},
		{"/usr/local/bin/foo.app", "", false}, // no bundle directory below it
	} {
		root, ok := bundleRoot(tt.path)
		if root != tt.root || ok != tt.ok {
			t.Errorf("bundleRoot(%q) = %q, %v; want %q, %v", tt.path, root, ok, tt.root, tt.ok)
		}
	}
}

func TestParseInfo(t *testing.T) {
	for _, tt := range []struct {
		name, plist string
		want        bundle
	}{
		{"folder name, not CFBundleName", `{"CFBundleName":"Code"}`, bundle{"Fallback", true}},
		{"folder name, not CFBundleDisplayName", `{"CFBundleName":"Code","CFBundleDisplayName":"Code"}`, bundle{"Fallback", true}},
		{"no name", `{}`, bundle{"Fallback", true}},
		{"LSUIElement bool", `{"CFBundleName":"MenuBarAgent","LSUIElement":true}`, bundle{"Fallback", false}},
		{"LSUIElement string", `{"CFBundleName":"X","LSUIElement":"1"}`, bundle{"Fallback", false}},
		{"LSBackgroundOnly", `{"CFBundleName":"X","LSBackgroundOnly":1}`, bundle{"Fallback", false}},
		{"LSUIElement false", `{"CFBundleName":"X","LSUIElement":false}`, bundle{"Fallback", true}},
	} {
		got, err := parseInfo([]byte(tt.plist), "Fallback")
		if err != nil || got != tt.want {
			t.Errorf("%s: parseInfo = %+v, %v; want %+v", tt.name, got, err, tt.want)
		}
	}
	if _, err := parseInfo([]byte("not json"), "x"); err == nil {
		t.Error("parseInfo(garbage) = nil error, want one")
	}
}

func TestRank(t *testing.T) {
	const me = 501
	cs := []coalition{
		{"com.apple.Terminal", 11000, []int{1, 2}},
		{"com.example.daemon", 9000, []int{3}},        // root's, however busy
		{"com.apple.MenuBarAgent", 4800, []int{4}},    // background-only agent
		{"com.apple.WindowServer", 5000, []int{5}},    // not in an app bundle
		{"com.microsoft.VSCode", Threshold, []int{6}}, // exactly at the threshold counts
		{"com.apple.Safari", Threshold - 1, []int{7}},
		{"com.other.user", 8000, []int{8}}, // another user's app
		{"com.apple.dt.Xcode", 3500, []int{9}},
	}
	procs := map[int]proc{
		1: {me, "/usr/bin/yes"},
		2: {me, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"},
		3: {0, "/Applications/Example Daemon.app/Contents/MacOS/exampled"},
		4: {me, "/System/Library/CoreServices/MenuBarAgent.app/Contents/MacOS/MenuBarAgent"},
		5: {0, "/System/Library/WindowServer"},
		6: {me, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"},
		7: {me, "/Applications/Safari.app/Contents/MacOS/Safari"},
		8: {502, "/Applications/Other.app/Contents/MacOS/Other"},
		9: {me, "/Applications/Xcode.app/Contents/MacOS/Xcode"},
	}
	bundles := map[string]bundle{
		"/System/Applications/Utilities/Terminal.app":   {"Terminal", true},
		"/Applications/Example Daemon.app":              {"Example Daemon", false},
		"/System/Library/CoreServices/MenuBarAgent.app": {"MenuBarAgent", false},
		"/Applications/Visual Studio Code.app":          {"Visual Studio Code", true},
		"/Applications/Safari.app":                      {"Safari", true},
		"/Applications/Other.app":                       {"Other", true},
		"/Applications/Xcode.app":                       {"Xcode", true},
	}
	lookup := func(root string) (bundle, bool) { b, ok := bundles[root]; return b, ok }
	got := Rank(cs, procs, me, lookup)
	want := []App{{"Terminal", 11000}, {"Xcode", 3500}, {"Visual Studio Code", Threshold}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Rank = %v, want %v (own GUI apps, summed per coalition, at or above the threshold, highest first)", got, want)
	}
}

func TestRankThresholdBoundary(t *testing.T) {
	cs := []coalition{{"at", Threshold, []int{1}}, {"below", Threshold - 0.01, []int{2}}}
	procs := map[int]proc{1: {1, "/A.app/x"}, 2: {1, "/B.app/x"}}
	lookup := func(root string) (bundle, bool) { return bundle{name: root, gui: true}, true }
	got := Rank(cs, procs, 1, lookup)
	if want := []App{{"/A.app", Threshold}}; !reflect.DeepEqual(got, want) {
		t.Errorf("Rank = %v, want %v (the threshold itself counts, just under does not)", got, want)
	}
}

func TestRankEmptyIsNotNil(t *testing.T) {
	if got := Rank(nil, nil, 0, nil); got == nil || len(got) != 0 {
		t.Errorf("Rank(nil) = %#v, want empty non-nil (it encodes as [])", got)
	}
}
