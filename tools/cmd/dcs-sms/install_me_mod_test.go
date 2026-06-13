package main

import (
	"bytes"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/nielsvaes/dcs-sms/tools/internal/elevate"
)

// helper: build a fake DCS install dir and return its path.
func newFakeInstall(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	me := filepath.Join(root, "MissionEditor")
	if err := os.MkdirAll(filepath.Join(me, "modules"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(me, "MissionEditor.lua"),
		[]byte("-- original ME bootstrap\nlocal x = 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestInstallMeMod_CopiesModuleFiles(t *testing.T) {
	install := newFakeInstall(t)
	var stdout, stderr bytes.Buffer
	code := installMeModCmd([]string{"--dcs-path", install, "--no-config-save"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("exit %d, stderr: %s", code, stderr.String())
	}
	moduleDir := filepath.Join(install, "MissionEditor", "modules", "dcs_sms_me")
	for _, name := range []string{"init.lua", "prefab_manager.lua", "selection.lua", "serializer.lua", "paths.lua"} {
		p := filepath.Join(moduleDir, name)
		if info, err := os.Stat(p); err != nil || info.Size() == 0 {
			t.Errorf("expected %s present and non-empty: %v", p, err)
		}
	}
}

func TestInstallMeMod_PatchesAndBacksUp(t *testing.T) {
	install := newFakeInstall(t)
	var stdout, stderr bytes.Buffer
	if code := installMeModCmd([]string{"--dcs-path", install, "--no-config-save"}, &stdout, &stderr); code != 0 {
		t.Fatalf("exit %d, stderr: %s", code, stderr.String())
	}
	bak, err := os.ReadFile(filepath.Join(install, "MissionEditor", "MissionEditor.lua.dcs-sms.bak"))
	if err != nil {
		t.Fatalf("backup not created: %v", err)
	}
	if !strings.Contains(string(bak), "original ME bootstrap") {
		t.Fatalf("backup does not contain original content: %q", bak)
	}
	patched, _ := os.ReadFile(filepath.Join(install, "MissionEditor", "MissionEditor.lua"))
	if !strings.Contains(string(patched), "-- dcs-sms-me-mod begin") ||
		!strings.Contains(string(patched), "require('dcs_sms_me.init')") ||
		!strings.Contains(string(patched), "-- dcs-sms-me-mod end") {
		t.Fatalf("patched MissionEditor.lua missing markers/require: %s", patched)
	}
	if !strings.Contains(string(patched), "original ME bootstrap") {
		t.Fatalf("original content lost from MissionEditor.lua: %s", patched)
	}
}

// Post-DCS-update recovery: a DCS update reverts MissionEditor.lua to vanilla
// while the old .dcs-sms.bak lingers. The installer must re-patch the current
// (vanilla) file and refresh the backup — NOT dead-end. Before the fix it
// refused to overwrite the existing backup and returned exit 3, leaving every
// Program-Files user unable to reinstall after a DCS update.
func TestInstallMeMod_RepatchesWhenBackupExists(t *testing.T) {
	install := newFakeInstall(t)
	bakPath := filepath.Join(install, "MissionEditor", "MissionEditor.lua.dcs-sms.bak")
	// Stale backup from a previous DCS version.
	if err := os.WriteFile(bakPath, []byte("stale older vanilla"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	code := installMeModCmd([]string{"--dcs-path", install, "--no-config-save"}, &stdout, &stderr)
	if code != 0 {
		t.Fatalf("expected success re-patching over a stale backup, exit %d, stderr: %s", code, stderr.String())
	}
	patched, _ := os.ReadFile(filepath.Join(install, "MissionEditor", "MissionEditor.lua"))
	if !strings.Contains(string(patched), "require('dcs_sms_me.init')") {
		t.Fatalf("MissionEditor.lua was not patched: %s", patched)
	}
	// The backup must be refreshed to the current vanilla file, not the stale text.
	bak, _ := os.ReadFile(bakPath)
	if !strings.Contains(string(bak), "original ME bootstrap") {
		t.Fatalf("backup not refreshed to current vanilla content, got: %q", bak)
	}
	if strings.Contains(string(bak), "stale older vanilla") {
		t.Fatalf("backup still holds stale content: %q", bak)
	}
}

func TestInstallMeMod_Idempotent_ReinstallPreservesPatch(t *testing.T) {
	install := newFakeInstall(t)
	var stdout, stderr bytes.Buffer
	if code := installMeModCmd([]string{"--dcs-path", install, "--no-config-save"}, &stdout, &stderr); code != 0 {
		t.Fatalf("first install exit %d, stderr: %s", code, stderr.String())
	}
	firstPatched, _ := os.ReadFile(filepath.Join(install, "MissionEditor", "MissionEditor.lua"))

	// Second run: should NOT add a second require line, should NOT touch the
	// existing backup, should still re-copy module files.
	stdout.Reset()
	stderr.Reset()
	if code := installMeModCmd([]string{"--dcs-path", install, "--no-config-save"}, &stdout, &stderr); code != 0 {
		t.Fatalf("re-install exit %d, stderr: %s", code, stderr.String())
	}
	secondPatched, _ := os.ReadFile(filepath.Join(install, "MissionEditor", "MissionEditor.lua"))
	if !bytes.Equal(firstPatched, secondPatched) {
		t.Fatalf("MissionEditor.lua changed on re-install:\n--- first:\n%s\n--- second:\n%s",
			firstPatched, secondPatched)
	}
	// Module files should still exist.
	if _, err := os.Stat(filepath.Join(install, "MissionEditor", "modules", "dcs_sms_me", "init.lua")); err != nil {
		t.Fatalf("module file missing after re-install: %v", err)
	}
}

func TestInstallMeMod_PrunesStaleModuleFiles(t *testing.T) {
	install := newFakeInstall(t)
	var stdout, stderr bytes.Buffer
	if code := installMeModCmd([]string{"--dcs-path", install, "--no-config-save"}, &stdout, &stderr); code != 0 {
		t.Fatalf("first install exit %d, stderr: %s", code, stderr.String())
	}
	moduleDir := filepath.Join(install, "MissionEditor", "modules", "dcs_sms_me")

	// Simulate files left by a previous version that were renamed or deleted in
	// this one (e.g. dtc_skins.lua after the dtc_skins->sms_skins rename), one at
	// the top level and one inside a real subdirectory.
	staleTop := filepath.Join(moduleDir, "dtc_skins.lua")
	if err := os.WriteFile(staleTop, []byte("-- stale orphan\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	staleSub := filepath.Join(moduleDir, "verbs", "ghost_verbs.lua")
	if err := os.WriteFile(staleSub, []byte("-- stale orphan in subdir\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Re-install: orphans must be pruned, real files must remain.
	stdout.Reset()
	stderr.Reset()
	if code := installMeModCmd([]string{"--dcs-path", install, "--no-config-save"}, &stdout, &stderr); code != 0 {
		t.Fatalf("re-install exit %d, stderr: %s", code, stderr.String())
	}
	if _, err := os.Stat(staleTop); !os.IsNotExist(err) {
		t.Errorf("top-level stale file should have been pruned, stat err: %v", err)
	}
	if _, err := os.Stat(staleSub); !os.IsNotExist(err) {
		t.Errorf("stale file in subdir should have been pruned, stat err: %v", err)
	}
	// A real embedded file must survive.
	if _, err := os.Stat(filepath.Join(moduleDir, "init.lua")); err != nil {
		t.Errorf("real module file init.lua missing after prune: %v", err)
	}
	// The verbs dir is real (still has real files), so it must survive.
	if info, err := os.Stat(filepath.Join(moduleDir, "verbs")); err != nil || !info.IsDir() {
		t.Errorf("real verbs dir should survive prune: %v", err)
	}
	// The removal should be reported to the user.
	if !strings.Contains(stdout.String(), "dtc_skins.lua") {
		t.Errorf("expected pruned file to be reported in stdout, got: %s", stdout.String())
	}
}

func TestInstallMeMod_ReturnsExitCode5WhenDirNotWritable(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Windows: read-only chmod doesn't block writes the same way; covered by manual testing")
	}
	install := newFakeInstall(t)
	// Make the MissionEditor dir read-only so the CanWrite probe fails.
	meDir := filepath.Join(install, "MissionEditor")
	if err := os.Chmod(meDir, 0o555); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(meDir, 0o755) // restore so t.TempDir cleanup works

	var stdout, stderr bytes.Buffer
	code := installMeModCmd([]string{"--dcs-path", install, "--no-config-save"}, &stdout, &stderr)
	if code != elevate.ExitCodeNeedsElevation {
		t.Errorf("exit code %d, want %d (needs elevation)", code, elevate.ExitCodeNeedsElevation)
	}
	if !strings.Contains(stderr.String(), "admin") {
		t.Errorf("stderr should mention admin / elevation, got: %s", stderr.String())
	}
}
