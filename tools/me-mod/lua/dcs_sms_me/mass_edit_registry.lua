-- mass_edit_registry.lua — declarative property registry for the Mass Edit
-- tool. Each entry describes one mass-editable property: which scope it
-- belongs to, which DCS categories it applies to, how to read/write the
-- value, which transform operations are valid, and optionally a pre-flight
-- validator. The View renders UI from this data; the Apply pipeline
-- dispatches reader/writer/preflight without knowing the specifics.
--
-- Entry shape:
--   id          string  unique key (used in undo snapshots & UI dropdowns)
--   scope       string  'group' | 'unit' | 'waypoint' | 'zone' | 'drawing'
--   label       string  human label for the property dropdown
--   category    string  optgroup label: 'Identity' | 'Behaviour' | 'Appearance' | 'Geometry'
--   control     table   { kind = 'string'|'number'|'enum'|'color'|'toggle', ... }
--   operations  array   ordered list of transform names (see mass_edit_transforms)
--   applies_to  array   DCS categories: 'plane' | 'helicopter' | 'vehicle' | 'ship' | 'static' | '*'
--   reader      fn(e)→v read current value from entity e
--   writer      fn(e,v)→ok,err  write new value v to entity e
--   preflight?  fn(e,v,ctx)→ok,err  optional pre-Apply validation (collision, type-match, etc.)
--
-- 'applies_to = {"*"}' means "no DCS category filter" — used for zones,
-- drawings, and properties that apply across all unit categories.

return {
  -- ============================================================
  -- group scope (6)
  -- ============================================================
  {
    id = 'group_name',
    scope = 'group',
    label = 'Name',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship', 'static' },
    reader = function(g) return g.name end,
    writer = function(g, value)
      local Mission = require('me_mission')
      if type(Mission.renameGroup) ~= 'function' then
        g.name = value
        return true
      end
      local ok = Mission.renameGroup(g, value)
      if not ok then return false, 'rename rejected by Mission.renameGroup' end
      return true
    end,
    preflight = function(g, new_name, ctx)
      if type(new_name) ~= 'string' or new_name == '' then
        return false, 'name cannot be empty'
      end
      ctx.names_seen = ctx.names_seen or {}
      if ctx.names_seen[new_name] then
        return false, 'name collision within batch: ' .. new_name
      end
      ctx.names_seen[new_name] = true
      return true
    end,
  },

  {
    id = 'group_country',
    scope = 'group',
    label = 'Country',
    category = 'Identity',
    control = { kind = 'enum', values_from = 'country_list' },
    operations = { 'set_all' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship', 'static' },
    reader = function(g) return g.country or (g.boss and g.boss.name) end,
    writer = function(g, value)
      local verbs = require('dcs_sms_me.verbs')
      local res = verbs.group_set_country({ id = g.groupId, country = value })
      if not res or not res.ok then return false, (res and res.error) or 'group_set_country failed' end
      return true
    end,
  },

  {
    id = 'group_frequency',
    scope = 'group',
    label = 'Frequency (MHz)',
    category = 'Behaviour',
    control = { kind = 'number', min = 0.1, max = 400, step = 0.5 },
    operations = { 'set_all', 'offset' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(g) return g.frequency end,
    writer = function(g, value) g.frequency = value; return true end,
  },

  {
    id = 'group_hidden',
    scope = 'group',
    label = 'Hidden on map',
    category = 'Appearance',
    control = { kind = 'toggle' },
    operations = { 'toggle_set' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship', 'static' },
    reader = function(g) return g.hidden end,
    writer = function(g, value) g.hidden = value; return true end,
  },

  {
    id = 'group_late_activation',
    scope = 'group',
    label = 'Late activation',
    category = 'Behaviour',
    control = { kind = 'toggle' },
    operations = { 'toggle_set' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship' },
    reader = function(g) return g.lateActivation end,
    writer = function(g, value) g.lateActivation = value; return true end,
  },

  {
    id = 'group_uncontrolled',
    scope = 'group',
    label = 'Uncontrolled',
    category = 'Behaviour',
    control = { kind = 'toggle' },
    operations = { 'toggle_set' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(g) return g.uncontrolled end,
    writer = function(g, value) g.uncontrolled = value; return true end,
  },

  -- ============================================================
  -- unit scope (5)
  -- ============================================================
  {
    id = 'unit_name',
    scope = 'unit',
    label = 'Name',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship', 'static' },
    reader = function(u) return u.name end,
    writer = function(u, value)
      local Mission = require('me_mission')
      if type(Mission.renameUnit) ~= 'function' then
        u.name = value
        return true
      end
      local ok = Mission.renameUnit(u, value)
      if not ok then return false, 'rename rejected by Mission.renameUnit' end
      return true
    end,
    preflight = function(u, new_name, ctx)
      if type(new_name) ~= 'string' or new_name == '' then
        return false, 'name cannot be empty'
      end
      ctx.names_seen = ctx.names_seen or {}
      if ctx.names_seen[new_name] then
        return false, 'name collision within batch: ' .. new_name
      end
      ctx.names_seen[new_name] = true
      return true
    end,
  },

  {
    id = 'unit_skill',
    scope = 'unit',
    label = 'Skill',
    category = 'Behaviour',
    control = { kind = 'enum', values = { 'Average', 'Good', 'High', 'Excellent', 'Random', 'Client', 'Player' } },
    operations = { 'set_all' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship' },
    reader = function(u) return u.skill end,
    writer = function(u, value) u.skill = value; return true end,
  },

  {
    id = 'unit_callsign',
    scope = 'unit',
    label = 'Callsign',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(u)
      if type(u.callsign) == 'table' then return u.callsign.name end
      return u.callsign
    end,
    writer = function(u, value)
      if type(u.callsign) == 'table' then u.callsign.name = value
      else u.callsign = value end
      return true
    end,
  },

  {
    id = 'unit_loadout',
    scope = 'unit',
    label = 'Loadout (named, same airframe)',
    category = 'Behaviour',
    control = { kind = 'enum', values_from = 'loadouts_for_unit_type' },
    operations = { 'set_all' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(u) return u.payload and u.payload.name or '(none)' end,
    writer = function(u, value)
      local verbs = require('dcs_sms_me.verbs')
      local res = verbs.unit_set_loadout({ id = u.unitId, loadout = value })
      if not res or not res.ok then return false, (res and res.error) or 'unit_set_loadout failed' end
      return true
    end,
    preflight = function(u, value, ctx)
      ctx.unit_type = ctx.unit_type or u.type
      if ctx.unit_type ~= u.type then
        return false, 'mixed airframes (' .. tostring(ctx.unit_type) .. ' and ' .. tostring(u.type) .. ') — loadout requires single airframe'
      end
      return true
    end,
  },

  {
    id = 'unit_fuel',
    scope = 'unit',
    label = 'Fuel (kg)',
    category = 'Behaviour',
    control = { kind = 'number', min = 0, max = 200000, step = 100 },
    operations = { 'set_all', 'offset' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(u) return u.payload and u.payload.fuel end,
    writer = function(u, value)
      u.payload = u.payload or {}
      u.payload.fuel = value
      return true
    end,
  },

  -- ============================================================
  -- waypoint scope (3 — type/action deferred to v2)
  -- ============================================================
  {
    id = 'waypoint_name',
    scope = 'waypoint',
    label = 'Name',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship' },
    reader = function(wp) return wp.name end,
    writer = function(wp, value) wp.name = value; return true end,
  },

  {
    id = 'waypoint_alt',
    scope = 'waypoint',
    label = 'Altitude (m)',
    category = 'Geometry',
    control = { kind = 'number', min = 0, max = 50000, step = 100 },
    operations = { 'set_all', 'offset' },
    applies_to = { 'plane', 'helicopter' },
    reader = function(wp) return wp.alt end,
    writer = function(wp, value) wp.alt = value; return true end,
  },

  {
    id = 'waypoint_speed',
    scope = 'waypoint',
    label = 'Speed (m/s)',
    category = 'Geometry',
    control = { kind = 'number', min = 0, max = 1500, step = 5 },
    operations = { 'set_all', 'offset' },
    applies_to = { 'plane', 'helicopter', 'vehicle', 'ship' },
    reader = function(wp) return wp.speed end,
    writer = function(wp, value) wp.speed = value; return true end,
  },

  -- ============================================================
  -- zone scope (4)
  -- ============================================================
  {
    id = 'zone_name',
    scope = 'zone',
    label = 'Name',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { '*' },
    reader = function(z) return z.name end,
    writer = function(z, value) z.name = value; return true end,
    preflight = function(z, new_name, ctx)
      if type(new_name) ~= 'string' or new_name == '' then
        return false, 'name cannot be empty'
      end
      ctx.names_seen = ctx.names_seen or {}
      if ctx.names_seen[new_name] then
        return false, 'name collision within batch: ' .. new_name
      end
      ctx.names_seen[new_name] = true
      return true
    end,
  },

  {
    id = 'zone_color',
    scope = 'zone',
    label = 'Color',
    category = 'Appearance',
    control = { kind = 'color' },
    operations = { 'set_all' },
    applies_to = { '*' },
    reader = function(z) return z.color end,
    writer = function(z, value) z.color = value; return true end,
  },

  {
    id = 'zone_radius',
    scope = 'zone',
    label = 'Radius (m)',
    category = 'Geometry',
    control = { kind = 'number', min = 1, max = 500000, step = 100 },
    operations = { 'set_all', 'offset' },
    applies_to = { '*' },
    reader = function(z) return z.radius end,
    writer = function(z, value) z.radius = value; return true end,
  },

  {
    id = 'zone_hidden',
    scope = 'zone',
    label = 'Hidden on map',
    category = 'Appearance',
    control = { kind = 'toggle' },
    operations = { 'toggle_set' },
    applies_to = { '*' },
    reader = function(z) return z.hidden end,
    writer = function(z, value) z.hidden = value; return true end,
  },

  -- ============================================================
  -- drawing scope (3)
  -- ============================================================
  {
    id = 'drawing_name',
    scope = 'drawing',
    label = 'Name',
    category = 'Identity',
    control = { kind = 'string' },
    operations = { 'set_all', 'add_prefix', 'add_suffix', 'find_replace', 'auto_number' },
    applies_to = { '*' },
    reader = function(d) return d.name end,
    writer = function(d, value) d.name = value; return true end,
  },

  {
    id = 'drawing_color',
    scope = 'drawing',
    label = 'Color',
    category = 'Appearance',
    control = { kind = 'color' },
    operations = { 'set_all' },
    applies_to = { '*' },
    reader = function(d) return d.colorString or d.color end,
    writer = function(d, value)
      if d.colorString ~= nil then d.colorString = value
      else d.color = value end
      return true
    end,
  },

  {
    id = 'drawing_thickness',
    scope = 'drawing',
    label = 'Line thickness',
    category = 'Appearance',
    control = { kind = 'number', min = 1, max = 20, step = 1 },
    operations = { 'set_all', 'offset' },
    applies_to = { '*' },
    reader = function(d) return d.thickness end,
    writer = function(d, value) d.thickness = value; return true end,
  },
}
