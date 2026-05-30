package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerAddActionOpts struct {
	Trigger		string
	Predicate	string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerAddActionFlags() (*flag.FlagSet, *meTriggerAddActionOpts) {
	opts := &meTriggerAddActionOpts{}
	fs := flag.NewFlagSet("me trigger add-action", flag.ContinueOnError)
	fs.StringVar(&opts.Trigger, "trigger", "", "trigger name")
	fs.StringVar(&opts.Predicate, "predicate", "", "action predicate (a_*) or alias")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "add-action", cmdInfo{
		Run:		meTriggerAddActionCmd,
		Flags:		flagsOnly(meTriggerAddActionFlags),
		Synopsis:	"append an action to an existing trigger",
	})
}

// meTriggerAddActionCmd implements
// `dcs-sms me trigger add-action --trigger T --predicate P [k=v ...]`.
//
// Appends an action to the named trigger. Predicate accepts canonical
// (a_set_flag) or alias (set-flag). Field values are positional key=value
// pairs after the known flags.
func meTriggerAddActionCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerAddActionFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Trigger == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger add-action: --trigger is required")
		return 2
	}
	if opts.Predicate == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger add-action: --predicate is required")
		return 2
	}
	fields, err := parseTriggerFieldArgs(fs.Args())
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me trigger add-action:", err)
		return 2
	}
	luaArgs := fmt.Sprintf(
		"{ trigger = %s, predicate = %s, fields = %s }", luaQuote(opts.Trigger), luaQuote(opts.Predicate), buildLuaFieldsExpr(fields))
	resp, exitCode := runMeVerb("trigger_add_action", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
