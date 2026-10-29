package energy

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestMerge(t *testing.T) {
	now := time.Unix(10000, 0)
	at := func(ago time.Duration) int64 { return now.Add(-ago).Unix() }
	for _, tt := range []struct {
		name     string
		prev     map[string]seen
		cur      []App
		want     []App
		wantNext map[string]seen
	}{
		{"new app is listed", nil, []App{{"Terminal", 9000}}, []App{{"Terminal", 9000}},
			map[string]seen{"Terminal": {9000, now.Unix()}}},
		{"quiet app is held", map[string]seen{"Terminal": {9000, at(100 * time.Second)}}, nil,
			[]App{{"Terminal", 9000}}, map[string]seen{"Terminal": {9000, at(100 * time.Second)}}},
		{"held up to the limit", map[string]seen{"Terminal": {9000, at(Hold)}}, nil,
			[]App{{"Terminal", 9000}}, map[string]seen{"Terminal": {9000, at(Hold)}}},
		{"dropped after the hold", map[string]seen{"Terminal": {9000, at(Hold + time.Second)}}, nil,
			[]App{}, map[string]seen{}},
		{"sampled again replaces the entry", map[string]seen{"Terminal": {9000, at(90 * time.Second)}},
			[]App{{"Terminal", 700}}, []App{{"Terminal", 700}}, map[string]seen{"Terminal": {700, now.Unix()}}},
		{"future stamp is dropped", map[string]seen{"Terminal": {9000, now.Unix() + 60}}, nil,
			[]App{}, map[string]seen{}},
		{"highest first, capped", map[string]seen{"A": {600, at(time.Second)}, "B": {900, at(time.Second)}},
			[]App{{"C", 700}}, []App{{"B", 900}, {"C", 700}},
			map[string]seen{"A": {600, at(time.Second)}, "B": {900, at(time.Second)}, "C": {700, now.Unix()}}},
	} {
		got, next := Merge(tt.prev, tt.cur, now, Hold)
		if !reflect.DeepEqual(got, tt.want) || !reflect.DeepEqual(next, tt.wantNext) {
			t.Errorf("%s:\n got  %v %v\n want %v %v", tt.name, got, next, tt.want, tt.wantNext)
		}
	}
}

func TestStateRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "energy.json")
	if got := loadState(path); len(got) != 0 {
		t.Errorf("loadState(missing) = %v, want empty", got)
	}
	want := map[string]seen{"Terminal": {9000.5, 12345}}
	if err := saveState(path, want); err != nil {
		t.Fatal(err)
	}
	if got := loadState(path); !reflect.DeepEqual(got, want) {
		t.Errorf("round trip = %v, want %v", got, want)
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o644 {
		t.Errorf("state file = %v, %v; want mode 0644", fi, err)
	}
	if err := os.WriteFile(path, []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := loadState(path); got == nil || len(got) != 0 {
		t.Errorf("loadState(corrupt) = %#v, want empty non-nil map", got)
	}
}
