-- community_transport.lua — real HTTPS transport for community_fetch.
-- Satisfies the transport contract: request(url) -> req with :poll() ->
-- 'pending' | 'done',body | 'error',msg.
--
-- DCS ships LuaSocket but NOT LuaSec; the LuaSec payload (ssl.dll, OpenSSL
-- DLLs, ssl.lua, https.lua, cacert.pem) is expected under
-- <Saved Games>/DCS/dcs-sms/lib/ and wired onto package.cpath/path by
-- init.lua. If LuaSec is absent, M.available() is false and the UI degrades
-- gracefully ("secure networking unavailable").
--
-- NOTE: this initial transport performs a SINGLE blocking https.request()
-- inside the first poll() and returns the result immediately. The fetch
-- coroutine still yields between separate requests, but a single GitHub
-- request is small (manifest is a few KB) so the per-tick stall is minimal.
-- The non-blocking, across-ticks TLS handshake is the documented follow-on
-- hardening (see spec Constraints / risks). Keeping it behind the same
-- transport contract means that upgrade is a drop-in replacement.

local paths = require('dcs_sms_me.paths')
local M = {}

local https
local function load_https()
    if https ~= nil then return https end
    local ok, mod = pcall(require, 'ssl.https')
    if ok and type(mod) == 'table' then https = mod else https = false end
    return https
end

function M.available()
    return load_https() ~= false
end

-- Path to the bundled CA bundle. https.request uses it for peer verification.
local function cafile()
    return paths.LIB_DIR .. 'cacert.pem'
end

local function do_request(url)
    local mod = load_https()
    if not mod then return nil, 'LuaSec not installed (place ssl.dll + cacert.pem in dcs-sms\\lib)' end
    -- ltn12 co-installs with LuaSocket, but guard the require so a missing
    -- dependency degrades to a returned error instead of throwing (ME-mod
    -- never throws out of runtime code — AGENTS.md §2.11).
    local ok_ltn, ltn12 = pcall(require, 'ltn12')
    if not ok_ltn or type(ltn12) ~= 'table' then return nil, 'ltn12 unavailable' end
    local chunks = {}
    local ok, code = pcall(function()
        local _, c = mod.request{
            url = url,
            sink = ltn12.sink.table(chunks),
            protocol = 'tlsv1_2',
            verify = 'peer',
            options = 'all',
            cafile = cafile(),
        }
        return c
    end)
    if not ok then return nil, 'request error: ' .. tostring(code) end
    if code ~= 200 then return nil, 'HTTP ' .. tostring(code) end
    return table.concat(chunks)
end

function M.request(_, url)
    local done = false
    return {
        poll = function()
            if done then return 'error', 'already polled' end
            done = true
            local body, err = do_request(url)
            if body then return 'done', body end
            return 'error', err
        end,
    }
end

return M
