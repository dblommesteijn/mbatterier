package pmset

import (
	"testing"
	"time"
)

const sample = `Battery Power:
 Sleep On Power Button 1
 powermode            1
 hibernatefile        /var/vm/sleepimage
 displaysleep         2
AC Power:
 Sleep On Power Button 1
 powermode            2
 displaysleep         5
`

func TestParse(t *testing.T) {
	got := parse([]byte(sample))
	want := map[Source]Mode{Battery: Low, AC: High}
	if len(got) != len(want) {
		t.Fatalf("parse() = %v, want %v", got, want)
	}
	for src, m := range want {
		if got[src] != m {
			t.Errorf("parse()[%s] = %v, want %v", src, got[src], m)
		}
	}
}

func TestParseMissing(t *testing.T) {
	got := parse([]byte("AC Power:\n displaysleep 5\n"))
	if len(got) != 0 {
		t.Errorf("parse() = %v, want empty", got)
	}
}

func TestModeString(t *testing.T) {
	tests := []struct {
		m    Mode
		want string
	}{
		{Automatic, "automatic"},
		{Low, "low"},
		{High, "high"},
		{Mode(7), "unknown (7)"},
	}
	for _, tt := range tests {
		if got := tt.m.String(); got != tt.want {
			t.Errorf("Mode(%d).String() = %q, want %q", int(tt.m), got, tt.want)
		}
	}
}

func TestParsePS(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    PS
		wantErr bool
	}{
		{
			name: "on the adapter",
			in:   "Now drawing from 'AC Power'\n -InternalBattery-0 (id=23920739)\t80%; AC attached; not charging present: true\n",
			want: PS{OnAC: true, Percent: 80},
		},
		{
			name: "charging on the adapter",
			in:   "Now drawing from 'AC Power'\n -InternalBattery-0 (id=23920739)\t87%; charging; 0:38 remaining present: true\n",
			want: PS{OnAC: true, Percent: 87, Charging: true, Remaining: 38 * time.Minute},
		},
		{
			name: "on battery",
			in:   "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=23920739)\t19%; discharging; 0:42 remaining present: true\n",
			want: PS{OnAC: false, Percent: 19, Remaining: 42 * time.Minute},
		},
		{
			name: "full charge",
			in:   "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true\n",
			want: PS{OnAC: true, Percent: 100},
		},
		{
			name: "empty battery",
			in:   "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t0%; discharging; (no estimate) present: true\n",
			want: PS{OnAC: false, Percent: 0},
		},
		{
			name: "no battery line",
			in:   "Now drawing from 'AC Power'\n",
			want: PS{OnAC: true, Percent: NoBattery},
		},
		{
			name: "UPS counts as battery",
			in:   "Now drawing from 'UPS Power'\n -InternalBattery-0\t55%; discharging\n",
			want: PS{OnAC: false, Percent: 55},
		},
		{name: "empty output", in: "", wantErr: true},
		{name: "unknown source", in: "garbage\n'AC Power'\n", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parsePS([]byte(tt.in))
			if (err != nil) != tt.wantErr {
				t.Fatalf("parsePS(%q) error = %v, wantErr %v", tt.in, err, tt.wantErr)
			}
			if err == nil && got != tt.want {
				t.Errorf("parsePS(%q) = %+v, want %+v", tt.in, got, tt.want)
			}
		})
	}
}

func TestParsePercent(t *testing.T) {
	tests := []struct {
		line string
		want int
		ok   bool
	}{
		{line: " -InternalBattery-0 (id=23920739)\t80%; AC attached", want: 80, ok: true},
		{line: " -InternalBattery-0 (id=23920739)\t7%; discharging", want: 7, ok: true},
		// The id is not a percentage, and neither is an out-of-range number.
		{line: " -InternalBattery-0 (id=23920739)"},
		{line: " -InternalBattery-0\t101%; bogus"},
		{line: ""},
	}
	for _, tt := range tests {
		got, ok := parsePercent(tt.line)
		if ok != tt.ok || (ok && got != tt.want) {
			t.Errorf("parsePercent(%q) = %d, %v, want %d, %v", tt.line, got, ok, tt.want, tt.ok)
		}
	}
}

func TestParseBattery(t *testing.T) {
	tests := []struct {
		name      string
		line      string
		pct       int
		charging  bool
		remaining time.Duration
		ok        bool
	}{
		{
			name: "discharging with an estimate",
			line: " -InternalBattery-0 (id=23920739)\t87%; discharging; 2:41 remaining present: true",
			pct:  87, remaining: 2*time.Hour + 41*time.Minute, ok: true,
		},
		{
			// The resting state with a charge limit: on the adapter, not
			// charging. "not charging" contains "charging", so a substring
			// match here would report the opposite of the truth.
			name: "on the adapter, not charging",
			line: " -InternalBattery-0 (id=23920739)\t80%; AC attached; not charging present: true",
			pct:  80, ok: true,
		},
		{
			name: "charging",
			line: " -InternalBattery-0 (id=1)\t87%; charging; 0:38 remaining present: true",
			pct:  87, charging: true, remaining: 38 * time.Minute, ok: true,
		},
		{
			name: "finishing charge still counts as charging",
			line: " -InternalBattery-0 (id=1)\t99%; finishing charge; 0:05 remaining present: true",
			pct:  99, charging: true, remaining: 5 * time.Minute, ok: true,
		},
		{
			// 0:00 is not an estimate of zero time left, it is no estimate.
			name: "charged",
			line: " -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true",
			pct:  100, ok: true,
		},
		{
			name: "no estimate",
			line: " -InternalBattery-0 (id=1)\t62%; discharging; (no estimate) present: true",
			pct:  62, ok: true,
		},
		{
			name: "state only, no third field",
			line: " -InternalBattery-0\t55%; discharging",
			pct:  55, ok: true,
		},
		// Lines that carry no percentage at all.
		{name: "header line", line: "Now drawing from 'AC Power'"},
		{name: "empty", line: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pct, charging, remaining, ok := parseBattery(tt.line)
			if ok != tt.ok {
				t.Fatalf("parseBattery(%q) ok = %v, want %v", tt.line, ok, tt.ok)
			}
			if !ok {
				return
			}
			if pct != tt.pct || charging != tt.charging || remaining != tt.remaining {
				t.Errorf("parseBattery(%q) = %d, %v, %v, want %d, %v, %v",
					tt.line, pct, charging, remaining, tt.pct, tt.charging, tt.remaining)
			}
		})
	}
}

func TestParseHM(t *testing.T) {
	tests := []struct {
		field string
		want  time.Duration
		ok    bool
	}{
		{field: " 2:41 remaining", want: 2*time.Hour + 41*time.Minute, ok: true},
		{field: " 0:38 remaining", want: 38 * time.Minute, ok: true},
		{field: " 0:00 remaining", ok: true},
		{field: " 12:05 remaining", want: 12*time.Hour + 5*time.Minute, ok: true},
		{field: " (no estimate) present: true"},
		{field: " not charging present: true"},
		{field: " discharging"},
		// A minute field out of range is not a time estimate.
		{field: " 1:60 remaining"},
		{field: ""},
	}
	for _, tt := range tests {
		got, ok := parseHM(tt.field)
		if ok != tt.ok || (ok && got != tt.want) {
			t.Errorf("parseHM(%q) = %v, %v, want %v, %v", tt.field, got, ok, tt.want, tt.ok)
		}
	}
}
