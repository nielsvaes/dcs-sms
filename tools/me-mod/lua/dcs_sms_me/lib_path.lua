-- lib_path.lua — build the package.cpath/path entries for the bundled
-- LuaSec payload under <writedir>/dcs-sms/lib/. Pure string work so it's
-- unit-testable; init.lua applies the result to the real package globals.
local paths = require('dcs_sms_me.paths')
local M = {}

-- Returns (new_cpath, new_path). Idempotent: if our entries are already
-- present, returns the inputs unchanged.
function M.build(cur_cpath, cur_path)
    local dll = paths.LIB_DIR .. '?.dll'
    local lua = paths.LIB_DIR .. '?.lua'
    cur_cpath = cur_cpath or ''
    cur_path  = cur_path or ''
    if not cur_cpath:find(dll, 1, true) then cur_cpath = dll .. ';' .. cur_cpath end
    if not cur_path:find(lua, 1, true)  then cur_path  = lua .. ';' .. cur_path end
    return cur_cpath, cur_path
end

-- Apply to the live package globals (called from init.lua).
function M.apply()
    package.cpath, package.path = M.build(package.cpath, package.path)
end

return M
