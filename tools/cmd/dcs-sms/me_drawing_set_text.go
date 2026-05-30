package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meDrawingSetTextOpts struct {
	Name		string
	Text		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meDrawingSetTextFlags() (*flag.FlagSet, *meDrawingSetTextOpts) {
	opts := &meDrawingSetTextOpts{}
	fs := flag.NewFlagSet("me drawing set-text", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "drawing name (TextBox only)")
	fs.StringVar(&opts.Text, "text", "", "new text content")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "set-text", cmdInfo{
		Run:		meDrawingSetTextCmd,
		Flags:		flagsOnly(meDrawingSetTextFlags),
		Synopsis:	"change a textbox drawing's text content",
	})
}

// meDrawingSetTextCmd implements
// `dcs-sms me drawing set-text --name <X> --text <S>`.
//
// TextBox-only setter — refuses on non-TextBox drawings (the rest
// have no text content). To change a textbox's font / fontSize /
// borderThickness / angle, remove + re-create with the new values.
func meDrawingSetTextCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingSetTextFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-text: --name is required")
		return 2
	}
	if opts.Text == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-text: --text is required")
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %s, text = %s }", luaQuote(opts.Name), luaQuote(opts.Text))

	resp, exitCode := runMeVerb("drawing_set_text", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
