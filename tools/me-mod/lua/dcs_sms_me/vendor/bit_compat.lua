-- bit_compat.lua — 32-bit bit operations.
-- Returns LuaJIT's `bit` module when available (DCS), normalising its
-- signed results to unsigned 32-bit; otherwise a pure-Lua fallback.
-- API: band, bor, bxor, bnot, lshift, rshift, rrotate — all operate on and
-- return UNSIGNED 32-bit numbers (0 .. 2^32-1).

local M = {}
local MOD = 4294967296  -- 2^32

local function u32(x) x = x % MOD; if x < 0 then x = x + MOD end; return x end

local has_bit, bit = pcall(require, 'bit')
if has_bit and bit and bit.bxor then
    -- LuaJIT bit.* returns signed 32-bit; mask back to unsigned.
    function M.band(a, c)   return u32(bit.band(a, c)) end
    function M.bor(a, c)    return u32(bit.bor(a, c)) end
    function M.bxor(a, c)   return u32(bit.bxor(a, c)) end
    function M.bnot(a)      return u32(bit.bnot(a)) end
    function M.lshift(a, n) return u32(bit.lshift(a, n)) end
    function M.rshift(a, n) return u32(bit.rshift(a, n)) end
    function M.rrotate(a, n) return u32(bit.ror(a, n)) end
    return M
end

-- Pure-Lua fallback. Bitwise via per-bit arithmetic on unsigned 32-bit.
local function binop(a, c, op)
    a, c = u32(a), u32(c)
    local r, p = 0, 1
    for _ = 1, 32 do
        local abit, cbit = a % 2, c % 2
        if op(abit, cbit) == 1 then r = r + p end
        a = (a - abit) / 2
        c = (c - cbit) / 2
        p = p * 2
    end
    return r
end

function M.band(a, c) return binop(a, c, function(x, y) return (x == 1 and y == 1) and 1 or 0 end) end
function M.bor(a, c)  return binop(a, c, function(x, y) return (x == 1 or  y == 1) and 1 or 0 end) end
function M.bxor(a, c) return binop(a, c, function(x, y) return (x ~= y) and 1 or 0 end) end
function M.bnot(a)    return u32(MOD - 1 - u32(a)) end

function M.lshift(a, n)
    if n >= 32 then return 0 end
    return u32(u32(a) * (2 ^ n))
end

function M.rshift(a, n)
    if n >= 32 then return 0 end
    return math.floor(u32(a) / (2 ^ n))
end

function M.rrotate(a, n)
    n = n % 32
    a = u32(a)
    return u32(M.bor(M.rshift(a, n), M.lshift(a, 32 - n)))
end

return M
