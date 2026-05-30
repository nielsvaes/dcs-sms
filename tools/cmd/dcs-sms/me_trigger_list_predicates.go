package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerListPredicatesOpts struct {
	Kind		string
	Search		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerListPredicatesFlags() (*flag.FlagSet, *meTriggerListPredicatesOpts) {
	opts := &meTriggerListPredicatesOpts{}
	fs := flag.NewFlagSet("me trigger list-predicates", flag.ContinueOnError)
	fs.StringVar(&opts.Kind, "kind", "", "filter: condition|action|trigger")
	fs.StringVar(&opts.Search, "search", "", "substring to match against name or alias")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "list-predicates", cmdInfo{
		Run:		meTriggerListPredicatesCmd,
		Flags:		flagsOnly(meTriggerListPredicatesFlags),
		Synopsis:	"list available trigger predicates (filter by kind / search)",
	})
}

// meTriggerListPredicatesCmd implements
// `dcs-sms me trigger list-predicates [--kind condition|action|trigger] [--search <substr>]`.
//
// Dumps every predicate ED knows about — names, aliases, field schemas,
// generated CLI examples — by reading me_trigrules.predicates.descrs and
// triggersDescr at runtime. Always current to the user's installed DCS,
// including any modded predicates.
func meTriggerListPredicatesCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerListPredicatesFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	switch opts.Kind {
	case "", "condition", "action", "trigger":
	default:
		fmt.Fprintln(stderr, `dcs-sms me trigger list-predicates: --kind must be condition|action|trigger`)
		return 2
	}
	luaArgs := fmt.Sprintf("{ kind = %s, search = %s }", luaQuote(opts.Kind), luaQuote(opts.Search))
	resp, exitCode := runMeVerb("trigger_list_predicates", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
