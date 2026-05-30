package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupSetFrequencyOpts struct {
	Name		string
	ID		int
	Frequency	float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupSetFrequencyFlags() (*flag.FlagSet, *meGroupSetFrequencyOpts) {
	opts := &meGroupSetFrequencyOpts{}
	fs := flag.NewFlagSet("me group set-frequency", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.Float64Var(&opts.Frequency, "frequency", 0, "frequency in MHz")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "set-frequency", cmdInfo{
		Run:		meGroupSetFrequencyCmd,
		Flags:		flagsOnly(meGroupSetFrequencyFlags),
		Synopsis:	"set a group's radio frequency in MHz",
	})
}

// meGroupSetFrequencyCmd implements
// `dcs-sms me group set-frequency --name|--id <X> --frequency <MHz>`.
//
// Sets the group-level radio frequency. Stored as a number in MHz (e.g. 251,
// 305.5). The ME doesn't validate band/range — passing 1000 just stores it.
func meGroupSetFrequencyCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupSetFrequencyFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group set-frequency: exactly one of --name or --id is required")
		return 2
	}
	if opts.Frequency <= 0 {
		fmt.Fprintln(stderr, "dcs-sms me group set-frequency: --frequency is required (> 0 MHz)")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, frequency = %g }", idClause, opts.Frequency)

	resp, exitCode := runMeVerb("group_set_frequency", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
