package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerRemoveOpts struct {
	Name		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerRemoveFlags() (*flag.FlagSet, *meTriggerRemoveOpts) {
	opts := &meTriggerRemoveOpts{}
	fs := flag.NewFlagSet("me trigger remove", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "trigger name (the comment field)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "remove", cmdInfo{
		Run:		meTriggerRemoveCmd,
		Flags:		flagsOnly(meTriggerRemoveFlags),
		Synopsis:	"delete a trigger from the open mission",
	})
}

// meTriggerRemoveCmd implements `dcs-sms me trigger remove --name X`.
//
// Deletes a trigger by name. Refuses cleanly if no trigger with that name
// exists.
func meTriggerRemoveCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerRemoveFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger remove: --name is required")
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %s }", luaQuote(opts.Name))
	resp, exitCode := runMeVerb("trigger_remove", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
