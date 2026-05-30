package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meZoneSetColorOpts struct {
	Name		string
	ID		int
	Color		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meZoneSetColorFlags() (*flag.FlagSet, *meZoneSetColorOpts) {
	opts := &meZoneSetColorOpts{}
	fs := flag.NewFlagSet("me zone set-color", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "zone name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "zone id (mutually exclusive with --name)")
	fs.StringVar(&opts.Color, "color", "",
		"color: name (red/green/blue/yellow/cyan/magenta/white/black/orange/purple), "+
			"hex \"#rrggbb\" (alpha 0.15), or \"#rrggbbaa\"")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("zone", "set-color", cmdInfo{
		Run:		meZoneSetColorCmd,
		Flags:		flagsOnly(meZoneSetColorFlags),
		Synopsis:	"change a zone's outline / fill color",
	})
}

// meZoneSetColorCmd implements `dcs-sms me zone set-color --name|--id <X> --color <c>`.
//
// Routes through the same `parseColorToLua` accepted by `me zone create
// --color` (named / hex RGB / hex RGBA). Calls into the Lua verb
// `zone_set_color` which wraps `Mission.TriggerZoneData.setTriggerZoneColor`.
func meZoneSetColorCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meZoneSetColorFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me zone set-color: exactly one of --name or --id is required")
		return 2
	}
	if opts.Color == "" {
		fmt.Fprintln(stderr, "dcs-sms me zone set-color: --color is required")
		return 2
	}
	colorLua, err := parseColorToLua(opts.Color)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me zone set-color:", err)
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, color = %s }", idClause, colorLua)

	resp, exitCode := runMeVerb("zone_set_color", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
