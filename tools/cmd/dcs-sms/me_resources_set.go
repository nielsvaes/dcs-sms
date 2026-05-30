package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

func init() {
	registerMeInfo("resources", "set", cmdInfo{
		Run:		meResourcesSetCmd,
		Flags:		flagsOnly(meResourcesSetFlags),
		Synopsis:	"mutate an airbase or ship/structure warehouse — toggle unlimited, clear categories, set per-fuel / per-aircraft / per-weapon counts",
	})
}

type meResourcesSetOpts struct {
	Airbase	string
	Unit	string

	Clear		bool
	Unlimited	bool

	ClearAircrafts	bool
	ClearFuel	bool
	ClearMunitions	bool

	UnlimitedAircrafts	bool
	UnlimitedFuel		bool
	UnlimitedMunitions	bool

	OperatingLevelAir	int
	OperatingLevelFuel	int
	OperatingLevelEqp	int

	Fuels		[]string	// raw "TYPE=N"
	Aircrafts	[]string	// raw "NAME=N"
	Weapons		[]string	// raw "FRAGMENT=N"

	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meResourcesSetFlags() (*flag.FlagSet, *meResourcesSetOpts) {
	opts := &meResourcesSetOpts{}
	fs := flag.NewFlagSet("me resources set", flag.ContinueOnError)

	fs.StringVar(&opts.Airbase, "airbase", "", "airbase name (mutually exclusive with --unit)")
	fs.StringVar(&opts.Unit, "unit", "", "unit name or numeric unitId (mutually exclusive with --airbase)")

	fs.BoolVar(&opts.Clear, "clear", false, "zero all inventory and uncheck all unlimited flags")
	fs.BoolVar(&opts.Unlimited, "unlimited", false, "set all three unlimited flags (use --unlimited=false to unset all)")

	fs.BoolVar(&opts.ClearAircrafts, "clear-aircrafts", false, "zero aircraft counts (does not touch unlimited flag)")
	fs.BoolVar(&opts.ClearFuel, "clear-fuel", false, "zero fuel percentages (does not touch unlimited flag)")
	fs.BoolVar(&opts.ClearMunitions, "clear-munitions", false, "zero weapon counts (does not touch unlimited flag)")

	fs.BoolVar(&opts.UnlimitedAircrafts, "unlimited-aircrafts", false, "set unlimitedAircrafts (use =false to unset)")
	fs.BoolVar(&opts.UnlimitedFuel, "unlimited-fuel", false, "set unlimitedFuel (use =false to unset)")
	fs.BoolVar(&opts.UnlimitedMunitions, "unlimited-munitions", false, "set unlimitedMunitions (use =false to unset)")

	fs.IntVar(&opts.OperatingLevelAir, "operating-level-air", 0, "minimum-stock %% for aircraft replenishment (0..100)")
	fs.IntVar(&opts.OperatingLevelFuel, "operating-level-fuel", 0, "minimum-stock %% for fuel replenishment (0..100)")
	fs.IntVar(&opts.OperatingLevelEqp, "operating-level-eqp", 0, "minimum-stock %% for equipment replenishment (0..100)")

	fs.Func("fuel", "TYPE=N where TYPE in {jet_fuel,gasoline,diesel,methanol_mixture} and N is 0..100; repeatable",
		func(v string) error { opts.Fuels = append(opts.Fuels, v); return nil })
	fs.Func("aircraft", `"DISPLAY NAME"=N — exact match against the warehouse's aircraft keys; repeatable`,
		func(v string) error { opts.Aircrafts = append(opts.Aircrafts, v); return nil })
	fs.Func("weapon", `"FRAGMENT"=N — substring match on weapon displayName (or full CLSID in {...} form); repeatable`,
		func(v string) error { opts.Weapons = append(opts.Weapons, v); return nil })

	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

// meResourcesSetCmd implements `dcs-sms me resources set { --airbase N | --unit ID } [...mods...]`.
//
// Atomic: validates all mods (parses K=V flags, range-checks operating
// levels) before issuing the bridge call. The Lua side does its own
// validation (weapon name resolution, aircraft key existence) before
// mutating the warehouse copy, and never partially applies.
func meResourcesSetCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meResourcesSetFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	if (opts.Airbase == "") == (opts.Unit == "") {
		fmt.Fprintln(stderr, "dcs-sms me resources set: exactly one of --airbase or --unit is required")
		return 2
	}

	// Track which bool flags the user actually touched so we send tristate
	// (omit / true / false) to the Lua side. Bare bool flags default to
	// false; we need to distinguish "not set" from "explicitly --flag=false".
	touched := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { touched[f.Name] = true })

	// Range-check operating levels (0..100).
	for _, p := range []struct {
		name	string
		val	int
	}{
		{"operating-level-air", opts.OperatingLevelAir},
		{"operating-level-fuel", opts.OperatingLevelFuel},
		{"operating-level-eqp", opts.OperatingLevelEqp},
	} {
		if touched[p.name] && (p.val < 0 || p.val > 100) {
			fmt.Fprintf(stderr, "dcs-sms me resources set: --%s must be 0..100 (got %d)\n", p.name, p.val)
			return 2
		}
	}

	fuelOverrides, err := parseFuelOverrides(opts.Fuels)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me resources set:", err)
		return 2
	}
	aircraftOverrides, err := parseAircraftOverrides(opts.Aircrafts)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me resources set:", err)
		return 2
	}
	weaponOverrides, err := parseWeaponOverrides(opts.Weapons)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me resources set:", err)
		return 2
	}

	luaArgs := buildResourcesSetLuaArgs(opts, touched, fuelOverrides, aircraftOverrides, weaponOverrides)
	resp, exitCode := runMeVerb("resources_set", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}

// buildResourcesSetLuaArgs renders the mods table as a Lua table literal.
// Bool flags only appear when touched (so the Lua side sees nil for "not
// set", true / false otherwise).
func buildResourcesSetLuaArgs(
	opts *meResourcesSetOpts,
	touched map[string]bool,
	fuel map[string]int,
	aircraft map[string]int,
	weapons []WeaponOverride,
) string {
	var b strings.Builder
	b.WriteString("{")
	first := true
	add := func(s string) {
		if !first {
			b.WriteString(", ")
		}
		b.WriteString(s)
		first = false
	}

	if opts.Airbase != "" {
		add(fmt.Sprintf("airbase = %s", luaQuote(opts.Airbase)))
	} else {
		add(fmt.Sprintf("unit = %s", luaQuote(opts.Unit)))
	}

	if opts.Clear {
		add("clear = true")
	}
	if touched["unlimited"] {
		add(fmt.Sprintf("unlimited = %t", opts.Unlimited))
	}
	if opts.ClearAircrafts {
		add("clear_aircrafts = true")
	}
	if opts.ClearFuel {
		add("clear_fuel = true")
	}
	if opts.ClearMunitions {
		add("clear_munitions = true")
	}
	if touched["unlimited-aircrafts"] {
		add(fmt.Sprintf("unlimited_aircrafts = %t", opts.UnlimitedAircrafts))
	}
	if touched["unlimited-fuel"] {
		add(fmt.Sprintf("unlimited_fuel = %t", opts.UnlimitedFuel))
	}
	if touched["unlimited-munitions"] {
		add(fmt.Sprintf("unlimited_munitions = %t", opts.UnlimitedMunitions))
	}
	if touched["operating-level-air"] {
		add(fmt.Sprintf("operating_level_air = %d", opts.OperatingLevelAir))
	}
	if touched["operating-level-fuel"] {
		add(fmt.Sprintf("operating_level_fuel = %d", opts.OperatingLevelFuel))
	}
	if touched["operating-level-eqp"] {
		add(fmt.Sprintf("operating_level_eqp = %d", opts.OperatingLevelEqp))
	}

	if len(fuel) > 0 {
		var inner strings.Builder
		innerFirst := true
		for k, v := range fuel {
			if !innerFirst {
				inner.WriteString(", ")
			}
			fmt.Fprintf(&inner, "%s = %d", k, v)
			innerFirst = false
		}
		add(fmt.Sprintf("fuel_overrides = { %s }", inner.String()))
	}
	if len(aircraft) > 0 {
		var inner strings.Builder
		innerFirst := true
		for k, v := range aircraft {
			if !innerFirst {
				inner.WriteString(", ")
			}
			fmt.Fprintf(&inner, "[%s] = %d", luaQuote(k), v)
			innerFirst = false
		}
		add(fmt.Sprintf("aircraft_overrides = { %s }", inner.String()))
	}
	if len(weapons) > 0 {
		var inner strings.Builder
		for i, w := range weapons {
			if i > 0 {
				inner.WriteString(", ")
			}
			fmt.Fprintf(&inner, "{ name = %s, count = %d }", luaQuote(w.Name), w.Count)
		}
		add(fmt.Sprintf("weapon_overrides = { %s }", inner.String()))
	}

	b.WriteString(" }")
	return b.String()
}
