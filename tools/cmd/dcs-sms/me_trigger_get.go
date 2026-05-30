package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerGetOpts struct {
	Name		string
	Raw		bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerGetFlags() (*flag.FlagSet, *meTriggerGetOpts) {
	opts := &meTriggerGetOpts{}
	fs := flag.NewFlagSet("me trigger get", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "trigger name (the comment field)")
	fs.BoolVar(&opts.Raw, "raw", false, "return verbatim trigrules entry (no enrichment)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "get", cmdInfo{
		Run:		meTriggerGetCmd,
		Flags:		flagsOnly(meTriggerGetFlags),
		Synopsis:	"return full data for a trigger by name",
	})
}

// meTriggerGetCmd implements `dcs-sms me trigger get --name X [--raw]`.
//
// Returns the full structured detail of a single trigger: rules and actions
// expanded with field values, dict-key text resolved to literals, reference
// ids enriched with *_name companions. --raw returns the on-disk trigrules
// entry verbatim (for debugging).
func meTriggerGetCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerGetFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger get: --name is required")
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %s, raw = %t }", luaQuote(opts.Name), opts.Raw)
	resp, exitCode := runMeVerb("trigger_get", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
