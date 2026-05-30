package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

func init() {
	registerMeInfo("airbase", "get", cmdInfo{
		Run:		meAirbaseGetCmd,
		Flags:		flagsOnly(meAirbaseGetFlags),
		Synopsis:	"get an airbase's full info — metadata, frequencies, parking stands, runways",
	})
}

type meAirbaseGetOpts struct {
	Name		string
	Filter		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meAirbaseGetFlags() (*flag.FlagSet, *meAirbaseGetOpts) {
	opts := &meAirbaseGetOpts{}
	fs := flag.NewFlagSet("me airbase get", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "airbase name (case-insensitive, exact match preferred, substring fallback)")
	fs.StringVar(&opts.Filter, "filter", "", "stand filter: '' (all), plane, helicopter")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

// meAirbaseGetCmd implements `dcs-sms me airbase get --name N [--filter plane|helicopter]`.
//
// Returns deep info for one airbase: position, coalition, frequencies (Hz +
// MHz), parking stands (each with name, crossroad_index, x/y/lat/lon, fit
// flags, dimensions), and runways. Plus warehouses/fueldepots counts.
func meAirbaseGetCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meAirbaseGetFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me airbase get: --name is required")
		return 2
	}
	switch strings.ToLower(opts.Filter) {
	case "", "plane", "helicopter":
	default:
		fmt.Fprintln(stderr, "dcs-sms me airbase get: --filter must be empty, plane, or helicopter")
		return 2
	}

	luaArgs := fmt.Sprintf("{ name = %s, filter = %s }", luaQuote(opts.Name), luaQuote(strings.ToLower(opts.Filter)))
	resp, exitCode := runMeVerb("airbase_get", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
