-- dcs_sms_me/sms_grid.lua — the shared sortable-grid plumbing for ME-mod tool
-- windows (Prefab Manager, Mass Edit, Trigger Finder).
--
-- This is deliberately NARROW. Every tool window builds its tree/list on ED's
-- dxgui `Grid` and then hand-rolls the same controller boilerplate around it:
-- skinned construction, per-column header cells, the header click-to-sort
-- asc/desc state machine, and the ▲/▼ header re-text. That plumbing is what
-- this module owns. See GH#75.
--
-- What this module does NOT own (the tools genuinely diverge here — see #75):
--   * the sort comparator — numeric vs string, prefab error-rows-to-bottom,
--     Trigger Finder's group→unit nesting. Each tool keeps its own.
--   * the row model + rendering — flat list vs folder tree vs checkbox rows.
--   * onMouseDown / selectRow semantics — context menus, shift-range selection,
--     camera pan, right-pane render. All window-specific.
--   * sort *state storage* — global `W.sort_key/dir` in Prefab Manager and
--     Trigger Finder vs per-scope `W.sort_state[scope]` in Mass Edit. The
--     toggle math is shared; where the state lives is the caller's business,
--     reached through the get_sort/on_sort callbacks.
--
-- dxgui globals `Grid` and `GridHeaderCell` are provided by the ME runtime
-- (same as in the consumer files); tests stub them.

local skin_helper    = require('dcs_sms_me.skin_helper')
local sms_skins      = require('dcs_sms_me.sms_skins')
local sms_scrollbars = require('dcs_sms_me.sms_scrollbars')

local M = {}

-- ▲ asc / ▼ desc, as UTF-8 escape sequences so the indicator is independent of
-- this file's on-disk encoding.
local ARROW_UP   = ' \226\150\178'
local ARROW_DOWN = ' \226\150\188'

-- build_grid(opts) — a Grid skinned with the DCS-SMS house grid skin.
--   opts.scrollbars — when a table, refine the skin's scrollbars via
--                     sms_scrollbars.apply(skin, opts.scrollbars) (Trigger
--                     Finder passes { refine_horz = false }). Omit to leave the
--                     stock grid scrollbars (Prefab Manager / Mass Edit).
-- Returns the Grid, or nil if the runtime didn't hand one back.
function M.build_grid(opts)
    opts = opts or {}
    if not (Grid and Grid.new) then return nil end
    local ok, grid = pcall(Grid.new)
    if not (ok and grid) then return nil end
    pcall(function()
        local sk = sms_skins.grid()
        if sk then
            if type(opts.scrollbars) == 'table' then
                sms_scrollbars.apply(sk, opts.scrollbars)
            end
            grid:setSkin(sk)
        end
    end)
    return grid
end

-- wire_sortable_headers(grid, cols, opts) — build one skinned GridHeaderCell per
-- column, insert it into the grid, and wire click-to-sort.
--
--   cols — { { key = <string>, label = <string>, width = <number> }, ... }
--   opts.get_sort() -> key, dir   — current sort state (caller-owned)
--   opts.on_sort(key, dir)        — called after a header click computes the
--                                   next state; the caller stores it and
--                                   re-renders. dir is 'asc' or 'desc'.
--   opts.is_sortable(col) -> bool — optional; return false to leave a column
--                                   unsorted (e.g. Mass Edit's 'check' column).
--
-- Toggle rule (shared across all three tools): clicking the active column flips
-- asc↔desc; clicking a different column selects it ascending.
--
-- Returns headers — { { hc = <GridHeaderCell>, key = <string>, label = <string> }, ... }
-- parallel to cols. Pass it back to update_header_labels.
function M.wire_sortable_headers(grid, cols, opts)
    opts = opts or {}
    local headers = {}
    for _, col in ipairs(cols) do
        local hc
        if GridHeaderCell and GridHeaderCell.new then
            local ok, cell = pcall(GridHeaderCell.new)
            if ok then hc = cell end
        end
        if hc then
            skin_helper.apply(hc, 'sms_grid_header')
            pcall(function() hc:setText(col.label) end)

            local sortable = (opts.is_sortable == nil) or opts.is_sortable(col)
            if sortable and hc.addChangeCallback then
                local key = col.key
                pcall(function()
                    hc:addChangeCallback(function()
                        local cur_key, cur_dir = opts.get_sort()
                        local dir
                        if cur_key == key then
                            dir = (cur_dir == 'asc') and 'desc' or 'asc'
                        else
                            dir = 'asc'
                        end
                        opts.on_sort(key, dir)
                    end)
                end)
            end

            headers[#headers + 1] = { hc = hc, key = col.key, label = col.label }
            pcall(function() grid:insertColumn(col.width, hc) end)
        end
    end
    return headers
end

-- update_header_labels(headers, sort_key, sort_dir) — re-text each header,
-- appending ▲/▼ to the column matching sort_key.
function M.update_header_labels(headers, sort_key, sort_dir)
    for _, h in ipairs(headers or {}) do
        local label = h.label
        if h.key == sort_key then
            label = label .. (sort_dir == 'desc' and ARROW_DOWN or ARROW_UP)
        end
        pcall(function()
            if h.hc and h.hc.setText then h.hc:setText(label) end
        end)
    end
end

return M
