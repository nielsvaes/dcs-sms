-- prefab_safe_load.lua — parse-don't-execute loader for untrusted prefab
-- files. Tokenises Lua source and parses ONLY the data subset:
--   return <table>
-- where <table> contains string/number/true/false/nil literals, nested
-- tables, and keys (bare identifier, ["str"], [num], [true]/[false], or
-- positional). Anything else (calls, identifiers-as-values, operators,
-- function defs, varargs, extra statements) is rejected without execution.
--
-- Public:
--   M.load_string(src) -> table | nil, err
--   M.load_file(path)  -> table | nil, err   (reads file, then load_string)

local M = {}

-- ---- Lexer -----------------------------------------------------------------
-- Produces tokens: { type = <kind>, value = <lua value or text>, pos = n }
-- kinds: 'punct' (one of { } [ ] = , ; ), 'string', 'number',
--        'true','false','nil','return','name', 'eof'.
-- Comments and whitespace are skipped. Any disallowed character/sequence
-- (operators, parens, etc.) raises a lex error captured by the caller.

local KEYWORD = { ['return']=true, ['true']=true, ['false']=true, ['nil']=true }

local function lex(src)
    local tokens = {}
    local i, n = 1, #src

    local function err(msg, at) error({ msg = msg, pos = at or i }, 0) end

    local function long_bracket(start)
        -- start points at first '['; supports [[ ]] and [=[ ]=] levels.
        local eqs = src:match('^%[(=*)%[', start)
        if not eqs then return nil end
        local level = #eqs
        local close = ']' .. string.rep('=', level) .. ']'
        local from = start + level + 2
        local e = src:find(close, from, true)
        if not e then err('unterminated long bracket', start) end
        return e + #close, src:sub(from, e - 1)
    end

    while i <= n do
        local c = src:sub(i, i)
        if c == ' ' or c == '\t' or c == '\r' or c == '\n' then
            i = i + 1
        elseif c == '-' and src:sub(i + 1, i + 1) == '-' then
            -- comment: long or line
            local after = i + 2
            if src:sub(after, after) == '[' then
                local nxt = long_bracket(after)
                if nxt then i = nxt else
                    local e = src:find('\n', after, true); i = e and (e + 1) or (n + 1)
                end
            else
                local e = src:find('\n', after, true); i = e and (e + 1) or (n + 1)
            end
        elseif c == '"' or c == "'" then
            local quote = c
            local buf, j = {}, i + 1
            while true do
                local ch = src:sub(j, j)
                if ch == '' then err('unterminated string', i) end
                if ch == quote then j = j + 1; break end
                if ch == '\n' then err('unterminated string', i) end
                if ch == '\\' then
                    local e = src:sub(j + 1, j + 1)
                    local map = { n='\n', t='\t', r='\r', a='\a', b='\b', f='\f', v='\v',
                                  ['\\']='\\', ['"']='"', ["'"]="'", ['\n']='\n' }
                    if map[e] then buf[#buf+1] = map[e]; j = j + 2
                    elseif e:match('%d') then
                        local digits = src:match('^%d%d?%d?', j + 1)
                        buf[#buf+1] = string.char(tonumber(digits) % 256); j = j + 1 + #digits
                    else err('invalid string escape \\' .. e, j) end
                else
                    buf[#buf+1] = ch; j = j + 1
                end
            end
            tokens[#tokens+1] = { type='string', value=table.concat(buf), pos=i }
            i = j
        elseif c:match('[%d]')
            or (c == '.' and src:sub(i+1,i+1):match('%d'))
            or (c == '-' and (src:sub(i+1,i+1):match('%d')
                              or (src:sub(i+1,i+1) == '.' and src:sub(i+2,i+2):match('%d')))) then
            -- number: optional leading '-' sign, then hex or decimal float w/
            -- exponent. The serializer emits negative literals (e.g. -123.5) so
            -- a '-' that *immediately* prefixes a digit/'.digit' is a numeric
            -- sign. A '-' NOT followed by a number falls through to the
            -- disallowed-character branch (so binary subtraction with spaces is
            -- rejected); a bare '-1' touching a preceding value lexes as a
            -- second number token and is rejected by the parser's separator
            -- check. NO '/' is ever lexed: the serializer emits NaN/inf as
            -- 0/0, 1/0, -1/0, and this validator deliberately rejects '/' (and
            -- thus those degenerate values) per the feature spec — shared
            -- prefabs must not contain NaN/inf, so such files are rejected.
            local negate = false
            local start = i
            if c == '-' then negate = true; start = i + 1 end
            local num = src:match('^0[xX]%x+', start)
                     or src:match('^%d*%.?%d+[eE][%+%-]?%d+', start)
                     or src:match('^%d*%.?%d+', start)
            if not num then err('malformed number', i) end
            -- Parse the unsigned magnitude, then negate numerically. Building
            -- the signed string ('-0xFF') and calling tonumber on it would, in
            -- Lua 5.1, unsigned-wrap a negative hex literal (yielding
            -- 4294967041 instead of -255), so we negate the value instead.
            local value = tonumber(num)
            if negate then value = -value end
            -- Reject non-finite results. '/' is disallowed (so NaN/inf written
            -- as 0/0, 1/0 never lex), but a huge literal like 1e999 overflows
            -- to inf via tonumber — shared prefabs must not carry inf/NaN (see
            -- the header note), so reject it here rather than write it to disk.
            if value == nil or value ~= value
                or value == math.huge or value == -math.huge then
                err('non-finite number not allowed', i)
            end
            tokens[#tokens+1] = { type='number', value=value, pos=i }
            i = start + #num
        elseif c:match('[%a_]') then
            local word = src:match('^[%a_][%w_]*', i)
            if KEYWORD[word] then tokens[#tokens+1] = { type=word, pos=i }
            else tokens[#tokens+1] = { type='name', value=word, pos=i } end
            i = i + #word
        elseif c == '{' or c == '}' or c == '[' or c == ']' or c == '=' or c == ',' or c == ';' then
            -- A lone '[' could start a long string literal (Lua allows [[...]]
            -- as a string). Support that so string values using long brackets
            -- still parse; but '=' must be a single '=' (reject '==' etc.).
            if c == '[' and src:sub(i+1,i+1):match('[%[=]') then
                local nxt, str = long_bracket(i)
                if nxt then tokens[#tokens+1] = { type='string', value=str, pos=i }; i = nxt
                else tokens[#tokens+1] = { type='punct', value='[', pos=i }; i = i + 1 end
            elseif c == '=' and src:sub(i+1,i+1) == '=' then
                err('comparison operator not allowed', i)
            else
                tokens[#tokens+1] = { type='punct', value=c, pos=i }; i = i + 1
            end
        else
            err('disallowed character "' .. c .. '"', i)
        end
    end
    tokens[#tokens+1] = { type='eof', pos=n + 1 }
    return tokens
end

-- ---- Parser ----------------------------------------------------------------

-- Hard cap on table-constructor nesting. The upstream pcall already fails
-- safe if the interpreter's own stack overflows on a pathologically deep
-- file, but an explicit cap rejects hostile input with a clean error well
-- before that limit (and before any LuaJIT C-stack edge case in DCS). No
-- real prefab nests anywhere near this deep.
local MAX_DEPTH = 200

local function parse(tokens)
    local p = 1
    local depth = 0
    local function peek() return tokens[p] end
    local function next_tok() local t = tokens[p]; p = p + 1; return t end
    local function expect(ty, val)
        local t = tokens[p]
        if t.type ~= ty or (val ~= nil and t.value ~= val) then
            error({ msg = 'expected ' .. ty .. (val and (' "'..val..'"') or ''), pos = t.pos }, 0)
        end
        p = p + 1; return t
    end

    local parse_value, parse_table  -- forward

    local function is_punct(t, v) return t.type == 'punct' and t.value == v end

    parse_value = function()
        local t = peek()
        if t.type == 'string' then next_tok(); return t.value end
        if t.type == 'number' then next_tok(); return t.value end
        if t.type == 'true'   then next_tok(); return true end
        if t.type == 'false'  then next_tok(); return false end
        if t.type == 'nil'    then next_tok(); return nil, true end  -- second ret: "was nil"
        if is_punct(t, '{')   then return parse_table() end
        if t.type == 'name' then
            error({ msg = 'identifier "' .. tostring(t.value) .. '" is not a literal value', pos = t.pos }, 0)
        end
        error({ msg = 'unexpected ' .. t.type .. ' where a value was expected', pos = t.pos }, 0)
    end

    parse_table = function()
        expect('punct', '{')
        depth = depth + 1
        if depth > MAX_DEPTH then
            error({ msg = 'table nesting too deep (>' .. MAX_DEPTH .. ')', pos = peek().pos }, 0)
        end
        local tbl = {}
        local array_idx = 0
        while true do
            local t = peek()
            if is_punct(t, '}') then next_tok(); break end

            if is_punct(t, '[') then
                -- [ key ] = value  where key is string/number/bool literal
                next_tok()
                local kt = peek()
                local key
                if kt.type == 'string' or kt.type == 'number' then key = kt.value; next_tok()
                elseif kt.type == 'true' then key = true; next_tok()
                elseif kt.type == 'false' then key = false; next_tok()
                else error({ msg = 'table key must be a string/number/boolean literal', pos = kt.pos }, 0) end
                expect('punct', ']')
                expect('punct', '=')
                local v, was_nil = parse_value()
                if not was_nil then tbl[key] = v end
            elseif t.type == 'name' and is_punct(tokens[p + 1], '=') then
                -- bare identifier key:  name = value
                local key = t.value
                next_tok(); next_tok()  -- name, '='
                local v, was_nil = parse_value()
                if not was_nil then tbl[key] = v end
            else
                -- positional value
                local v, was_nil = parse_value()
                array_idx = array_idx + 1
                if not was_nil then tbl[array_idx] = v end
            end

            local sep = peek()
            if is_punct(sep, ',') or is_punct(sep, ';') then next_tok()
            elseif is_punct(sep, '}') then -- loop handles close
            else error({ msg = 'expected "," ";" or "}" in table', pos = sep.pos }, 0) end
        end
        depth = depth - 1
        return tbl
    end

    expect('return')
    if not is_punct(peek(), '{') then
        error({ msg = 'top-level value must be a table constructor', pos = peek().pos }, 0)
    end
    local result = parse_table()
    -- Allow a single optional trailing ';' then require EOF.
    if is_punct(peek(), ';') then next_tok() end
    if peek().type ~= 'eof' then
        error({ msg = 'unexpected trailing content', pos = peek().pos }, 0)
    end
    return result
end

function M.load_string(src)
    if type(src) ~= 'string' then return nil, 'source must be a string' end
    local ok, result = pcall(function()
        local tokens = lex(src)
        return parse(tokens)
    end)
    if not ok then
        local e = result
        if type(e) == 'table' and e.msg then
            return nil, string.format('safe-load rejected (pos %d): %s', e.pos or 0, e.msg)
        end
        return nil, 'safe-load rejected: ' .. tostring(e)
    end
    if type(result) ~= 'table' then return nil, 'top-level value is not a table' end
    return result
end

function M.load_file(path)
    if type(path) ~= 'string' or path == '' then return nil, 'path required' end
    local f, oerr = io.open(path, 'rb')
    if not f then return nil, 'open failed: ' .. tostring(oerr) end
    local src = f:read('*a'); f:close()
    return M.load_string(src or '')
end

return M
