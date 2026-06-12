-- static_catalog.lua — placeable Static types from me_db_api, as plain rows.
--
-- The ME-API touch is kept thin (resolve/list walk the DB inside pcall);
-- everything downstream works on plain rows { type, display, shape_name,
-- category, rate } so list/filter logic stays unit-testable.
--
-- Category convention: the mission table stores the *display label* of the
-- static panel's category combo, NOT a DB field. (Verified against real
-- ME-placed statics: a Fortification carries category = "Structures".)
-- The label is derived from WHICH plural table of country.Units an entry
-- sits in (mirrors me_static.lua addCategory) — unit defs themselves often
-- have category = nil (every aircraft) or vehicle-combat categories
-- ("Armor", "Unarmed") that never appear in the static panel. The one
-- vanilla quirk we mirror: defs with def.category == 'Fortification'
-- always file under 'Structures' even when found in the Cars table.
--
-- Public:
--   M.PLURAL_LABEL                   — country.Units table name → label
--   M.resolve_type(type_name) → row | nil, err
--   M.list(country_name) → rows[], err? (sorted by category, then display)
--   M.categories(rows) → sorted unique category labels in rows
--   M.filter(rows, opts) → rows[]   — pure; opts.category / opts.search

local M = {}

-- country.Units.<plural> → static-panel category label. Tables not listed
-- here are not offered as statics.
M.PLURAL_LABEL = {
    Planes         = 'Planes',
    Helicopters    = 'Helicopters',
    Ships          = 'Ships',
    Cars           = 'Ground vehicles',
    Fortifications = 'Structures',
    Heliports      = 'Heliports',
    Warehouses     = 'Warehouses',
    Cargos         = 'Cargos',
    Effects        = 'Effects',
    Personnel      = 'Personnel',
    ADEquipments   = 'Airfield and deck equipment',
    Animals        = 'Animals',
    GrassAirfields = 'Grass Airfields',
    WWIIstructures = 'WWIIstructures',
    LTAvehicles    = 'LTAvehicles',
}

local function label_for(plural, def)
    local label = M.PLURAL_LABEL[plural]
    if not label then return nil end
    -- Vanilla quirk (me_static.lua isValidType): Fortification defs file
    -- under Structures regardless of which table they came from.
    if def and def.category == 'Fortification' then return 'Structures' end
    return label
end

local function make_row(type_name, def, label)
    return {
        type       = type_name,
        display    = (def and (def.DisplayName or def.Name)) or type_name,
        shape_name = (def and def.ShapeName) or '',
        category   = label,
        rate       = (def and tonumber(def.Rate)) or 100,
    }
end

-- Lazy type → category-label index, built once by walking every country's
-- Units tree (a type's label is the same in every country).
local type_label_cache = nil

local function type_label_index()
    if type_label_cache then return type_label_cache end
    local idx = {}
    pcall(function()
        local DB = require('me_db_api')
        if type(DB.db) ~= 'table' or type(DB.db.Countries) ~= 'table' then return end
        for _, c in pairs(DB.db.Countries) do
            if type(c) == 'table' and type(c.Units) == 'table' then
                for plural, tbl in pairs(c.Units) do
                    if M.PLURAL_LABEL[plural] and type(tbl) == 'table' then
                        for _, subcat in pairs(tbl) do
                            if type(subcat) == 'table' then
                                for _, entry in pairs(subcat) do
                                    if type(entry) == 'table' and type(entry.Name) == 'string'
                                       and not idx[entry.Name] then
                                        idx[entry.Name] = plural
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    type_label_cache = idx
    return idx
end

-- Resolve one type name against the DB. Returns a row or nil + error.
function M.resolve_type(type_name)
    if type(type_name) ~= 'string' or type_name == '' then
        return nil, 'type name is empty'
    end
    local def
    local ok = pcall(function()
        local DB = require('me_db_api')
        def = DB.unit_by_type and DB.unit_by_type[type_name]
    end)
    if not ok or not def then
        return nil, 'unknown unit type: ' .. type_name
    end
    local plural = type_label_index()[type_name]
    local label = plural and label_for(plural, def)
    if not label then
        return nil, 'type "' .. type_name .. '" is not a placeable static'
    end
    return make_row(type_name, def, label)
end

-- Enumerate every static-placeable type `country_name` can deploy.
-- Returns {} (never nil) plus an optional error string when the DB isn't
-- reachable.
function M.list(country_name)
    local rows = {}
    local err
    local ok = pcall(function()
        local DB = require('me_db_api')
        if type(DB.db) ~= 'table' or type(DB.db.Countries) ~= 'table' then
            err = 'me_db_api DB unavailable'
            return
        end
        local country
        for _, c in pairs(DB.db.Countries) do
            if type(c) == 'table' and c.Name == country_name then country = c; break end
        end
        if not country or type(country.Units) ~= 'table' then
            err = 'country not in DB: ' .. tostring(country_name)
            return
        end
        local seen = {}
        for plural, tbl in pairs(country.Units) do
            if M.PLURAL_LABEL[plural] and type(tbl) == 'table' then
                for _, subcat in pairs(tbl) do
                    if type(subcat) == 'table' then
                        for _, entry in pairs(subcat) do
                            if type(entry) == 'table' and type(entry.Name) == 'string'
                               and not seen[entry.Name] then
                                seen[entry.Name] = true
                                local def = DB.unit_by_type and DB.unit_by_type[entry.Name]
                                local label = label_for(plural, def)
                                if label then
                                    rows[#rows + 1] = make_row(entry.Name, def, label)
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    if not ok then err = err or 'me_db_api walk failed' end
    table.sort(rows, function(a, b)
        if a.category ~= b.category then return a.category < b.category end
        return a.display < b.display
    end)
    return rows, err
end

-- Sorted unique category labels present in `rows`. Pure.
function M.categories(rows)
    local seen, out = {}, {}
    for _, r in ipairs(rows or {}) do
        if r.category and not seen[r.category] then
            seen[r.category] = true
            out[#out + 1] = r.category
        end
    end
    table.sort(out)
    return out
end

-- Pure filter: opts.category (exact label, nil = all), opts.search
-- (case-insensitive substring of display OR type, nil/'' = all).
function M.filter(rows, opts)
    opts = opts or {}
    local needle = type(opts.search) == 'string' and opts.search:lower() or ''
    local out = {}
    for _, r in ipairs(rows or {}) do
        local cat_ok = (opts.category == nil) or (r.category == opts.category)
        local search_ok = needle == ''
            or r.display:lower():find(needle, 1, true) ~= nil
            or r.type:lower():find(needle, 1, true) ~= nil
        if cat_ok and search_ok then out[#out + 1] = r end
    end
    return out
end

return M
