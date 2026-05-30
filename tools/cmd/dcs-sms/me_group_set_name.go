package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meGroupSetNameOpts struct {
	Name		string
	ID		int
	NewName		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meGroupSetNameFlags() (*flag.FlagSet, *meGroupSetNameOpts) {
	opts := &meGroupSetNameOpts{}
	fs := flag.NewFlagSet("me group set-name", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "group name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "group id (mutually exclusive with --name)")
	fs.StringVar(&opts.NewName, "new-name", "", "new group name")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("group", "set-name", cmdInfo{
		Run:		meGroupSetNameCmd,
		Flags:		flagsOnly(meGroupSetNameFlags),
		Synopsis:	"rename a group",
	})
}

// meGroupSetNameCmd implements `dcs-sms me group set-name --name|--id <X> --new-name <Y>`.
//
// Uses Mission.renameGroup which refuses on collision (returns false). The
// verb propagates that as an error rather than silently uniquifying — if the
// user picks a colliding name we want them to know, not get back "Foo-1".
func meGroupSetNameCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meGroupSetNameFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me group set-name: exactly one of --name or --id is required")
		return 2
	}
	if opts.NewName == "" {
		fmt.Fprintln(stderr, "dcs-sms me group set-name: --new-name is required")
		return 2
	}

	var idClause string
	if hasName {
		idClause = fmt.Sprintf("name = %s", luaQuote(opts.Name))
	} else {
		idClause = fmt.Sprintf("id = %d", opts.ID)
	}
	luaArgs := fmt.Sprintf("{ %s, new_name = %s }", idClause, luaQuote(opts.NewName))

	resp, exitCode := runMeVerb("group_set_name", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
