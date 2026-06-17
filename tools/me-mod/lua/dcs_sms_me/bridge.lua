-- bridge.lua — inbox poller running in the ME Lua state.
--
-- Lives in: <DCS install>/MissionEditor/modules/dcs_sms_me/bridge.lua
-- Runs in:  ME env (full io/lfs, Lua 5.1, UpdateManager wired to GUI tick via
--           MissionEditor.lua's `Gui.AddUpdateCallback(UpdateManager.update)`).
--
-- Why this lives here and not in the dcs-sms hook:
--   The Hooks/ env (where dcs-sms-hook.lua runs) has no per-frame tick outside
--   a running mission, and it can't reach the ME's editable mission table.
--   The ME env has both. We use UpdateManager.add to drive a continuous
--   inbox poll while the user is in the Mission Editor.
--
-- Responsibilities:
--   * Poll <SavedGames>/DCS/dcs-sms/inbox/*.req.json every UpdateManager tick.
--   * Process target=gui requests via loadstring + xpcall (executes in the
--     ME env, where the editable `mission` table lives).
--   * Skip target=mission/empty requests — those are the dcs-sms hook's job
--     and it'll pick them up via onSimulationFrame when a mission is running.
--   * Write a heartbeat to <SavedGames>/DCS/dcs-sms/state/me.json so the CLI
--     knows the ME-side bridge is alive and what state it's in.
--
-- Gated by _G.DCS_SMS_GUI_BRIDGE_ENABLED, flipped from the DCS-SMS menu's
-- "External execution: ON/OFF" item in menu.lua. Same Lua state, same _G.

local M = {}

local UpdateManager
do
    local ok, mod = pcall(require, 'UpdateManager')
    if ok then UpdateManager = mod end
end

-- Paths. lfs.writedir() points at <Saved Games>/DCS in this env, same as
-- the hook env, so the file mailbox is shared.
local ROOT      = lfs.writedir() .. "dcs-sms\\"
local INBOX     = ROOT .. "inbox\\"
local OUTBOX    = ROOT .. "outbox\\"
local STATE_DIR = ROOT .. "state\\"
local LOG_DIR   = ROOT .. "log\\"

local VERSION = require('dcs_sms_me.version')

local HEARTBEAT_EVERY_TICKS = 30
local STALE_MAX_AGE_SECONDS = 60

local STATE = {
    tick                 = 0,
    last_heartbeat_tick  = -1e9,  -- force first heartbeat immediately
    installed            = false,
}

-- ----------------------------------------------------------------------------
-- helpers

local function ensure_dirs()
    for _, d in ipairs({ROOT, INBOX, OUTBOX, STATE_DIR, LOG_DIR}) do
        lfs.mkdir(d)
    end
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function write_atomic(path, data)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then
        log.write("sms.bridge", log.ERROR, "open tmp " .. tmp .. ": " .. tostring(err))
        return false
    end
    f:write(data)
    f:close()
    local ok = os.rename(tmp, path)
    if not ok then
        os.remove(path)
        os.rename(tmp, path)
    end
    return true
end

local function iso_now()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function escape_json_string(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    return s
end

local function sweep_stale(dir, suffix)
    local now = os.time()
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local full = dir .. entry
            local attrs = lfs.attributes(full)
            if attrs and attrs.mode == "file"
               and (entry:sub(-#suffix) == suffix or entry:match("%.tmp$"))
               and (now - (attrs.modification or now)) > STALE_MAX_AGE_SECONDS then
                os.remove(full)
            end
        end
    end
end

-- Pure-Lua JSON encoder for response files. Same shape as the hook's encoder
-- (we both emit the proto.ExecResponse Go struct).
local function jstr(s)
    s = tostring(s)
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    s = s:gsub("[%z\1-\31]", function(c) return string.format("\\u%04x", string.byte(c)) end)
    return '"' .. s .. '"'
end

local function jval(v)
    if v == nil then return "null" end
    local t = type(v)
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return string.format("%.6g", v)
    end
    if t == "string" then return jstr(v) end
    if t == "table" then
        local n, is_array = 0, true
        for k in pairs(v) do
            n = n + 1
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then is_array = false end
        end
        if is_array and n == #v then
            local parts = {}
            for i = 1, n do parts[i] = jval(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts+1] = jstr(k) .. ":" .. jval(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function write_response_file(req_id, ok, return_value, output, error_table, duration_ms)
    local resp = {
        id             = req_id,
        ok             = ok,
        output         = output or "",
        return_value   = return_value,
        error          = error_table,
        frame_executed = STATE.tick,
        duration_ms    = duration_ms or 0,
    }
    local outbox_path = OUTBOX .. req_id .. ".res.json"
    local ok_enc, json_or_err = pcall(jval, resp)
    if not ok_enc then
        log.write("sms.bridge", log.ERROR, "json encode failed for " .. tostring(req_id) .. ": " .. tostring(json_or_err))
        return
    end
    write_atomic(outbox_path, json_or_err)
end

-- ----------------------------------------------------------------------------
-- request execution (target=gui only)

local function execute_gui(req_id, code)
    if _G.DCS_SMS_GUI_BRIDGE_ENABLED ~= true then
        write_response_file(req_id, false, nil, "", {
            message   = "gui bridge is disabled — open the DCS-SMS menu in the Mission Editor and toggle 'External execution' on",
            traceback = "",
        }, 0)
        return
    end

    -- Capture print output. The ME env's print likely goes to dcs.log; we
    -- rebind to a buffer so the user gets it back in the response.
    local out = {}
    local orig_print = print
    print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring(select(i, ...)) end
        out[#out+1] = table.concat(parts, "\t")
    end

    local chunk, load_err = loadstring(code, "dcs-sms-gui:" .. req_id)
    if not chunk then
        print = orig_print
        write_response_file(req_id, false, nil, "", {
            message   = "loadstring: " .. tostring(load_err),
            traceback = "",
        }, 0)
        return
    end

    local start = os.clock()
    local ok_run, ret = xpcall(chunk, debug.traceback)
    print = orig_print
    local dur = (os.clock() - start) * 1000

    if ok_run then
        write_response_file(req_id, true, ret, table.concat(out, "\n"), nil, dur)
    else
        write_response_file(req_id, false, nil, table.concat(out, "\n"), {
            message   = tostring(ret),
            traceback = "",
        }, dur)
    end
end

-- Minimal hand-written JSON parser for the request file. The ME env doesn't
-- have net.json2lua, so we parse just enough to extract id/code/target.
-- Requests are written by the Go CLI with predictable structure.
local function parse_request(raw)
    -- Accept only object form; pull id, target, code as strings.
    local function strfield(name)
        local pat = '"' .. name .. '"%s*:%s*"((\\"|[^"])*)"'
        -- The "[^"]" naive approach can miss escaped quotes, so unescape what
        -- we capture. Code can have escaped quotes — we need a real parser.
        return raw:match('"' .. name .. '"%s*:%s*"(.-)"%s*[,}]')
    end
    -- The Go CLI's JSON output never embeds raw `,` or `}` inside string keys
    -- before this regex would pick up an early terminator unless the string
    -- contains an escaped quote followed by ",}". To handle code with quotes,
    -- we parse code specially: find the start of "code":" and then scan to
    -- the matching unescaped closing quote.
    local function strfield_long(name)
        local prefix = '"' .. name .. '"%s*:%s*"'
        local s = raw:find(prefix)
        if not s then return nil end
        local _, e = raw:find(prefix, s)
        local i = e + 1
        local out_chars = {}
        while i <= #raw do
            local c = raw:sub(i, i)
            if c == "\\" then
                local nxt = raw:sub(i+1, i+1)
                if nxt == "\\" or nxt == '"' or nxt == '/' then
                    out_chars[#out_chars+1] = nxt
                elseif nxt == "n" then out_chars[#out_chars+1] = "\n"
                elseif nxt == "r" then out_chars[#out_chars+1] = "\r"
                elseif nxt == "t" then out_chars[#out_chars+1] = "\t"
                elseif nxt == "u" then
                    local hex = raw:sub(i+2, i+5)
                    local cp = tonumber(hex, 16)
                    if cp then out_chars[#out_chars+1] = string.char(cp % 256) end
                    i = i + 4
                else
                    out_chars[#out_chars+1] = nxt
                end
                i = i + 2
            elseif c == '"' then
                return table.concat(out_chars)
            else
                out_chars[#out_chars+1] = c
                i = i + 1
            end
        end
        return nil
    end

    return {
        id     = strfield_long("id"),
        target = strfield_long("target"),
        code   = strfield_long("code"),
    }
end

local function parse_request_id_from_filename(name)
    return name:match("^(.+)%.req%.json$")
end

local function execute_request(filename)
    local req_path = INBOX .. filename
    local raw = read_file(req_path)
    if not raw then return end

    local parsed = parse_request(raw)
    local req_id = (parsed and parsed.id and parsed.id ~= "" and parsed.id)
                or parse_request_id_from_filename(filename)
    if not req_id or not parsed or type(parsed.code) ~= "string" then
        log.write("sms.bridge", log.ERROR, "could not parse request " .. filename)
        os.remove(req_path)
        return
    end

    local target = parsed.target
    if type(target) ~= "string" or target == "" then
        target = "mission"  -- legacy back-compat — leave for hook
    end

    if target == "gui" then
        execute_gui(req_id, parsed.code)
        os.remove(req_path)
    else
        -- target=mission and unknown targets aren't ours. Leave in inbox so
        -- the hook (or its sweep) handles them. The hook will write an error
        -- response for unknown targets; mission requests get processed there
        -- when a sim is running.
        return
    end
end

local function process_inbox()
    for entry in lfs.dir(INBOX) do
        if entry:sub(-9) == ".req.json" then
            local ok, err = pcall(execute_request, entry)
            if not ok then
                log.write("sms.bridge", log.ERROR, "execute_request crashed: " .. tostring(err))
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- heartbeat

-- mission_state — best-effort read of the currently-open mission from the ME
-- env. A mission table is always present while the editor is open (even a
-- brand-new untitled mission), so `loaded` tracks whether `me_mission` and
-- its `.mission` table are reachable. `name` is the basename of the saved
-- .miz path; it's empty for a never-saved new mission (path is empty until
-- the first Save-As). This is what `me group list` etc. read too — the hook
-- env can't see it, so the ME heartbeat must carry it itself.
local function mission_state()
    local ok, mm = pcall(require, "me_mission")
    if not ok or type(mm) ~= "table" or mm.mission == nil then
        return false, ""
    end
    local path = mm.mission.path
    if type(path) ~= "string" or path == "" then
        return true, ""
    end
    -- basename: strip everything up to the last slash or backslash
    local name = path:match("[^/\\]+$") or path
    return true, name
end

local function write_heartbeat()
    -- Heartbeat schema mirrors proto.HookState. The ME-side heartbeat is the
    -- source of truth for `state`, `gui_bridge_enabled`, and (in the ME) the
    -- loaded-mission info — the hook env can't see any of those. The hook
    -- keeps writing `state/hook.json` with its own mission-side info; the CLI
    -- reads both.
    local loaded, name = mission_state()
    local payload = string.format(
        '{"hook_version":"%s","state":"%s","mission_loaded":%s,"mission_name":"%s",' ..
        '"gui_bridge_enabled":%s,"tick_source":"%s",' ..
        '"last_tick":%d,"last_tick_at":"%s",' ..
        '"last_frame":%d,"last_frame_at":"%s"}',
        "me-bridge-" .. tostring(VERSION),
        "in_mission_editor",  -- best-effort: ME-mod runs in the ME env
        tostring(loaded),
        escape_json_string(name),
        tostring(_G.DCS_SMS_GUI_BRIDGE_ENABLED == true),
        "update_manager",
        STATE.tick, iso_now(),
        STATE.tick, iso_now()
    )
    write_atomic(STATE_DIR .. "me.json", payload)
    STATE.last_heartbeat_tick = STATE.tick
end

-- ----------------------------------------------------------------------------
-- dev-reload safety: generation counter
--
-- dev-reload clears `package.loaded.dcs_sms_me.bridge` and re-dofiles
-- init.lua. That loads this file again with a fresh local STATE (so
-- STATE.installed is back to false) and a freshly-defined `tick` upvalue.
-- The previous bridge's tick is still in UpdateManager's queue — there's
-- no public unregister API across DCS builds we can rely on — so without
-- a guard you get N+1 tick callbacks racing on the same inbox / state
-- files after N reloads. Symptom: `dcs-sms status` reports a stale
-- `hook_version` (the older bridge's heartbeat wins the write race) and
-- occasional spurious "gui bridge is disabled" errors on requests that
-- a stale tick happened to pick up mid-reload.
--
-- The fix: every install() bumps a `_G`-scoped generation counter and
-- stamps it into the local `MY_GEN`. Each tick checks against the
-- current `_G.DCS_SMS_BRIDGE_GEN` and no-ops itself when it isn't the
-- active generation — the old instances stay registered but do nothing.
local MY_GEN = nil

-- ----------------------------------------------------------------------------
-- tick

local function tick()
    if _G.DCS_SMS_BRIDGE_GEN ~= MY_GEN then
        return false  -- a newer install() took over; stay quiet
    end
    STATE.tick = STATE.tick + 1
    pcall(process_inbox)
    if STATE.tick - STATE.last_heartbeat_tick >= HEARTBEAT_EVERY_TICKS then
        pcall(write_heartbeat)
    end
    return false  -- keep registered with UpdateManager
end

-- ----------------------------------------------------------------------------
-- public API

function M.install()
    if STATE.installed then return true end

    if not UpdateManager or type(UpdateManager.add) ~= 'function' then
        log.write("sms.bridge", log.ERROR,
            "UpdateManager unavailable in ME env — bridge can't tick. " ..
            "Check that you're on a recent DCS build.")
        return false
    end

    _G.DCS_SMS_BRIDGE_GEN = (_G.DCS_SMS_BRIDGE_GEN or 0) + 1
    MY_GEN = _G.DCS_SMS_BRIDGE_GEN

    pcall(ensure_dirs)
    pcall(sweep_stale, INBOX, ".req.json")
    pcall(sweep_stale, OUTBOX, ".res.json")
    pcall(write_heartbeat)

    UpdateManager.add(tick)
    STATE.installed = true
    log.write("sms.bridge", log.INFO,
        "ME-side bridge installed (version " .. tostring(VERSION)
        .. ", gen " .. tostring(MY_GEN) .. ")")
    return true
end

return M
