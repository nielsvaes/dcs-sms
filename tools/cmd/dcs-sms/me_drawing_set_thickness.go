package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meDrawingSetThicknessOpts struct {
	Name		string
	Thickness	float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meDrawingSetThicknessFlags() (*flag.FlagSet, *meDrawingSetThicknessOpts) {
	opts := &meDrawingSetThicknessOpts{}
	fs := flag.NewFlagSet("me drawing set-thickness", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "drawing name (Line / Polygon only)")
	fs.Float64Var(&opts.Thickness, "thickness", 0, "thickness in pixels (positive)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "set-thickness", cmdInfo{
		Run:		meDrawingSetThicknessCmd,
		Flags:		flagsOnly(meDrawingSetThicknessFlags),
		Synopsis:	"change a line / polygon drawing's outline thickness",
	})
}

// meDrawingSetThicknessCmd implements
// `dcs-sms me drawing set-thickness --name <X> --thickness <px>`.
//
// Line and Polygon shapes only. TextBox has its own border-thickness
// concept (separate verb if/when needed); Icon has scale instead.
func meDrawingSetThicknessCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingSetThicknessFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-thickness: --name is required")
		return 2
	}
	if opts.Thickness <= 0 {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-thickness: --thickness is required (> 0)")
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %s, thickness = %g }", luaQuote(opts.Name), opts.Thickness)

	resp, exitCode := runMeVerb("drawing_set_thickness", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
