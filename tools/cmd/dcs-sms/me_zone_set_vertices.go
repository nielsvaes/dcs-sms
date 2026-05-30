package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meZoneSetVerticesOpts struct {
	Name		string
	ID		int
	Vertices	string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meZoneSetVerticesFlags() (*flag.FlagSet, *meZoneSetVerticesOpts) {
	opts := &meZoneSetVerticesOpts{}
	fs := flag.NewFlagSet("me zone set-vertices", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "zone name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "zone id (mutually exclusive with --name)")
	fs.StringVar(&opts.Vertices, "vertices", "",
		"4 corners as \"n1,e1;n2,e2;n3,e3;n4,e4\" (>= 3 corners actually allowed)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("zone", "set-vertices", cmdInfo{
		Run:		meZoneSetVerticesCmd,
		Flags:		flagsOnly(meZoneSetVerticesFlags),
		Synopsis:	"replace a quad zone's 4 corners",
	})
}

// meZoneSetVerticesCmd implements
// `dcs-sms me zone set-vertices --name|--id <X> --vertices "n1,e1;n2,e2;..."`.
//
// Quad-zone reshape. Reuses the same --vertices string format as
// `me zone create --type quad`. The Lua verb computes a new center (average
// of supplied vertices) and emits relative points + a new position — same
// shape `zone_create_quad` produces, so save+reload behavior is identical.
//
// Refuses to operate on circle zones (those don't have vertices). Use
// set-radius for those.
func meZoneSetVerticesCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meZoneSetVerticesFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me zone set-vertices: exactly one of --name or --id is required")
		return 2
	}
	if opts.Vertices == "" {
		fmt.Fprintln(stderr, "dcs-sms me zone set-vertices: --vertices is required (\"n1,e1;n2,e2;n3,e3;n4,e4\")")
		return 2
	}
	verticesLua, err := parseVerticesToLua(opts.Vertices)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me zone set-vertices:", err)
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, vertices = %s }", idClause, verticesLua)

	resp, exitCode := runMeVerb("zone_set_vertices", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
