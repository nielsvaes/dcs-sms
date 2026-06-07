payload/lib/  →  installs to  <Saved Games>/DCS/dcs-sms/lib/
============================================================

Everything in this folder (EXCEPT this README and dotfiles) is copied to the
user's  ...\Saved Games\DCS\dcs-sms\lib\  by `dcs-sms install-me-mod`.
init.lua puts that dir on package.cpath (?.dll) and package.path (?.lua), so
require('ssl.https') resolves from here.

Drop a matching LuaSec build here (PUC Lua 5.1, x64, OpenSSL 1.1):

    ssl.lua            LuaSec  (require('ssl'))
    ssl/https.lua      LuaSec  (require('ssl.https'))
    ssl/core.dll       LuaSec native module (exports luaopen_ssl_core)
    cacert.pem         CA bundle (already provided — refresh from
                       https://curl.se/ca/cacert.pem when it ages)

core.dll must import DCS's Lua C API. Cleanest: build it linking
<DCS>/bin/lua.dll (generate an import lib from that DLL) so it imports lua.dll
directly — then no separate lua5.1.dll is needed. If your core.dll instead
imports lua5.1.dll, also place an x64 PUC lua5.1.dll in payload/bin/ (see that
folder's README).

The OpenSSL TLS half goes in payload/bin/ (libssl-1_1-x64.dll) — DCS already
ships libcrypto-1_1-x64.dll in its bin.
