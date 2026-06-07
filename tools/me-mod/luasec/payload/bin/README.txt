payload/bin/  →  installs to  <DCS install>/bin/  AND  <DCS install>/bin-mt/
==========================================================================

Everything here (EXCEPT this README and dotfiles) is copied into BOTH DCS bin
folders by `dcs-sms install-me-mod`. These are the native DLL dependencies of
ssl/core.dll — Windows resolves them via the OS DLL search path (the DCS exe
directory), NOT via Lua's package.cpath, which is why they go in bin and not
in lib/.

Drop here (matching your LuaSec/OpenSSL build):

    libssl-1_1-x64.dll     OpenSSL 1.1 TLS half. (DCS already ships
                           libcrypto-1_1-x64.dll, so you usually only need
                           libssl here.)
    lua5.1.dll             ONLY if your core.dll imports "lua5.1.dll" instead
                           of DCS's own lua.dll. x64 PUC Lua 5.1.

NOTE: this writes into the DCS install dir. Adding DLLs to bin can be flagged
by DCS's multiplayer Integrity Check; it only matters for MP, and these DLLs
load only in the Mission Editor (GUI). If that's a concern, ship none here and
instead keep the OpenSSL DLLs in lib/ and pre-load them from Lua (a follow-up
we can add).
