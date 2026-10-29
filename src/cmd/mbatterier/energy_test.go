package main

import (
	"encoding/json"
	"testing"

	"mbatterier/internal/energy"
)

func TestEnergyLines(t *testing.T) {
	for _, tt := range []struct {
		name string
		apps []energy.App
		want string
	}{
		{"none", []energy.App{}, "No apps using significant energy\n"},
		{"aligned", []energy.App{{Name: "Visual Studio Code", Impact: 41.25}, {Name: "Music", Impact: 20}},
			"Visual Studio Code   41.2\nMusic                20.0\n"},
	} {
		if got := energyLines(tt.apps); got != tt.want {
			t.Errorf("%s: energyLines = %q, want %q", tt.name, got, tt.want)
		}
	}
}

func TestEnergyDocEncodesNoAppsAsEmptyList(t *testing.T) {
	b, err := json.Marshal(energyDoc{Apps: []energy.App{}})
	if err != nil || string(b) != `{"apps":[]}` {
		t.Errorf("got %s, %v; want {\"apps\":[]}", b, err)
	}
}
