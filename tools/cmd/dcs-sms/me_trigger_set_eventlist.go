package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerSetEventlistOpts struct {
	Name		string
	Event		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meTriggerSetEventlistFlags() (*flag.FlagSet, *meTriggerSetEventlistOpts) {
	opts := &meTriggerSetEventlistOpts{}
	fs := flag.NewFlagSet("me trigger set-eventlist", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "trigger name")
	fs.StringVar(&opts.Event, "event", "", "event id (empty to clear)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "set-eventlist", cmdInfo{
		Run:		meTriggerSetEventlistCmd,
		Flags:		flagsOnly(meTriggerSetEventlistFlags),
		Synopsis:	"set the event filter list for an event-driven trigger",
	})
}

// meTriggerSetEventlistCmd implements
// `dcs-sms me trigger set-eventlist --name X [--event E]`.
//
// Sets the trigger's event filter. Pass --event "" or omit it to clear.
func meTriggerSetEventlistCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerSetEventlistFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger set-eventlist: --name is required")
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %s, event = %s }", luaQuote(opts.Name), luaQuote(opts.Event))
	resp, exitCode := runMeVerb("trigger_set_eventlist", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
