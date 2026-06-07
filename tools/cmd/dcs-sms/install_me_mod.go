package main

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/nielsvaes/dcs-sms/tools/internal/dcspath"
	"github.com/nielsvaes/dcs-sms/tools/internal/elevate"
	memod "github.com/nielsvaes/dcs-sms/tools/me-mod/lua"
	luasec "github.com/nielsvaes/dcs-sms/tools/me-mod/luasec"
)

type installMeModOpts struct {
	DCSPath string
	NoSave  bool
}

func installMeModFlags() (*flag.FlagSet, *installMeModOpts) {
	opts := &installMeModOpts{}
	fs := flag.NewFlagSet("install-me-mod", flag.ContinueOnError)
	fs.StringVar(&opts.DCSPath, "dcs-path", "", "override DCS install path")
	fs.BoolVar(&opts.NoSave, "no-config-save", false, "do not persist --dcs-path to config")
	return fs, opts
}

func init() {
	registerInfo("install-me-mod", cmdInfo{
		Run:      installMeModCmd,
		Flags:    flagsOnly(installMeModFlags),
		Synopsis: "install/update the Mission Editor mod into <DCS install>/MissionEditor/",
	})
}

const meModBackupSuffix = ".dcs-sms.bak"

func installMeModCmd(args []string, stdout, stderr io.Writer) int {
	fs, opts := installMeModFlags()
	fs.SetOutput(stderr)
	if err := fs.Parse(args); err != nil {
		return 2
	}

	cfg, _ := dcspath.DefaultConfigPath()
	install, err := dcspath.DiscoverInstall(opts.DCSPath, cfg)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms install-me-mod:", err)
		return 3
	}

	// Sanity check: <install>/MissionEditor/MissionEditor.lua must exist.
	meDir := filepath.Join(install, "MissionEditor")
	meFile := filepath.Join(meDir, "MissionEditor.lua")
	if _, err := os.Stat(meFile); err != nil {
		fmt.Fprintf(stderr, "dcs-sms install-me-mod: %s not found (is --dcs-path correct?)\n", meFile)
		return 3
	}

	// Pre-flight: confirm the MissionEditor dir is writable. If not, the
	// caller likely needs admin privileges (e.g. DCS lives under Program
	// Files). Return exit code 5 so the interactive menu can prompt for
	// a UAC re-launch; non-interactive callers see a clear error.
	if !elevate.CanWrite(meDir) {
		if elevate.IsElevated() {
			fmt.Fprintf(stderr, "dcs-sms install-me-mod: cannot write to %s even with admin privileges (file locks? antivirus?)\n", meDir)
			return 3
		}
		fmt.Fprintf(stderr, "dcs-sms install-me-mod: %s is not writable.\n", meDir)
		fmt.Fprintln(stderr, "  This usually means DCS is installed under Program Files and admin permission is needed.")
		fmt.Fprintln(stderr, "  Re-run dcs-sms.exe from an admin terminal, or use the interactive menu (double-click) to be prompted.")
		return elevate.ExitCodeNeedsElevation
	}

	// Step 1: copy module files.
	moduleDst := filepath.Join(meDir, "modules", memod.ModuleDirName)
	if err := os.MkdirAll(moduleDst, 0o755); err != nil {
		fmt.Fprintln(stderr, "dcs-sms install-me-mod: mkdir modules:", err)
		return 3
	}
	if err := copyEmbedDir(memod.FS, memod.ModuleDirName, moduleDst); err != nil {
		fmt.Fprintln(stderr, "dcs-sms install-me-mod: copy modules:", err)
		return 3
	}
	fmt.Fprintf(stdout, "copied %s/* → %s\n", memod.ModuleDirName, moduleDst)

	// Prune files left by an earlier version that were renamed or removed in this
	// one (the module dir is owned entirely by the installer, so anything not in
	// the embed is stale). Without this, a rename like dtc_skins.lua ->
	// sms_skins.lua would leave the old file lingering and loadable.
	removed, err := pruneStaleEmbedDir(memod.FS, memod.ModuleDirName, moduleDst)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms install-me-mod: prune stale modules:", err)
		return 3
	}
	for _, rel := range removed {
		fmt.Fprintf(stdout, "removed stale %s\n", rel)
	}

	// Step 1b: deploy the optional LuaSec HTTPS payload (native module + CA
	// bundle) so the Community prefab library can fetch over HTTPS.
	//   payload/lib/* → <Saved Games>/DCS/dcs-sms/lib/   (Lua require path)
	//   payload/bin/* → <install>/bin and /bin-mt        (native DLL deps)
	// Entirely best-effort + additive (never pruned): a missing payload, an
	// unresolved Saved Games path, or a read-only bin just logs and skips, so
	// the core mod install always succeeds. README/dotfile placeholders in the
	// embed are not copied (copyPayloadDir skips them).
	if sg, derr := dcspath.Discover("", cfg); derr == nil {
		libDst := filepath.Join(sg, "dcs-sms", "lib")
		if n, cerr := copyPayloadDir(luasec.FS, "payload/lib", libDst); cerr != nil {
			fmt.Fprintln(stderr, "dcs-sms install-me-mod: warning: LuaSec lib payload:", cerr)
		} else if n > 0 {
			fmt.Fprintf(stdout, "copied LuaSec lib payload (%d files) → %s\n", n, libDst)
		}
	} else {
		fmt.Fprintln(stdout, "note: Saved Games path not resolved; skipped LuaSec lib payload")
	}
	binTotal := 0
	for _, sub := range []string{"bin", "bin-mt"} {
		binDst := filepath.Join(install, sub)
		if _, serr := os.Stat(binDst); serr != nil {
			continue // some installs don't have bin-mt
		}
		if n, cerr := copyPayloadDir(luasec.FS, "payload/bin", binDst); cerr != nil {
			fmt.Fprintln(stderr, "dcs-sms install-me-mod: warning: LuaSec bin payload:", cerr)
		} else {
			binTotal += n
		}
	}
	if binTotal > 0 {
		fmt.Fprintf(stdout, "copied LuaSec bin payload (%d files) → %s\\bin[-mt]\n", binTotal, install)
	}

	// Step 2: patch MissionEditor.lua (idempotent).
	meSrc, err := os.ReadFile(meFile)
	if err != nil {
		fmt.Fprintln(stderr, "dcs-sms install-me-mod: read ME file:", err)
		return 3
	}
	if bytes.Contains(meSrc, []byte(memod.RequireBeginMarker)) {
		fmt.Fprintf(stdout, "patch already present in %s, skipping\n", meFile)
	} else {
		backup := meFile + meModBackupSuffix
		if _, err := os.Stat(backup); err == nil {
			fmt.Fprintf(stderr,
				"dcs-sms install-me-mod: refusing to overwrite existing backup %s\n"+
					"  (run `dcs-sms uninstall-me-mod` first, or remove the .bak manually)\n",
				backup)
			return 3
		} else if !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintln(stderr, "dcs-sms install-me-mod: stat backup:", err)
			return 3
		}
		if err := os.WriteFile(backup, meSrc, 0o644); err != nil {
			fmt.Fprintln(stderr, "dcs-sms install-me-mod: write backup:", err)
			return 3
		}
		patched := append(meSrc, []byte(memod.PatchBlock)...)
		if err := os.WriteFile(meFile, patched, 0o644); err != nil {
			fmt.Fprintln(stderr, "dcs-sms install-me-mod: write ME file:", err)
			return 3
		}
		fmt.Fprintf(stdout, "patched %s (backup: %s)\n", meFile, backup)
	}

	// Step 3: cache --dcs-path to config (unless --no-config-save).
	if opts.DCSPath != "" && !opts.NoSave {
		if cfg != "" {
			if err := dcspath.SaveInstallConfig(cfg, opts.DCSPath); err != nil {
				fmt.Fprintln(stderr, "dcs-sms install-me-mod: warning: could not save config:", err)
			} else {
				fmt.Fprintf(stdout, "saved dcs_install = %q to %s\n", opts.DCSPath, cfg)
			}
		}
	}

	fmt.Fprintln(stdout, "")
	fmt.Fprintln(stdout, "Install complete. Restart DCS, then open the Mission Editor — DCS-SMS should appear in the top menu bar.")
	return 0
}

// copyEmbedDir walks an embed.FS subtree and writes every file to dstDir,
// preserving the relative directory structure under srcSubdir.
func copyEmbedDir(efs fs.FS, srcSubdir, dstDir string) error {
	return fs.WalkDir(efs, srcSubdir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel := strings.TrimPrefix(path, srcSubdir)
		rel = strings.TrimPrefix(rel, "/")
		target := filepath.Join(dstDir, filepath.FromSlash(rel))
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := fs.ReadFile(efs, path)
		if err != nil {
			return fmt.Errorf("read %s: %w", path, err)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o644)
	})
}

// copyPayloadDir copies every real file under the embed subtree srcSubdir into
// dstDir (creating directories), preserving structure, and returns the count
// copied. Placeholder docs (README*, dotfiles) are skipped so they don't land
// in the user's lib/ or the DCS bin. Additive only — it never prunes the
// destination (unlike the installer-owned module dir). Returns 0 with no error
// when the subtree holds only placeholders or doesn't exist.
func copyPayloadDir(efs fs.FS, srcSubdir, dstDir string) (int, error) {
	count := 0
	err := fs.WalkDir(efs, srcSubdir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			// Missing subtree (payload not present) is not an error here.
			if errors.Is(walkErr, fs.ErrNotExist) {
				return fs.SkipDir
			}
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		base := filepath.Base(path)
		if strings.HasPrefix(base, ".") || strings.HasPrefix(strings.ToLower(base), "readme") {
			return nil
		}
		rel := strings.TrimPrefix(strings.TrimPrefix(path, srcSubdir), "/")
		target := filepath.Join(dstDir, filepath.FromSlash(rel))
		data, err := fs.ReadFile(efs, path)
		if err != nil {
			return fmt.Errorf("read %s: %w", path, err)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(target, data, 0o644); err != nil {
			return err
		}
		count++
		return nil
	})
	return count, err
}

// pruneStaleEmbedDir removes any file or directory under dstDir that is not part
// of the embed subtree srcSubdir, so files renamed or deleted between versions
// don't linger in the install. The module directory is owned entirely by the
// installer (pure source, no user/runtime files), so deleting orphans is safe.
// Returns the slash-separated relative paths removed.
func pruneStaleEmbedDir(efs fs.FS, srcSubdir, dstDir string) ([]string, error) {
	expected := map[string]bool{}
	if err := fs.WalkDir(efs, srcSubdir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel := strings.TrimPrefix(strings.TrimPrefix(path, srcSubdir), "/")
		if rel != "" {
			expected[filepath.FromSlash(rel)] = true
		}
		return nil
	}); err != nil {
		return nil, err
	}

	var removed []string
	if err := filepath.WalkDir(dstDir, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if path == dstDir {
			return nil
		}
		rel, err := filepath.Rel(dstDir, path)
		if err != nil {
			return err
		}
		if expected[rel] {
			return nil
		}
		// Orphan: not in the embed. RemoveAll handles both files and dirs; for a
		// dir, skip descending since it's gone.
		if err := os.RemoveAll(path); err != nil {
			return err
		}
		removed = append(removed, filepath.ToSlash(rel))
		if d.IsDir() {
			return filepath.SkipDir
		}
		return nil
	}); err != nil {
		return nil, err
	}
	return removed, nil
}
