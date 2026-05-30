package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meDrawingSetAngleOpts struct {
	Name		string
	Angle		float64
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meDrawingSetAngleFlags() (*flag.FlagSet, *meDrawingSetAngleOpts) {
	opts := &meDrawingSetAngleOpts{}
	fs := flag.NewFlagSet("me drawing set-angle", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "drawing name")
	fs.Float64Var(&opts.Angle, "angle", 0, "rotation in degrees (CW positive)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "set-angle", cmdInfo{
		Run:		meDrawingSetAngleCmd,
		Flags:		flagsOnly(meDrawingSetAngleFlags),
		Synopsis:	"set a drawing's rotation in degrees (CW positive)",
	})
}

// meDrawingSetAngleCmd implements
// `dcs-sms me drawing set-angle --name <X> --angle <degrees>`.
//
// Rotates a drawing around its anchor. Supported shapes: TextBox, Icon,
// and Polygon (oval / rect / arrow). Line, Polygon-circle (rotation
// symmetric), and Polygon-free (would need per-point transform) are
// refused with a clear error.
//
// Angle is in degrees (CW positive). Internally converted to radians
// via math.rad — saveToMission's `angle` field is radians, so this
// keeps the on-disk format consistent.
func meDrawingSetAngleCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingSetAngleFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Name == "" {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-angle: --name is required")
		return 2
	}
	angleSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "angle" {
			angleSet = true
		}
	})
	if !angleSet {
		fmt.Fprintln(stderr, "dcs-sms me drawing set-angle: --angle is required (degrees)")
		return 2
	}
	luaArgs := fmt.Sprintf("{ name = %s, angle_deg = %g }", luaQuote(opts.Name), opts.Angle)

	resp, exitCode := runMeVerb("drawing_set_angle", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
