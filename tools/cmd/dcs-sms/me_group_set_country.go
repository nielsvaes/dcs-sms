package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupSetCountryOpts struct {
	Name		string
	ID		int
	Country		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupSetCountryFlags() (*flag.FlagSet, *meGroupSetCountryOpts) {
	opts := &meGroupSetCountryOpts{}
	fs := flag.NewFlagSet("me group set-country", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.StringVar(&opts.Country, "country", "", "target country name (case-insensitive)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "set-country", cmdInfo{
		Run:		meGroupSetCountryCmd,
		Flags:		flagsOnly(meGroupSetCountryFlags),
		Synopsis:	"change a group's country/coalition",
	})
}

// meGroupSetCountryCmd implements
// `dcs-sms me group set-country --name|--id <X> --country <name>`.
//
// Moves a group between countries (and possibly coalitions). Replicates the
// data-side flow of me_aircraft.changeCountry: removes from old country list,
// updates boss/color, inserts into new country list, fixes liveries (air
// groups), and re-attracts takeoff/landing waypoints if needed.
//
// Target country must already exist in the mission tree (i.e. was added via
// the new-mission default coalitions or explicitly). Refuses cleanly if not.
//
// ME does not refuse moves that leave unit types orphaned (Su-27 → USA);
// liveries go empty but the data is otherwise valid. The verb mirrors that.
func meGroupSetCountryCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupSetCountryFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group set-country: exactly one of --name or --id is required")
		return 2
	}
	if opts.Country == "" {
		fmt.Fprintln(stderr, "dcs-sms me group set-country: --country is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, country = %s }", idClause, luaQuote(opts.Country))

	resp, exitCode := runMeVerb("group_set_country", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
