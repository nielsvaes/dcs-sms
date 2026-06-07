-- test_community_tab_import.lua
-- Regression test for the Community-tab import wiring: when a 'file' fetch job
-- completes, handle:tick() must dispatch on_file_done with the entry that was
-- pending, so importer.import actually runs. A bug cleared W.pending_import
-- BEFORE on_file_done read it, so the import silently no-op'd (toast stuck on
-- "Downloading…", nothing written to Community/).
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Stub lfs so paths/community_import load in the bare test VM.
package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             attributes = function() return nil end }
end

local importer = require('dcs_sms_me.community_import')
local tab      = require('dcs_sms_me.community_tab')

local failures = 0
local function check(n, ok, msg)
    if ok then print('PASS ' .. n) else print('FAIL ' .. n .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Record importer.import calls instead of touching disk. Same table reference
-- the tab captured at load, so this stub is what the tab will call.
local import_calls = {}
importer.import = function(entry, body)
    import_calls[#import_calls + 1] = { entry = entry, body = body }
    return true, 'C:\\fake\\Community\\' .. tostring(entry and entry.name) .. '.prefab'
end
-- The tab also probes is_imported during update_detail; keep it harmless.
importer.is_imported = function() return false end

-- Build the tab. Widgets are all nil in the test VM (pcall-guarded), but the
-- fetch/import wiring under test is pure Lua.
local statuses = {}
local refreshed = { n = 0 }
local handle = tab.build(nil, {
    set_status = function(text, sev) statuses[#statuses + 1] = { text = text, sev = sev } end,
    refresh_my_library = function() refreshed.n = refreshed.n + 1 end,
})
check('build returns a handle', type(handle) == 'table' and type(handle.tick) == 'function')

local W = handle._W
check('exposes _W', type(W) == 'table')

-- Simulate the state right after on_import_click kicked a file fetch that has
-- now completed: a done 'file' job carrying the downloaded body, plus the
-- pending entry awaiting import.
local entry = { name = '2 x ZSU 01', path = 'prefabs/2-x-zsu-01.prefab',
                sha256 = 'deadbeef', tags = {} }
W.job = { file_body = 'return {}', step = function() return 'done' end }
W.job_kind = 'file'
W.pending_import = entry

handle:tick()

check('importer.import was called once', #import_calls == 1,
      'import called ' .. #import_calls .. ' time(s)')
check('import received the pending entry',
      import_calls[1] and import_calls[1].entry == entry,
      'got entry=' .. tostring(import_calls[1] and import_calls[1].entry))
check('import received the downloaded body',
      import_calls[1] and import_calls[1].body == 'return {}',
      'got body=' .. tostring(import_calls[1] and import_calls[1].body))
check('My-Prefabs library was refreshed after import', refreshed.n == 1,
      'refresh count=' .. refreshed.n)
check('job state cleared after completion', W.job == nil and W.job_kind == nil)

if failures > 0 then os.exit(1) end
print('All community_tab import tests passed.')
