package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

func init() {
	registerMeInfo("airbase", "set-coalition", cmdInfo{
		Run:		meAirbaseSetCoalitionCmd,
		Flags:		flagsOnly(meAirbaseSetCoalitionFlags),
		Synopsis:	"set an airbase's coalition (red, blue, neutral) and refresh the map display",
	})
}

type meAirbaseSetCoalitionOpts struct {
	Name		string
	Coalition	string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meAirbaseSetCoalitionFlags() (*flag.FlagSet, *meAirbaseSetCoalitionOpts) {
	opts := &meAirbaseSetCoalitionOpts{}
	fs := flag.NewFlagSet("me airbase set-coalition", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "airbase name")
	fs.StringVar(&opts.Coalition, "coalition", "", "red, blue, or neutral")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

// meAirbaseSetCoalitionCmd implements `dcs-sms me airbase set-coalition --name N --coalition C`.
//
// Updates the warehouse entry's coalition field and pushes through
// AirdromeController.setAirdromeCoalition so the live map display refreshes.
// Coalition input is normalised: "neutral" / "neutrals" both map to the
// canonical lowercase plural form ED uses internally.
func meAirbaseSetCoalitionCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meAirbaseSetCoalitionFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me airbase set-coalition: --name is required")
		return 2
	}
	switch strings.ToLower(opts.Coalition) {
	case "red", "blue", "neutral", "neutrals":
	default:
		fmt.Fprintln(stderr, "dcs-sms me airbase set-coalition: --coalition must be red, blue, or neutral")
		return 2
	}

	luaArgs := fmt.Sprintf("{ name = %s, coalition = %s }", luaQuote(opts.Name), luaQuote(strings.ToLower(opts.Coalition)))
	resp, exitCode := runMeVerb("airbase_set_coalition", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
