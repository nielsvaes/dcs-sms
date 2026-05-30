package main

import (
	"flag"
	"fmt"
	"io"
	"time"
)

type meWaypointDescribeTaskOpts struct {
	Task		string
	Kind		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meWaypointDescribeTaskFlags() (*flag.FlagSet, *meWaypointDescribeTaskOpts) {
	opts := &meWaypointDescribeTaskOpts{}
	fs := flag.NewFlagSet("me waypoint describe-task", flag.ContinueOnError)
	fs.StringVar(&opts.Task, "task", "", "task id (e.g. Bombing, EngageTargets)")
	fs.StringVar(&opts.Kind, "kind", "", "optional filter: 'waypoint' or 'enroute'")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func init() {
	registerMeInfo("waypoint", "describe-task", cmdInfo{
		Run:		meWaypointDescribeTaskCmd,
		Flags:		flagsOnly(meWaypointDescribeTaskFlags),
		Synopsis:	"print the parameter schema (fields, defaults, allowed values) of one task id",
	})
}

func meWaypointDescribeTaskCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meWaypointDescribeTaskFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Task == "" {
		fmt.Fprintln(stderr, "dcs-sms me waypoint describe-task: --task is required")
		return 2
	}
	if opts.Kind != "" && opts.Kind != "waypoint" && opts.Kind != "enroute" {
		fmt.Fprintln(stderr, "dcs-sms me waypoint describe-task: --kind must be 'waypoint' or 'enroute' (or omitted)")
		return 2
	}
	var luaArgs string
	if opts.Kind == "" {
		luaArgs = fmt.Sprintf("{ task = %s }", luaQuote(opts.Task))
	} else {
		luaArgs = fmt.Sprintf("{ task = %s, kind = %s }", luaQuote(opts.Task), luaQuote(opts.Kind))
	}
	resp, exitCode := runMeVerb("waypoint_describe_task", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}
