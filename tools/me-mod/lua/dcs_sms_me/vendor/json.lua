-- json.lua — minimal decode-only JSON parser (vendored, MIT-style).
-- decode(str) -> value | raises error on malformed input.
-- Maps JSON null to Lua nil (so absent vs null are indistinguishable —
-- acceptable for the manifest, which never uses null meaningfully).
local M = {}

-- Hard cap on object/array nesting. decode is pcall-guarded by callers, so a
-- stack overflow on pathologically deep input already fails safe; this rejects
-- hostile input with a clean error before that limit is reached.
local MAX_DEPTH = 200

local function skip_ws(s, i)
    local _, j = s:find('^[ \t\r\n]*', i)
    return (j or i - 1) + 1
end

local decode_value  -- forward

local esc_map = { ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }

local function decode_string(s, i)
    -- assumes s:sub(i,i) == '"'
    i = i + 1
    local buf = {}
    while true do
        local c = s:sub(i, i)
        if c == '' then error('unterminated string') end
        if c == '"' then return table.concat(buf), i + 1 end
        if c == '\\' then
            local e = s:sub(i + 1, i + 1)
            if e == 'u' then
                local hex = s:sub(i + 2, i + 5)
                if not hex:match('^%x%x%x%x$') then error('bad \\u escape') end
                local cp = tonumber(hex, 16)
                -- Encode the BMP code point as UTF-8 (manifest text is ASCII/BMP).
                if cp < 0x80 then
                    buf[#buf+1] = string.char(cp)
                elseif cp < 0x800 then
                    buf[#buf+1] = string.char(0xC0 + math.floor(cp/0x40), 0x80 + (cp % 0x40))
                else
                    buf[#buf+1] = string.char(0xE0 + math.floor(cp/0x1000),
                        0x80 + (math.floor(cp/0x40) % 0x40), 0x80 + (cp % 0x40))
                end
                i = i + 6
            else
                local m = esc_map[e]
                if not m then error('bad escape \\' .. e) end
                buf[#buf+1] = m
                i = i + 2
            end
        else
            buf[#buf+1] = c
            i = i + 1
        end
    end
end

local function decode_number(s, i)
    local num = s:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', i)
    if not num or num == '' then error('invalid number at ' .. i) end
    local n = tonumber(num)
    if not n then error('invalid number "' .. num .. '"') end
    return n, i + #num
end

local function decode_array(s, i, depth)
    i = i + 1  -- skip [
    local arr = {}
    i = skip_ws(s, i)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
        local v
        v, i = decode_value(s, i, depth + 1)
        arr[#arr + 1] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == ']' then return arr, i + 1 end
        if c ~= ',' then error('expected , or ] at ' .. i) end
        i = skip_ws(s, i + 1)
    end
end

local function decode_object(s, i, depth)
    i = i + 1  -- skip {
    local obj = {}
    i = skip_ws(s, i)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
        i = skip_ws(s, i)
        if s:sub(i, i) ~= '"' then error('expected string key at ' .. i) end
        local key; key, i = decode_string(s, i)
        i = skip_ws(s, i)
        if s:sub(i, i) ~= ':' then error('expected : at ' .. i) end
        i = skip_ws(s, i + 1)
        local v; v, i = decode_value(s, i, depth + 1)
        obj[key] = v
        i = skip_ws(s, i)
        local c = s:sub(i, i)
        if c == '}' then return obj, i + 1 end
        if c ~= ',' then error('expected , or } at ' .. i) end
        i = i + 1
    end
end

decode_value = function(s, i, depth)
    depth = depth or 0
    if depth > MAX_DEPTH then error('nesting too deep (>' .. MAX_DEPTH .. ') at ' .. i) end
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '{' then return decode_object(s, i, depth) end
    if c == '[' then return decode_array(s, i, depth) end
    if c == '"' then return decode_string(s, i) end
    if c == '-' or c:match('%d') then return decode_number(s, i) end
    if s:sub(i, i + 3) == 'true'  then return true,  i + 4 end
    if s:sub(i, i + 4) == 'false' then return false, i + 5 end
    if s:sub(i, i + 3) == 'null'  then return nil,   i + 4 end
    error('unexpected character "' .. c .. '" at ' .. i)
end

function M.decode(str)
    if type(str) ~= 'string' then error('decode expects a string') end
    local v, i = decode_value(str, 1)
    i = skip_ws(str, i)
    if i <= #str then error('trailing data at ' .. i) end
    return v
end

return M
