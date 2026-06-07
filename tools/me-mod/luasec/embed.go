// Package luasec embeds the optional LuaSec HTTPS payload so the
// `install-me-mod` command can deploy it to the right places automatically.
//
// The native binaries are NOT committed by default — a maintainer drops a
// matching LuaSec build into payload/ (see payload/lib/README.txt). Until then
// only the CA bundle + docs ship, and the Community tab degrades to "secure
// networking unavailable". The //go:embed below still compiles because the
// README placeholders + cacert.pem are always present.
//
// Layout → install destination:
//
//	payload/lib/**  →  <Saved Games>/DCS/dcs-sms/lib/**   (package.cpath/path)
//	payload/bin/**  →  <DCS install>/bin/** and /bin-mt/** (OS DLL search path)
package luasec

import "embed"

//go:embed payload
var FS embed.FS
