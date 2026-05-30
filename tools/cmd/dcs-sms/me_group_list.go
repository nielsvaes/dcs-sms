package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

type meGroupListOpts struct {
	Side		string
	Country		string
	Category	string
	Name		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupListFlags() (*flag.FlagSet, *meGroupListOpts) {
	opts := &meGroupListOpts{}
	fs := flag.NewFlagSet("me group list", flag.ContinueOnError)
	fs.StringVar(&opts.Side, "side", "", "filter by side: red | blue | neutrals")
	fs.StringVar(&opts.Country, "country", "", "filter by country (case-insensitive exact match)")
	fs.StringVar(&opts.Category, "category", "", "filter by category: plane | helicopter | vehicle | ship | static")
	fs.StringVar(&opts.Name, "name", "", "filter by group-name substring (case-insensitive)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "list", cmdInfo{
		Run:		meGroupListCmd,
		Flags:		flagsOnly(meGroupListFlags),
		Synopsis:	"list all groups in the open mission",
	})
}

// meGroupListCmd implements `dcs-sms me group list [--side --country --category --name]`.
//
// Returns concise group summaries. All filter flags are optional and AND-combined.
// For full mission-table detail of one group, use `me group get`.
func meGroupListCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupListFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	var parts []string
	if opts.Side != "" {
		parts = append(parts, fmt.Sprintf("side = %s", luaQuote(strings.ToLower(opts.Side))))
	}
	if opts.Country != "" {
		parts = append(parts, fmt.Sprintf("country = %s", luaQuote(opts.Country)))
	}
	if opts.Category != "" {
		parts = append(parts, fmt.Sprintf("category = %s", luaQuote(strings.ToLower(opts.Category))))
	}
	if opts.Name != "" {
		parts = append(parts, fmt.Sprintf("name = %s", luaQuote(opts.Name)))
	}
	luaArgs := "{ " + strings.Join(parts, ", ") + " }"

	resp, exitCode := runMeVerb("group_list", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
