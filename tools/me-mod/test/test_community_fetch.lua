-- test_community_fetch.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local fetch = require('dcs_sms_me.community_fetch')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures = failures + 1 end end

-- Mock transport: returns 'pending' for `delay` polls, then 'done' with body.
local function mock_transport(body, delay, fail)
    return {
        request = function(_, url)
            local n = 0
            return { poll = function()
                n = n + 1
                if fail then return 'error', 'mock failure' end
                if n <= (delay or 0) then return 'pending' end
                return 'done', body
            end }
        end,
    }
end

-- Happy path: manifest decodes + parses.
do
    local raw = '{"schema":1,"generated":"t","prefabs":[{"name":"A","sha256":"aa","path":"p","tags":["x"],"likes":3}]}'
    local job = fetch.new(mock_transport(raw, 2))
    job:start_manifest()
    local state
    for _ = 1, 10 do state = job:step(); if state ~= 'running' then break end end
    check('manifest done', state == 'done', state .. ' / ' .. tostring(job.error))
    check('parsed entries', job.manifest and #job.manifest.entries == 1)
    check('raw captured', job.raw == raw)
end

-- Transport error → job error.
do
    local job = fetch.new(mock_transport('', 0, true))
    job:start_manifest()
    local state
    for _ = 1, 5 do state = job:step(); if state ~= 'running' then break end end
    check('transport error surfaced', state == 'error' and type(job.error) == 'string', job.error)
end

-- Bad JSON → job error.
do
    local job = fetch.new(mock_transport('{not json', 0))
    job:start_manifest()
    local state
    for _ = 1, 5 do state = job:step(); if state ~= 'running' then break end end
    check('bad json error', state == 'error' and type(job.error) == 'string', job.error)
end

-- File fetch helper.
do
    local job = fetch.new(mock_transport('return {}', 1))
    job:fetch_file('http://x/p.prefab')
    local state
    for _ = 1, 5 do state = job:step(); if state ~= 'running' then break end end
    check('file body done', state == 'done' and job.file_body == 'return {}', tostring(job.file_body))
end

if failures > 0 then os.exit(1) end
print('All community_fetch tests passed.')
