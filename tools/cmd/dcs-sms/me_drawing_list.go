package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingListOpts struct {
	Layer      string
	Type       string
	Mode       string
	Name       string
	NamePrefix string
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meDrawingListFlags() (*flag.FlagSet, *meDrawingListOpts) {
	opts := &meDrawingListOpts{}
	fs := flag.NewFlagSet("me drawing list", flag.ContinueOnError)
	fs.StringVar(&opts.Layer, "layer", "", "Red | Blue | Neutral | Common | Author")
	fs.StringVar(&opts.Type, "type", "", "Line | Polygon | TextBox | Icon")
	fs.StringVar(&opts.Mode, "mode", "", "circle | oval | rect | free | arrow | segments | segment")
	fs.StringVar(&opts.Name, "name", "", "name substring (case-insensitive)")
	fs.StringVar(&opts.NamePrefix, "name-prefix", "", "anchored name prefix (case-insensitive); combines with --name if both given")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "list", cmdInfo{
		Run:      meDrawingListCmd,
		Flags:    flagsOnly(meDrawingListFlags),
		Synopsis: "list all drawings in the open mission",
	})
}

// meDrawingListCmd implements `dcs-sms me drawing list [filters]`.
//
// Returns concise summaries of all drawings across all 5 layers
// (Red / Blue / Neutral / Common / Author). Optional filters narrow by
// layer, primitive type, polygon/line sub-mode, or substring name match.
func meDrawingListCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingListFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	var parts []string
	if opts.Layer != "" {
		parts = append(parts, fmt.Sprintf("layer = %q", opts.Layer))
	}
	if opts.Type != "" {
		parts = append(parts, fmt.Sprintf("type = %q", opts.Type))
	}
	if opts.Mode != "" {
		parts = append(parts, fmt.Sprintf("mode = %q", opts.Mode))
	}
	if opts.Name != "" {
		parts = append(parts, fmt.Sprintf("name = %q", opts.Name))
	}
	if opts.NamePrefix != "" {
		parts = append(parts, fmt.Sprintf("name_prefix = %q", opts.NamePrefix))
	}
	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("drawing_list", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
