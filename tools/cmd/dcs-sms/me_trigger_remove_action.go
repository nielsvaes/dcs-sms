package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerRemoveActionOpts struct {
	Trigger		string
	Index		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerRemoveActionFlags() (*flag.FlagSet, *meTriggerRemoveActionOpts) {
	opts := &meTriggerRemoveActionOpts{}
	fs := flag.NewFlagSet("me trigger remove-action", flag.ContinueOnError)
	fs.StringVar(&opts.Trigger, "trigger", "", "trigger name")
	fs.IntVar(&opts.Index, "index", 0, "1-based action index to remove")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "remove-action", cmdInfo{
		Run:		meTriggerRemoveActionCmd,
		Flags:		flagsOnly(meTriggerRemoveActionFlags),
		Synopsis:	"delete one action from a trigger by index",
	})
}

// meTriggerRemoveActionCmd implements
// `dcs-sms me trigger remove-action --trigger T --index N`.
//
// Removes the action at the given 1-based index.
func meTriggerRemoveActionCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerRemoveActionFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Trigger == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger remove-action: --trigger is required")
		return 2
	}
	if opts.Index < 1 {
		fmt.Fprintln(stderr, "dcs-sms me trigger remove-action: --index (>= 1) is required")
		return 2
	}
	luaArgs := fmt.Sprintf("{ trigger = %s, index = %d }", luaQuote(opts.Trigger), opts.Index)
	resp, exitCode := runMeVerb("trigger_remove_action", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
