package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/nielsvaes/dcs-sms/tools/internal/aiskill"
	"github.com/nielsvaes/dcs-sms/tools/internal/ui"
)

func init() {
	register("install-ai-skill", installAISkillCmd)
}

func installAISkillCmd(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("install-ai-skill", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() {
		fmt.Fprintln(stderr, "Usage of install-ai-skill:")
		fmt.Fprintln(stderr, "  --agent string   claude | codex | gemini | all (required)")
	}
	flagAgent := fs.String("agent", "", "claude | codex | gemini | all (required)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *flagAgent == "" {
		fs.Usage()
		return 2
	}
	agent, ok := aiskill.ParseAgent(*flagAgent)
	if !ok {
		fmt.Fprintf(stderr, "dcs-sms install-ai-skill: invalid --agent %q (want claude|codex|gemini|all)\n", *flagAgent)
		return 2
	}

	home, err := os.UserHomeDir()
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms install-ai-skill: could not resolve home directory:", err)
		return 3
	}

	results := aiskill.Install(agent, home)
	return printAISkillResults(stdout, stderr, "wrote", results)
}

// printAISkillResults prints one line per file: "<verb>: <path>" on success,
// "error: <path>: <err>" on failure. Returns 0 if every result is fully
// clean, 3 if any agent had at least one error.
func printAISkillResults(stdout, stderr io.Writer, verb string, results []aiskill.Result) int {
	hadError := false
	for _, r := range results {
		errPaths := map[string]bool{}
		for _, e := range r.Errors {
			fmt.Fprintln(stderr, ui.For(stderr).Err("error:"), e)
			hadError = true
			errPaths[errorPath(e)] = true
		}
		for _, p := range r.Paths {
			if errPaths[p] {
				continue
			}
			fmt.Fprintf(stdout, "%s: %s\n", verb, p)
		}
	}
	if hadError {
		return 3
	}
	return 0
}

// errorPath extracts the leading "<path>: " segment from an error string
// formatted by aiskill.installOne / uninstallOne. Returns the empty string
// if the format doesn't match.
func errorPath(e error) string {
	s := e.Error()
	if i := indexColonSpace(s); i > 0 {
		return s[:i]
	}
	return ""
}

func indexColonSpace(s string) int {
	for i := 0; i+1 < len(s); i++ {
		if s[i] == ':' && s[i+1] == ' ' {
			return i
		}
	}
	return -1
}
