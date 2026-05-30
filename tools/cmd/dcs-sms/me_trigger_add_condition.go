package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerAddConditionOpts struct {
	Trigger		string
	Predicate	string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerAddConditionFlags() (*flag.FlagSet, *meTriggerAddConditionOpts) {
	opts := &meTriggerAddConditionOpts{}
	fs := flag.NewFlagSet("me trigger add-condition", flag.ContinueOnError)
	fs.StringVar(&opts.Trigger, "trigger", "", "trigger name")
	fs.StringVar(&opts.Predicate, "predicate", "", "condition predicate (c_*) or alias")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "add-condition", cmdInfo{
		Run:		meTriggerAddConditionCmd,
		Flags:		flagsOnly(meTriggerAddConditionFlags),
		Synopsis:	"append a condition to an existing trigger",
	})
}

// meTriggerAddConditionCmd implements
// `dcs-sms me trigger add-condition --trigger T --predicate P [k=v ...]`.
//
// Appends a condition to the named trigger. Predicate accepts canonical
// (c_flag_is_true) or alias (flag-is-true). Field values are positional
// key=value pairs after the known flags.
func meTriggerAddConditionCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerAddConditionFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Trigger == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger add-condition: --trigger is required")
		return 2
	}
	if opts.Predicate == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger add-condition: --predicate is required")
		return 2
	}
	fields, err := parseTriggerFieldArgs(fs.Args())
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me trigger add-condition:", err)
		return 2
	}
	luaArgs := fmt.Sprintf(
		"{ trigger = %s, predicate = %s, fields = %s }", luaQuote(opts.Trigger), luaQuote(opts.Predicate), buildLuaFieldsExpr(fields))
	resp, exitCode := runMeVerb("trigger_add_condition", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
