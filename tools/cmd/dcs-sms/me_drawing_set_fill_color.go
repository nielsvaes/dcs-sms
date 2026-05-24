package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meDrawingSetFillColorOpts struct {
	Name       string
	Color      string
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meDrawingSetFillColorFlags() (*flag.FlagSet, *meDrawingSetFillColorOpts) {
	opts := &meDrawingSetFillColorOpts{}
	fs := flag.NewFlagSet("me drawing set-fill-color", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "drawing name")
	fs.StringVar(&opts.Color, "color", "", "color: name, #rrggbb, #rrggbbaa, or 0xRRGGBBAA")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "set-fill-color", cmdInfo{
		Run:      meDrawingSetFillColorCmd,
		Flags:    flagsOnly(meDrawingSetFillColorFlags),
		Synopsis: "change a drawing's fill color",
	})
}

// meDrawingSetFillColorCmd implements
// `dcs-sms me drawing set-fill-color --name <X> --color <c>`.
//
// Polygon shapes (circle / rect / oval / arrow / free) and TextBox have a
// fill color. Line and Icon don't — the verb refuses on those. Default
// alpha 0x80 (half) matches create-time defaults.
func meDrawingSetFillColorCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingSetFillColorFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-fill-color: --name is required")
		return 2
	}
	if opts.Color == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-fill-color: --color is required")
		return 2
	}
	colorLua, err := parseDrawingColorToHex(opts.Color, 0x80)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-fill-color:", err)
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %q, color = %s }", opts.Name, colorLua)

	resp, exitCode := runMeVerb("drawing_set_fill_color", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
