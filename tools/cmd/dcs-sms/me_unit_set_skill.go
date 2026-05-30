package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitSetSkillOpts struct {
	Name		string
	ID		int
	Skill		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitSetSkillFlags() (*flag.FlagSet, *meUnitSetSkillOpts) {
	opts := &meUnitSetSkillOpts{}
	fs := flag.NewFlagSet("me unit set-skill", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.StringVar(&opts.Skill, "skill", "",
		"skill: Average | Good | High | Excellent | Random | Player | Client")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "set-skill", cmdInfo{
		Run:		meUnitSetSkillCmd,
		Flags:		flagsOnly(meUnitSetSkillFlags),
		Synopsis:	"set a unit's AI skill (Average, Good, High, Excellent, Random, Player)",
	})
}

// meUnitSetSkillCmd implements `dcs-sms me unit set-skill --name|--id <X> --skill <S>`.
//
// AI skill levels: Average, Good, High, Excellent, Random, Player, Client.
// (No validation here — DCS stores the string verbatim. Misspellings will
// surface at mission-load time.)
func meUnitSetSkillCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitSetSkillFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit set-skill: exactly one of --name or --id is required")
		return 2
	}
	if opts.Skill == "" {
		fmt.Fprintln(stderr, "dcs-sms me unit set-skill: --skill is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, skill = %s }", idClause, luaQuote(opts.Skill))

	resp, exitCode := runMeVerb("unit_set_skill", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
