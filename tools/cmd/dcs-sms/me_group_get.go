package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupGetOpts struct {
	Name		string
	ID		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupGetFlags() (*flag.FlagSet, *meGroupGetOpts) {
	opts := &meGroupGetOpts{}
	fs := flag.NewFlagSet("me group get", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (exact match)")
	fs.IntVar(&opts.ID, "id", 0, "groupId (numeric)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "get", cmdInfo{
		Run:		meGroupGetCmd,
		Flags:		flagsOnly(meGroupGetFlags),
		Synopsis:	"return full data for a group by name or id",
	})
}

// meGroupGetCmd implements `dcs-sms me group get --name <n> | --id <n>`.
//
// Returns the full mission-table group structure (back-references stripped
// for JSON safety). For a concise listing, use `me group list`.
func meGroupGetCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupGetFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group get: pass exactly one of --name or --id")
		return 2
	}
	var luaArgs string
	if hasName {
		luaArgs = fmt.Sprintf("{ name = %s }", luaQuote(opts.Name))
	} else {
		luaArgs = fmt.Sprintf("{ id = %d }", opts.ID)
	}
	resp, exitCode := runMeVerb("group_get", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
