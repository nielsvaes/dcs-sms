-- base64.lua — pure-Lua base64 encode/decode (Lua 5.1, no bitops).
-- Used to embed trigger-referenced media (pictures, sounds, script
-- files) inside .prefab files. decode tolerates embedded whitespace;
-- both return nil on bad input (never throw) per the repo failure model.

local M = {}

local ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local BYTE_TO_CHAR = {}
local CHAR_TO_BYTE = {}
for i = 1, 64 do
    local c = ALPHABET:sub(i, i)
    BYTE_TO_CHAR[i - 1] = c
    CHAR_TO_BYTE[c] = i - 1
end

function M.encode(s)
    if type(s) ~= 'string' then return nil end
    local out = {}
    local len = #s
    local i = 1
    while i + 2 <= len do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + b * 256 + c
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = BYTE_TO_CHAR[c1] .. BYTE_TO_CHAR[c2]
                     .. BYTE_TO_CHAR[c3] .. BYTE_TO_CHAR[c4]
        i = i + 3
    end
    local rem = len - i + 1
    if rem == 1 then
        local a = s:byte(i)
        local n = a * 65536
        out[#out + 1] = BYTE_TO_CHAR[math.floor(n / 262144) % 64]
                     .. BYTE_TO_CHAR[math.floor(n / 4096) % 64] .. '=='
    elseif rem == 2 then
        local a, b = s:byte(i, i + 1)
        local n = a * 65536 + b * 256
        out[#out + 1] = BYTE_TO_CHAR[math.floor(n / 262144) % 64]
                     .. BYTE_TO_CHAR[math.floor(n / 4096) % 64]
                     .. BYTE_TO_CHAR[math.floor(n / 64) % 64] .. '='
    end
    return table.concat(out)
end

function M.decode(s)
    if type(s) ~= 'string' then return nil end
    -- Strip whitespace; serialized blobs may be wrapped.
    s = s:gsub('%s+', '')
    if s == '' then return '' end
    if #s % 4 ~= 0 then return nil end
    local pad = 0
    if s:sub(-2) == '==' then pad = 2
    elseif s:sub(-1) == '=' then pad = 1 end
    local body = s:sub(1, #s - pad)
    -- Validate alphabet up-front so we can return nil instead of garbage.
    if body:find('[^A-Za-z0-9+/]') then return nil end

    local out = {}
    local full = math.floor(#s / 4) - (pad > 0 and 1 or 0)
    local i = 1
    for _ = 1, full do
        local c1 = CHAR_TO_BYTE[s:sub(i, i)]
        local c2 = CHAR_TO_BYTE[s:sub(i + 1, i + 1)]
        local c3 = CHAR_TO_BYTE[s:sub(i + 2, i + 2)]
        local c4 = CHAR_TO_BYTE[s:sub(i + 3, i + 3)]
        local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4
        out[#out + 1] = string.char(math.floor(n / 65536) % 256,
                                    math.floor(n / 256) % 256,
                                    n % 256)
        i = i + 4
    end
    if pad == 2 then
        local c1 = CHAR_TO_BYTE[s:sub(i, i)]
        local c2 = CHAR_TO_BYTE[s:sub(i + 1, i + 1)]
        if not (c1 and c2) then return nil end
        local n = c1 * 262144 + c2 * 4096
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    elseif pad == 1 then
        local c1 = CHAR_TO_BYTE[s:sub(i, i)]
        local c2 = CHAR_TO_BYTE[s:sub(i + 1, i + 1)]
        local c3 = CHAR_TO_BYTE[s:sub(i + 2, i + 2)]
        if not (c1 and c2 and c3) then return nil end
        local n = c1 * 262144 + c2 * 4096 + c3 * 64
        out[#out + 1] = string.char(math.floor(n / 65536) % 256,
                                    math.floor(n / 256) % 256)
    end
    return table.concat(out)
end

return M
