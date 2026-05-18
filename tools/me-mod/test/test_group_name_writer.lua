-- Standalone test for dcs_sms_me.group_name_writer.
-- Verifies the check_group_name → renameGroup pipeline + fallback paths.

package.path = '../?.lua;../lua/dcs_sms_me/?.lua;../lua/?.lua;' .. package.path

-- Build a fresh Mission stub per case. We can't use the real mock_me_mission
-- because we want to control check_group_name / renameGroup presence and
-- behavior precisely per case.

local check_calls, rename_calls
local function fresh_mission(opts)
    opts = opts or {}
    check_calls = {}
    rename_calls = {}
    local m = {}
    if opts.check_returns ~= nil then
        function m.check_group_name(name)
            check_calls[#check_calls + 1] = name
            if type(opts.check_returns) == 'function' then
                return opts.check_returns(name)
            end
            return opts.check_returns
        end
    end
    if opts.rename_returns ~= nil then
        function m.renameGroup(g, name)
            rename_calls[#rename_calls + 1] = { group = g, name = name }
            if type(opts.rename_returns) == 'function' then
                return opts.rename_returns(g, name)
            end
            return opts.rename_returns
        end
    end
    package.loaded['me_mission'] = m
    return m
end

local function load_writer()
    package.loaded['dcs_sms_me.group_name_writer'] = nil
    return require('dcs_sms_me.group_name_writer')
end

local failures = 0
local function check(name, ok, msg)
    if ok then print('PASS ' .. name)
    else print('FAIL ' .. name .. ': ' .. tostring(msg)); failures = failures + 1 end
end

-- Case 1: check_group_name returns the same name (no collision) → renameGroup called with desired.
do
    fresh_mission({
        check_returns = function(n) return n end,
        rename_returns = true,
    })
    local writer = load_writer()
    local g = { name = 'A' }
    local ok, actual, err = writer.write(g, 'Foo')
    check('case1: ok=true', ok == true)
    check('case1: actual=Foo', actual == 'Foo')
    check('case1: err=nil', err == nil)
    check('case1: check_group_name called with desired', check_calls[1] == 'Foo')
    check('case1: renameGroup called with safe (=desired)', rename_calls[1] and rename_calls[1].name == 'Foo')
end

-- Case 2: check_group_name auto-suffixes → renameGroup called with the suffixed name.
do
    fresh_mission({
        check_returns = function(n) return n .. '-1' end,
        rename_returns = true,
    })
    local writer = load_writer()
    local g = { name = 'A' }
    local ok, actual, err = writer.write(g, 'Foo')
    check('case2: ok=true', ok == true)
    check('case2: actual=Foo-1 (auto-suffixed)', actual == 'Foo-1')
    check('case2: renameGroup called with Foo-1', rename_calls[1] and rename_calls[1].name == 'Foo-1')
end

-- Case 3: check_group_name absent → falls through to renameGroup with desired.
do
    fresh_mission({
        check_returns = nil,
        rename_returns = true,
    })
    local writer = load_writer()
    local g = { name = 'A' }
    local ok, actual = writer.write(g, 'Foo')
    check('case3: ok=true', ok == true)
    check('case3: actual=Foo (no disambiguation)', actual == 'Foo')
    check('case3: 0 check calls', #check_calls == 0)
    check('case3: renameGroup called with Foo', rename_calls[1] and rename_calls[1].name == 'Foo')
end

-- Case 4: check_group_name throws → swallow + fall through with desired.
do
    fresh_mission({
        check_returns = function() error('boom') end,
        rename_returns = true,
    })
    local writer = load_writer()
    local g = { name = 'A' }
    local ok, actual = writer.write(g, 'Foo')
    check('case4: ok=true (rename succeeds even though check threw)', ok == true)
    check('case4: actual=Foo (fallback to desired)', actual == 'Foo')
    check('case4: renameGroup called with Foo', rename_calls[1] and rename_calls[1].name == 'Foo')
end

-- Case 5: renameGroup absent (very old / test VM) → direct g.name assign + ok=true.
do
    fresh_mission({
        check_returns = function(n) return n end,
        rename_returns = nil,
    })
    local writer = load_writer()
    local g = { name = 'A' }
    local ok, actual = writer.write(g, 'Foo')
    check('case5: ok=true', ok == true)
    check('case5: actual=Foo', actual == 'Foo')
    check('case5: g.name mutated directly', g.name == 'Foo')
    check('case5: 0 rename calls', #rename_calls == 0)
end

-- Case 6: renameGroup returns false (rejected) → ok=false, err set, g.name unchanged.
do
    fresh_mission({
        check_returns = function(n) return n end,
        rename_returns = false,
    })
    local writer = load_writer()
    local g = { name = 'A' }
    local ok, actual, err = writer.write(g, 'Foo')
    check('case6: ok=false', ok == false)
    check('case6: actual=Foo (the name we tried)', actual == 'Foo')
    check('case6: err is set', type(err) == 'string' and #err > 0)
    check('case6: g.name unchanged (real ME would mutate on success only)', g.name == 'A')
end

-- Case 7: both APIs missing → direct g.name assign, ok=true.
do
    fresh_mission({})
    local writer = load_writer()
    local g = { name = 'A' }
    local ok, actual = writer.write(g, 'Foo')
    check('case7: ok=true', ok == true)
    check('case7: actual=Foo', actual == 'Foo')
    check('case7: g.name mutated directly', g.name == 'Foo')
end

-- Case 8: check_group_name returns empty/nil → fall through to desired (defensive).
do
    fresh_mission({
        check_returns = function() return '' end,
        rename_returns = true,
    })
    local writer = load_writer()
    local g = { name = 'A' }
    local ok, actual = writer.write(g, 'Foo')
    check('case8: ok=true', ok == true)
    check('case8: actual=Foo (empty check result ignored)', actual == 'Foo')
    check('case8: renameGroup called with Foo', rename_calls[1] and rename_calls[1].name == 'Foo')
end

if failures > 0 then print(failures .. ' failure(s)'); os.exit(1) end
print('All group_name_writer tests passed.')
