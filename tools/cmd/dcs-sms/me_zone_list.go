package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meZoneListOpts struct {
	Shape		string
	Name		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meZoneListFlags() (*flag.FlagSet, *meZoneListOpts) {
	opts := &meZoneListOpts{}
	fs := flag.NewFlagSet("me zone list", flag.ContinueOnError)
	fs.StringVar(&opts.Shape, "shape", "", "filter by shape: circle | quad")
	fs.StringVar(&opts.Name, "name", "", "filter by zone-name substring (case-insensitive)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("zone", "list", cmdInfo{
		Run:		meZoneListCmd,
		Flags:		flagsOnly(meZoneListFlags),
		Synopsis:	"list all zones in the open mission",
	})
}

// meZoneListCmd implements `dcs-sms me zone list [--shape --name]`.
func meZoneListCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meZoneListFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	var parts []string
	if opts.Shape != "" {
		parts = append(parts, fmt.Sprintf("shape = %s", luaQuote(strings.ToLower(opts.Shape))))
	}
	if opts.Name != "" {
		parts = append(parts, fmt.Sprintf("name = %s", luaQuote(opts.Name)))
	}
	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("zone_list", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
