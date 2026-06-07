-- community_fetch.lua — non-blocking fetch orchestration. A job runs a
-- coroutine that polls an injected transport; the caller pumps it with
-- :step() (one call per UpdateManager tick in production). No blocking.
local cfg      = require('dcs_sms_me.community_config')
local json     = require('dcs_sms_me.vendor.json')
local manifest = require('dcs_sms_me.community_manifest')

local M = {}
local Job = {}
Job.__index = Job

function M.new(transport)
    return setmetatable({
        transport = transport,
        co = nil, state = 'idle',
        manifest = nil, raw = nil, file_body = nil, error = nil,
    }, Job)
end

-- Drive one transport request to completion inside a coroutine. Yields
-- 'pending' until poll() resolves; returns body or raises on error.
local function pull(transport, url)
    local req = transport:request(url)
    while true do
        local status, result = req:poll()
        if status == 'done' then return result end
        if status == 'error' then error(tostring(result), 0) end
        coroutine.yield()  -- 'pending' → give the tick back
    end
end

function Job:start_manifest()
    self.state = 'running'; self.error = nil; self.manifest = nil; self.raw = nil
    self.co = coroutine.create(function()
        local body = pull(self.transport, cfg.manifest_url())
        self.raw = body
        local ok, decoded = pcall(json.decode, body)
        if not ok then error('manifest JSON parse failed: ' .. tostring(decoded), 0) end
        local m, merr = manifest.parse(decoded)
        if not m then error(merr, 0) end
        self.manifest = m
    end)
end

function Job:fetch_file(url)
    self.state = 'running'; self.error = nil; self.file_body = nil
    self.co = coroutine.create(function()
        self.file_body = pull(self.transport, url)
    end)
end

function Job:step()
    if self.state ~= 'running' or not self.co then return self.state end
    local ok, err = coroutine.resume(self.co)
    if not ok then
        self.state = 'error'; self.error = tostring(err); self.co = nil
        return self.state
    end
    if coroutine.status(self.co) == 'dead' then
        self.state = 'done'; self.co = nil
    end
    return self.state
end

return M
