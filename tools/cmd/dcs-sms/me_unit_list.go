package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meUnitListOpts struct {
	Side       string
	Country    string
	Category   string
	Group      string
	Name       string
	Type       string
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
}

func meUnitListFlags() (*flag.FlagSet, *meUnitListOpts) {
	opts := &meUnitListOpts{}
	fs := flag.NewFlagSet("me unit list", flag.ContinueOnError)
	fs.StringVar(&opts.Side, "side", "", "filter by side: red | blue | neutrals")
	fs.StringVar(&opts.Country, "country", "", "filter by country (case-insensitive exact match)")
	fs.StringVar(&opts.Category, "category", "", "filter by category: plane | helicopter | vehicle | ship | static")
	fs.StringVar(&opts.Group, "group", "", "filter by group name (exact match)")
	fs.StringVar(&opts.Name, "name", "", "filter by unit-name substring (case-insensitive)")
	fs.StringVar(&opts.Type, "type", "", "filter by airframe / unit type (exact match; comma-separate for any-of, e.g. flak18,flak36,bofors40)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "list", cmdInfo{
		Run:      meUnitListCmd,
		Flags:    flagsOnly(meUnitListFlags),
		Synopsis: "list all units in the open mission",
	})
}

// meUnitListCmd implements `dcs-sms me unit list [filters]`.
func meUnitListCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitListFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	var parts []string
	if opts.Side != "" {
		parts = append(parts, fmt.Sprintf("side = %q", strings.ToLower(opts.Side)))
	}
	if opts.Country != "" {
		parts = append(parts, fmt.Sprintf("country = %q", opts.Country))
	}
	if opts.Category != "" {
		parts = append(parts, fmt.Sprintf("category = %q", strings.ToLower(opts.Category)))
	}
	if opts.Group != "" {
		parts = append(parts, fmt.Sprintf("group = %q", opts.Group))
	}
	if opts.Name != "" {
		parts = append(parts, fmt.Sprintf("name = %q", opts.Name))
	}
	if opts.Type != "" {
		// Split comma-list into a Lua list; the verb tests inclusion against
		// the set so callers can pass either a single airframe ("F-16C_50") or
		// any-of ("flak18,flak36,bofors40"). Empty entries (e.g. trailing
		// commas, double commas) are skipped silently.
		var quoted []string
		for _, t := range strings.Split(opts.Type, ",") {
			t = strings.TrimSpace(t)
			if t != "" {
				quoted = append(quoted, fmt.Sprintf("%q", t))
			}
		}
		if len(quoted) > 0 {
			parts = append(parts, "type = { "+strings.Join(quoted, ", ")+" }")
		}
	}
	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("unit_list", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
