package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupCreateStaticOpts struct {
	Country		string
	Type		string
	North		float64
	East		float64
	Name		string
	Heading		float64
	Category	string
	ShapeName	string
	Dead		bool
	CanCargo	bool
	Mass		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupCreateStaticFlags() (*flag.FlagSet, *meGroupCreateStaticOpts) {
	opts := &meGroupCreateStaticOpts{}
	fs := flag.NewFlagSet("me group create-static", flag.ContinueOnError)
	fs.StringVar(&opts.Country, "country", "", "country in current mission")
	fs.StringVar(&opts.Type, "type", "", "static id (e.g. \"Container red 1\", \"FARP_Tent\")")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin")
	fs.StringVar(&opts.Name, "name", "", "group name (auto-allocated if empty)")
	fs.Float64Var(&opts.Heading, "heading", 0, "heading in degrees (0 = north, CW positive)")
	fs.StringVar(&opts.Category, "category", "Fortifications",
		"static class: Cargos | Fortifications | Warehouses | Trucks")
	fs.StringVar(&opts.ShapeName, "shape-name", "", "model id (often required; varies per static type)")
	fs.BoolVar(&opts.Dead, "dead", false, "spawn already-destroyed")
	fs.BoolVar(&opts.CanCargo, "can-cargo", false, "make cargo-pickup-able by helos")
	fs.Float64Var(&opts.Mass, "mass", 0, "cargo mass in kg (when --can-cargo)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "create-static", cmdInfo{
		Run:		meGroupCreateStaticCmd,
		Flags:		flagsOnly(meGroupCreateStaticFlags),
		Synopsis:	"spawn a new static object group at the given coordinates",
	})
}

// meGroupCreateStaticCmd implements
// `dcs-sms me group create-static --country <c> --type <t> --north --east [...]`.
//
// Statics are fixed-position, non-AI objects (cargo crates, fortifications,
// warehouses, etc.). They live under country.static.group same as other
// categories but with a minimal shape: one unit, one position, no AI
// behavior. The category flag corresponds to DCS's static class
// ("Cargos" / "Fortifications" / "Warehouses" / "Trucks") — picking the
// wrong one for a given shape may render strangely.
func meGroupCreateStaticCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupCreateStaticFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Country == "" {
		fmt.Fprintln(stderr, "dcs-sms me group create-static: --country is required")
		return 2
	}
	if opts.Type == "" {
		fmt.Fprintln(stderr, "dcs-sms me group create-static: --type is required")
		return 2
	}

	luaArgs := fmt.Sprintf(
		"{ country = %s, type = %s, north = %g, east = %g, name = %s, "+
			"heading_deg = %g, category = %s, shape_name = %s, dead = %t, "+
			"can_cargo = %t, mass = %g }", luaQuote(opts.Country), luaQuote(opts.Type), opts.North, opts.East, luaQuote(opts.Name), opts.Heading, luaQuote(opts.Category), luaQuote(opts.ShapeName), opts.Dead,
		opts.CanCargo, opts.Mass,
	)

	resp, exitCode := runMeVerb("group_create_static", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
