package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meZoneGetOpts struct {
	Name		string
	ID		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meZoneGetFlags() (*flag.FlagSet, *meZoneGetOpts) {
	opts := &meZoneGetOpts{}
	fs := flag.NewFlagSet("me zone get", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "zone name (exact match)")
	fs.IntVar(&opts.ID, "id", 0, "zoneId (numeric)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("zone", "get", cmdInfo{
		Run:		meZoneGetCmd,
		Flags:		flagsOnly(meZoneGetFlags),
		Synopsis:	"return full data for a zone by name or id",
	})
}

// meZoneGetCmd implements `dcs-sms me zone get --name <n> | --id <n>`.
func meZoneGetCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meZoneGetFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me zone get: pass exactly one of --name or --id")
		return 2
	}
	var luaArgs string
	if hasName {
		luaArgs = fmt.Sprintf("{ name = %s }", luaQuote(opts.Name))
	} else {
		luaArgs = fmt.Sprintf("{ id = %d }", opts.ID)
	}
	resp, exitCode := runMeVerb("zone_get", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
