-- mass_edit_transforms.lua — pure operation primitives for the Mass Edit
-- tool. Each transform takes (old, args, idx) and returns the new value.
-- No I/O, no ME-internal globals — fully unit-testable.
--
-- idx is the 1-based row position in the apply plan. Ordering is decided
-- in mass_edit_ops.compute_plan before transforms are invoked, so a
-- transform can assume idx maps to user-chosen order.

local M = {}

-- Escape Lua-pattern metacharacters so find_replace treats user input as
-- a literal substring. Without this, '.' and '-' (etc.) would silently
-- match arbitrary characters.
function M.escape_pattern(s)
    return (s:gsub('([%(%)%.%%%+%-%*%?%[%]%^%$])', '%%%1'))
end

function M.set_all(old, args, idx)
    return args.value
end

function M.add_prefix(old, args, idx)
    return (args.text or '') .. (old or '')
end

function M.add_suffix(old, args, idx)
    return (old or '') .. (args.text or '')
end

function M.find_replace(old, args, idx)
    local subject = old or ''
    local find = args.find or ''
    if find == '' then return subject end
    local pat = M.escape_pattern(find)
    -- gsub replaces all by default; second return is count which we drop.
    local result = subject:gsub(pat, args.replace or '')
    return result
end

return M
