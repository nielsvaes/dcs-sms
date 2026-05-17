-- undo.lua — single-slot, handler-based undo bus.
--
-- The slot holds { handler = '<name>', payload = <handler-specific data> }.
-- Each tool window registers its own handler via M.register_handler, then
-- pushes payloads via M.record_generic (or the legacy M.record path for
-- prefab placements). M.undo() dispatches the slot to the registered
-- handler. Single-slot semantics — a new record replaces any existing
-- one regardless of handler.
--
-- The existing prefab API (M.record / M.add_airbase_snapshots) is preserved
-- verbatim — it now writes the slot in handler-keyed form internally, and
-- the existing remove logic is registered as the 'prefab' handler at
-- module load.
--
-- Public:
--   M.register_handler(name, fn)         — register an undo handler
--   M.record_generic(name, payload)      — push a slot (single-slot)
--   M.record(injection_record)           — legacy: prefab placement record
--   M.add_airbase_snapshots(snaps)       — legacy: augment prefab slot
--   M.undo() → ok, err_string            — dispatch to handler, then clear
--   M.has_record() → boolean
--   M.clear()
--
-- Handler fn(payload) contract:
--   returns ok=true on success, ok=true with err='N partial failures' on
--   per-item failures, or ok=nil with err=string on hard failure. The bus
--   clears the slot regardless of handler return — a record is consumed
--   on undo whether it fully succeeded or not.

local M = {}
local handlers = {}
local slot = nil

function M.register_handler(name, fn)
    handlers[name] = fn
end

-- Generic record: write a handler-keyed slot. Logs and no-ops on unknown
-- handler so a misnamed call from a calling tool doesn't crash the ME.
function M.record_generic(handler_name, payload)
    if not handlers[handler_name] then
        local ok, log = pcall(function() return _G.log end)
        if ok and log and log.write then
            log.write('sms.me.undo', log.ERROR or 1,
                'record_generic: unknown handler "' .. tostring(handler_name) .. '"')
        end
        return
    end
    slot = { handler = handler_name, payload = payload }
end

-- Legacy prefab record API. Writes the same handler-keyed slot shape so
-- M.undo() can dispatch through the same path.
function M.record(injection_record)
    slot = { handler = 'prefab', payload = injection_record }
end

-- Legacy: augment the prefab slot with airbase snapshots. No-op when the
-- current slot isn't a prefab one (matches original semantics — the
-- caller guards on has_record before calling).
function M.add_airbase_snapshots(snaps)
    if slot == nil or slot.handler ~= 'prefab' or type(snaps) ~= 'table' then return end
    slot.payload.airbase_snapshots = slot.payload.airbase_snapshots or {}
    for _, s in ipairs(snaps) do
        slot.payload.airbase_snapshots[#slot.payload.airbase_snapshots + 1] = s
    end
end

function M.has_record() return slot ~= nil end
function M.clear() slot = nil end

function M.undo()
    if slot == nil then return nil, 'nothing to undo' end
    local s = slot
    slot = nil  -- clear before dispatch — record consumed regardless of partial failures
    local fn = handlers[s.handler]
    if not fn then
        return nil, 'no handler registered for "' .. tostring(s.handler) .. '"'
    end
    local ok, ok_or_err, err = pcall(fn, s.payload)
    if not ok then return nil, 'handler threw: ' .. tostring(ok_or_err) end
    return ok_or_err, err
end

-- ---------------------------------------------------------------------------
-- 'prefab' handler — the original remove_groups/zones/drawings + airbase
-- snapshot restore logic, registered at module load so M.record() works
-- transparently.
-- ---------------------------------------------------------------------------

local prefab_ops    = require('dcs_sms_me.prefab_ops')
local warehouse_ops = require('dcs_sms_me.warehouse_ops')

local function remove_groups(arr)
    if not arr then return 0 end
    local errors = 0
    local fn = prefab_ops._remove and prefab_ops._remove.group
    if not fn then return #arr end
    for _, entry in ipairs(arr) do
        local ok = fn(entry.group_obj)
        if not ok then errors = errors + 1 end
    end
    return errors
end

local function remove_zones(arr)
    if not arr then return 0 end
    local errors = 0
    local fn = prefab_ops._remove and prefab_ops._remove.zone
    if not fn then return #arr end
    for _, entry in ipairs(arr) do
        local ok = fn(entry.runtime_id)
        if not ok then errors = errors + 1 end
    end
    return errors
end

local function remove_drawings(arr)
    if not arr then return 0 end
    local errors = 0
    local fn = prefab_ops._remove and prefab_ops._remove.drawing
    if not fn then return #arr end
    for _, entry in ipairs(arr) do
        local ok = fn(entry.drawing_obj)
        if not ok then errors = errors + 1 end
    end
    return errors
end

local function restore_airbases(arr)
    if type(arr) ~= 'table' then return 0 end
    local errors = 0
    for _, s in ipairs(arr) do
        if type(s) == 'table' and s.airdrome_number and s.prev ~= nil then
            local ok = warehouse_ops.apply(s.airdrome_number, s.prev)
            if not ok then errors = errors + 1 end
        end
    end
    return errors
end

M.register_handler('prefab', function(r)
    local errors = 0
    errors = errors + remove_groups(r.groups)
    errors = errors + remove_zones(r.zones)
    errors = errors + remove_drawings(r.drawings)
    errors = errors + restore_airbases(r.airbase_snapshots)
    return true, errors > 0 and (errors .. ' partial failures') or nil
end)

return M
