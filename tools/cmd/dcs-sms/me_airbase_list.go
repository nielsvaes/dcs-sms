package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

func init() {
	registerMeInfo("airbase", "list", cmdInfo{
		Run:		meAirbaseListCmd,
		Flags:		flagsOnly(meAirbaseListFlags),
		Synopsis:	"list airbases on the current theatre (name, position, coalition)",
	})
}

type meAirbaseListOpts struct {
	Coalition	string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meAirbaseListFlags() (*flag.FlagSet, *meAirbaseListOpts) {
	opts := &meAirbaseListOpts{}
	fs := flag.NewFlagSet("me airbase list", flag.ContinueOnError)
	fs.StringVar(&opts.Coalition, "coalition", "all", "filter: all, red, blue, neutrals")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

// meAirbaseListCmd implements `dcs-sms me airbase list [--coalition F]`.
//
// Returns a lightweight summary per airbase (name, airdrome_number, coalition,
// x, y, lat, lon). Parking and runways are deferred to `me airbase get`.
func meAirbaseListCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meAirbaseListFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	switch strings.ToLower(opts.Coalition) {
	case "", "all", "red", "blue", "neutrals":
	default:
		fmt.Fprintln(stderr, "dcs-sms me airbase list: --coalition must be all, red, blue, or neutrals")
		return 2
	}

	luaArgs := fmt.Sprintf("{ coalition = %s }", luaQuote(strings.ToLower(opts.Coalition)))
	resp, exitCode := runMeVerb("airbase_list", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
