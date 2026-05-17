-- mass_edit.lua — the Mass Edit tool window.
--
-- A single sms_window-chromed window with a top-of-window scope tab strip
-- and (filled in by later tasks) a treeview / filter widgets / property
-- panel / preview table. Toggle via DCS-SMS → Mass Edit menu entry.
--
-- The window's lifecycle is idempotent — show() reuses the previous
-- widget tree (hidden, not destroyed) when re-opened in the same session.
-- All per-session state lives in the W table; rebuild_pool / rebuild_
-- treeview / rebuild_property_panel / recompute_plan / rebuild_preview
-- helpers wire the data flow.

local M = {}

local sms_window = require('dcs_sms_me.sms_window')
local selection  = require('dcs_sms_me.selection')
local registry   = require('dcs_sms_me.mass_edit_registry')
local ops        = require('dcs_sms_me.mass_edit_ops')
local version    = require('dcs_sms_me.version')

-- ---------------------------------------------------------------------------
-- Per-window state.
-- ---------------------------------------------------------------------------

local W = {
    sms_window         = nil,
    scope              = 'group',   -- 'group' | 'unit' | 'waypoint' | 'zone' | 'drawing'
    source             = 'marquee',
    pool               = {},
    parent_map         = {},
    checked            = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {} },
    filters            = { group = {}, unit = {}, waypoint = {}, zone = {}, drawing = {} },
    property_id        = nil,
    operation          = nil,
    op_args            = {},
    plan               = nil,
    debounce_deadline  = nil,
    -- Widget handles (populated lazily on first show).
    widgets = {
        scope_tabs   = {},
        scope_counts = {},
        tree         = nil,
        property_sel = nil,
        operation_sel = nil,
        args_panel   = nil,
        preview_grid = nil,
        apply_btn    = nil,
        cancel_btn   = nil,
        refresh_btn  = nil,
        banner_label = nil,
    },
    _built = false,
}

local SCOPES = { 'group', 'unit', 'waypoint', 'zone', 'drawing' }

local function log_info(msg)
    pcall(function() _G.log.write('sms.me.mass_edit', _G.log.INFO or 0, msg) end)
end
local function log_warn(msg)
    pcall(function() _G.log.write('sms.me.mass_edit', _G.log.WARNING or 2, msg) end)
end

-- ---------------------------------------------------------------------------
-- Data flow helpers.
-- ---------------------------------------------------------------------------

local function rebuild_pool()
    local snap = selection.snapshot_drilled(W.scope)
    if not snap.ok then
        log_warn('snapshot_drilled failed: ' .. tostring(snap.error))
        W.pool = {}; W.parent_map = {}; W.source = 'marquee'
        return
    end
    W.pool, W.parent_map, W.source = snap.pool, snap.parent_map, snap.source

    -- Drop checked entries for items no longer in the pool.
    local in_pool = {}
    for _, e in ipairs(W.pool) do in_pool[e] = true end
    for e, _ in pairs(W.checked[W.scope] or {}) do
        if not in_pool[e] then W.checked[W.scope][e] = nil end
    end
end

local function scope_pool_counts()
    local counts = {}
    for _, s in ipairs(SCOPES) do
        local snap = selection.snapshot_drilled(s)
        counts[s] = snap.ok and #snap.pool or 0
    end
    return counts
end

local function recompute_plan()
    if not W.property_id or not W.operation then
        W.plan = nil
        return
    end
    local checked_entities = {}
    for _, e in ipairs(W.pool) do
        if W.checked[W.scope][e] then
            checked_entities[#checked_entities + 1] = e
        end
    end
    W.plan = ops.compute_plan(W.scope, checked_entities, W.parent_map,
                              W.property_id, W.operation, W.op_args)
end

local function on_scope_changed(new_scope)
    if new_scope == W.scope then return end
    W.scope = new_scope
    W.property_id, W.operation, W.op_args = nil, nil, {}
    rebuild_pool()
    M.rebuild_treeview()
    M.rebuild_property_panel()
    recompute_plan()
    M.rebuild_preview()
end

local function on_refresh_clicked()
    rebuild_pool()
    M.update_scope_counts()
    M.rebuild_treeview()
    M.rebuild_property_panel()
    recompute_plan()
    M.rebuild_preview()
end

-- ---------------------------------------------------------------------------
-- Stub widget hooks; real bodies in tasks 12/13/14.
-- ---------------------------------------------------------------------------

function M.rebuild_treeview()         W._tree_dirty = true end
function M.rebuild_property_panel()   W._panel_dirty = true end
function M.rebuild_preview()          W._preview_dirty = true end
function M.update_scope_counts()
    if not W.widgets.scope_counts then return end
    local counts = scope_pool_counts()
    for scope, lbl in pairs(W.widgets.scope_counts) do
        if lbl and lbl.setText then pcall(lbl.setText, lbl, tostring(counts[scope] or 0)) end
    end
end

-- ---------------------------------------------------------------------------
-- Window construction (scaffolding; live widgets come in task 12).
-- ---------------------------------------------------------------------------

local function build_window()
    if W._built then return end

    W.sms_window = sms_window.new({
        title    = 'Mass Edit',
        size     = { w = 900, h = 600 },
        min_size = { w = 720, h = 500 },
        on_undo  = sms_window.default_on_undo,
        on_resize = function(handle, x, y, w, h)
            -- Future: respond to resize.
        end,
    })
    if not W.sms_window then
        log_warn('sms_window.new returned nil')
        return
    end

    local raw = W.sms_window:raw()
    if not raw then
        log_warn('sms_window:raw() returned nil')
        return
    end

    -- Scope tab strip and other widgets are added in task 12. This task
    -- only ensures the chrome is in place.

    W._built = true
end

function M.show()
    build_window()
    if not W.sms_window then return end
    rebuild_pool()
    M.update_scope_counts()
    M.rebuild_treeview()
    M.rebuild_property_panel()
    recompute_plan()
    M.rebuild_preview()
    W.sms_window:show()
end

function M.hide()
    if W.sms_window then W.sms_window:hide() end
end

function M.toggle()
    if W.sms_window and W.sms_window:raw() and W.sms_window:raw():isVisible() then
        M.hide()
    else
        M.show()
    end
end

-- Expose internals for tests.
M._W = W
M._scope_pool_counts = scope_pool_counts
M._recompute_plan    = recompute_plan
M._rebuild_pool      = rebuild_pool
M._on_scope_changed  = on_scope_changed
M._on_refresh_clicked = on_refresh_clicked

return M
