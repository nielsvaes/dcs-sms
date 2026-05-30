package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupSetTaskOpts struct {
	Name		string
	ID		int
	Task		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupSetTaskFlags() (*flag.FlagSet, *meGroupSetTaskOpts) {
	opts := &meGroupSetTaskOpts{}
	fs := flag.NewFlagSet("me group set-task", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.StringVar(&opts.Task, "task", "", "group task (e.g. CAP, CAS, Escort, Nothing)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "set-task", cmdInfo{
		Run:		meGroupSetTaskCmd,
		Flags:		flagsOnly(meGroupSetTaskFlags),
		Synopsis:	"set a group's role/task (e.g. CAP, CAS, Escort)",
	})
}

// meGroupSetTaskCmd implements `dcs-sms me group set-task --name|--id <X> --task <T>`.
//
// Sets the group-level mission task (g.task). Common values: "Nothing",
// "CAS", "CAP", "Intercept", "Escort", "Reconnaissance", "AWACS", "Tanker",
// "Refueling", "Ground Attack", "SEAD", "Anti-ship Strike", "Pinpoint
// Strike", "Runway Attack", "Fighter Sweep", "Transport". Note: this is the
// *group* task, not a waypoint task — waypoints carry their own ComboTask.
//
// The ME does not range-check the value; passing an unknown task string just
// stores it as-is. The discoverable list is in
// MissionEditor/modules/Mission/CoalitionPanel.lua.
func meGroupSetTaskCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupSetTaskFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group set-task: exactly one of --name or --id is required")
		return 2
	}
	if opts.Task == "" {
		fmt.Fprintln(stderr, "dcs-sms me group set-task: --task is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, task = %s }", idClause, luaQuote(opts.Task))

	resp, exitCode := runMeVerb("group_set_task", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
