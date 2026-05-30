package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

func init() {
	registerMeInfo("trigger", "reorder-condition", cmdInfo{
		Run:		meTriggerReorderConditionCmd,
		Flags:		flagsOnly(meTriggerReorderConditionFlags),
		Synopsis:	"move a condition to a new index in a trigger's condition list",
	})
}

type meTriggerReorderConditionOpts struct {
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

func meTriggerReorderConditionFlags() (*flag.FlagSet, *meTriggerReorderConditionOpts) {
	opts := &meTriggerReorderConditionOpts{}
	fs := flag.NewFlagSet("me trigger reorder-condition", flag.ContinueOnError)
	fs.StringVar(&opts.Trigger, "trigger", "", "parent trigger name")
	fs.IntVar(&opts.Index, "index", 0, "1-based source condition index in t.rules")
	fs.IntVar(&opts.Before, "before", 0, "anchor: move source to just before this 1-based condition index")
	fs.IntVar(&opts.After, "after", 0, "anchor: move source to just after this 1-based condition index")
	fs.IntVar(&opts.ToIndex, "to-index", 0, "1-based final position in t.rules")
	fs.BoolVar(&opts.ToStart, "to-start", false, "sugar for --to-index 1")
	fs.BoolVar(&opts.ToEnd, "to-end", false, "sugar for --to-index #rules")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

// meTriggerReorderConditionCmd implements
//
//	dcs-sms me trigger reorder-condition --trigger T --index N
//	  { --before M | --after M | --to-index M | --to-start | --to-end }
//
// Moves a condition to a new position in t.rules. Anchor references
// (--before / --after) are 1-based indices into t.rules. Exactly one
// position flag must be provided.
func meTriggerReorderConditionCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerReorderConditionFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Trigger == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger reorder-condition: --trigger is required")
		return 2
	}
	if opts.Index < 1 {
		fmt.Fprintln(stderr, "dcs-sms me trigger reorder-condition: --index (>= 1) is required")
		return 2
	}

	// Mutual exclusion: exactly one position flag. Note --before/--after
	// are int flags here (vs string in `me trigger reorder`); 0 means unset.
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
		fmt.Fprintln(stderr, "dcs-sms me trigger reorder-condition: exactly one of "+
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

	resp, exitCode := runMeVerb("trigger_reorder_condition", b.String(), opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
