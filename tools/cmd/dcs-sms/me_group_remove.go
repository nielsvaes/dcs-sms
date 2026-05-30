package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupRemoveOpts struct {
	Name		string
	ID		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupRemoveFlags() (*flag.FlagSet, *meGroupRemoveOpts) {
	opts := &meGroupRemoveOpts{}
	fs := flag.NewFlagSet("me group remove", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (exact match)")
	fs.IntVar(&opts.ID, "id", 0, "groupId (numeric)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "remove", cmdInfo{
		Run:		meGroupRemoveCmd,
		Flags:		flagsOnly(meGroupRemoveFlags),
		Synopsis:	"delete a group from the open mission",
	})
}

// meGroupRemoveCmd implements `dcs-sms me group remove --name <name> | --id <n>`.
//
// Walks the mission coalition tree, finds the matching group, and calls
// Mission.remove_group on it. Exactly one of --name or --id is required.
// Note: groupIds and unitIds are NOT reused after remove (they increment
// monotonically), so a fresh inject afterwards will land at id+1, not id.
func meGroupRemoveCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupRemoveFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {	// both or neither
		fmt.Fprintln(stderr, "dcs-sms me group remove: pass exactly one of --name or --id")
		return 2
	}

	var luaArgs string
	if hasName {
		luaArgs = fmt.Sprintf("{ name = %s }", luaQuote(opts.Name))
	} else {
		luaArgs = fmt.Sprintf("{ id = %d }", opts.ID)
	}

	resp, exitCode := runMeVerb("group_remove", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
