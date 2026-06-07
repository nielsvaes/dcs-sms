-- test_community_transport.lua
-- Drives community_transport's non-blocking HTTPS state machine through a
-- MOCK LuaSocket + LuaSec, with no real network. The mocks script each
-- socket/ssl call so the test exercises every stage transition — including the
-- "still pending" branches (timeout / wantread / wantwrite), partial send,
-- partial-receive accumulation, SNI, and the cert-verify params — that a live
-- smoke test can't deterministically hit. One poll() must advance the machine
-- exactly one step and never block.
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub lfs so paths (required by the transport) loads in the bare VM.
package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             attributes = function() return nil end }
end

-- Per-request scenario the mocks read (response split + status line).
local scenario = {}
local captured  = { wrap_params = nil, sni_host = nil, sent = nil }

-- Mock raw TCP socket. connect() reports "still connecting" once (timeout),
-- then "already connected" — both must be treated as pending, not errors.
local function new_sock()
    local connects = 0
    return {
        settimeout = function() end,
        connect = function(_, host, port)
            connects = connects + 1
            if connects == 1 then return nil, 'timeout' end
            return nil, 'already connected'
        end,
        close = function() end,
    }
end

-- Mock TLS connection. Each verb yields a "want*"/timeout pending step before
-- succeeding, and send() reports a partial write before completing.
local function new_conn()
    local hs, sends, recvs = 0, 0, 0
    return {
        sni = function(_, host) captured.sni_host = host end,
        settimeout = function() end,
        dohandshake = function()
            hs = hs + 1
            if hs == 1 then return nil, 'wantread' end   -- pending
            return 1                                      -- handshake complete
        end,
        send = function(_, data, from)
            sends = sends + 1
            if sends == 1 then return nil, 'wantwrite' end          -- pending
            if sends == 2 then return math.floor(#data / 2) end     -- partial → pending
            captured.sent = #data
            return #data                                            -- fully sent → recv
        end,
        receive = function(_, pat)
            recvs = recvs + 1
            if recvs == 1 then return nil, 'wantread', '' end        -- pending, no bytes
            if recvs == 2 then return nil, 'timeout', scenario.part1 end -- partial body
            return nil, 'closed', scenario.part2                     -- server closed → done
        end,
        close = function() end,
    }
end

package.preload['socket'] = function() return { tcp = function() return new_sock() end } end
package.preload['ssl']    = function()
    return { wrap = function(sock, params) captured.wrap_params = params; return new_conn() end }
end

local paths     = require('dcs_sms_me.paths')
local transport = require('dcs_sms_me.community_transport')

local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end

-- Pump poll() to completion (bounded), recording the status sequence.
local function drive(req, max)
    local seq, body, err = {}, nil, nil
    for _ = 1, (max or 50) do
        local status, payload = req.poll()
        seq[#seq+1] = status
        if status == 'done'  then body = payload; break end
        if status == 'error' then err  = payload; break end
    end
    return seq, body, err
end

-- available() is true once the (mock) ssl module loads.
check('available() true with ssl present', transport.available() == true)

-- ---- Happy path: 200 with a body split across two partial receives ----------
scenario = {
    part1 = 'HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nServer: mock\r\n\r\nHELLO-',
    part2 = 'WORLD',
}
captured = {}
local req = transport.request(nil, 'https://raw.githubusercontent.com/owner/repo/main/index.json')
local seq, body, err = drive(req)

check('completes with done (not error)', body ~= nil and err == nil, err)
check('body = stripped, reassembled payload', body == 'HELLO-WORLD', body)
-- Every step before the last is pending — one non-blocking step per poll.
local all_pending = true
for i = 1, #seq - 1 do if seq[i] ~= 'pending' then all_pending = false end end
check('each poll advanced exactly one pending step', all_pending and seq[#seq] == 'done',
      table.concat(seq, ','))
check('multiple pending steps were taken (machine really stepped)', #seq >= 8, #seq)
-- SNI is required for GitHub's SDN; cert verification must be real.
check('SNI set to the host', captured.sni_host == 'raw.githubusercontent.com', captured.sni_host)
check('TLS verify = peer (cert checked)', captured.wrap_params and captured.wrap_params.verify == 'peer')
check('cafile points at the bundled CA bundle',
      captured.wrap_params and tostring(captured.wrap_params.cafile):match('cacert%.pem$') ~= nil,
      captured.wrap_params and captured.wrap_params.cafile)
check('full request was sent before recv', captured.sent ~= nil and captured.sent > 0)

-- ---- Error path: non-200 status is surfaced as an error ---------------------
scenario = { part1 = 'HTTP/1.0 404 Not Found\r\n\r\n', part2 = '' }
captured = {}
local req404 = transport.request(nil, 'https://raw.githubusercontent.com/owner/repo/main/missing.json')
local _, body404, err404 = drive(req404)
check('404 yields no body', body404 == nil)
check('404 surfaced as HTTP 404 error', type(err404) == 'string' and err404:find('404', 1, true) ~= nil, err404)

-- ---- Guard: a non-https URL fails immediately, without touching a socket ----
local reqbad = transport.request(nil, 'http://insecure.example/x')
local sbad, pbad = reqbad.poll()
check('non-https URL rejected', sbad == 'error' and tostring(pbad):find('https', 1, true) ~= nil, pbad)

if failures > 0 then os.exit(1) end
print('All community_transport tests passed.')
