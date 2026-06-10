-- mock_trigger_descr.lua — synthetic ED trigger descriptors + factories
-- for standalone tests. Field tables carry a test-only `kind` attribute;
-- pass M.field_kind as the schema's field_kind_fn.

local M = {}

local function fields(...) return { ... } end
local function f(id, opts)
    local t = { id = id, type = (opts and opts.type) or 'edit' }
    if opts then
        t.kind = opts.kind
        t.default = opts.default
        if opts.combo then t.type = 'combo' end
    end
    return t
end

M.triggersDescr = {
    { name = 'triggerOnce',       fields = fields() },
    { name = 'triggerContinious', fields = fields() },
    { name = 'triggerStart',      fields = fields() },
    { name = 'triggerFront',      fields = fields() },
}

M.rulesDescr = {
    { name = 'c_all_of_group_in_zone', fields = fields(
        f('group', { combo = true, kind = 'group' }),
        f('zone',  { combo = true, kind = 'zone', default = 0 })) },
    { name = 'c_flag_is_true', fields = fields(
        f('flag', { default = 1 })) },
    { name = 'c_predicate', fields = fields(
        f('text'),
        f('zone', { combo = true, kind = 'zone', default = 0 }),
        f('coalitionlist', { combo = true, kind = 'coalition', default = 'red' }),
        f('unitType')) },
    { name = 'c_unit_alive', fields = fields(
        f('unit', { combo = true, kind = 'unit' })) },
}
-- Pseudo-predicate under a string key, like ED's me_predicates.rulesDescr.
M.rulesDescr['or'] = { name = 'or', fields = fields() }

M.actionsDescr = {
    { name = 'a_activate_group', fields = fields(
        f('group', { combo = true, kind = 'group' })) },
    { name = 'a_set_flag', fields = fields(
        f('flag', { default = 1 })) },
    { name = 'a_do_script', fields = fields(
        f('text')) },
    { name = 'a_out_text_delay', fields = fields(
        f('text'), f('seconds', { default = 10 })) },
    { name = 'a_out_picture', fields = fields(
        f('file', { type = 'file' }), f('seconds', { default = 10 })) },
    { name = 'a_out_sound', fields = fields(
        f('file', { type = 'file' })) },
}

function M.field_kind(fd)
    return type(fd) == 'table' and fd.kind or nil
end

-- ED-factory stand-ins (shape mirrors createTrigger/createRule/createAction:
-- predicate = DESCRIPTOR TABLE, defaults pre-filled).
local function fill_defaults(entry, descr)
    for _, fd in ipairs(descr.fields or {}) do
        if fd.default ~= nil then entry[fd.id] = fd.default end
    end
    return entry
end

function M.createTrigger(descr)
    return { predicate = descr, comment = 'Trigger 12345', eventlist = '',
             rules = {}, actions = {} }
end
function M.createRule(descr)   return fill_defaults({ predicate = descr }, descr) end
function M.createAction(descr) return fill_defaults({ predicate = descr }, descr) end

return M
