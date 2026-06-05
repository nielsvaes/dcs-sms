-- me_hotkey_engine.lua — keymap merge + diff over an injected backend.
--
-- Pure logic: the backend ({ attach(key,fn)->token, detach(key,token) }) and
-- the actions list are injected, so this unit-tests with a fake backend.
--
-- Override states per action id:
--   absent           -> action is at its registry default_key
--   '<key>'          -> overridden to that key
--   ''  (empty)      -> explicitly unbound (no key)
--
-- Attachment rule (avoids double-firing ED's native keys): an action is
-- attached to the backend UNLESS its current key equals its ed_key (the
-- editor already handles that key natively). Keyless actions (ed_key=nil) and
-- overrides are always attached. Unbound actions are never attached.

local M = {}
local Engine = {}
Engine.__index = Engine

-- deps: { actions, backend, overrides, ed_conflicts, normalize }
function M.new(deps)
    local self = setmetatable({}, Engine)
    self._actions   = deps.actions or {}
    self._backend   = deps.backend
    self._ed        = deps.ed_conflicts or {}
    self._normalize = deps.normalize or function(k) return k end
    self._by_id     = {}
    for _, a in ipairs(self._actions) do self._by_id[a.id] = a end
    -- copy overrides so callers' tables aren't mutated
    self._overrides = {}
    for k, v in pairs(deps.overrides or {}) do self._overrides[k] = v end
    self._live = {}  -- id -> { key = <key>, token = <backend token> }
    return self
end

function Engine:_action(id) return self._by_id[id] end

-- current key string, or nil when unbound. A disabled action reports no key.
-- An empty-string key (used by keyless user scripts) is also treated as unbound.
function Engine:current_key(id)
    local a = self:_action(id)
    if a and a.disabled then return nil end
    local ov = self._overrides[id]
    if ov == '' then return nil end
    if ov ~= nil then return ov end
    local dk = a and a.default_key
    if dk == nil or dk == '' then return nil end
    return dk
end

function Engine:default_key(id)
    local a = self:_action(id)
    if a and a.disabled then return nil end
    local dk = a and a.default_key
    if dk == nil or dk == '' then return nil end
    return dk
end

function Engine:is_modified(id)
    return self._normalize(self:current_key(id)) ~= self._normalize(self:default_key(id))
end

-- Which managed action currently holds `key` (normalized), or nil.
function Engine:key_holder(key)
    local nk = self._normalize(key)
    for _, a in ipairs(self._actions) do
        if self._normalize(self:current_key(a.id)) == nk then return a.id end
    end
    return nil
end

-- Should this action be attached to the backend right now?
function Engine:_should_attach(a)
    if a.disabled then return false end
    local cur = self:current_key(a.id)
    if cur == nil then return false end                       -- unbound
    if a.ed_key and self._normalize(cur) == self._normalize(a.ed_key) then
        return false                                          -- ED handles it
    end
    return true
end

-- Guarded closure for a backend attachment.
local function wrap(a)
    return function() pcall(a.invoke) end
end

-- Reconcile backend attachments with desired state.
function Engine:apply()
    if not self._backend then return end
    -- desired: id -> key. At most one id may claim a given normalized key, so
    -- _live never holds two ids on one backend key (which would let a detach for
    -- one silently kill the binding the other still wants). Registry order wins:
    -- iterate self._actions and skip any later id whose key is already claimed.
    local desired = {}
    local claimed = {}  -- normalized key -> true
    for _, a in ipairs(self._actions) do
        if self:_should_attach(a) then
            local key = self:current_key(a.id)
            local nk = self._normalize(key)
            if not claimed[nk] then
                claimed[nk] = true
                desired[a.id] = key
            end
        end
    end
    -- detach anything live that is gone or changed
    for id, rec in pairs(self._live) do
        if desired[id] == nil or self._normalize(desired[id]) ~= self._normalize(rec.key) then
            pcall(function() self._backend.detach(rec.key, rec.token) end)
            self._live[id] = nil
        end
    end
    -- attach anything desired that isn't already live
    for id, key in pairs(desired) do
        if not self._live[id] then
            local a = self:_action(id)
            local token
            pcall(function() token = self._backend.attach(key, wrap(a)) end)
            self._live[id] = { key = key, token = token }
        end
    end
end

-- Set override (clearing it when the key equals the default), then re-apply.
-- Returns { displaced = { id=, label= } | { ed = label } | nil }.
function Engine:bind(id, key)
    local a = self:_action(id)
    if not a or a.disabled then return { displaced = nil } end
    local nk = self._normalize(key)

    -- find a managed holder to displace
    local displaced
    local holder = self:key_holder(key)
    if holder and holder ~= id then
        self._overrides[holder] = ''  -- unbind the prior holder
        local ha = self:_action(holder)
        displaced = { id = holder, label = ha and ha.label or holder }
    elseif self._ed[nk] then
        displaced = { ed = self._ed[nk] }
    end

    if nk == self._normalize(a.default_key) then
        self._overrides[id] = nil      -- back to default; no delta
    else
        self._overrides[id] = key
    end
    self:apply()
    return { displaced = displaced }
end

function Engine:unbind(id)
    self._overrides[id] = ''
    self:apply()
end

function Engine:reset(id)
    self._overrides[id] = nil
    self:apply()
end

function Engine:reset_all()
    self._overrides = {}
    self:apply()
end

-- UI model: one row per action in registry order.
function Engine:rows()
    local rows = {}
    for _, a in ipairs(self._actions) do
        rows[#rows + 1] = {
            id = a.id, label = a.label, category = a.category,
            current_key = self:current_key(a.id),
            default_key = a.default_key,
            modified = self:is_modified(a.id),
            disabled = a.disabled or false,
            script = a.script or false,
        }
    end
    return rows
end

-- The persistable delta: self._overrides minus any disabled action (which can
-- never be (re)bound, so a leftover override would otherwise persist forever as
-- a stale entry). Non-default by construction — bind clears the override when
-- the key equals the default.
function Engine:overrides_delta()
    local out = {}
    for k, v in pairs(self._overrides) do
        local a = self:_action(k)
        if not (a and a.disabled) then out[k] = v end
    end
    return out
end

return M
