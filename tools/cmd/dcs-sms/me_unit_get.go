package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meUnitGetOpts struct {
	Name		string
	ID		int
	GroupName	string
	GroupID		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitGetFlags() (*flag.FlagSet, *meUnitGetOpts) {
	opts := &meUnitGetOpts{}
	fs := flag.NewFlagSet("me unit get", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (exact match)")
	fs.IntVar(&opts.ID, "id", 0, "unitId (numeric)")
	fs.StringVar(&opts.GroupName, "group-name", "", "parent group name (returns the first unit of that group)")
	fs.IntVar(&opts.GroupID, "group-id", 0, "parent groupId (returns the first unit of that group)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("unit", "get", cmdInfo{
		Run:		meUnitGetCmd,
		Flags:		flagsOnly(meUnitGetFlags),
		Synopsis:	"return full data for a unit (by --name/--id, or first unit of a group via --group-name/--group-id)",
	})
}

// meUnitGetCmd implements `dcs-sms me unit get --name <n> | --id <n> | --group-name <n> | --group-id <n>`.
func meUnitGetCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitGetFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	selectors := 0
	if opts.Name != "" {
		selectors++
	}
	if opts.ID != 0 {
		selectors++
	}
	if opts.GroupName != "" {
		selectors++
	}
	if opts.GroupID != 0 {
		selectors++
	}
	if selectors != 1 {
		fmt.Fprintln(stderr, "dcs-sms me unit get: pass exactly one of --name, --id, --group-name, or --group-id")
		return 2
	}
	var luaArgs string
	switch {
	case opts.Name != "":
		luaArgs = fmt.Sprintf("{ name = %s }", luaQuote(opts.Name))
	case opts.ID != 0:
		luaArgs = fmt.Sprintf("{ id = %d }", opts.ID)
	case opts.GroupName != "":
		luaArgs = fmt.Sprintf("{ group_name = %s }", luaQuote(opts.GroupName))
	default:
		luaArgs = fmt.Sprintf("{ group_id = %d }", opts.GroupID)
	}
	resp, exitCode := runMeVerb("unit_get", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
