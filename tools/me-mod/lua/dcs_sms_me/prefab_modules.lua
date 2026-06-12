-- prefab_modules.lua — detect community-mod dependencies of a prefab selection
-- and check, at load time, which required mods are missing.
--
-- This is the ONLY file that touches the mod-detection ED globals
-- (me_mission.setRequiredModules, me_modulesInfo, _G.pluginsById), mirroring
-- how selection.lua owns the ME selection globals. Every ED touch is
-- pcall-guarded; on any failure we log + degrade to empty so a save or a
-- placement is never broken (project failure model: log + empty, never throw).
--
-- "What is a mod" is settled by DCS itself: me_mission.setRequiredModules is
-- the exact logic that fills mission.requiredModules. A live probe over the
-- full unit DB showed it flags only third-party community mods (Hercules,
-- A-4E-C, UH-60L, AH-6J) — official paid modules self-exempt via is_core. So
-- we delegate; we do no official-vs-community classification of our own.
--
-- Public:
--   M.detect(dump [, deps]) -> required_modules_map | nil
--       dump = { groups = {...}, statics = {...}, ... } — each group/static
--              has .units[].type (the same envelope prefab_ops builds for
--              distill). Returns the meta.required_modules map keyed by module
--              id, or nil when nothing is required.
--   M.missing(prefab [, deps]) -> { {id, display_name, count}, ... }
--       Reads prefab.meta.required_modules and returns the entries whose
--       providing plugin is not installed. Empty when all present / on error.
--
-- `deps` is an optional injection table for tests:
--   deps.required_ids(unit_type) -> { module_id, ... }
--   deps.display_name(module_id) -> string
--   deps.plugin_present(module_id) -> boolean

local M = {}

local function log_warn(msg)
    pcall(function()
        local log = require('log')
        log.write('sms.me.prefab', log.WARNING, msg)
    end)
end

-- Default: run DCS's own setRequiredModules for one unit type and return the
-- set of module ids it would require (empty for core/exempt/unknown types).
local function default_required_ids(unit_type)
    local ids = {}
    pcall(function()
        local me_mission = require('me_mission')
        if type(me_mission.setRequiredModules) ~= 'function' then return end
        local probe = { requiredModules = {} }
        pcall(me_mission.setRequiredModules, probe, unit_type)
        for id in pairs(probe.requiredModules) do ids[#ids + 1] = id end
    end)
    return ids
end

-- Default: best-effort friendly name for a module id. Captured at SAVE time
-- (the mod is installed then) so the load-side warning can show a real name
-- even on a machine that lacks the mod. Falls back to the id.
local function default_display_name(id)
    local name
    pcall(function()
        local plug = _G.pluginsById and _G.pluginsById[id]
        if plug then
            if type(plug.displayName) == 'string' and plug.displayName ~= '' then
                name = plug.displayName
            elseif type(plug.fileMenuName) == 'string' and plug.fileMenuName ~= '' then
                name = plug.fileMenuName
            end
        end
        if not name then
            local mi = require('me_modulesInfo')
            if type(mi.getModulDisplayNameByModulId) == 'function' then
                local n = mi.getModulDisplayNameByModulId(id)
                if type(n) == 'string' and n ~= '' then name = n end
            end
        end
    end)
    return name or id
end

-- Default: is module `id` installed? A plugin present in pluginsById is loaded.
-- If pluginsById is unavailable we can't tell, so we report PRESENT to avoid a
-- false "missing mod" warning (spec: missing-check failure -> nothing missing).
local function default_plugin_present(id)
    local present = true
    pcall(function()
        if type(_G.pluginsById) ~= 'table' then return end  -- can't tell -> present
        present = _G.pluginsById[id] ~= nil
    end)
    return present
end

-- Visit every unit type across the dump's groups + statics, honoring count.
local function each_unit_type(dump, cb)
    local function walk(container)
        if type(container) ~= 'table' then return end
        for _, entry in ipairs(container) do
            if type(entry) == 'table' and type(entry.units) == 'table' then
                for _, u in ipairs(entry.units) do
                    if type(u) == 'table' and type(u.type) == 'string' and u.type ~= '' then
                        cb(u.type)
                    end
                end
            end
        end
    end
    walk(dump.groups)
    walk(dump.statics)
end

function M.detect(dump, deps)
    if type(dump) ~= 'table' then return nil end
    deps = deps or {}
    local required_ids = deps.required_ids or default_required_ids
    local display_name = deps.display_name or default_display_name

    local acc = {}
    local ok = pcall(function()
        each_unit_type(dump, function(unit_type)
            local got, ids = pcall(required_ids, unit_type)
            if not got or type(ids) ~= 'table' then return end
            for _, id in ipairs(ids) do
                if type(id) == 'string' and id ~= '' then
                    local rec = acc[id]
                    if not rec then
                        rec = { id = id, display_name = nil, objects = {}, count = 0 }
                        acc[id] = rec
                    end
                    rec.objects[unit_type] = (rec.objects[unit_type] or 0) + 1
                    rec.count = rec.count + 1
                end
            end
        end)
    end)
    if not ok then
        log_warn('detect: walk failed; recording no required_modules')
        return nil
    end

    local any = false
    for id, rec in pairs(acc) do
        any = true
        local got, name = pcall(display_name, id)
        rec.display_name = (got and type(name) == 'string' and name) or id
    end
    if not any then return nil end
    return acc
end

function M.missing(prefab, deps)
    if type(prefab) ~= 'table' or type(prefab.meta) ~= 'table' then return {} end
    local req = prefab.meta.required_modules
    if type(req) ~= 'table' then return {} end
    deps = deps or {}
    local plugin_present = deps.plugin_present or default_plugin_present

    local out = {}
    for id, rec in pairs(req) do
        if type(id) == 'string' and type(rec) == 'table' then
            local got, present = pcall(plugin_present, id)
            -- Report missing ONLY when the check succeeded and says absent.
            if got and present == false then
                out[#out + 1] = {
                    id = id,
                    display_name = (type(rec.display_name) == 'string' and rec.display_name ~= ''
                                    and rec.display_name) or id,
                    count = tonumber(rec.count) or 0,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- M.absent(list [, deps]) -> { {id, display_name, count}, ... }
-- List-shaped sibling of M.missing for the Community manifest entry, whose
-- `required_modules` is an ARRAY of { id, display_name, count } (not a map).
-- Returns the subset whose providing plugin is NOT installed, sorted by id.
-- Same plugin-present check + same fail-safe as M.missing (can't tell ->
-- present -> not reported). Bad input -> {}; never throws.
function M.absent(list, deps)
    if type(list) ~= 'table' then return {} end
    deps = deps or {}
    local plugin_present = deps.plugin_present or default_plugin_present

    local out = {}
    for _, rec in ipairs(list) do
        if type(rec) == 'table' and type(rec.id) == 'string' and rec.id ~= '' then
            local got, present = pcall(plugin_present, rec.id)
            -- Report missing ONLY when the check succeeded and says absent.
            if got and present == false then
                out[#out + 1] = {
                    id = rec.id,
                    display_name = (type(rec.display_name) == 'string' and rec.display_name ~= ''
                                    and rec.display_name) or rec.id,
                    count = tonumber(rec.count) or 0,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

return M
