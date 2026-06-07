-- sha256.lua — SHA-256 hex digest of a Lua string. Pure Lua via bit_compat.
local bit = require('dcs_sms_me.vendor.bit_compat')
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, rrotate       = bit.rshift, bit.rrotate
local MOD = 4294967296

local K = {
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2,
}

local function add(...)
    local s = 0
    for _, v in ipairs({...}) do s = s + v end
    return s % MOD
end

local function preprocess(msg)
    local len = #msg
    local bitlen = len * 8
    msg = msg .. '\128'
    while (#msg % 64) ~= 56 do msg = msg .. '\0' end
    -- 64-bit big-endian length. JS-safe: split into hi/lo 32 bits.
    local hi = math.floor(bitlen / MOD)
    local lo = bitlen % MOD
    local function be32(n)
        return string.char(
            math.floor(n / 0x1000000) % 256,
            math.floor(n / 0x10000) % 256,
            math.floor(n / 0x100) % 256,
            n % 256)
    end
    return msg .. be32(hi) .. be32(lo)
end

local M = {}

function M.hex(msg)
    if type(msg) ~= 'string' then error('sha256.hex expects a string') end
    msg = preprocess(msg)

    local h0,h1,h2,h3 = 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a
    local h4,h5,h6,h7 = 0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19

    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local p = chunk + i * 4
            w[i] = ((msg:byte(p) * 0x1000000)
                  + (msg:byte(p + 1) * 0x10000)
                  + (msg:byte(p + 2) * 0x100)
                  + (msg:byte(p + 3))) % MOD
        end
        for i = 16, 63 do
            local x = w[i - 15]
            local s0 = bxor(bxor(rrotate(x, 7), rrotate(x, 18)), rshift(x, 3))
            local y = w[i - 2]
            local s1 = bxor(bxor(rrotate(y, 17), rrotate(y, 19)), rshift(y, 10))
            w[i] = add(w[i - 16], s0, w[i - 7], s1)
        end

        local a,b,c,d,e,f,g,h = h0,h1,h2,h3,h4,h5,h6,h7
        for i = 0, 63 do
            local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = add(h, S1, ch, K[i + 1], w[i])
            local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local t2 = add(S0, maj)
            h = g; g = f; f = e; e = add(d, t1); d = c; c = b; b = a; a = add(t1, t2)
        end

        h0 = add(h0, a); h1 = add(h1, b); h2 = add(h2, c); h3 = add(h3, d)
        h4 = add(h4, e); h5 = add(h5, f); h6 = add(h6, g); h7 = add(h7, h)
    end

    return string.format('%08x%08x%08x%08x%08x%08x%08x%08x', h0,h1,h2,h3,h4,h5,h6,h7)
end

return M
