package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meDrawingRemoveOpts struct {
	Name       string
	NamePrefix string
	Layer      string
	All        bool
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meDrawingRemoveFlags() (*flag.FlagSet, *meDrawingRemoveOpts) {
	opts := &meDrawingRemoveOpts{}
	fs := flag.NewFlagSet("me drawing remove", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "drawing name (exact, single delete)")
	fs.StringVar(&opts.NamePrefix, "name-prefix", "", "batch delete: name prefix (case-insensitive); combines with --layer")
	fs.StringVar(&opts.Layer, "layer", "", "scope to layer: Red | Blue | Neutral | Common | Author")
	fs.BoolVar(&opts.All, "all", false, "required when deleting by --layer alone (no --name or --name-prefix); deletes every drawing on that layer")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("drawing", "remove", cmdInfo{
		Run:      meDrawingRemoveCmd,
		Flags:    flagsOnly(meDrawingRemoveFlags),
		Synopsis: "delete one or many drawings from the open mission",
	})
}

// meDrawingRemoveCmd implements `dcs-sms me drawing remove [--name X | --name-prefix P [--layer L] | --layer L --all]`.
//
// Three modes:
//   1. --name <X>                 — exact single delete (legacy form).
//   2. --name-prefix <P> [--layer <L>]
//                                 — batch delete every drawing whose name starts with P
//                                   (case-insensitive), optionally scoped to a layer.
//   3. --layer <L> --all          — wipe an entire layer. The --all guard exists so a
//                                   stray `--layer Blue` doesn't accidentally delete
//                                   every Blue drawing.
//
// Returns { ok=true, removed = [names...], count = N }. Exit code is 1 if zero matched
// (so the caller can distinguish a no-op from an environment problem).
func meDrawingRemoveCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meDrawingRemoveFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	hasName := opts.Name != ""
	hasPrefix := opts.NamePrefix != ""
	hasLayer := opts.Layer != ""

	if !hasName && !hasPrefix && !hasLayer {
		fmt.Fprintln(stderr, "dcs-sms me drawing remove: provide --name, --name-prefix, or --layer (with --all)")
		return 2
	}
	if hasName && (hasPrefix || hasLayer) {
		fmt.Fprintln(stderr, "dcs-sms me drawing remove: --name is exclusive with --name-prefix and --layer")
		return 2
	}
	if !hasName && !hasPrefix && hasLayer && !opts.All {
		fmt.Fprintln(stderr, "dcs-sms me drawing remove: --layer without --name-prefix requires --all to confirm full-layer wipe")
		return 2
	}

	var parts []string
	if hasName {
		parts = append(parts, fmt.Sprintf("name = %q", opts.Name))
	}
	if hasPrefix {
		parts = append(parts, fmt.Sprintf("name_prefix = %q", opts.NamePrefix))
	}
	if hasLayer {
		parts = append(parts, fmt.Sprintf("layer = %q", opts.Layer))
	}
	if opts.All {
		parts = append(parts, "all = true")
	}
	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("drawing_remove", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
