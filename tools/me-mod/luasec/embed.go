// Package luasec embeds the optional LuaSec HTTPS payload so the
// `install-me-mod` command can deploy it to the right places automatically.
//
// The native binaries (ssl.dll, lua5.1.dll, libssl-4/libcrypto-4) ARE
// committed — a matching LuaSec build was vendored into payload/ (see
// payload/lib/README.txt + the .gitignore exception that tracks the DLLs), so
// install-me-mod deploys a working HTTPS stack out of the box. If the payload
// is ever stripped, the //go:embed below still compiles (cacert.pem + README
// placeholders are always present) and the Community tab degrades to "secure
// networking unavailable".
//
// Layout → install destination:
//
//	payload/lib/**  →  <Saved Games>/DCS/dcs-sms/lib/**   (package.cpath/path)
//	payload/bin/**  →  <DCS install>/bin/** and /bin-mt/** (OS DLL search path)
package luasec

import "embed"

//go:embed payload
var FS embed.FS
