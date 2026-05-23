-- applicability.lua — category-aware gating helper for Mass Edit forms.
--
-- Each unit-scope form may declare M.applies_to = { plane = true,
-- helicopter = true } to restrict which categories it operates on.
-- Forms without M.applies_to apply to every category (universal).
--
-- compute() returns (applicable_count, total_count) over a checked-set
-- so the host knows whether to gray-out the form (applicable == 0) or
-- leave it interactive (applicable > 0, with skip-and-count for the
-- non-matching units inside _apply).
--
-- is_applicable() is the per-entity convenience used inside _apply to
-- decide whether to skip a row.

local M = {}

-- Compute (applicable, total) for a checked set under a form's applies_to
-- map. `applies_to` nil/false/empty → universal (every entity applicable).
function M.compute(applies_to, checked, categories)
    if type(checked) ~= 'table' then return 0, 0 end
    local total = #checked
    if not applies_to or next(applies_to) == nil then
        return total, total
    end
    local cats = categories or {}
    local applicable = 0
    for _, e in ipairs(checked) do
        local cat = cats[e] or 'unknown'
        if applies_to[cat] then applicable = applicable + 1 end
    end
    return applicable, total
end

-- True iff a single entity is applicable under the given applies_to map.
function M.is_applicable(applies_to, entity, categories)
    if not applies_to or next(applies_to) == nil then return true end
    local cat = (categories or {})[entity] or 'unknown'
    return applies_to[cat] == true
end

return M
