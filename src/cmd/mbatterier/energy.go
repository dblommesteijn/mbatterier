package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"mbatterier/internal/energy"
)

// energyDoc is the `mbat energy --json` document. It is consumed by Swift in
// menulets/MBatterier/Sources/Status.swift (EnergyUse), so the two change
// together.
type energyDoc struct {
	Apps []energy.App `json:"apps"`
}

// energyLines is the plain output: one app per line, impact right-aligned.
func energyLines(apps []energy.App) string {
	if len(apps) == 0 {
		return "No apps using significant energy\n"
	}
	width := 0
	for _, a := range apps {
		width = max(width, len(a.Name))
	}
	var b strings.Builder
	for _, a := range apps {
		fmt.Fprintf(&b, "%-*s  %5.1f\n", width, a.Name, a.Impact)
	}
	return b.String()
}

// showEnergy prints the apps using significant energy. Unlike status it needs
// root, because powermetrics does, and it takes 15 seconds, which is
// why it is not part of status.
func showEnergy(args []string) error {
	asJSON := false
	for _, a := range args {
		if a != "--json" {
			return fmt.Errorf("unknown argument %q", a)
		}
		asJSON = true
	}
	// powermetrics insists on root; requireRoot re-runs this command through
	// sudo (without a prompt when there is no terminal, as for the menu bar app).
	requireRoot()
	apps, err := energy.Read()
	if err != nil {
		return err
	}
	if !asJSON {
		fmt.Print(energyLines(apps))
		return nil
	}
	b, err := json.MarshalIndent(energyDoc{Apps: apps}, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}
