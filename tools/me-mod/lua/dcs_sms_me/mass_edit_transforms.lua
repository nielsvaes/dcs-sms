-- mass_edit_transforms.lua — pure operation primitives for the Mass Edit
-- tool. Each transform takes (old, args, idx) and returns the new value.
-- No I/O, no ME-internal globals — fully unit-testable.
--
-- idx is the 1-based row position in the apply order. Ordering is decided
-- by the calling form module before transforms are invoked, so a
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

-- auto_number — substitute {n} in args.pattern with the running index.
-- args = { pattern, start, step, pad }.
--   pattern : string with one or more {n} tokens.
--   start   : number; running value at idx=1.
--   step    : number; increment per row.
--   pad     : integer >= 1; zero-pad width.
function M.auto_number(old, args, idx)
    local pattern = args.pattern or ''
    local start = args.start or 1
    local step = args.step or 1
    local pad = math.max(1, math.floor(args.pad or 1))
    local n = start + (idx - 1) * step
    local fmt = '%0' .. tostring(pad) .. 'd'
    local rendered = string.format(fmt, n)
    -- gsub replaces all occurrences; second return is count which we drop.
    local result = pattern:gsub('{n}', rendered)
    return result
end

function M.offset(old, args, idx)
    return (old or 0) + (args.delta or 0)
end

-- toggle_set — for 3-state boolean controls.
--   args.value = true  → set to true
--   args.value = false → set to false
--   args.value = nil   → leave unchanged (compute_plan converts this to a
--                        no-op row by checking the returned value before
--                        committing to the plan).
function M.toggle_set(old, args, idx)
    return args.value  -- pass-through, including nil
end

return M
