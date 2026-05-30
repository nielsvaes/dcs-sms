-- task_extras.lua — hand-curated supplementary descriptor for tasks
-- whose param schema isn't fully expressed in me_action_db.actionsData.
--
-- ED's actionsData entry for a task carries `task.params` defaults that
-- the GUI auto-fills, but several tasks have pattern-conditional or
-- runtime-only fields the GUI sets via dedicated panels in
-- me_action_edit_panel.lua. Those don't appear in actionsData, so a
-- pure-actionsData describe-task can't tell a caller what fields the
-- task actually accepts.
--
-- Each entry has:
--   always: array of field specs that always apply
--   selector: optional { id=..., options={...} } — names a field whose
--     value selects which variant's extra fields apply
--   variants: optional array of { value=..., fields={...} } — extra
--     field specs that apply when selector's field equals `value`
--
-- Field spec: { id=string, type='number'|'boolean'|'string'|'enum',
--               default=value (optional), options=array (when enum) }
--
-- This file is intentionally hand-curated and small. Adding a task
-- here is opt-in — describe-task gracefully falls back to the bare
-- actionsData params when no entry exists.

local M = {}

-- ============================================================
-- Orbit (waypoint task)
-- ============================================================
-- Source: MissionEditor/modules/me_action_edit_panel.lua updateOrbitPanel
-- around line 1007. The Anchored branch sets hotLegDir/legLength/width/
-- clockWise; the Race-Track and Circle branches don't carry extras.
M.Orbit = {
    always = {
        { id = 'altitude',        type = 'number',  default = 2000 },
        { id = 'altitudeEnabled', type = 'boolean', default = true },
        { id = 'speed',           type = 'number',  default = 180  },
    },
    selector = {
        id = 'pattern',
        type = 'enum',
        options = { 'Circle', 'Race-Track', 'Anchored' },
    },
    variants = {
        { value = 'Circle',     fields = {} },
        { value = 'Race-Track', fields = {} },
        { value = 'Anchored',   fields = {
            { id = 'hotLegDir', type = 'number',  default = 0,
              note = 'direction in radians (0 = north)' },
            { id = 'legLength', type = 'number',  default = 92500,
              note = 'meters; ME quick-set buttons offer 18520/37040/27780/92600' },
            { id = 'width',     type = 'number',  default = 37000,
              note = 'meters' },
            { id = 'clockWise', type = 'boolean', default = false },
        } },
    },
}

return M
