package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meTriggerReorderOpts struct {
	Name		string
	Before		string
	After		string
	ToIndex		int
	ToStart		bool
	ToEnd		bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerReorderFlags() (*flag.FlagSet, *meTriggerReorderOpts) {
	opts := &meTriggerReorderOpts{}
	fs := flag.NewFlagSet("me trigger reorder", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "trigger name to move (the comment field)")
	fs.StringVar(&opts.Before, "before", "", "anchor: move source to just before this trigger name")
	fs.StringVar(&opts.After, "after", "", "anchor: move source to just after this trigger name")
	fs.IntVar(&opts.ToIndex, "to-index", 0, "1-based final position in mission.trigrules")
	fs.BoolVar(&opts.ToStart, "to-start", false, "sugar for --to-index 1")
	fs.BoolVar(&opts.ToEnd, "to-end", false, "sugar for --to-index #trigrules")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "reorder", cmdInfo{
		Run:		meTriggerReorderCmd,
		Flags:		flagsOnly(meTriggerReorderFlags),
		Synopsis:	"reorder triggers in the open mission",
	})
}

// meTriggerReorderCmd implements
//
//	dcs-sms me trigger reorder --name T { --before X | --after X
//	                                    | --to-index N | --to-start
//	                                    | --to-end }
//
// Moves a trigger to a new position in mission.trigrules. Exactly one
// position flag must be provided.
func meTriggerReorderCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerReorderFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger reorder: --name is required")
		return 2
	}

	// Mutual exclusion: exactly one position flag.
	set := 0
	if opts.Before != "" {
		set++
	}
	if opts.After != "" {
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
		fmt.Fprintln(stderr, "dcs-sms me trigger reorder: exactly one of "+
			"--before / --after / --to-index / --to-start / --to-end is required")
		return 2
	}

	// Build the Lua args literal.
	var b strings.Builder
	fmt.Fprintf(&b, "{ name = %s", luaQuote(opts.Name))
	if opts.Before != "" {
		fmt.Fprintf(&b, ", before = %s", luaQuote(opts.Before))
	}
	if opts.After != "" {
		fmt.Fprintf(&b, ", after = %s", luaQuote(opts.After))
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

	resp, exitCode := runMeVerb("trigger_reorder", b.String(), opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
