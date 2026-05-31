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
-- check_group_name added a suffix).
--
-- Pass {literal=true} as opts to skip the collision check. Used by
-- undo handlers: the snapshot's `old` is what the user wants restored
-- verbatim. Without the literal flag, undo could silently produce
-- "Foo-1" when the user is owed "Foo".

local M = {}

-- M.write(g, desired)              — collision-safe rename via check_group_name
-- M.write(g, desired, {literal=1}) — literal rename, skip the collision pre-step
--
-- Use the literal variant from undo handlers: the snapshot's `old` name was
-- the entity's name BEFORE the apply happened, and the whole point of undo
-- is to restore that exact string. Without the literal flag, undo would
-- silently auto-suffix any restore that collides with another row already
-- restored earlier in the same batch (or with any unrelated group that has
-- taken the name in the meantime), which is the opposite of what undo
-- promises.
function M.write(g, desired, opts)
    local Mission = require('me_mission')
    opts = opts or {}

    -- Step 1: collision auto-disambiguation. Skipped for literal writes.
    local safe = desired
    if not opts.literal and type(Mission.check_group_name) == 'function' then
        local p_ok, candidate = pcall(Mission.check_group_name, desired)
        if p_ok and type(candidate) == 'string' and candidate ~= '' then
            safe = candidate
        end
    end

    -- Step 2: hand the safe (or literal) name to renameGroup if available.
    if type(Mission.renameGroup) == 'function' then
        local ok = Mission.renameGroup(g, safe)
        if not ok then
            return false, safe, 'rename rejected by Mission.renameGroup'
        end
        return true, safe
    end

    -- Step 3: fallback for environments without renameGroup.
    g.name = safe
    return true, safe
end

return M
