package.preload['lfs'] = function()
    return { writedir = function() return '' end, mkdir = function() return true end,
             attributes = function() return nil end, dir = function() return function() return nil end end }
end
package.preload['dcs_sms_me.selection'] = function()
    return { snapshot = function() return { ok = true, groups = {}, statics = {}, zones = {}, drawings = {} } end }
end
log = log or { write = function() end, INFO = 0, WARNING = 0, ERROR = 0 }

package.path = package.path .. ';../lua/?.lua;../lua/?/init.lua'

local prefab_ops = require('dcs_sms_me.prefab_ops')

local function pass(label) io.write('PASS ', label, '\n') end
local function check(label, ok)
    if ok then pass(label) else
        io.write('FAIL ', label, '\n'); os.exit(1)
    end
end

local v = prefab_ops._validate_folder_name

check('plain name OK',           v('CAP'))
check('with spaces OK',          v('Static defense'))
check('with dash/underscore OK', v('FARP-kits_2'))
check('alphanumeric OK',         v('CAP123'))

check('empty rejected',          not v(''))
check('whitespace-only rejected',not v('   '))
check('nil rejected',            not v(nil))
check('slash rejected',          not v('CAP/Tomcats'))
check('backslash rejected',      not v('CAP\\Tomcats'))
check('colon rejected',          not v('CAP:1'))
check('asterisk rejected',       not v('CAP*'))
check('question rejected',       not v('CAP?'))
check('quote rejected',          not v('CAP"name'))
check('lt rejected',             not v('CAP<'))
check('gt rejected',             not v('CAP>'))
check('pipe rejected',           not v('CAP|x'))
check('leading dot rejected',    not v('.hidden'))
check('reserved DOS name rejected', not v('CON'))
check('CON lowercase rejected',  not v('con'))
check('PRN rejected',            not v('PRN'))
check('NUL rejected',            not v('NUL'))

-- Multi-segment folder-path validation (path-traversal guard).
local vp = prefab_ops._validate_folder_path
check('empty path OK',             vp(''))
check('single segment OK',         vp('CAP'))
check('multi segment OK',          vp('CAP/Tomcats'))
check('deep segment OK',           vp('A/B/C/D'))

check('. segment rejected',        not vp('.'))
check('.. segment rejected',       not vp('..'))
check('nested .. rejected',        not vp('CAP/..'))
check('mid-path .. rejected',      not vp('CAP/../X'))
check('mid-path . rejected',       not vp('CAP/./X'))
check('backslash rejected',        not vp('CAP\\Tomcats'))
check('absolute Windows rejected', not vp('C:/Windows'))
check('reserved segment rejected', not vp('CAP/CON'))
check('trailing slash OK',         vp('CAP/'))    -- single empty segment after split = no segments, so OK
check('reserved char rejected',    not vp('CAP/Bad>Name'))

-- Community/ is import-only: user writes targeting it are rejected with the
-- shared managed-folder message (imports bypass prefab_ops, so they're
-- unaffected — see community_import.import).
local cfg = require('dcs_sms_me.community_config')
local function rejects(label, ok, err)
    check(label .. ' returns nil', ok == nil)
    check(label .. ' returns managed message', err == cfg.MANAGED_MSG)
end
do
    local ok, err = prefab_ops.save_selection('mine', false, nil, 'Community')
    rejects('save into Community', ok, err)
    local ok2, err2 = prefab_ops.save_selection('mine', false, nil, 'Community/CAP')
    rejects('save into Community subfolder', ok2, err2)
    local ok3, err3 = prefab_ops.move_prefab('CAP', 'mine', 'Community')
    rejects('move into Community', ok3, err3)
    local ok4, err4 = prefab_ops.rename_folder('Community', 'Renamed')
    rejects('rename Community', ok4, err4)
    local ok5, err5 = prefab_ops.rename_folder('CAP', 'Community')
    rejects('rename a folder TO Community', ok5, err5)
    -- Control: a normal folder is NOT community-blocked (it fails later for an
    -- unrelated reason — empty selection — never with the managed message).
    local _, err6 = prefab_ops.save_selection('mine', false, nil, 'CAP')
    check('normal folder not community-blocked', err6 ~= cfg.MANAGED_MSG)
end

io.write('All _validate_folder_name tests passed.\n')
