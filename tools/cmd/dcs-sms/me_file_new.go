package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meFileNewOpts struct {
	Map		string
	Force		bool
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meFileNewFlags() (*flag.FlagSet, *meFileNewOpts) {
	opts := &meFileNewOpts{}
	fs := flag.NewFlagSet("me file new", flag.ContinueOnError)
	fs.StringVar(&opts.Map, "map", "", "theatre name (e.g. Syria, Caucasus)")
	fs.BoolVar(&opts.Force, "force", false, "discard unsaved changes in the current mission")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("file", "new", cmdInfo{
		Run:		meFileNewCmd,
		Flags:		flagsOnly(meFileNewFlags),
		Synopsis:	"create a new empty mission in the open Mission Editor",
	})
}

// meFileNewCmd implements `dcs-sms me file new --map <theatre>`.
//
// Calls dcs_sms_me.verbs.file_new(args) on the ME-mod side, which bypasses the
// "New Mission Settings" UI dialog and reproduces its OK-button effect
// directly: setDefaultCoalitions → selectTheatreOfWar → MapWindow.initTerrain
// → module_mission.create_new_mission. The terrain init runs on a later tick
// (scheduled via ProgressBarDialog), so the response confirms dispatch, not
// completion.
func meFileNewCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meFileNewFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Map == "" {
		fmt.Fprintln(stderr, "dcs-sms me file new: --map is required")
		return 2
	}

	luaArgs := fmt.Sprintf("{ map = %s, force = %t }", luaQuote(opts.Map), opts.Force)

	resp, exitCode := runMeVerb("file_new", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
