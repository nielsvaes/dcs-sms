-- lfs.lua — thin pure-Lua shim for the LuaFileSystem C extension.
-- Implements only the subset used by the ME-mod test suite:
--   lfs.mkdir(path)                      → true or nil
--   lfs.rmdir(path)                      → true or nil
--   lfs.dir(path)                        → iterator over entry names
--   lfs.attributes(path, attrib)         → value or nil
--   lfs.writedir()                       → '' (not meaningful outside DCS)
--
-- Uses os.execute / io.popen so it works on the plain LuaBinaries zip
-- (which ships lua5.1.exe without any C extensions).
--
-- This file lives in tools/me-mod/test/ so tests that set
--   package.path = './?.lua;...'
-- pick it up automatically. Production code must NEVER load this file
-- (production runs inside DCS which ships the real lfs C extension).

local M = {}

-- On Windows, forward slashes work fine in most places but cmd.exe needs
-- backslashes for a few builtins. Normalise both ways.
local function to_bs(p)  return (p:gsub('/', '\\')) end
local function strip_trailing_sep(p)
    return (p:gsub('[/\\]+$', ''))
end

-- -------------------------------------------------------------------------
-- mkdir: equivalent to `mkdir /s /q path` (creates intermediates if needed)
-- -------------------------------------------------------------------------
function M.mkdir(path)
    local p = strip_trailing_sep(to_bs(path))
    -- /q: quiet; ignore "already exists" error
    local rc = os.execute('mkdir "' .. p .. '" 2>nul')
    -- os.execute returns 0 on success on some Lua builds, true on others
    if rc == 0 or rc == true then return true end
    -- Already exists is not an error for our purposes
    local attr = M.attributes(path, 'mode')
    if attr == 'directory' then return true end
    return nil
end

-- -------------------------------------------------------------------------
-- rmdir: remove an empty directory
-- -------------------------------------------------------------------------
function M.rmdir(path)
    local p = strip_trailing_sep(to_bs(path))
    local rc = os.execute('rmdir "' .. p .. '" 2>nul')
    if rc == 0 or rc == true then return true end
    return nil
end

-- -------------------------------------------------------------------------
-- attributes(path [, attrib])
-- Returns full table when attrib is nil; single value when attrib is a string.
-- Only implements 'mode' (the only attrib our tests check).
-- -------------------------------------------------------------------------
function M.attributes(path, attrib)
    local p = strip_trailing_sep(to_bs(path))
    -- Use cmd /c if exist to probe existence and type
    local is_dir_handle = io.popen('cmd /c if exist "' .. p .. '\\*" (echo D) else (echo N) 2>nul')
    local is_dir_result = is_dir_handle and is_dir_handle:read('*l')
    if is_dir_handle then is_dir_handle:close() end

    local is_file_handle = io.popen('cmd /c if exist "' .. p .. '" (echo Y) else (echo N) 2>nul')
    local is_file_result = is_file_handle and is_file_handle:read('*l')
    if is_file_handle then is_file_handle:close() end

    local mode
    if is_dir_result and is_dir_result:find('D') then
        mode = 'directory'
    elseif is_file_result and is_file_result:find('Y') then
        mode = 'file'
    else
        -- Does not exist
        if attrib == 'mode' then return nil end
        return nil
    end

    if attrib == 'mode' then return mode end
    -- Return partial table for other callers
    return { mode = mode }
end

-- -------------------------------------------------------------------------
-- dir(path): returns an iterator function that yields entry names including
-- '.' and '..' (matching the real lfs.dir behaviour).
-- -------------------------------------------------------------------------
function M.dir(path)
    local p = strip_trailing_sep(to_bs(path))
    -- dir /b lists bare names; /a lists all including hidden
    local handle = io.popen('dir /b /a "' .. p .. '" 2>nul')
    local entries = {'.', '..'}
    if handle then
        for line in handle:lines() do
            entries[#entries + 1] = line
        end
        handle:close()
    end
    local i = 0
    return function()
        i = i + 1
        return entries[i]
    end
end

-- Not meaningful outside DCS; return an empty string so callers don't error.
function M.writedir()
    return ''
end

return M
