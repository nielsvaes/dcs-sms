package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerRemoveConditionOpts struct {
	Trigger		string
	Index		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerRemoveConditionFlags() (*flag.FlagSet, *meTriggerRemoveConditionOpts) {
	opts := &meTriggerRemoveConditionOpts{}
	fs := flag.NewFlagSet("me trigger remove-condition", flag.ContinueOnError)
	fs.StringVar(&opts.Trigger, "trigger", "", "trigger name")
	fs.IntVar(&opts.Index, "index", 0, "1-based condition index to remove")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "remove-condition", cmdInfo{
		Run:		meTriggerRemoveConditionCmd,
		Flags:		flagsOnly(meTriggerRemoveConditionFlags),
		Synopsis:	"delete one condition from a trigger by index",
	})
}

// meTriggerRemoveConditionCmd implements
// `dcs-sms me trigger remove-condition --trigger T --index N`.
//
// Removes the rule at the given 1-based index.
func meTriggerRemoveConditionCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerRemoveConditionFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Trigger == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger remove-condition: --trigger is required")
		return 2
	}
	if opts.Index < 1 {
		fmt.Fprintln(stderr, "dcs-sms me trigger remove-condition: --index (>= 1) is required")
		return 2
	}
	luaArgs := fmt.Sprintf("{ trigger = %s, index = %d }", luaQuote(opts.Trigger), opts.Index)
	resp, exitCode := runMeVerb("trigger_remove_condition", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
