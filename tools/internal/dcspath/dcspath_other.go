//go:build !windows

package dcspath

// savedGamesBase is Windows-only — DCS Saved Games discovery has no sensible
// default off Windows, so non-Windows callers must pass --saved-games or set
// DCS_SMS_SAVED_GAMES. Returning ("", false) makes DiscoverDefault yield no
// path, matching the prior behaviour.
func savedGamesBase() (string, bool) {
	return "", false
}
