package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingCreateIconOpts struct {
	North		float64
	East		float64
	File		string
	Scale		float64
	Angle		float64
	Name		string
	Color		string
	Layer		string
	HiddenOnPlanner	bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meDrawingCreateIconFlags() (*flag.FlagSet, *meDrawingCreateIconOpts) {
	opts := &meDrawingCreateIconOpts{}
	fs := flag.NewFlagSet("me drawing create-icon", flag.ContinueOnError)
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (icon anchor)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (icon anchor)")
	fs.StringVar(&opts.File, "file", "", "icon filename within the icons folder")
	fs.Float64Var(&opts.Scale, "scale", 1, "icon scale (default 1)")
	fs.Float64Var(&opts.Angle, "angle", 0, "rotation in degrees (CW, 0 = unrotated)")
	fs.StringVar(&opts.Name, "name", "", "drawing name (auto-allocated if empty)")
	fs.StringVar(&opts.Color, "color", "", "tint color (default white, opaque)")
	fs.StringVar(&opts.Layer, "layer", "", "Red|Blue|Neutral|Common|Author (default Common)")
	fs.BoolVar(&opts.HiddenOnPlanner, "hidden-on-planner", false, "hide on mission planner")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "create-icon", cmdInfo{
		Run:		meDrawingCreateIconCmd,
		Flags:		flagsOnly(meDrawingCreateIconFlags),
		Synopsis:	"place an icon on the F10 map",
	})
}

// meDrawingCreateIconCmd implements
// `dcs-sms me drawing create-icon --north <m> --east <m> --file <F> [...]`.
//
// Icon drawing at a map point. The icon `file` is a filename within
// the active icon folder ('./MissionEditor/data/NewMap/images/<theme>/'
// where theme is 'nato' or 'russian' per the user's options). Pass the
// bare filename (e.g. 'aaa_air_neutral.png'); the runtime resolves the
// theme prefix.
func meDrawingCreateIconCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingCreateIconFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.File == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-icon: --file is required")
		return 2
	}

	colorLua, err := parseDrawingColorToHex(opts.Color, 0xFF)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-icon:", err)
		return 2
	}

	parts := []string{
		fmt.Sprintf("north = %g", opts.North),
		fmt.Sprintf("east = %g", opts.East),
		fmt.Sprintf("file = %s", luaQuote(opts.File)),
		fmt.Sprintf("scale = %g", opts.Scale),
		fmt.Sprintf("angle_deg = %g", opts.Angle),
	}
	if opts.Name != "" {
		parts = append(parts, fmt.Sprintf("name = %s", luaQuote(opts.Name)))
	}
	if colorLua != "" {
		parts = append(parts, "color = "+colorLua)
	}
	if opts.Layer != "" {
		parts = append(parts, fmt.Sprintf("layer = %s", luaQuote(opts.Layer)))
	}
	if opts.HiddenOnPlanner {
		parts = append(parts, "hidden_on_planner = true")
	}
	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("drawing_create_icon", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
