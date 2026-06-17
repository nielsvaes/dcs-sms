// Package hookstatus reads state/hook.json and reasons about whether the
// hook is alive enough to accept work.
package hookstatus

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"time"

	"github.com/nielsvaes/dcs-sms/tools/internal/fileutil"
	"github.com/nielsvaes/dcs-sms/tools/internal/proto"
)

// Read parses state/hook.json from the state directory.
func Read(stateDir string) (proto.HookState, error) {
	return readOne(filepath.Join(stateDir, "hook.json"))
}

// readOne is the workhorse: parses one heartbeat file or returns an error.
// Uses fileutil.ReadFileRetry so a transient Windows sharing-violation
// against the hook's in-progress atomic rename doesn't surface as a hard
// failure.
func readOne(path string) (proto.HookState, error) {
	data, err := fileutil.ReadFileRetry(path)
	if err != nil {
		return proto.HookState{}, fmt.Errorf("read %s: %w", path, err)
	}
	var st proto.HookState
	if err := json.Unmarshal(data, &st); err != nil {
		return proto.HookState{}, fmt.Errorf("parse %s: %w", path, err)
	}
	return st, nil
}

// ReadMerged reads both state/hook.json (written by the dcs-sms hook in the
// Hooks/ env, in-mission only) and state/me.json (written by the ME-mod's
// bridge.lua, always-on while DCS is up). Merges them into a single HookState
// that callers can use as a unified view of the bridge.
//
// Merge rules:
//   - mission_loaded / mission_name: from the heartbeat that owns the current
//     environment — hook.json while a sim runs ("in_mission"), me.json while
//     in the Mission Editor. The ME-mod populates these from me_mission; the
//     hook can't see the editor's open mission, and a stale hook.json left
//     over from a prior sim would otherwise report mission_loaded=false.
//   - gui_bridge_enabled: from me.json (only the ME-mod knows the toggle).
//   - state: prefer "in_mission" if hook says so, otherwise me.json's value.
//   - tick fields: whichever heartbeat is most recent.
//   - hook_version: me.json's takes precedence (it's the active ticker), with
//     hook.json's as fallback.
//
// Returns the most informative state available. If neither file is present,
// returns an error. If only one is present, returns that one as-is.
func ReadMerged(stateDir string) (proto.HookState, error) {
	hook, hookErr := readOne(filepath.Join(stateDir, "hook.json"))
	me, meErr := readOne(filepath.Join(stateDir, "me.json"))

	if hookErr != nil && meErr != nil {
		return proto.HookState{}, fmt.Errorf("no heartbeat found (hook: %v; me: %v)", hookErr, meErr)
	}
	if hookErr != nil {
		return me, nil
	}
	if meErr != nil {
		return hook, nil
	}

	merged := proto.HookState{
		GuiBridgeEnabled: me.GuiBridgeEnabled,
	}

	// State: prefer "in_mission" if the hook says so (or implies it via the
	// legacy mission_loaded flag). Otherwise defer to ME-mod's view.
	if hook.State == "in_mission" || (hook.State == "" && hook.MissionLoaded) {
		merged.State = "in_mission"
	} else {
		merged.State = me.State
	}

	// Mission info follows the active environment. In a running sim the hook
	// owns it; in the editor the ME-mod does (it reads me_mission, which the
	// hook env can't see). Keying off merged.State avoids surfacing a stale
	// hook.json's mission_loaded=false while the user is back in the ME.
	if merged.State == "in_mission" {
		merged.MissionLoaded = hook.MissionLoaded
		merged.MissionName = hook.MissionName
	} else {
		merged.MissionLoaded = me.MissionLoaded
		merged.MissionName = me.MissionName
	}

	// hook_version: ME-mod is the active ticker, surface its version first.
	if me.HookVersion != "" {
		merged.HookVersion = me.HookVersion
	} else {
		merged.HookVersion = hook.HookVersion
	}

	// tick_source: ME-mod ticks via UpdateManager almost always, hook only
	// during sim. Prefer ME-mod's reported tick_source.
	if me.TickSource != "" {
		merged.TickSource = me.TickSource
	} else {
		merged.TickSource = hook.TickSource
	}

	// Pick the most recent heartbeat for tick fields. ISO 8601 string compare
	// is correct for fixed-format timestamps.
	hookAt := hook.LastTickAt
	if hookAt == "" {
		hookAt = hook.LastFrameAt
	}
	meAt := me.LastTickAt
	if meAt == "" {
		meAt = me.LastFrameAt
	}
	if meAt > hookAt {
		merged.LastTick = me.LastTick
		merged.LastTickAt = me.LastTickAt
		merged.LastFrame = me.LastFrame
		merged.LastFrameAt = me.LastFrameAt
	} else {
		merged.LastTick = hook.LastTick
		merged.LastTickAt = hook.LastTickAt
		merged.LastFrame = hook.LastFrame
		merged.LastFrameAt = hook.LastFrameAt
	}

	return merged, nil
}

// IsFresh returns true when st.LastFrameAt is within maxAge of now,
// in either direction. Future timestamps caused by minor clock skew between
// the hook process and the CLI are treated as fresh as long as the absolute
// difference is within maxAge — but a far-future timestamp is just as stale
// as a far-past one.
//
// An unparseable LastFrameAt is treated as stale (safer default).
//
// time.RFC3339Nano accepts timestamps both with and without fractional
// seconds, so a single parse layout covers everything the Lua hook emits.
func IsFresh(st proto.HookState, maxAge time.Duration, now time.Time) bool {
	t, err := time.Parse(time.RFC3339Nano, st.LastFrameAt)
	if err != nil {
		return false
	}
	diff := now.Sub(t)
	if diff < 0 {
		diff = -diff
	}
	return diff <= maxAge
}

// RouteForTarget resolves the user's --target flag against the current hook
// state. Returns the concrete target the request should carry ("mission" or
// "gui"), or an error describing why the requested route isn't usable right
// now.
//
// requested values: "mission", "gui", "auto", or "" (treated as "auto").
func RouteForTarget(requested string, st proto.HookState) (string, error) {
	switch requested {
	case "mission":
		return "mission", nil
	case "gui":
		if !st.GuiBridgeEnabled {
			return "", fmt.Errorf("gui bridge is disabled — open the DCS-SMS menu in the Mission Editor and toggle 'External execution' on")
		}
		return "gui", nil
	case "", "auto":
		// Auto-routing decision tree. Order matters: prefer "mission" when
		// a sim is running (exec speed via onSimulationFrame), fall through
		// to "gui" when the user is in the ME or main menu.
		if st.State == "in_mission" || (st.State == "" && st.MissionLoaded) {
			return "mission", nil
		}
		if st.State == "in_mission_editor" || st.State == "at_main_menu" {
			if !st.GuiBridgeEnabled {
				return "", fmt.Errorf("DCS is in the %s but the gui bridge is disabled — toggle 'External execution' on in the DCS-SMS menu", st.State)
			}
			return "gui", nil
		}
		// State "loading_mission", "starting", "stopping" or unknown.
		// Legacy hook with mission unloaded and no state info also lands here.
		return "", fmt.Errorf("hook reports state=%q (mission_loaded=%v) — no target available right now; pass --target mission or --target gui explicitly", st.State, st.MissionLoaded)
	default:
		return "", fmt.Errorf("unknown --target %q (allowed: mission, gui, auto)", requested)
	}
}
