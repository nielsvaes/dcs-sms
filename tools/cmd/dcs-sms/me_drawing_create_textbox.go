package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingCreateTextboxOpts struct {
	North		float64
	East		float64
	Text		string
	FontSize	int
	BorderThickness	int
	Angle		float64
	Font		string
	Name		string
	Color		string
	FillColor	string
	Layer		string
	HiddenOnPlanner	bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meDrawingCreateTextboxFlags() (*flag.FlagSet, *meDrawingCreateTextboxOpts) {
	opts := &meDrawingCreateTextboxOpts{}
	fs := flag.NewFlagSet("me drawing create-textbox", flag.ContinueOnError)
	fs.Float64Var(&opts.North, "north", 0, "meters north of theatre origin (textbox anchor)")
	fs.Float64Var(&opts.East, "east", 0, "meters east of theatre origin (textbox anchor)")
	fs.StringVar(&opts.Text, "text", "", "text content")
	fs.IntVar(&opts.FontSize, "font-size", 0, "font size in pixels (default 24)")
	fs.IntVar(&opts.BorderThickness, "border-thickness", -1, "border thickness in pixels (default 4)")
	fs.Float64Var(&opts.Angle, "angle", 0, "rotation in degrees (CW, 0 = upright)")
	fs.StringVar(&opts.Font, "font", "", "font ttf filename (default DejaVuLGCSansCondensed.ttf)")
	fs.StringVar(&opts.Name, "name", "", "drawing name (auto-allocated if empty)")
	fs.StringVar(&opts.Color, "color", "", "text color (default green, opaque)")
	fs.StringVar(&opts.FillColor, "fill-color", "", "background fill (default red, half alpha)")
	fs.StringVar(&opts.Layer, "layer", "", "Red|Blue|Neutral|Common|Author (default Common)")
	fs.BoolVar(&opts.HiddenOnPlanner, "hidden-on-planner", false, "hide on mission planner")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "create-textbox", cmdInfo{
		Run:		meDrawingCreateTextboxCmd,
		Flags:		flagsOnly(meDrawingCreateTextboxFlags),
		Synopsis:	"place a text label on the F10 map",
	})
}

// meDrawingCreateTextboxCmd implements
// `dcs-sms me drawing create-textbox --north <m> --east <m> --text <S> [...]`.
//
// Text label drawn at a map point. The text color (--color) is the
// foreground (default green opaque, matching the ME's own new-textbox
// default), --fill-color is the background (default red 50% alpha).
// Default font is DejaVuLGCSansCondensed.ttf — same one the ME uses
// internally for new textboxes.
func meDrawingCreateTextboxCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingCreateTextboxFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Text == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-textbox: --text is required")
		return 2
	}

	colorLua, err := parseDrawingColorToHex(opts.Color, 0xFF)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-textbox:", err)
		return 2
	}
	fillLua, err := parseDrawingColorToHex(opts.FillColor, 0x80)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms me drawing create-textbox:", err)
		return 2
	}

	parts := []string{
		fmt.Sprintf("north = %g", opts.North),
		fmt.Sprintf("east = %g", opts.East),
		fmt.Sprintf("text = %s", luaQuote(opts.Text)),
		fmt.Sprintf("angle_deg = %g", opts.Angle),
	}
	if opts.FontSize > 0 {
		parts = append(parts, fmt.Sprintf("font_size = %d", opts.FontSize))
	}
	if opts.BorderThickness >= 0 {
		parts = append(parts, fmt.Sprintf("border_thickness = %d", opts.BorderThickness))
	}
	if opts.Font != "" {
		parts = append(parts, fmt.Sprintf("font = %s", luaQuote(opts.Font)))
	}
	if opts.Name != "" {
		parts = append(parts, fmt.Sprintf("name = %s", luaQuote(opts.Name)))
	}
	if colorLua != "" {
		parts = append(parts, "color = "+colorLua)
	}
	if fillLua != "" {
		parts = append(parts, "fill_color = "+fillLua)
	}
	if opts.Layer != "" {
		parts = append(parts, fmt.Sprintf("layer = %s", luaQuote(opts.Layer)))
	}
	if opts.HiddenOnPlanner {
		parts = append(parts, "hidden_on_planner = true")
	}
	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("drawing_create_textbox", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
