package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"time"
)

type meTriggerCreateOpts struct {
	Type		string
	Name		string
	Timeout		time.Duration
	Pretty		bool
	SavedGames	string
	Conditions	stringSliceFlag
	Actions		stringSliceFlag
}

func meTriggerCreateFlags() (*flag.FlagSet, *meTriggerCreateOpts) {
	opts := &meTriggerCreateOpts{}
	fs := flag.NewFlagSet("me trigger create", flag.ContinueOnError)
	fs.StringVar(&opts.Type, "type", "", "trigger type: once|continuous|start|front")
	fs.StringVar(&opts.Name, "name", "", "trigger name (defaults to \"Trigger <epoch>\")")
	fs.DurationVar(&opts.Timeout, "timeout", 30*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	fs.Var(&opts.Conditions, "condition", `bundled condition (repeatable): "<predicate> k=v..."`)
	fs.Var(&opts.Actions, "action", `bundled action (repeatable): "<predicate> k=v..."`)
	return fs, opts
}

func init() {
	registerMeInfo("trigger", "create", cmdInfo{
		Run:		meTriggerCreateCmd,
		Flags:		flagsOnly(meTriggerCreateFlags),
		Synopsis:	"create a new trigger (start / once / continuous / front)",
	})
}

// meTriggerCreateCmd implements
// `dcs-sms me trigger create --type once|continuous|start|front [--name N]
//   [--condition "<predicate> k=v..."]... [--action "<predicate> k=v..."]...`.
//
// Inserts a trigger; optionally bundles initial conditions and actions in the
// same call. Each --condition / --action takes a single string of
// "<predicate> <k>=<v> <k>=<v>..." tokens — same vocabulary as the standalone
// add-condition / add-action verbs. Limitation: values containing literal
// spaces need shell-quoting (text='Hello World') or use the composable form.
func meTriggerCreateCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := meTriggerCreateFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if opts.Type == "" {
		fmt.Fprintln(stderr, "dcs-sms me trigger create: --type is required")
		return 2
	}

	// Pre-validate every bundled rule string so we fail BEFORE creating the
	// trigger if any rule is malformed.
	type parsedRule struct {
		pred	string
		fields	map[string]string
	}
	cond := make([]parsedRule, 0, len(opts.Conditions))
	for _, s := range opts.Conditions {
		p, f, err := parseBundledRuleString(s)
		if err != nil {
			fmt.Fprintln(stderr, "dcs-sms me trigger create:", err)
			return 2
		}
		cond = append(cond, parsedRule{p, f})
	}
	act := make([]parsedRule, 0, len(opts.Actions))
	for _, s := range opts.Actions {
		p, f, err := parseBundledRuleString(s)
		if err != nil {
			fmt.Fprintln(stderr, "dcs-sms me trigger create:", err)
			return 2
		}
		act = append(act, parsedRule{p, f})
	}

	// 1) Create the empty trigger.
	luaArgs := fmt.Sprintf("{ [\"type\"] = %s, name = %s }", luaQuote(opts.Type), luaQuote(opts.Name))
	resp, exitCode := runMeVerb("trigger_create", luaArgs, opts.Timeout, opts.SavedGames, stderr)
	if exitCode != 0 {
		return exitCode
	}
	if !resp.OK {
		// Surface the verb error and stop — don't try to add rules.
		return emitMeResponse(resp, opts.Pretty, stdout)
	}

	// Extract the resolved name from the response so the bundled add-*
	// calls target the right trigger (the user's --name might have been
	// auto-suffixed). resp.ReturnValue is json.RawMessage — decode it.
	resolvedName := opts.Name
	if len(resp.ReturnValue) > 0 {
		var rv map[string]any
		if err := json.Unmarshal(resp.ReturnValue, &rv); err == nil {
			if n, ok := rv["name"].(string); ok && n != "" {
				resolvedName = n
			}
		}
	}

	// 2) Apply each bundled condition.
	for _, r := range cond {
		condArgs := fmt.Sprintf(
			"{ trigger = %s, predicate = %s, fields = %s }", luaQuote(resolvedName), luaQuote(r.pred), buildLuaFieldsExpr(r.fields))
		condResp, ec := runMeVerb("trigger_add_condition", condArgs, opts.Timeout, opts.SavedGames, stderr)
		if ec != 0 {
			return ec
		}
		if !condResp.OK {
			// Bundled rule failed mid-stream; surface the partial state.
			return emitMeResponse(condResp, opts.Pretty, stdout)
		}
		// Outer OK only confirms the Lua snippet ran — the verb itself may
		// still have rejected the rule (unknown predicate, missing field,
		// etc.). Inspect the inner return_value.ok to surface those.
		if len(condResp.ReturnValue) > 0 {
			var rv map[string]any
			if err := json.Unmarshal(condResp.ReturnValue, &rv); err == nil {
				if ok, _ := rv["ok"].(bool); !ok {
					return emitMeResponse(condResp, opts.Pretty, stdout)
				}
			}
		}
	}

	// 3) Apply each bundled action.
	for _, r := range act {
		actArgs := fmt.Sprintf(
			"{ trigger = %s, predicate = %s, fields = %s }", luaQuote(resolvedName), luaQuote(r.pred), buildLuaFieldsExpr(r.fields))
		actResp, ec := runMeVerb("trigger_add_action", actArgs, opts.Timeout, opts.SavedGames, stderr)
		if ec != 0 {
			return ec
		}
		if !actResp.OK {
			return emitMeResponse(actResp, opts.Pretty, stdout)
		}
		// Same inner-ok guard as for conditions above.
		if len(actResp.ReturnValue) > 0 {
			var rv map[string]any
			if err := json.Unmarshal(actResp.ReturnValue, &rv); err == nil {
				if ok, _ := rv["ok"].(bool); !ok {
					return emitMeResponse(actResp, opts.Pretty, stdout)
				}
			}
		}
	}

	// Success — return the original create response (which has the trigger
	// name + index). Bundled rules count is implicit.
	return emitMeResponse(resp, opts.Pretty, stdout)
}
