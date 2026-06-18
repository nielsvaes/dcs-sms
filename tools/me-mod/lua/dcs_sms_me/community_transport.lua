-- community_transport.lua — NON-BLOCKING HTTPS GET for community_fetch.
--
-- Satisfies the transport contract: request(url) -> req with :poll() returning
--   'pending'              — not done yet, call again next tick
--   'done', body           — full response body (headers stripped)
--   'error', message       — failed
--
-- CRITICAL: the Mission Editor is single-threaded PUC Lua. A blocking socket
-- call freezes (and can CRASH) the editor — so EVERY socket operation here runs
-- with settimeout(0) and the request is advanced ONE non-blocking step per
-- poll() (community_fetch pumps poll() once per UpdateManager tick via a
-- coroutine). We use LuaSocket's raw TCP + LuaSec's ssl.wrap/dohandshake and
-- speak HTTP/1.0 ourselves, rather than the blocking ssl.https/socket.http.
--
-- DCS ships LuaSocket but NOT LuaSec; the LuaSec payload (ssl.dll + ssl.lua +
-- OpenSSL DLLs + cacert.pem) is deployed by `install-me-mod` to dcs-sms\lib\
-- (+ DCS bin) and wired onto package.cpath/path by init.lua. When absent,
-- M.available() is false and the UI degrades to "secure networking
-- unavailable".

local paths = require('dcs_sms_me.paths')
local M = {}

-- Lazy, cached require of LuaSec. false (not nil) once known-missing so the
-- pcall cost is paid at most once.
local ssl
local function load_ssl()
    if ssl ~= nil then return ssl end
    local ok, mod = pcall(require, 'ssl')
    ssl = (ok and type(mod) == 'table') and mod or false
    return ssl
end

function M.available()
    return load_ssl() ~= false
end

-- Parse an https URL into host, port, path. Returns nil on a non-https URL.
local function parse_url(url)
    local host, rest = tostring(url or ''):match('^https://([^/]*)(.*)$')
    if not host or host == '' then return nil end
    local port = 443
    local h, p = host:match('^(.-):(%d+)$')
    if h then host, port = h, tonumber(p) end
    if rest == '' then rest = '/' end
    return host, port, rest
end

-- Split the raw HTTP response into status code + body (strip headers at the
-- first blank line). Returns code (number) and body (string).
local function split_response(raw)
    local head, body = raw:match('^(.-)\r\n\r\n(.*)$')
    if not head then head, body = raw, '' end
    local code = tonumber(head:match('^HTTP/%d%.%d%s+(%d%d%d)')) or 0
    return code, body
end

-- Safety cap so a stuck connection can never spin forever (each poll ≈ one ME
-- tick). ~3600 ticks is well over a minute even at 60 fps.
local MAX_POLLS = 3600

-- Read at most this many bytes per poll. LuaSocket's '*a' pattern drains the
-- whole socket buffer in a single call — on a fast/large download that is the
-- entire response in one tick, which freezes the editor for the whole transfer.
-- A bounded receive caps each tick's work so the download spreads across ticks
-- and the editor stays responsive. 16 KB ≈ one TLS record.
local RECV_CHUNK = 16384

function M.request(_, url)
    local mod = load_ssl()
    if not mod then
        return { poll = function() return 'error', 'LuaSec not installed (run dcs-sms install-me-mod)' end }
    end
    local socket_ok, socket = pcall(require, 'socket')
    if not socket_ok or type(socket) ~= 'table' then
        return { poll = function() return 'error', 'LuaSocket unavailable' end }
    end
    local host, port, path = parse_url(url)
    if not host then
        return { poll = function() return 'error', 'not an https URL: ' .. tostring(url) end }
    end

    local stage    = 'connect'   -- connect → wrap → handshake → send → recv → done
    local sock, conn
    local request  = string.format(
        'GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: dcs-sms\r\nAccept: */*\r\nConnection: close\r\n\r\n',
        path, host)
    local sent     = 0
    local chunks   = {}
    local polls    = 0

    local function cleanup()
        if conn then pcall(function() conn:close() end)
        elseif sock then pcall(function() sock:close() end) end
    end

    -- One non-blocking step. Returns ('pending') | ('done', body) | ('error', msg).
    local function step()
        if stage == 'connect' then
            if not sock then
                local s, e = socket.tcp()
                if not s then return 'error', 'tcp(): ' .. tostring(e) end
                sock = s
                sock:settimeout(0)
            end
            local r, e = sock:connect(host, port)
            if r then stage = 'wrap'; return 'pending' end
            -- Non-blocking connect: these all mean "still connecting". We poll by
            -- re-calling connect() each tick; on Windows the in-progress call
            -- reports WSAEALREADY ("Operation already in progress"), but Winsock
            -- remaps that to WSAEINVAL ("Invalid argument") for backward compat
            -- (and some LSPs/VPN/AV shims do the same) — so treat that as
            -- still-connecting too, or the refresh aborts on machines where it
            -- surfaces. The bounded MAX_POLLS budget caps a genuinely stuck connect.
            if e == 'timeout' or e == 'Operation already in progress'
               or e == 'Operation now in progress' or e == 'Invalid argument' then return 'pending' end
            if e == 'already connected' then stage = 'wrap'; return 'pending' end
            return 'error', 'connect: ' .. tostring(e)

        elseif stage == 'wrap' then
            local c, e = mod.wrap(sock, {
                mode     = 'client',
                protocol = 'any',
                cafile   = paths.LIB_DIR .. 'cacert.pem',
                verify   = 'peer',
                options  = 'all',
            })
            if not c then return 'error', 'ssl.wrap: ' .. tostring(e) end
            conn = c
            pcall(function() conn:sni(host) end)  -- SNI: GitHub needs it
            conn:settimeout(0)
            stage = 'handshake'
            return 'pending'

        elseif stage == 'handshake' then
            local r, e = conn:dohandshake()
            if r then stage = 'send'; return 'pending' end
            if e == 'wantread' or e == 'wantwrite' or e == 'timeout' then return 'pending' end
            return 'error', 'handshake: ' .. tostring(e)

        elseif stage == 'send' then
            local i, e = conn:send(request, sent + 1)
            if i then
                sent = i
                if sent >= #request then stage = 'recv' end
                return 'pending'
            end
            if e == 'wantwrite' or e == 'wantread' or e == 'timeout' then return 'pending' end
            return 'error', 'send: ' .. tostring(e)

        elseif stage == 'recv' then
            -- Read at most RECV_CHUNK bytes per poll (NOT '*a', which drains the
            -- whole buffer in one call and stalls the tick for the full
            -- transfer). receive(n) returns: n bytes as `data` with no error
            -- (more may remain → yield); or a short `partial` with
            -- wantread/wantwrite/timeout (would block → yield); or `closed` with
            -- the final partial (HTTP/1.0 Connection: close → body complete).
            local data, e, partial = conn:receive(RECV_CHUNK)
            if data and #data > 0 then chunks[#chunks + 1] = data end
            if partial and #partial > 0 then chunks[#chunks + 1] = partial end
            if e == 'closed' then
                cleanup()
                local code, body = split_response(table.concat(chunks))
                if code ~= 200 then return 'error', 'HTTP ' .. tostring(code) end
                return 'done', body
            end
            if e == nil or e == 'wantread' or e == 'wantwrite' or e == 'timeout' then
                return 'pending'
            end
            return 'error', 'recv: ' .. tostring(e)
        end
        return 'error', 'bad stage'
    end

    local req = {}
    function req.poll()
        polls = polls + 1
        if polls > MAX_POLLS then cleanup(); return 'error', 'timed out' end
        local ok, status, payload = pcall(step)
        if not ok then
            cleanup()
            return 'error', 'transport: ' .. tostring(status)
        end
        return status, payload
    end
    return req
end

return M
