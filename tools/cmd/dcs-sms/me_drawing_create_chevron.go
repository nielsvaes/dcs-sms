package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingCreateChevronOpts struct {
	North           float64
	East            float64
	Bearing         float64
	Size            float64
	ArmAngle        float64
	Name            string
	Color           string
	Thickness       float64
	Style           string
	Layer           string
	HiddenOnPlanner bool
	Timeout         time.Duration
	Pretty          bool
	SavedGames      string
}

func meDrawingCreateChevronFlags() (*flag.FlagSet, *meDrawingCreateChevronOpts) {
	opts := &meDrawingCreateChevronOpts{}
	fs := flag.NewFlagSet("me drawing create-chevron", flag.ContinueOnError)
	fs.Float64Var(&opts.North, "north", 0, "meters north (chevron tip)")
	fs.Float64Var(&opts.East, "east", 0, "meters east (chevron tip)")
	fs.Float64Var(&opts.Bearing, "bearing", 0, "tip bearing in degrees (0=N, 90=E, clockwise) — the direction the V points")
	fs.Float64Var(&opts.Size, "size", 0, "arm length in meters (each arm extends this far back from the tip)")
	fs.Float64Var(&opts.ArmAngle, "arm-angle", 100,
		"angle of each arm from the forward bearing, in degrees (0,180). 100=wide V (160° tip — good for route ticks), 150=tight arrowhead (60° tip)")
	fs.StringVar(&opts.Name, "name", "", "drawing name (auto-allocated if empty)")
	fs.StringVar(&opts.Color, "color", "", "line color: name, #rrggbb, #rrggbbaa, or 0xRRGGBBAA (default red, opaque)")
	fs.Float64Var(&opts.Thickness, "thickness", 0, "line thickness in pixels (default 2)")
	fs.StringVar(&opts.Style, "style", "", "line style (default solid)")
	fs.StringVar(&opts.Layer, "layer", "", "Red|Blue|Neutral|Common|Author (default Common)")
	fs.BoolVar(&opts.HiddenOnPlanner, "hidden-on-planner", false, "hide on mission planner")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "create-chevron", cmdInfo{
		Run:      meDrawingCreateChevronCmd,
		Flags:    flagsOnly(meDrawingCreateChevronFlags),
		Synopsis: "draw a V-shape chevron / directional tick mark on the F10 map",
	})
}

// meDrawingCreateChevronCmd implements
// `dcs-sms me drawing create-chevron --north <m> --east <m> --bearing <deg> --size <m> [...]`.
//
// Renders a 3-vertex chevron: tip at (north, east), arms of length `size`
// meters extending at +/- arm-angle degrees off the forward bearing.
// Internally a 2-segment polyline; reuses the same plumbing as create-line.
//
// Useful for route tick marks, threat-direction indicators, and any other
// directional V the caller would otherwise build by hand with sin/cos.
func meDrawingCreateChevronCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingCreateChevronFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Size <= 0 {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-chevron: --size is required (> 0, meters)")
		return 2
	}
	if opts.ArmAngle <= 0 || opts.ArmAngle >= 180 {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-chevron: --arm-angle must be in (0, 180) degrees")
		return 2
	}

	colorLua, err := parseDrawingColorToHex(opts.Color, 0xFF)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-chevron:", err)
		return 2
	}

	parts := []string{
		fmt.Sprintf("north = %g", opts.North),
		fmt.Sprintf("east = %g", opts.East),
		fmt.Sprintf("bearing = %g", opts.Bearing),
		fmt.Sprintf("size = %g", opts.Size),
		fmt.Sprintf("arm_angle = %g", opts.ArmAngle),
	}
	if opts.Name != "" {
		parts = append(parts, fmt.Sprintf("name = %q", opts.Name))
	}
	if colorLua != "" {
		parts = append(parts, "color = "+colorLua)
	}
	if opts.Thickness > 0 {
		parts = append(parts, fmt.Sprintf("thickness = %g", opts.Thickness))
	}
	if opts.Style != "" {
		parts = append(parts, fmt.Sprintf("style = %q", opts.Style))
	}
	if opts.Layer != "" {
		parts = append(parts, fmt.Sprintf("layer = %q", opts.Layer))
	}
	if opts.HiddenOnPlanner {
		parts = append(parts, "hidden_on_planner = true")
	}
	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("drawing_create_chevron", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
