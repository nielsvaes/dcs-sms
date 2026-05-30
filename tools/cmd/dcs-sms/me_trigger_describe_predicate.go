package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerDescribePredicateOpts struct {
	Name		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerDescribePredicateFlags() (*flag.FlagSet, *meTriggerDescribePredicateOpts) {
	opts := &meTriggerDescribePredicateOpts{}
	fs := flag.NewFlagSet("me trigger describe-predicate", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "predicate canonical name (e.g. c_flag_is_true) or alias (flag-is-true)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "describe-predicate", cmdInfo{
		Run:		meTriggerDescribePredicateCmd,
		Flags:		flagsOnly(meTriggerDescribePredicateFlags),
		Synopsis:	"print the field schema for one trigger predicate",
	})
}

// meTriggerDescribePredicateCmd implements
// `dcs-sms me trigger describe-predicate --name <canonical-or-alias>`.
//
// Returns the same shape as one entry from `list-predicates`, but for a
// single named predicate — useful when an agent has narrowed to one verb
// and wants the full schema without scanning the whole dump.
func meTriggerDescribePredicateCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerDescribePredicateFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger describe-predicate: --name is required")
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %s }", luaQuote(opts.Name))
	resp, exitCode := runMeVerb("trigger_describe_predicate", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
