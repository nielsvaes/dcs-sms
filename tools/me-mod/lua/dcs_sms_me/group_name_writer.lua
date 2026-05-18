-- group_name_writer.lua — single-name group rename helper used by every
-- Mass Edit form that mutates a group's name (rename_group,
-- find_replace_group_name, and future unit-name forms once they ship).
--
-- Centralises three pieces of DCS-API plumbing that every name-writing
-- form needs:
--
--   1. Mission.check_group_name(desired) — DCS's built-in collision
--      reservation. Returns either the desired name (if free) or an
--      auto-disambiguated variant like "Foo-1", "Foo-2", … . The default
--      ME group panel uses this on every rename, which is why typing the
--      same name twice in the ME silently produces "Foo" and "Foo-1"
--      instead of erroring out. Without this step, the SECOND batch
--      rename to the same string fails with "rename rejected by
--      Mission.renameGroup" because DCS refuses duplicates outright.
--
--   2. Mission.renameGroup(g, safe_name) — performs the actual rename.
--      Returns true / false (rejected).
--
--   3. Direct g.name fallback — for test VMs and very old DCS builds
--      that don't expose either of the above.
--
-- Returns (ok, actual_name, err). `actual_name` is the name that
-- *actually* landed on the group (which may differ from `desired` if
-- check_group_name added a suffix). Callers that want to report or log
-- the actual name use this; callers that don't care can ignore it.
-- Undo snapshots don't need it — they capture `old` (the pre-rename
-- name), which is unaffected by collision logic.

local M = {}

function M.write(g, desired)
    local Mission = require('me_mission')

    -- Step 1: ask DCS for a collision-safe variant of `desired`. If the
    -- API isn't available or throws, fall through with `desired` unchanged.
    local safe = desired
    if type(Mission.check_group_name) == 'function' then
        local p_ok, candidate = pcall(Mission.check_group_name, desired)
        if p_ok and type(candidate) == 'string' and candidate ~= '' then
            safe = candidate
        end
    end

    -- Step 2: hand the safe name to renameGroup if available.
    if type(Mission.renameGroup) == 'function' then
        local ok = Mission.renameGroup(g, safe)
        if not ok then
            return false, safe, 'rename rejected by Mission.renameGroup'
        end
        return true, safe
    end

    -- Step 3: fallback for environments without renameGroup (test VMs,
    -- old builds). Direct assignment, since there's no ME-side bookkeeping
    -- to coordinate with.
    g.name = safe
    return true, safe
end

return M
