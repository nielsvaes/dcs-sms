package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meDrawingSetPosOpts struct {
	Name		string
	North		float64
	East		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meDrawingSetPosFlags() (*flag.FlagSet, *meDrawingSetPosOpts) {
	opts := &meDrawingSetPosOpts{}
	fs := flag.NewFlagSet("me drawing set-pos", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "drawing name")
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "set-pos", cmdInfo{
		Run:		meDrawingSetPosCmd,
		Flags:		flagsOnly(meDrawingSetPosFlags),
		Synopsis:	"move a drawing's anchor to a new north/east coordinate",
	})
}

// meDrawingSetPosCmd implements
// `dcs-sms me drawing set-pos --name <X> --north <m> --east <m>`.
//
// Moves the drawing's anchor. For shapes with relative-to-anchor points
// (line, free polygon), the shape moves rigidly with the anchor. For
// analytic shapes (circle / rect / oval / arrow), only the center
// moves; the dimensions are unchanged.
func meDrawingSetPosCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingSetPosFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-pos: --name is required")
		return 2
	}
	northSet, eastSet := false, false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "north" {
			northSet = true
		}
		if f.Name == "east" {
			eastSet = true
		}
	})
	if !northSet || !eastSet {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-pos: --north and --east are both required")
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %s, north = %g, east = %g }", luaQuote(opts.Name), opts.North, opts.East)

	resp, exitCode := runMeVerb("drawing_set_pos", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
