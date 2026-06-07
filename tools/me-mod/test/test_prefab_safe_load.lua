-- test_prefab_safe_load.lua
package.path = '../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path
local sl = require('dcs_sms_me.prefab_safe_load')
local failures = 0
local function check(n, ok, msg) if ok then print('PASS '..n) else print('FAIL '..n..': '..tostring(msg)); failures=failures+1 end end
local function accepts(label, src)
    local t, err = sl.load_string(src)
    check('accept '..label, type(t) == 'table', err)
    return t
end
local function rejects(label, src)
    local t, err = sl.load_string(src)
    check('reject '..label, t == nil and type(err) == 'string', 'unexpectedly accepted')
end

-- Accept: serializer-shaped output (bracketed keys, comments, nested, negatives, escapes).
local t = accepts('serializer shape', [[
return {
  ["meta"] = {
    ["name"] = "farp_alpha",
    ["theatre"] = "Caucasus",
    ["place_at_origin"] = false,
  },
  ["groups"] = {
    [1] = { ["x"] = -123.5, ["y"] = 0, ["name"] = "g\"1", ["alive"] = true },
  },
  ["zones"] = {},
  -- a trailing comment
}
]])
check('value: nested string', t and t.meta and t.meta.name == 'farp_alpha', t and t.meta and t.meta.name)
check('value: negative number', t and t.groups[1].x == -123.5)
check('value: escaped quote in string', t and t.groups[1].name == 'g"1')
check('value: bool', t and t.groups[1].alive == true)

accepts('bare identifier keys', 'return { meta = { name = "x" }, a = 1, b = nil }')
accepts('positional array', 'return { 1, 2, "three", { 4 } }')
accepts('block comment', 'return { --[[ hi ]] a = 1 }')
accepts('boolean key', 'return { [true] = 1, [false] = 2 }')
accepts('nil value', 'return { ["x"] = nil }')

-- Negative numbers, including negative hex (must NOT unsigned-wrap in Lua 5.1).
local tn = accepts('negative numbers', 'return { ["a"] = -0xFF, ["b"] = -255, ["c"] = -1.5e3 }')
check('value: negative hex', tn and tn.a == -255, tn and tn.a)
check('value: negative decimal', tn and tn.b == -255, tn and tn.b)
check('value: negative exponent', tn and tn.c == -1500, tn and tn.c)

-- Reject: anything that isn't pure data.
rejects('top-level call before return', 'print("x") return {}')
rejects('call in value', 'return { name = os.execute("calc") }')
rejects('bare global value', 'return { x = os }')
rejects('concatenation operator', 'return { x = "a" .. "b" }')
rejects('arithmetic operator', 'return { x = 1 + 1 }')
rejects('division idiom (nan)', 'return { x = 0/0 }')
rejects('function definition', 'return { f = function() end }')
rejects('method call', 'return { x = ("a"):rep(3) }')
rejects('loadstring', 'return loadstring("os.exit()")')
rejects('vararg', 'return { ... }')
rejects('two returns', 'return {} return {}')
rejects('trailing code after table', 'return {} ; os.exit()')
rejects('no return', '{ a = 1 }')
rejects('return non-table', 'return 42')
rejects('unterminated table', 'return { a = 1')
rejects('index expression value', 'return { x = a[1] }')

if failures > 0 then os.exit(1) end
print('All prefab_safe_load tests passed.')
