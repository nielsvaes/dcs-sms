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

-- -------------------------------------------------------------------------
-- Regression: relayout must NOT reveal media widgets while the panel is
-- hidden. Bug: after viewing a Community image then switching to My Prefabs,
-- a window resize (which relayouts every tab, hidden or not) re-showed the
-- image + missing-mod warning "through" the My-Prefabs page.
-- -------------------------------------------------------------------------
local function vis_stub()
    return { visible = nil,
             setVisible = function(self, on) self.visible = (on and true) or false end }
end

check('panel starts hidden (W.shown is false)', W.shown == false,
      'W.shown=' .. tostring(W.shown))

-- A selection state that wants the missing-mod warning band shown.
W.mod_warn    = vis_stub()
W.mod_warn_on = true
W.cur_images  = {}

-- Hidden + window resize: the warning band must stay hidden.
handle:hide()
handle:relayout(900, 600)
check('relayout while hidden keeps mod-warn hidden', W.mod_warn.visible == false,
      'mod_warn.visible=' .. tostring(W.mod_warn.visible))

-- Active tab: relayout reveals it for the current selection.
handle:show()
check('relayout while shown reveals mod-warn', W.mod_warn.visible == true,
      'mod_warn.visible=' .. tostring(W.mod_warn.visible))

-- Switch away again, then resize: must hide once more (the reported bug).
handle:hide()
handle:relayout(820, 560)
check('resize after switching away re-hides mod-warn', W.mod_warn.visible == false,
      'mod_warn.visible=' .. tostring(W.mod_warn.visible))

-- Leaving the Community tab must also close the pop-out enlarge window (it's a
-- separate top-level window that would otherwise linger with a stale image).
-- community_tab captured this module table at load, so replacing .hide here is
-- seen by handle:hide()'s call-time lookup.
local image_window = require('dcs_sms_me.community_image_window')
local enlarge_hidden = 0
image_window.hide = function() enlarge_hidden = enlarge_hidden + 1 end
handle:show()
handle:hide()
check('handle:hide() closes the enlarge image window', enlarge_hidden >= 1,
      'enlarge_hidden=' .. enlarge_hidden)

if failures > 0 then os.exit(1) end
print('All community_tab import tests passed.')
