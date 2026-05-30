package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meGroupAddUnitOpts struct {
	Group		string
	GroupID		int
	Type		string
	OffsetNorth	float64
	OffsetEast	float64
	Skill		string
	Livery		string
	Heading		float64
	Alt		float64
	AltType		string
	OnboardNum	string
	Callsign	string
	Frequency	float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupAddUnitFlags() (*flag.FlagSet, *meGroupAddUnitOpts) {
	opts := &meGroupAddUnitOpts{}
	fs := flag.NewFlagSet("me group add-unit", flag.ContinueOnError)
	fs.StringVar(&opts.Group, "group", "", "group name (mutually exclusive with --group-id)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "group id (mutually exclusive with --group)")
	fs.StringVar(&opts.Type, "type", "", "unit type (defaults to last unit's type)")
	fs.Float64Var(&opts.OffsetNorth, "offset-north", 0, "meters north of group anchor (positive = north)")
	fs.Float64Var(&opts.OffsetEast, "offset-east", 0, "meters east of group anchor (positive = east)")
	fs.StringVar(&opts.Skill, "skill", "", "AI skill (defaults to last unit's)")
	fs.StringVar(&opts.Livery, "livery", "", "livery id (defaults to last unit's)")
	fs.Float64Var(&opts.Heading, "heading", 0, "heading in degrees (defaults to last unit's)")
	fs.Float64Var(&opts.Alt, "alt", 0, "altitude in meters (air only; defaults to last unit's)")
	fs.StringVar(&opts.AltType, "alt-type", "", "BARO | RADIO (air only; defaults to last unit's)")
	fs.StringVar(&opts.OnboardNum, "onboard-num", "", "onboard number (insert_unit auto-allocates if empty)")
	fs.StringVar(&opts.Callsign, "callsign", "", "radio callsign label (auto-allocates if empty)")
	fs.Float64Var(&opts.Frequency, "frequency", 0, "frequency MHz (ship only)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "add-unit", cmdInfo{
		Run:		meGroupAddUnitCmd,
		Flags:		flagsOnly(meGroupAddUnitFlags),
		Synopsis:	"add a unit to an existing group",
	})
}

// meGroupAddUnitCmd implements `dcs-sms me group add-unit --group <X> [...]`.
//
// Adds a unit to an existing group, mirroring the ME UI's "+" button. The
// new unit copies its skill / livery / heading / alt / payload from the
// group's last unit by default (so adding to a 4-ship F-16 flight gives
// you a 5th F-16 with the same load); any field can be overridden with
// the matching flag.
//
// For plane / helicopter groups the new unit's --type must equal
// g.units[1].type — DCS doesn't support heterogeneous air groups. The
// verb refuses on mismatch. For vehicle / ship / static groups, mixed
// types are allowed (Hawk SAM site = PCP + SR + TR + LN).
//
// Position: --offset-north and --offset-east are added to the group
// anchor (g.x / g.y). If neither is passed, Mission.insert_unit's
// default index-cumulative spread (40m south + 40m east per unit) takes
// over — same behaviour as the ME's + button.
//
// IMPORTANT for air groups: per-unit (x, y) is decorative for plane /
// helicopter groups — DCS overrides it at mission load and pins every
// unit to the group's formation_template. The offsets survive in the
// ME view and on disk, but at runtime the flight is laid out by the
// formation, not by what you set here. Vehicle / ship / static groups
// respect per-unit positions verbatim. (A future `me group set-formation`
// would be the right knob for air-group runtime layout.)
func meGroupAddUnitCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupAddUnitFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasGroup := opts.Group != ""
	hasGroupID := opts.GroupID != 0
	if hasGroup == hasGroupID {
		fmt.Fprintln(stderr, "dcs-sms me group add-unit: exactly one of --group or --group-id is required")
		return 2
	}

	// Selector clause for the group target.
	var groupClause string
	if hasGroup {
		groupClause = fmt.Sprintf("name = %s", luaQuote(opts.Group))
	} else {
		groupClause = fmt.Sprintf("id = %d", opts.GroupID)
	}

	// Build the optional-args section. Lua-side handles nil-semantics; we
	// only emit fields the user actually passed (tracked via fs.Visit).
	var parts []string
	parts = append(parts, groupClause)
	visited := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { visited[f.Name] = true })

	if opts.Type != "" {
		parts = append(parts, fmt.Sprintf("type = %s", luaQuote(opts.Type)))
	}
	if visited["offset-north"] {
		parts = append(parts, fmt.Sprintf("offset_north = %g", opts.OffsetNorth))
	}
	if visited["offset-east"] {
		parts = append(parts, fmt.Sprintf("offset_east = %g", opts.OffsetEast))
	}
	if opts.Skill != "" {
		parts = append(parts, fmt.Sprintf("skill = %s", luaQuote(opts.Skill)))
	}
	if visited["livery"] {
		// Allow explicit empty string (= "default") via --livery="".
		parts = append(parts, fmt.Sprintf("livery = %s", luaQuote(opts.Livery)))
	}
	if visited["heading"] {
		parts = append(parts, fmt.Sprintf("heading_deg = %g", opts.Heading))
	}
	if visited["alt"] {
		parts = append(parts, fmt.Sprintf("alt = %g", opts.Alt))
	}
	if opts.AltType != "" {
		altType := strings.ToUpper(opts.AltType)
		if altType != "BARO" && altType != "RADIO" {
			fmt.Fprintln(stderr, "dcs-sms me group add-unit: --alt-type must be BARO or RADIO")
			return 2
		}
		parts = append(parts, fmt.Sprintf("alt_type = %s", luaQuote(altType)))
	}
	if opts.OnboardNum != "" {
		parts = append(parts, fmt.Sprintf("onboard_num = %s", luaQuote(opts.OnboardNum)))
	}
	if opts.Callsign != "" {
		parts = append(parts, fmt.Sprintf("callsign = %s", luaQuote(opts.Callsign)))
	}
	if visited["frequency"] {
		parts = append(parts, fmt.Sprintf("frequency = %g", opts.Frequency))
	}

	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("group_add_unit", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
