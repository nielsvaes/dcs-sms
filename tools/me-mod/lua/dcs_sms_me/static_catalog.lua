-- static_catalog.lua — placeable Static types from me_db_api, as plain rows.
--
-- The ME-API touch is kept thin (resolve/list walk the DB inside pcall);
-- everything downstream works on plain rows { type, display, shape_name,
-- category, rate } so list/filter logic stays unit-testable.
--
-- Category convention: the mission table stores the *display label* of the
-- static panel's category combo, NOT the DB's singular category name.
-- (Verified against real ME-placed statics: a Fortification carries
-- category = "Structures".) CATEGORY_LABEL maps DB → mission label.
--
-- Public:
--   M.CATEGORY_LABEL                 — DB singular category → mission label
--   M.resolve_type(type_name) → row | nil, err
--   M.list(country_name) → rows[], grouped sort (category, then display)
--   M.categories(rows) → sorted unique category labels in rows
--   M.filter(rows, opts) → rows[]   — pure; opts.category / opts.search

local M = {}

-- DB.unit_by_type[*].category → the label the mission table (and the ME
-- static panel) uses. Categories not listed here are not placeable as
-- statics ('Air Defence', 'Armor', … belong to vehicle groups).
M.CATEGORY_LABEL = {
    Fortification  = 'Structures',
    Cargo          = 'Cargos',
    Warehouse      = 'Warehouses',
    Heliport       = 'Heliports',
    Plane          = 'Planes',
    Helicopter     = 'Helicopters',
    Ship           = 'Ships',
    Car            = 'Ground vehicles',
    Personnel      = 'Personnel',
    ADEquipment    = 'Airfield and deck equipment',
    Effect         = 'Effects',
    Animal         = 'Animals',
    GrassAirfield  = 'Grass Airfields',
    WWIIstructure  = 'WWIIstructures',
    LTAvehicle     = 'LTAvehicles',
    MissilesSS     = 'MissilesSS',
}

-- Build a row from a DB unit def. Returns nil when the def isn't a
-- static-placeable category.
local function row_from_def(type_name, def)
    if type(def) ~= 'table' then return nil end
    local label = M.CATEGORY_LABEL[def.category]
    if not label then return nil end
    return {
        type       = type_name,
        display    = def.DisplayName or def.Name or type_name,
        shape_name = def.ShapeName or '',
        category   = label,
        rate       = tonumber(def.Rate) or 100,
    }
end

-- Resolve one type name against DB.unit_by_type. Log-free; the caller
-- surfaces the error string in its status bar.
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
    local row = row_from_def(type_name, def)
    if not row then
        return nil, 'type "' .. type_name .. '" is not a placeable static (category '
            .. tostring(def.category) .. ')'
    end
    return row
end

-- Enumerate every static-placeable type `country_name` can deploy.
-- Walks DB.db.Countries[*].Units[<plural>][<subcat>][] — the same data the
-- ME's unit-creation panels use. Returns {} (never nil) plus an optional
-- error string when the DB isn't reachable.
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
        for _, plural in pairs(country.Units) do
            if type(plural) == 'table' then
                for _, subcat in pairs(plural) do
                    if type(subcat) == 'table' then
                        for _, entry in pairs(subcat) do
                            if type(entry) == 'table' and type(entry.Name) == 'string'
                               and not seen[entry.Name] then
                                seen[entry.Name] = true
                                local def = DB.unit_by_type and DB.unit_by_type[entry.Name]
                                local row = row_from_def(entry.Name, def)
                                if row then rows[#rows + 1] = row end
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
