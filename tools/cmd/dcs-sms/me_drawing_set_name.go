package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meDrawingSetNameOpts struct {
	Name		string
	NewName		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meDrawingSetNameFlags() (*flag.FlagSet, *meDrawingSetNameOpts) {
	opts := &meDrawingSetNameOpts{}
	fs := flag.NewFlagSet("me drawing set-name", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "current drawing name")
	fs.StringVar(&opts.NewName, "new-name", "", "new drawing name")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "set-name", cmdInfo{
		Run:		meDrawingSetNameCmd,
		Flags:		flagsOnly(meDrawingSetNameFlags),
		Synopsis:	"rename a drawing",
	})
}

// meDrawingSetNameCmd implements
// `dcs-sms me drawing set-name --name <X> --new-name <Y>`.
//
// Refuses on name collision — drawing names are unique across all
// layers (verifyName at panel level enforces this).
func meDrawingSetNameCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingSetNameFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-name: --name is required")
		return 2
	}
	if opts.NewName == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-name: --new-name is required")
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %s, new_name = %s }", luaQuote(opts.Name), luaQuote(opts.NewName))

	resp, exitCode := runMeVerb("drawing_set_name", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
