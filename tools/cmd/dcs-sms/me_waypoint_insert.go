package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meWaypointInsertOpts struct {
	GroupName		string
	GroupID			int
	Before			int
	North			float64
	East			float64
	Alt			float64
	AltType			string
	Speed			float64
	WpType			string
	Action			string
	NameText		string
	ETA			float64
	SpeedLocked		string
	ETALocked		string
	FormationTemplate	string
	Timeout			time.Duration
	Pretty			bool
	SavedGames		string

	beforeSet								bool
	northSet, eastSet, altSet, altTypeSet, speedSet, wpTypeSet, actionSet	bool
	nameTextSet, etaSet, formationSet					bool
}

func meWaypointInsertFlags() (*flag.FlagSet, *meWaypointInsertOpts) {
	opts := &meWaypointInsertOpts{}
	fs := flag.NewFlagSet("me waypoint insert", flag.ContinueOnError)
	fs.StringVar(&opts.GroupName, "group-name", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group-name)")
	fs.IntVar(&opts.Before, "before", -1, "insertion index (0-based; --before K appends)")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (required)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (required)")
	fs.Float64Var(&opts.Alt, "alt", 0, "altitude meters (optional)")
	fs.StringVar(&opts.AltType, "alt-type", "", "BARO or RADIO (optional)")
	fs.Float64Var(&opts.Speed, "speed", 0, "speed m/s (optional)")
	fs.StringVar(&opts.WpType, "type", "", "waypoint type (optional)")
	fs.StringVar(&opts.Action, "action", "", "waypoint action (optional)")
	fs.StringVar(&opts.NameText, "name", "", "waypoint display name (optional)")
	fs.Float64Var(&opts.ETA, "eta", 0, "ETA seconds (optional)")
	fs.StringVar(&opts.SpeedLocked, "speed-locked", "", "speed-locked: true|false (optional)")
	fs.StringVar(&opts.ETALocked, "eta-locked", "", "eta-locked: true|false (optional)")
	fs.StringVar(&opts.FormationTemplate, "formation-template", "", "formation template (optional)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "insert", cmdInfo{
		Run:		meWaypointInsertCmd,
		Flags:		flagsOnly(meWaypointInsertFlags),
		Synopsis:	"insert a waypoint at index N (shifts subsequent WPs up; --before K appends)",
	})
}

func meWaypointInsertCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointInsertFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "before":
			opts.beforeSet = true
		case "north":
			opts.northSet = true
		case "east":
			opts.eastSet = true
		case "alt":
			opts.altSet = true
		case "alt-type":
			opts.altTypeSet = true
		case "speed":
			opts.speedSet = true
		case "type":
			opts.wpTypeSet = true
		case "action":
			opts.actionSet = true
		case "name":
			opts.nameTextSet = true
		case "eta":
			opts.etaSet = true
		case "formation-template":
			opts.formationSet = true
		}
	})
	hasName := opts.GroupName != ""
	hasID := opts.GroupID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me waypoint insert: exactly one of --group-name or --group-id is required")
		return 2
	}
	if !opts.beforeSet || opts.Before < 0 {
		fmt.Fprintln(stderr, "dcs-sms me waypoint insert: --before is required (integer >= 0)")
		return 2
	}
	if !opts.northSet || !opts.eastSet {
		fmt.Fprintln(stderr, "dcs-sms me waypoint insert: --north and --east are both required")
		return 2
	}
	if opts.altTypeSet && opts.AltType != "BARO" && opts.AltType != "RADIO" {
		fmt.Fprintln(stderr, "dcs-sms me waypoint insert: --alt-type must be BARO or RADIO")
		return 2
	}
	var b strings.Builder
	b.WriteString("{ ")
	if hasName {
		fmt.Fprintf(&b, "name = %s, ", luaQuote(opts.GroupName))
	} else {
		fmt.Fprintf(&b, "id = %d, ", opts.GroupID)
	}
	fmt.Fprintf(&b, "before = %d, north = %g, east = %g", opts.Before, opts.North, opts.East)
	if opts.altSet {
		fmt.Fprintf(&b, ", alt = %g", opts.Alt)
	}
	if opts.altTypeSet {
		fmt.Fprintf(&b, ", alt_type = %s", luaQuote(opts.AltType))
	}
	if opts.speedSet {
		fmt.Fprintf(&b, ", speed = %g", opts.Speed)
	}
	if opts.wpTypeSet {
		fmt.Fprintf(&b, ", type = %s", luaQuote(opts.WpType))
	}
	if opts.actionSet {
		fmt.Fprintf(&b, ", action = %s", luaQuote(opts.Action))
	}
	if opts.nameTextSet {
		fmt.Fprintf(&b, ", name_text = %s", luaQuote(opts.NameText))
	}
	if opts.etaSet {
		fmt.Fprintf(&b, ", eta = %g", opts.ETA)
	}
	if opts.formationSet {
		fmt.Fprintf(&b, ", formation_template = %s", luaQuote(opts.FormationTemplate))
	}
	if opts.SpeedLocked != "" {
		v, ok := parseBoolFlag(opts.SpeedLocked)
		if !ok {
			fmt.Fprintln(stderr, "dcs-sms me waypoint insert: --speed-locked must be true or false")
			return 2
		}
		fmt.Fprintf(&b, ", speed_locked = %t", v)
	}
	if opts.ETALocked != "" {
		v, ok := parseBoolFlag(opts.ETALocked)
		if !ok {
			fmt.Fprintln(stderr, "dcs-sms me waypoint insert: --eta-locked must be true or false")
			return 2
		}
		fmt.Fprintf(&b, ", eta_locked = %t", v)
	}
	b.WriteString(" }")
	resp, exitCode := runMeVerb("waypoint_insert", b.String(), opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
