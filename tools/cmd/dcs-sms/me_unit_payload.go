package main

import (
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

func init() {
	registerMeInfo("unit", "payload", cmdInfo{
		Run:		meUnitPayloadCmd,
		Synopsis:	"manage a unit's per-pylon weapon payload (sub-verbs: set, clear, set-fuze, list-settings)",
		SubCommands: []subCommand{
			{Name: "set", Synopsis: "set a single pylon's weapon (--weapon accepts a CLSID or display name)",
				Flags: flagsOnly(meUnitPayloadSetFlags)},
			{Name: "clear", Synopsis: "remove a single pylon's weapon entry",
				Flags: flagsOnly(meUnitPayloadClearFlags)},
			{Name: "set-fuze", Synopsis: "set per-pylon weapon settings (fuzes, function delays, presets) via repeatable --set, validated against the weapon's descriptor",
				Flags: flagsOnly(meUnitPayloadSetFuzeFlags)},
			{Name: "list-settings", Synopsis: "dump a weapon's configurable-settings descriptor (ids, labels, combo values, defaults)",
				Flags: flagsOnly(meUnitPayloadListSettingsFlags)},
		},
	})
}

// meUnitPayloadCmd implements `dcs-sms me unit payload <sub-verb> [flags]`.
// Sub-dispatches on args[0] (the third token after `me unit payload`):
//   set            --pylon N --weapon CLSID|name      set a pylon's weapon
//   clear          --pylon N                          remove a pylon's weapon
//   set-fuze       --pylon N --set "<key>=<value>"…   set per-pylon settings
//   list-settings  --pylon N | --weapon CLSID         dump the settings schema
//
// `me unit set-loadout` is the verb for applying a whole named loadout —
// these per-pylon ops are for fine-tuning after.
func meUnitPayloadCmd(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" || args[0] == "help" {
		printPayloadUsage(stdout)
		if len(args) == 0 {
			return 2
		}
		return 0
	}
	switch args[0] {
	case "set":
		return meUnitPayloadSetCmd(args[1:], stdout, stderr)
	case "clear":
		return meUnitPayloadClearCmd(args[1:], stdout, stderr)
	case "set-fuze":
		return meUnitPayloadSetFuzeCmd(args[1:], stdout, stderr)
	case "list-settings":
		return meUnitPayloadListSettingsCmd(args[1:], stdout, stderr)
	default:
		fmt.Fprintf(stderr, "dcs-sms me unit payload: unknown sub-verb %q (expected set|clear|set-fuze|list-settings)\n", args[0])
		printPayloadUsage(stderr)
		return 2
	}
}

func printPayloadUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: dcs-sms me unit payload <set|clear|set-fuze|list-settings> --name|--id <X> --pylon N [...]")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Sub-verbs:")
	fmt.Fprintln(w, "  set            Set a single pylon's weapon (--weapon accepts CLSID or display name).")
	fmt.Fprintln(w, "  clear          Remove a single pylon's weapon entry.")
	fmt.Fprintln(w, "  set-fuze       Set per-pylon weapon settings (fuzes, delays, presets) via repeatable")
	fmt.Fprintln(w, "                 --set \"<id-or-label>=<value>\". Values validated against the weapon's descriptor.")
	fmt.Fprintln(w, "  list-settings  Dump a weapon's configurable settings descriptor (ids, labels, combo values).")
}

// ------------------------------------------------------------------ set

type meUnitPayloadSetOpts struct {
	Name		string
	ID		int
	Pylon		int
	Weapon		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitPayloadSetFlags() (*flag.FlagSet, *meUnitPayloadSetOpts) {
	opts := &meUnitPayloadSetOpts{}
	fs := flag.NewFlagSet("me unit payload set", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.IntVar(&opts.Pylon, "pylon", 0, "pylon number (per-airframe, see DB.unit_by_type[type].Pylons)")
	fs.StringVar(&opts.Weapon, "weapon", "", "weapon CLSID (e.g. \"{GUID}\") or display name")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func meUnitPayloadSetCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitPayloadSetFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit payload set: exactly one of --name or --id is required")
		return 2
	}
	if opts.Pylon < 1 {
		fmt.Fprintln(stderr, "dcs-sms me unit payload set: --pylon (>= 1) is required")
		return 2
	}
	if opts.Weapon == "" {
		fmt.Fprintln(stderr, "dcs-sms me unit payload set: --weapon is required")
		return 2
	}

	luaArgs := fmt.Sprintf("{ %s, pylon = %d, weapon = %s }",
		payloadIDClause(hasName, opts.Name, opts.ID), opts.Pylon, luaQuote(opts.Weapon))
	resp, exitCode := runMeVerb("unit_payload_set", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}

// ---------------------------------------------------------------- clear

type meUnitPayloadClearOpts struct {
	Name		string
	ID		int
	Pylon		int
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitPayloadClearFlags() (*flag.FlagSet, *meUnitPayloadClearOpts) {
	opts := &meUnitPayloadClearOpts{}
	fs := flag.NewFlagSet("me unit payload clear", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.IntVar(&opts.Pylon, "pylon", 0, "pylon number")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func meUnitPayloadClearCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitPayloadClearFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit payload clear: exactly one of --name or --id is required")
		return 2
	}
	if opts.Pylon < 1 {
		fmt.Fprintln(stderr, "dcs-sms me unit payload clear: --pylon (>= 1) is required")
		return 2
	}

	luaArgs := fmt.Sprintf("{ %s, pylon = %d }",
		payloadIDClause(hasName, opts.Name, opts.ID), opts.Pylon)
	resp, exitCode := runMeVerb("unit_payload_clear", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}

// ------------------------------------------------------------- set-fuze

type meUnitPayloadSetFuzeOpts struct {
	Name		string
	ID		int
	Pylon		int
	Weapon		string
	Sets		stringSliceFlag
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitPayloadSetFuzeFlags() (*flag.FlagSet, *meUnitPayloadSetFuzeOpts) {
	opts := &meUnitPayloadSetFuzeOpts{}
	fs := flag.NewFlagSet("me unit payload set-fuze", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.IntVar(&opts.Pylon, "pylon", 0, "pylon number (per-airframe)")
	fs.StringVar(&opts.Weapon, "weapon", "", "optional weapon CLSID or display name to set on the pylon first")
	fs.Var(&opts.Sets, "set", "setting as \"<id-or-label>=<value>\" (repeatable). "+
		"Key matches a descriptor id or label; value matches a combo id/name or numeric value. "+
		"Discover legal keys with `me unit payload list-settings`.")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func meUnitPayloadSetFuzeCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitPayloadSetFuzeFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit payload set-fuze: exactly one of --name or --id is required")
		return 2
	}
	if opts.Pylon < 1 {
		fmt.Fprintln(stderr, "dcs-sms me unit payload set-fuze: --pylon (>= 1) is required")
		return 2
	}
	if len(opts.Sets) == 0 {
		fmt.Fprintln(stderr, "dcs-sms me unit payload set-fuze: at least one --set \"<key>=<value>\" is required")
		return 2
	}
	pairs, err := parseSetPairs(opts.Sets)
	if err != nil {
		fmt.Fprintf(stderr, "dcs-sms me unit payload set-fuze: %v\n", err)
		return 2
	}

	var weaponClause string
	if opts.Weapon != "" {
		weaponClause = fmt.Sprintf(", weapon = %s", luaQuote(opts.Weapon))
	}
	luaArgs := fmt.Sprintf("{ %s, pylon = %d%s, sets = %s }",
		payloadIDClause(hasName, opts.Name, opts.ID), opts.Pylon, weaponClause, buildSetsExpr(pairs))
	resp, exitCode := runMeVerb("unit_payload_set_fuze", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}

// -------------------------------------------------------- list-settings

type meUnitPayloadListSettingsOpts struct {
	Name		string
	ID		int
	Pylon		int
	Weapon		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
}

func meUnitPayloadListSettingsFlags() (*flag.FlagSet, *meUnitPayloadListSettingsOpts) {
	opts := &meUnitPayloadListSettingsOpts{}
	fs := flag.NewFlagSet("me unit payload list-settings", flag.ContinueOnError)
	fs.StringVar(&opts.Name, "name", "", "unit name (mutually exclusive with --id)")
	fs.IntVar(&opts.ID, "id", 0, "unit id (mutually exclusive with --name)")
	fs.IntVar(&opts.Pylon, "pylon", 0, "pylon number (resolves the weapon from the current loadout)")
	fs.StringVar(&opts.Weapon, "weapon", "", "weapon CLSID or display name (overrides --pylon's weapon)")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	return fs, opts
}

func meUnitPayloadListSettingsCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meUnitPayloadListSettingsFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	hasName := opts.Name != ""
	hasID := opts.ID != 0
	if hasName == hasID {
		fmt.Fprintln(stderr, "dcs-sms me unit payload list-settings: exactly one of --name or --id is required")
		return 2
	}
	if opts.Pylon < 1 && opts.Weapon == "" {
		fmt.Fprintln(stderr, "dcs-sms me unit payload list-settings: --pylon (>= 1) or --weapon is required")
		return 2
	}

	parts := payloadIDClause(hasName, opts.Name, opts.ID)
	if opts.Pylon >= 1 {
		parts += fmt.Sprintf(", pylon = %d", opts.Pylon)
	}
	if opts.Weapon != "" {
		parts += fmt.Sprintf(", weapon = %s", luaQuote(opts.Weapon))
	}
	luaArgs := fmt.Sprintf("{ %s }", parts)
	resp, exitCode := runMeVerb("unit_payload_list_settings", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	return emitMeResponse(resp, opts.Pretty, stdout)
}

// ----------------------------------------------------------- shared helpers

// payloadIDClause renders the `name = "..."` or `id = N` selector clause.
func payloadIDClause(hasName bool, name string, id int) string {
	if hasName {
		return fmt.Sprintf("name = %s", luaQuote(name))
	}
	return fmt.Sprintf("id = %d", id)
}

// parseSetPairs splits repeatable `--set "<key>=<value>"` flags into ordered
// (key, value) pairs. The first `=` separates; everything after is the value
// verbatim (so dispNames with `=` survive). Order is preserved because some
// settings gate others via VisibilityCondition. Empty key → error.
func parseSetPairs(raw []string) ([]struct{ Key, Value string }, error) {
	out := make([]struct{ Key, Value string }, 0, len(raw))
	for _, a := range raw {
		i := strings.Index(a, "=")
		if i < 0 {
			return nil, fmt.Errorf("expected key=value, got %q", a)
		}
		k := a[:i]
		if k == "" {
			return nil, fmt.Errorf("empty key in %q", a)
		}
		out = append(out, struct{ Key, Value string }{k, a[i+1:]})
	}
	return out, nil
}

// buildSetsExpr renders ordered (key, value) pairs as a Lua array literal:
// { { key = "...", value = "..." }, ... }. Empty → "{}".
func buildSetsExpr(pairs []struct{ Key, Value string }) string {
	if len(pairs) == 0 {
		return "{}"
	}
	parts := make([]string, 0, len(pairs))
	for _, p := range pairs {
		parts = append(parts, fmt.Sprintf("{ key = %s, value = %s }", luaQuote(p.Key), luaQuote(p.Value)))
	}
	return "{ " + strings.Join(parts, ", ") + " }"
}
