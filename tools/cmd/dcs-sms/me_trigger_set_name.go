package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerSetNameOpts struct {
	Name		string
	To		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerSetNameFlags() (*flag.FlagSet, *meTriggerSetNameOpts) {
	opts := &meTriggerSetNameOpts{}
	fs := flag.NewFlagSet("me trigger set-name", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "current trigger name")
	fs.StringVar(&opts.To, "to", "", "new trigger name")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "set-name", cmdInfo{
		Run:		meTriggerSetNameCmd,
		Flags:		flagsOnly(meTriggerSetNameFlags),
		Synopsis:	"rename a trigger",
	})
}

// meTriggerSetNameCmd implements
// `dcs-sms me trigger set-name --name X --to Y`.
//
// Renames a trigger (mutates its comment field). Refuses cleanly if the
// target name is already taken by a different trigger.
func meTriggerSetNameCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerSetNameFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger set-name: --name is required")
		return 2
	}
	if opts.To == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger set-name: --to is required")
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %s, to = %s }", luaQuote(opts.Name), luaQuote(opts.To))
	resp, exitCode := runMeVerb("trigger_set_name", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
