package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meDrawingSetColorOpts struct {
	Name       string
	Color      string
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meDrawingSetColorFlags() (*flag.FlagSet, *meDrawingSetColorOpts) {
	opts := &meDrawingSetColorOpts{}
	fs := flag.NewFlagSet("me drawing set-color", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "drawing name")
	fs.StringVar(&opts.Color, "color", "", "color: name, #rrggbb, #rrggbbaa, or 0xRRGGBBAA")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "set-color", cmdInfo{
		Run:      meDrawingSetColorCmd,
		Flags:    flagsOnly(meDrawingSetColorFlags),
		Synopsis: "change a drawing's outline / line color",
	})
}

// meDrawingSetColorCmd implements
// `dcs-sms me drawing set-color --name <X> --color <c>`.
//
// Changes the colorString field on the drawing (outline / line / text
// color depending on shape — for fills use set-fill-color). Color
// accepts the same shapes as create-* `--color`: name, "#rrggbb",
// "#rrggbbaa". Default alpha 0xFF.
func meDrawingSetColorCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingSetColorFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-color: --name is required")
		return 2
	}
	if opts.Color == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-color: --color is required")
		return 2
	}
	colorLua, err := parseDrawingColorToHex(opts.Color, 0xFF)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-color:", err)
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %q, color = %s }", opts.Name, colorLua)

	resp, exitCode := runMeVerb("drawing_set_color", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
