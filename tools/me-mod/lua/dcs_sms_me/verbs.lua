-- dcs_sms_me/verbs.lua — aggregator for `dcs-sms me <noun> <verb>` commands.
--
-- The verb implementations live in `dcs_sms_me/verbs/<noun>_verbs.lua`, one
-- file per noun group, plus shared helpers in `dcs_sms_me/verb_helpers.lua`.
-- This module merges each noun file's `M.*` exports into a single table so
-- the bridge can keep dispatching `verbs.<name>(args)` exactly as before.
--
-- Naming convention: verb function names use snake_case to mirror the CLI's
-- `<noun> <verb>` shape (`me file open` → `verbs.file_open(args)`).
--
-- Error handling: each verb wraps its work in pcall and returns a uniform
-- result shape:
--   { ok = true,  ... }       -- success, with verb-specific extra fields
--   { ok = false, error = "..." }  -- failure, error string
-- The CLI side checks resp.return_value.ok to decide its exit code.

local M = {}

-- Order matters only for human reading; the aggregator copies every M.<verb>
-- key from every file, and duplicates would be a bug (each verb's canonical
-- home is its noun file). Alphabetical here for grep-friendliness.
local noun_modules = {
    'airbase_verbs',
    'camera_verbs',
    'drawing_verbs',
    'file_verbs',
    'group_verbs',
    'resources_verbs',
    'route_verbs',
    'trigger_verbs',
    'unit_verbs',
    'zone_verbs',
}

local first_owner = {}
for _, mod_name in ipairs(noun_modules) do
    local mod = require('dcs_sms_me.verbs.' .. mod_name)
    for k, v in pairs(mod) do
        if M[k] ~= nil then
            error('verbs.lua: duplicate verb "' .. tostring(k)
                  .. '" registered by ' .. mod_name
                  .. ', already owned by ' .. first_owner[k])
        end
        M[k] = v
        first_owner[k] = mod_name
    end
end

return M
