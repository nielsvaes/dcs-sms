//go:build windows

package dcspath

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// savedGamesBase returns the user's real "Saved Games" folder.
//
// It queries the Windows Known Folder API (FOLDERID_SavedGames), which is how
// DCS itself locates Saved Games — so it respects users who relocated the
// folder to another drive (Properties → Location → Move). The previous naive
// join of %USERPROFILE%\Saved Games missed relocation entirely, which made the
// installer report "Saved Games path not resolved" and silently skip both the
// LuaSec HTTPS payload and the hook on machines where DCS found Saved Games
// fine. Falls back to %USERPROFILE%\Saved Games if the Known Folder lookup is
// unavailable for any reason.
func savedGamesBase() (string, bool) {
	if p, err := windows.KnownFolderPath(windows.FOLDERID_SavedGames, windows.KF_FLAG_DEFAULT); err == nil && p != "" {
		return p, true
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, "Saved Games"), true
	}
	return "", false
}
