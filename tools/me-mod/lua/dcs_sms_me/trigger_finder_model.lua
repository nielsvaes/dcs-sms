-- trigger_finder_model.lua — pure, dxgui-free model for the Trigger Finder.
--
-- Builds a display-ordered tree of the selected groups (→ their units) and
-- statics, and buckets each mission.trigrules entry under every node it
-- references. Walking is done here (not via trigger_export.find_related) so
-- each match keeps its source (condition|action) and predicate for the UI's
-- "why" line. All editor-specific knowledge is injected as two closures, so
-- this module is unit-testable on standalone Lua.
--
-- M.build(opts) -> { nodes = { <flat, display order> }, by_key = { key -> node } }
--   opts.groups: array (display order), each:
--     { id=<groupId>, name=<string>, kind='group'|'static',
--       units = { { id=<unitId>, name=<string> }, ... } }   -- statics: units ignored
--   opts.zones: array (display order), each { id=<zoneId>, name=<string> }
--     -- rendered as leaf nodes after the groups
--   opts.trigrules: array of raw trigger entries:
--     { comment=<string>, predicate=<pred>, rules={...}, actions={...} }
--     each rule/action: { predicate=<pred>, [fieldKey]=<number>, ... }
--   opts.field_kind(predicate, field_key) -> 'group'|'unit'|'zone'|nil
--   opts.type_label(predicate) -> short string (e.g. 'once', 'unit-dead')
--
-- Each node:
--   { key, kind='group'|'static'|'unit'|'zone', name, depth (0|1),
--     parent (unit only), group_id|unit_id|zone_id, expandable (group with units),
--     triggers = { { index, name, type, why }, ... } (index order), count }
local M = {}

local function gkey(id) return 'g' .. tostring(id) end
local function ukey(id) return 'u' .. tostring(id) end
local function zkey(id) return 'z' .. tostring(id) end

function M.build(opts)
    opts = opts or {}
    local groups     = opts.groups or {}
    local zones      = opts.zones or {}
    local trigrules  = opts.trigrules or {}
    local field_kind = opts.field_kind or function() return nil end
    local type_label = opts.type_label or function() return '' end

    local nodes, by_key = {}, {}
    local group_by_id, unit_by_id, zone_by_id = {}, {}, {}

    local function add_node(n)
        n.triggers = {}
        n.count = 0
        nodes[#nodes + 1] = n
        by_key[n.key] = n
        return n
    end

    for _, g in ipairs(groups) do
        local is_static = (g.kind == 'static')
        local has_units = (not is_static) and type(g.units) == 'table' and #g.units > 0
        local gnode = add_node({
            key        = gkey(g.id),
            kind       = is_static and 'static' or 'group',
            name       = g.name or '',
            depth      = 0,
            group_id   = g.id,
            expandable = has_units or false,
        })
        group_by_id[g.id] = gnode
        if not is_static then
            for _, u in ipairs(g.units or {}) do
                local unode = add_node({
                    key     = ukey(u.id),
                    kind    = 'unit',
                    name    = u.name or '',
                    depth   = 1,
                    parent  = gnode.key,
                    unit_id = u.id,
                })
                unit_by_id[u.id] = unode
            end
        end
    end

    for _, z in ipairs(zones) do
        local znode = add_node({
            key        = zkey(z.id),
            kind       = 'zone',
            name       = z.name or '',
            depth      = 0,
            zone_id    = z.id,
            expandable = false,
        })
        zone_by_id[z.id] = znode
    end

    local function attribute(node, rec, seen)
        if not node then return end
        local sk = node.key .. '#' .. rec.index
        if seen[sk] then return end
        seen[sk] = true
        node.triggers[#node.triggers + 1] = rec
    end

    for index, t in ipairs(trigrules) do
        if type(t) == 'table' then
            local tname = t.comment or ''
            local ttype = type_label(t.predicate)
            local seen = {}
            local function scan(list, source)
                for _, entry in ipairs(list or {}) do
                    if type(entry) == 'table' then
                        local entry_label = type_label(entry.predicate)
                        for k, v in pairs(entry) do
                            if k ~= 'predicate' and type(v) == 'number' then
                                local kind = field_kind(entry.predicate, k)
                                local node
                                if kind == 'group' then node = group_by_id[v]
                                elseif kind == 'unit' then node = unit_by_id[v]
                                elseif kind == 'zone' then node = zone_by_id[v] end
                                if node then
                                    attribute(node, {
                                        index = index,
                                        name  = tname,
                                        type  = ttype,
                                        why   = source .. ' · ' .. entry_label,
                                    }, seen)
                                end
                            end
                        end
                    end
                end
            end
            scan(t.rules, 'condition')
            scan(t.actions, 'action')
        end
    end

    for _, n in ipairs(nodes) do n.count = #n.triggers end
    return { nodes = nodes, by_key = by_key }
end

return M
