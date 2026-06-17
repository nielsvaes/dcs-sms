package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/nielsvaes/dcs-sms/tools/internal/dcspath"
	"github.com/nielsvaes/dcs-sms/tools/internal/hookstatus"
	"github.com/nielsvaes/dcs-sms/tools/internal/mailbox"
	"github.com/nielsvaes/dcs-sms/tools/internal/proto"
)

// stdinReader is the source for code when neither --file nor --code is
// given. Tests swap this out to inject input.
var stdinReader io.Reader = os.Stdin

type execOpts struct {
	File       string
	Code       string
	Timeout    time.Duration
	Pretty     bool
	SavedGames string
	Wait       bool
	Target     string
}

func execFlags() (*flag.FlagSet, *execOpts) {
	opts := &execOpts{}
	fs := flag.NewFlagSet("exec", flag.ContinueOnError)
	fs.StringVar(&opts.File, "file", "", "path to a .lua file")
	fs.StringVar(&opts.Code, "code", "", "Lua code (inline)")
	fs.DurationVar(&opts.Timeout, "timeout", 5*time.Second, "wall-clock timeout")
	fs.BoolVar(&opts.Pretty, "pretty", false, "indent JSON output")
	fs.StringVar(&opts.SavedGames, "saved-games", "", "override Saved Games path")
	fs.BoolVar(&opts.Wait, "wait", false, "if hook isn't ready, poll until it is or --timeout elapses")
	fs.StringVar(&opts.Target, "target", "auto", "execution target: mission (live mission scripting env) | gui (Mission Editor env — full DCS modules like magvar/Terrain, reads/writes the open mission) | auto")
	return fs, opts
}

func init() {
	registerInfo("exec", cmdInfo{
		Run:      execCmd,
		Flags:    flagsOnly(execFlags),
		Synopsis: "execute a Lua snippet. --target gui runs it in the Mission Editor env (open the ME and toggle DCS-SMS → External execution ON first); --target mission runs it in a live mission; auto picks based on DCS state. Returns JSON with return_value (the snippet's return), output (captured print), and error.",
		Examples: []string{
			`dcs-sms exec --target mission --code "return Unit.getByName('Alpha-1'):getCoalition()"`,
			`# Mission Editor: any DCS module the ME has, e.g. magnetic declination at a lat/lon`,
			`dcs-sms exec --target gui --code "return require('magvar').get_mag_decl(51.556, -0.419)"`,
			`# (for magvar specifically, prefer the typed wrapper: dcs-sms me coords magvar --lat 51.556 --lon -0.419)`,
		},
	})
}

func execCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := execFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	code, err := readCode(opts.File, opts.Code, stdinReader)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms exec:", err)
		return 2
	}

	root, err := resolveRoot(opts.SavedGames)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms exec:", err)
		return 3
	}
	mb := mailbox.New(filepath.Join(root, "dcs-sms"))
	if err := ensureMailboxDirs(mb.Root); err != nil {
		fmt.Fprintln(stderr, "dcs-sms exec:", err)
		return 3
	}

	if err := waitForHook(mb.State(), opts.Wait, opts.Timeout); err != nil {
		fmt.Fprintln(stderr, "dcs-sms exec:", err)
		return 3
	}

	// Best-effort cleanup of orphan responses left by previous timed-out
	// runs. Errors here are non-fatal — we'd rather proceed than refuse.
	_ = mb.SweepOutboxOlderThan(60 * time.Second)

	// Resolve --target against the current hook state. RouteForTarget returns
	// "mission" or "gui" on success, or an error describing why the requested
	// target isn't usable right now (e.g. gui bridge disabled).
	hookState, _ := hookstatus.ReadMerged(mb.State())
	target, err := hookstatus.RouteForTarget(opts.Target, hookState)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms exec:", err)
		return 4
	}

	req := proto.ExecRequest{
		ID:        mailbox.NewID(),
		Kind:      "exec",
		Target:    target,
		Code:      code,
		TimeoutMs: int(opts.Timeout.Milliseconds()),
		CreatedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}

	if err := mb.WriteRequest(req); err != nil {
		fmt.Fprintln(stderr, "dcs-sms exec: write request:", err)
		return 3
	}

	resp, err := pollResponse(mb, req.ID, opts.Timeout)
	if err != nil {
		if errors.Is(err, errPollTimeout) {
			fmt.Fprintln(stderr, "dcs-sms exec: timeout — no response within", opts.Timeout)
			return 2
		}
		fmt.Fprintln(stderr, "dcs-sms exec: poll:", err)
		return 3
	}

	var data []byte
	if opts.Pretty {
		data, _ = json.MarshalIndent(resp, "", "  ")
	} else {
		data, _ = json.Marshal(resp)
	}
	fmt.Fprintln(stdout, string(data))

	if !resp.OK {
		return 1
	}
	return 0
}

// readCode resolves which input source to use, in priority order: --file,
// --code, stdin. Empty result is an error.
func readCode(file, code string, stdin io.Reader) (string, error) {
	if file != "" {
		data, err := os.ReadFile(file)
		if err != nil {
			return "", fmt.Errorf("read --file: %w", err)
		}
		return string(data), nil
	}
	if code != "" {
		return code, nil
	}
	// If stdin is a terminal, ReadAll would block forever waiting for EOF.
	// Detect that case (real *os.File only — tests inject strings.Reader,
	// which doesn't implement *os.File and harmlessly falls through).
	if f, ok := stdin.(*os.File); ok {
		if fi, err := f.Stat(); err == nil && (fi.Mode()&os.ModeCharDevice) != 0 {
			return "", errors.New("no code provided (use --file, --code, or pipe via stdin)")
		}
	}
	data, err := io.ReadAll(stdin)
	if err != nil {
		return "", fmt.Errorf("read stdin: %w", err)
	}
	if len(data) == 0 {
		return "", errors.New("no code provided (use --file, --code, or pipe via stdin)")
	}
	return string(data), nil
}

// resolveRoot returns the Saved Games path using the standard discovery chain.
func resolveRoot(override string) (string, error) {
	cfg, _ := dcspath.DefaultConfigPath()
	return dcspath.Discover(override, cfg)
}

// ensureMailboxDirs creates dcs-sms/{inbox,outbox,state,log} if missing.
func ensureMailboxDirs(root string) error {
	for _, sub := range []string{"inbox", "outbox", "state", "log"} {
		if err := os.MkdirAll(filepath.Join(root, sub), 0o755); err != nil {
			return err
		}
	}
	return nil
}

var errPollTimeout = errors.New("poll timeout")

// pollResponse polls outbox/<id>.res.json every ~25ms until found or
// timeout. The poll interval shrinks if the deadline is closer than 25ms
// so we don't oversleep past it.
func pollResponse(mb *mailbox.Mailbox, id string, timeout time.Duration) (proto.ExecResponse, error) {
	deadline := time.Now().Add(timeout)
	const pollInterval = 25 * time.Millisecond
	for {
		resp, ok, err := mb.ReadResponse(id)
		if err != nil {
			return proto.ExecResponse{}, err
		}
		if ok {
			return resp, nil
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return proto.ExecResponse{}, errPollTimeout
		}
		sleep := pollInterval
		if remaining < sleep {
			sleep = remaining
		}
		time.Sleep(sleep)
	}
}

// waitForHook returns nil if the hook heartbeat is fresh. The mission_loaded
// gate is no longer applied here — RouteForTarget is the source of truth for
// "is the user's chosen target usable right now". This lets `--target gui`
// work in the ME / main menu where mission_loaded is false.
//
// If wait is true, polls every 50ms until fresh or timeout. If wait is false
// and the hook isn't fresh, returns immediately with an error.
func waitForHook(stateDir string, wait bool, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		st, err := hookstatus.ReadMerged(stateDir)
		if err == nil && hookstatus.IsFresh(st, 2*time.Second, time.Now()) {
			return nil
		}
		if !wait {
			if err != nil {
				return fmt.Errorf("hook not ready (%v) — start DCS or pass --wait", err)
			}
			return errors.New("hook heartbeat stale — DCS may be paused/hung; pass --wait to retry")
		}
		if time.Now().After(deadline) {
			return errors.New("timed out waiting for hook to become ready")
		}
		time.Sleep(50 * time.Millisecond)
	}
}
