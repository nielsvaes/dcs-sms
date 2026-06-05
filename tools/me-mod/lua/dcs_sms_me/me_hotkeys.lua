-- me_hotkeys.lua — facade/singleton tying the ME-Hotkey layers together.
--
-- Builds one engine from the registry + saved overrides + selected backend,
-- applies it on bootstrap, and exposes toggle_window() for the menu. Pure
-- delegation; no dxgui at load (the window is required lazily on toggle).

local actions    = require('dcs_sms_me.me_hotkey_actions')
local config      = require('dcs_sms_me.me_hotkey_config')
local engine_mod  = require('dcs_sms_me.me_hotkey_engine')
local backend_mod = require('dcs_sms_me.me_hotkey_backend')
local scripts_mod = require('dcs_sms_me.me_hotkey_scripts')

local M = {}
local _engine

-- Built-in registry actions + one dynamic action per saved user script.
local function all_actions()
    local list = {}
    for _, a in ipairs(actions.list()) do list[#list + 1] = a end
    for _, a in ipairs(scripts_mod.to_actions(scripts_mod.load())) do list[#list + 1] = a end
    return list
end

local function build()
    return engine_mod.new({
        actions      = all_actions(),
        backend      = backend_mod.get(config.BACKEND_MODE),
        overrides    = config.load(),
        ed_conflicts = actions.ED_CONFLICTS,
        normalize    = actions.normalize_key,
    })
end

function M.engine()
    if not _engine then _engine = build() end
    return _engine
end

-- Called from init.lua on bootstrap (and on dev-reload). Rebuilds the engine
-- from disk and attaches the bindings. Note: on dev-reload the previous
-- generation's attachments persist on the toolbar window (perkey backend can't
-- recover lost tokens), so a double-attach is possible until a full DCS
-- restart — acceptable per the spec (bootstrap-level changes may need restart).
function M.install()
    local ok, err = pcall(function()
        _engine = build()
        _engine:apply()
    end)
    if ok then
        log.write('sms.me', log.INFO, 'ME Hotkeys installed')
    else
        log.write('sms.me', log.ERROR, 'ME Hotkeys install failed: ' .. tostring(err))
    end
end

function M.persist()
    pcall(function() config.save(M.engine():overrides_delta()) end)
end

-- Suspend / resume all live hotkey bindings. The capture overlay calls these
-- around a capture so the key the user presses to assign a binding doesn't also
-- fire whatever that key is currently bound to. resume re-attaches from the
-- current override state, so a bind made during the capture is honoured.
function M.suspend_bindings()
    pcall(function() M.engine():detach_all() end)
end

function M.resume_bindings()
    pcall(function() M.engine():apply() end)
end

function M.toggle_window()
    local ok, err = pcall(function() require('dcs_sms_me.me_hotkey_window').toggle() end)
    if not ok then log.write('sms.me', log.ERROR, 'ME Hotkeys window failed: ' .. tostring(err)) end
end

-- Called by the script editor after add/update/remove. Reconcile the LIVE engine
-- in place: swap in the new action set and re-apply so the engine detaches the
-- removed script's key and attaches the new one, leaving every other hotkey
-- untouched. (Do NOT call M.install() here — that builds a fresh engine with an
-- empty _live and re-registers every hotkey on top of the still-live previous
-- registrations, which broke all hotkeys on every save.)
function M.scripts_changed()
    pcall(function()
        local e = M.engine()
        e:set_actions(all_actions())
        e:apply()
    end)
    pcall(function()
        local w = require('dcs_sms_me.me_hotkey_window')
        if w and w.refresh then w.refresh() end
    end)
end

-- Open the script editor (id = existing script to edit, or nil for a new one).
function M.open_script_editor(id)
    local ok, err = pcall(function() require('dcs_sms_me.me_hotkey_script_editor').open(id) end)
    if not ok then
        log.write('sms.me', log.ERROR, 'script editor failed: ' .. tostring(err))
    end
end

return M
