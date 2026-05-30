package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

func init() {
	registerMeInfo("trigger", "reorder-action", cmdInfo{
		Run:		meTriggerReorderActionCmd,
		Flags:		flagsOnly(meTriggerReorderActionFlags),
		Synopsis:	"move an action to a new index in a trigger's action list",
	})
}

type meTriggerReorderActionOpts struct {
	Trigger		string
	Index		int
	Before		int
	After		int
	ToIndex		int
	ToStart		bool
	ToEnd		bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerReorderActionFlags() (*flag.FlagSet, *meTriggerReorderActionOpts) {
	opts := &meTriggerReorderActionOpts{}
	fs := flag.NewFlagSet("me trigger reorder-action", flag.ContinueOnError)
	fs.StringVar(&opts.Trigger, "trigger", "", "parent trigger name")
	fs.IntVar(&opts.Index, "index", 0, "1-based source action index in t.actions")
	fs.IntVar(&opts.Before, "before", 0, "anchor: move source to just before this 1-based action index")
	fs.IntVar(&opts.After, "after", 0, "anchor: move source to just after this 1-based action index")
	fs.IntVar(&opts.ToIndex, "to-index", 0, "1-based final position in t.actions")
	fs.BoolVar(&opts.ToStart, "to-start", false, "sugar for --to-index 1")
	fs.BoolVar(&opts.ToEnd, "to-end", false, "sugar for --to-index #actions")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

// meTriggerReorderActionCmd implements
//
//	dcs-sms me trigger reorder-action --trigger T --index N
//	  { --before M | --after M | --to-index M | --to-start | --to-end }
//
// Moves an action to a new position in t.actions. Anchor references
// (--before / --after) are 1-based indices into t.actions. Exactly one
// position flag must be provided.
func meTriggerReorderActionCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerReorderActionFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Trigger == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger reorder-action: --trigger is required")
		return 2
	}
	if opts.Index < 1 {
		fmt.Fprintln(stderr, "dcs-sms me trigger reorder-action: --index (>= 1) is required")
		return 2
	}

	set := 0
	if opts.Before != 0 {
		set++
	}
	if opts.After != 0 {
		set++
	}
	if opts.ToIndex != 0 {
		set++
	}
	if opts.ToStart {
		set++
	}
	if opts.ToEnd {
		set++
	}
	if set != 1 {
		fmt.Fprintln(stderr, "dcs-sms me trigger reorder-action: exactly one of "+
			"--before / --after / --to-index / --to-start / --to-end is required")
		return 2
	}

	var b strings.Builder
	fmt.Fprintf(&b, "{ trigger = %s, index = %d", luaQuote(opts.Trigger), opts.Index)
	if opts.Before != 0 {
		fmt.Fprintf(&b, ", before = %d", opts.Before)
	}
	if opts.After != 0 {
		fmt.Fprintf(&b, ", after = %d", opts.After)
	}
	if opts.ToIndex != 0 {
		fmt.Fprintf(&b, ", to_index = %d", opts.ToIndex)
	}
	if opts.ToStart {
		b.WriteString(", to_start = true")
	}
	if opts.ToEnd {
		b.WriteString(", to_end = true")
	}
	b.WriteString(" }")

	resp, exitCode := runMeVerb("trigger_reorder_action", b.String(), opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
