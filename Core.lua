-- Forge_Inspector: real-time _G tree browser + watch list.

local ADDON, ns = ...

ns.VERSION = "0.1.0-dev"

local db = Cairn.DB.New("ForgeInspectorDB", {
    defaults = {
        profile = {
            watch       = {},     -- list of path strings (Watch pane)
            pinnedRoots = {},     -- list of { kind = "path", path = "_G.X" } specs
            live        = false,  -- 0.5s auto-poll toggle (off by default for taint safety)
            -- Event watcher (Events pane).
            -- eventWatch[name] = { event = "PLAYER_LOGIN", active = true, fireCount = 0 }
            eventWatch  = {},
            -- Function call logger (FnLog pane).
            -- fnLogs[key] = { parentPath = "_G.UIParent", fnName = "Show",
            --                  active = true, callCount = 0 }   -- key = parentPath..":"..fnName
            fnLogs      = {},
        },
    },
    profileType = "char",
})
ns.db = db
-- IMPORTANT: do NOT touch db.profile at file scope. WoW loads SavedVariables
-- AFTER addon files execute but BEFORE ADDON_LOADED fires. Reading db.profile
-- here orphans the wrapper. Force-init lives inside addon:OnInit below.

-- ----- Watch storage -----------------------------------------------------
function ns.GetWatch() return db.profile.watch or {} end

function ns.AddWatch(path)
    if type(path) ~= "string" or path == "" then return false end
    for _, p in ipairs(db.profile.watch) do
        if p == path then return false end
    end
    db.profile.watch[#db.profile.watch + 1] = path
    return true
end

function ns.RemoveWatch(path)
    for i, p in ipairs(db.profile.watch) do
        if p == path then table.remove(db.profile.watch, i); return true end
    end
    return false
end

function ns.ClearWatch() db.profile.watch = {} end

-- ----- Pinned roots (persisted) ------------------------------------------
-- Only `path` kind specs persist. Snapshot/find roots are session-only.
function ns.GetPinnedRoots()
    return db.profile.pinnedRoots or {}
end

local function specsEqual(a, b)
    if a.kind ~= b.kind then return false end
    if a.kind == "path" then return a.path == b.path end
    if a.kind == "snapshot" then return a.name == b.name end
    return false
end

function ns.AddPinnedRoot(spec)
    if not spec or spec.kind ~= "path" then return false end
    db.profile.pinnedRoots = db.profile.pinnedRoots or {}
    for _, existing in ipairs(db.profile.pinnedRoots) do
        if specsEqual(existing, spec) then return false end
    end
    db.profile.pinnedRoots[#db.profile.pinnedRoots + 1] = { kind = spec.kind, path = spec.path }
    return true
end

function ns.RemovePinnedRoot(spec)
    if not spec then return false end
    local list = db.profile.pinnedRoots or {}
    for i = #list, 1, -1 do
        if specsEqual(list[i], spec) then
            table.remove(list, i)
            return true
        end
    end
    return false
end

-- ----- Event watcher -----------------------------------------------------
-- Persistent registry of events to monitor + an in-memory ring buffer of
-- recent fires. The log is intentionally NOT persisted (it would balloon
-- SavedVariables); only the registry survives /reload.
--
-- Subscriptions go through Cairn.Events so we share Cairn's single
-- underlying frame with the rest of the addon ecosystem.

local MAX_EVENT_LOG = 200
local _eventLog     = {}     -- ring buffer, newest last
local _unsubs       = {}     -- { [eventName] = unsubFn returned by Cairn.Events }
local _logSubs      = {}     -- callbacks to fire when log changes

function ns.GetEventWatches() return db.profile.eventWatch or {} end

function ns.AddEventWatch(eventName)
    if type(eventName) ~= "string" or eventName == "" then return false end
    db.profile.eventWatch = db.profile.eventWatch or {}
    if db.profile.eventWatch[eventName] then return false end
    db.profile.eventWatch[eventName] = { event = eventName, active = true, fireCount = 0 }
    ns.RecheckEventRegistrations()
    return true
end

function ns.RemoveEventWatch(eventName)
    db.profile.eventWatch = db.profile.eventWatch or {}
    if not db.profile.eventWatch[eventName] then return false end
    db.profile.eventWatch[eventName] = nil
    ns.RecheckEventRegistrations()
    return true
end

function ns.SetEventWatchActive(eventName, on)
    local w = db.profile.eventWatch and db.profile.eventWatch[eventName]
    if not w then return false end
    w.active = on and true or false
    ns.RecheckEventRegistrations()
    return true
end

function ns.RecheckEventRegistrations()
    if not (Cairn and Cairn.Events) then return end

    -- Build the set of currently-active event names.
    local active = {}
    for name, w in pairs(db.profile.eventWatch or {}) do
        if w and w.active then active[name] = true end
    end

    -- Subscribe newly-active events through Cairn.Events. The handler
    -- closes over `name` so OnEventFired knows which event fired.
    for name in pairs(active) do
        if not _unsubs[name] then
            local unsub = Cairn.Events:Subscribe(name, function(...)
                if ns.OnEventFired then ns.OnEventFired(name, ...) end
            end, "Forge_Inspector")
            _unsubs[name] = unsub
        end
    end

    -- Unsubscribe events that are no longer active.
    for name, unsub in pairs(_unsubs) do
        if not active[name] then
            if type(unsub) == "function" then pcall(unsub) end
            _unsubs[name] = nil
        end
    end
end

local function fmtArgsInline(argc, ...)
    if argc == 0 then return "" end
    local parts = {}
    for i = 1, argc do
        local v = select(i, ...)
        local t = type(v)
        if t == "string" then
            local s = v
            if #s > 30 then s = s:sub(1, 27) .. "..." end
            parts[i] = string.format("%q", s)
        elseif t == "nil" then
            parts[i] = "nil"
        else
            parts[i] = tostring(v)
        end
    end
    return table.concat(parts, ", ")
end

function ns.OnEventFired(event, ...)
    local w = db.profile.eventWatch and db.profile.eventWatch[event]
    if not w or not w.active then return end
    w.fireCount = (w.fireCount or 0) + 1

    local argc = select("#", ...)
    local entry = {
        ts    = (time and time()) or os.time(),
        event = event,
        argc  = argc,
        args  = fmtArgsInline(argc, ...),
    }
    _eventLog[#_eventLog + 1] = entry
    while #_eventLog > MAX_EVENT_LOG do
        table.remove(_eventLog, 1)
    end

    for _, fn in ipairs(_logSubs) do
        pcall(fn, entry)
    end
end

function ns.GetEventLog()    return _eventLog end
function ns.ClearEventLog()  _eventLog = {} ; for _, fn in ipairs(_logSubs) do pcall(fn, nil) end end
function ns.SubscribeEventLog(fn)
    _logSubs[#_logSubs + 1] = fn
    return function()
        for i = #_logSubs, 1, -1 do
            if _logSubs[i] == fn then table.remove(_logSubs, i) break end
        end
    end
end

-- ----- Function call logger ---------------------------------------------
-- Wraps `parent[fnName]` with a logging shim. Stores the original so we
-- can restore it on deactivate. The wrapper calls the original, captures
-- args + return values, appends to a ring buffer, and propagates the
-- return values to the caller.

local MAX_FN_LOG = 200
local _fnCallLog  = {}      -- ring buffer of recent calls
local _fnSubs     = {}
local _originals  = {}      -- _originals[parentPath][fnName] = oldFn

local function fnKey(parentPath, fnName) return parentPath .. ":" .. fnName end

local function resolveParent(parentPath)
    if not parentPath or parentPath == "" then return nil end
    if parentPath == "_G" then return _G end
    local cur = _G
    for seg in parentPath:gsub("^_G%.?", ""):gmatch("[^%.]+") do
        if type(cur) ~= "table" then return nil end
        cur = cur[seg]
    end
    return (type(cur) == "table") and cur or nil
end

local function fmtArgs(argc, ...)
    if argc == 0 then return "" end
    local parts = {}
    for i = 1, argc do
        local v = select(i, ...)
        local t = type(v)
        if t == "string" then
            local s = v
            if #s > 30 then s = s:sub(1, 27) .. "..." end
            parts[i] = string.format("%q", s)
        elseif t == "table" then
            parts[i] = "<table>"
        elseif t == "function" then
            parts[i] = "<function>"
        elseif t == "nil" then
            parts[i] = "nil"
        else
            parts[i] = tostring(v)
        end
    end
    return table.concat(parts, ", ")
end

local function logFnCall(parentPath, fnName, argc, args, retc, rets)
    local entry = {
        ts         = (time and time()) or os.time(),
        parentPath = parentPath,
        fnName     = fnName,
        args       = fmtArgs(argc, unpack(args, 1, argc)),
        returns    = fmtArgs(retc, unpack(rets, 1, retc)),
    }
    _fnCallLog[#_fnCallLog + 1] = entry
    while #_fnCallLog > MAX_FN_LOG do table.remove(_fnCallLog, 1) end
    for _, fn in ipairs(_fnSubs) do pcall(fn, entry) end
end

local function wrapFn(parentPath, fnName)
    local parent = resolveParent(parentPath)
    if type(parent) ~= "table" then return false, "parent not found" end
    local original = parent[fnName]
    if type(original) ~= "function" then return false, "not a function" end

    -- Already wrapped?
    if _originals[parentPath] and _originals[parentPath][fnName] then
        return true
    end
    _originals[parentPath] = _originals[parentPath] or {}
    _originals[parentPath][fnName] = original

    -- Capture return-count + values WITHOUT calling original twice
    -- (which would fire side effects twice). The inner `pack` is a varargs
    -- trick: select("#", ...) sees every return slot including trailing nils.
    local function pack(...) return select("#", ...), { ... } end

    parent[fnName] = function(...)
        local argc = select("#", ...)
        local args = { ... }
        local retc, rets = pack(original(...))
        local w = db.profile.fnLogs and db.profile.fnLogs[fnKey(parentPath, fnName)]
        if w then w.callCount = (w.callCount or 0) + 1 end
        logFnCall(parentPath, fnName, argc, args, retc, rets)
        return unpack(rets, 1, retc)
    end
    return true
end

local function unwrapFn(parentPath, fnName)
    local saved = _originals[parentPath] and _originals[parentPath][fnName]
    if not saved then return false end
    local parent = resolveParent(parentPath)
    if type(parent) == "table" then
        parent[fnName] = saved
    end
    _originals[parentPath][fnName] = nil
    return true
end

function ns.GetFnLogs() return db.profile.fnLogs or {} end

function ns.AddFnLog(parentPath, fnName)
    if type(parentPath) ~= "string" or type(fnName) ~= "string" then return false end
    if parentPath == "" or fnName == "" then return false end
    db.profile.fnLogs = db.profile.fnLogs or {}
    local key = fnKey(parentPath, fnName)
    if db.profile.fnLogs[key] then return false end
    db.profile.fnLogs[key] = {
        parentPath = parentPath,
        fnName     = fnName,
        active     = true,
        callCount  = 0,
    }
    ns.RecheckFnLogs()
    return true
end

function ns.RemoveFnLog(parentPath, fnName)
    db.profile.fnLogs = db.profile.fnLogs or {}
    local key = fnKey(parentPath, fnName)
    if not db.profile.fnLogs[key] then return false end
    unwrapFn(parentPath, fnName)
    db.profile.fnLogs[key] = nil
    return true
end

function ns.SetFnLogActive(parentPath, fnName, on)
    local key = fnKey(parentPath, fnName)
    local w = db.profile.fnLogs and db.profile.fnLogs[key]
    if not w then return false end
    w.active = on and true or false
    ns.RecheckFnLogs()
    return true
end

function ns.RecheckFnLogs()
    -- Wrap newly-active, unwrap newly-inactive.
    for key, w in pairs(db.profile.fnLogs or {}) do
        local wrapped = _originals[w.parentPath] and _originals[w.parentPath][w.fnName]
        if w.active and not wrapped then
            local ok, err = wrapFn(w.parentPath, w.fnName)
            if not ok and ns.out then
                ns.out("FnLog wrap failed for " .. w.parentPath .. "." .. w.fnName .. ": " .. tostring(err))
            end
        elseif (not w.active) and wrapped then
            unwrapFn(w.parentPath, w.fnName)
        end
    end
end

function ns.GetFnCallLog()    return _fnCallLog end
function ns.ClearFnCallLog()  _fnCallLog = {} ; for _, fn in ipairs(_fnSubs) do pcall(fn, nil) end end
function ns.SubscribeFnLog(fn)
    _fnSubs[#_fnSubs + 1] = fn
    return function()
        for i = #_fnSubs, 1, -1 do
            if _fnSubs[i] == fn then table.remove(_fnSubs, i) break end
        end
    end
end

-- ----- Live polling ------------------------------------------------------
function ns.IsLive() return db.profile.live and true or false end
function ns.SetLive(on)
    db.profile.live = on and true or false
    if ns.out then
        ns.out("Inspector live polling: " .. (db.profile.live and "ON" or "OFF") ..
               (db.profile.live and "  |cffff8080(taint risk)|r" or ""))
    end
end

-- ----- Lifecycle ---------------------------------------------------------
local addon = Cairn.Addon.New("Forge_Inspector")
ns.addon = addon

local descriptor = {
    name        = "Inspector",
    title       = "Inspector",
    order       = 35,
    description = "Real-time _G tree browser.",
    SlashSub    = { name = "inspect", help = "open the Inspector tab" },
    OnTabShow   = function(parent, mod)
        if not mod._built then
            ns.UI.Build(parent, mod)
            mod._built = true
        end
        if mod._frame then mod._frame:Show() end
        if ns.UI and ns.UI.OnTabShow then ns.UI.OnTabShow(mod) end
    end,
    OnTabHide   = function(parent, mod)
        if mod._frame then mod._frame:Hide() end
    end,
}
ns.descriptor = descriptor

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffd87f3aForge:|r " .. tostring(msg))
    end
end
ns.out = out

function addon:OnInit()
    local _ = db.profile
    if db.profile.watch       == nil then db.profile.watch       = {} end
    if db.profile.pinnedRoots == nil then db.profile.pinnedRoots = {} end
    if db.profile.live        == nil then db.profile.live        = false end
    if db.profile.eventWatch  == nil then db.profile.eventWatch  = {} end
    if db.profile.fnLogs      == nil then db.profile.fnLogs      = {} end
end

function addon:OnLogin()
    if Forge and Forge.Registry then
        Forge.Registry.Register(descriptor)
    end

    -- Re-register all active event watches that survived /reload.
    ns.RecheckEventRegistrations()
    -- Re-wrap all active function-call logs.
    ns.RecheckFnLogs()

    if Forge and Forge.slash then
        Forge.slash:Subcommand("inspectwatch", function()
            local watch = ns.GetWatch()
            if #watch == 0 then out("watch list is empty.") return end
            out("watch list:")
            for _, p in ipairs(watch) do out("  " .. p) end
        end, "list pinned Inspector watch entries")

        Forge.slash:Subcommand("inspectpin", function(rest)
            local path = rest and rest:match("^%s*(.-)%s*$") or ""
            if path == "" then
                out("usage: /forge inspectpin <_G.path>  (e.g. /forge inspectpin _G.Forge)")
                return
            end
            if not path:match("^_G") then path = "_G." .. path end
            -- Open the tab first so UI is built (sets _activeMod). Persist
            -- the pin to db even if the user hasn't viewed the tab yet, then
            -- AddRoot fills the live UI.
            if not ns.AddPinnedRoot({ kind = "path", path = path }) then
                out("already pinned: " .. path)
                return
            end
            if Forge.Window and Forge.Window.OpenTab then Forge.Window.OpenTab("Inspector") end
            if ns.UI and ns.UI.AddRoot then
                ns.UI.AddRoot({ kind = "path", path = path }, false)  -- already persisted above
            end
            out("pinned root: " .. path)
        end, "pin a _G path as a top-level root in the Inspector tree")

        Forge.slash:Subcommand("inspectunpin", function(rest)
            local path = rest and rest:match("^%s*(.-)%s*$") or ""
            if path == "" then
                out("usage: /forge inspectunpin <_G.path>")
                return
            end
            if not path:match("^_G") then path = "_G." .. path end
            local spec = { kind = "path", path = path }
            -- Always remove from db so persistence is consistent regardless
            -- of whether the live tree has been built yet.
            local removedDb = ns.RemovePinnedRoot(spec)
            local removedUi = ns.UI and ns.UI.RemoveRoot and ns.UI.RemoveRoot(spec) or false
            if removedDb or removedUi then
                out("unpinned: " .. path)
            else
                out("not pinned: " .. path)
            end
        end, "remove a pinned root from the Inspector tree")

        Forge.slash:Subcommand("inspectroots", function()
            local roots = ns.UI and ns.UI.ListRoots and ns.UI.ListRoots() or {}
            if #roots == 0 then out("no roots (open the Inspector tab first).") return end
            out("roots (" .. #roots .. "):")
            for i, r in ipairs(roots) do
                out(string.format("  %d. %s  |cffaaaaaa(%s)|r", i, r.name, r.kind or "?"))
            end
        end, "list current Inspector roots")

        Forge.slash:Subcommand("inspectsize", function()
            local n = 0
            for _ in pairs(_G) do n = n + 1 end
            out(string.format("_G has %d keys on this character.", n))
        end, "count _G keys (handy for sizing)")

        -- ----- Mouseover: pin the frame currently under the cursor ------
        Forge.slash:Subcommand("inspectmouse", function()
            local frame
            if GetMouseFoci then
                local list = GetMouseFoci() or {}
                frame = list[1]
            elseif GetMouseFocus then
                frame = GetMouseFocus()
            end
            if not frame then out("no frame under cursor.") return end
            local name = frame.GetName and frame:GetName() or nil
            if Forge.Window and Forge.Window.OpenTab then Forge.Window.OpenTab("Inspector") end
            if name and _G[name] == frame then
                local path = "_G." .. name
                ns.AddPinnedRoot({ kind = "path", path = path })
                if ns.UI and ns.UI.AddRoot then
                    ns.UI.AddRoot({ kind = "path", path = path }, false)
                end
                out("pinned mouseover frame: " .. path)
            else
                local label = "mouseover:" .. (name or "<anonymous>")
                if ns.UI and ns.UI.AddSnapshotRoot then
                    ns.UI.AddSnapshotRoot(label, frame)
                    out("pinned mouseover frame as snapshot: " .. label .. "  |cffaaaaaa(session-only)|r")
                end
            end
        end, "pin the frame currently under the cursor as a root in the Inspector")

        -- ----- Find: substring search across a parent table -------------
        local function findCommand(rest, mode)
            local pattern, parentPath = rest:match("^%s*(%S+)%s*(.-)%s*$")
            if not pattern or pattern == "" then
                out("usage: /forge inspect" .. (mode == "prefix" and "start" or "find")
                    .. " <pattern> [parent]    (default parent = _G)")
                return
            end
            local parent = _G
            local parentLabel = "_G"
            if parentPath and parentPath ~= "" then
                parentLabel = parentPath
                if not parentPath:match("^_G") then parentPath = "_G." .. parentPath end
                local cur = _G
                for seg in parentPath:gsub("^_G%.?", ""):gmatch("[^%.]+") do
                    if type(cur) ~= "table" then cur = nil break end
                    cur = cur[seg]
                end
                if type(cur) ~= "table" then
                    out("parent not found or not a table: " .. parentLabel)
                    return
                end
                parent = cur
            end
            if not (ns.UI and ns.UI.FindInTable) then out("Inspector UI not loaded.") return end
            local results, count = ns.UI.FindInTable(parent, pattern, mode)
            if not results or count == 0 then
                out("no matches for '" .. pattern .. "' in " .. parentLabel)
                return
            end
            local label = string.format("%s '%s' in %s (%d)",
                mode == "prefix" and "startswith" or "find",
                pattern, parentLabel, count)
            if Forge.Window and Forge.Window.OpenTab then Forge.Window.OpenTab("Inspector") end
            ns.UI.AddSnapshotRoot(label, results)
            out("pinned: " .. label)
        end

        Forge.slash:Subcommand("inspectfind", function(rest)
            findCommand(rest or "", "contains")
        end, "find <pattern> [parent]: pin keys containing pattern (default _G)")

        Forge.slash:Subcommand("inspectstart", function(rest)
            findCommand(rest or "", "prefix")
        end, "startswith <prefix> [parent]: pin keys starting with prefix")

        -- ----- fstack: open Blizzard's frame-stack tooltip --------------
        Forge.slash:Subcommand("inspectfstack", function()
            if SlashCmdList and SlashCmdList.FRAMESTACK then
                SlashCmdList.FRAMESTACK("")
                return
            end
            if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_DebugTools") end
            if FrameStackTooltip and FrameStackTooltip.Toggle then
                FrameStackTooltip:Toggle()
            else
                out("frame stack tool unavailable on this client.")
            end
        end, "toggle Blizzard's frame stack tooltip (same as /framestack)")

        -- ----- etrace: open Blizzard's event trace ---------------------
        Forge.slash:Subcommand("inspectetrace", function()
            for _, key in ipairs({ "EVENTTRACE", "ETRACE" }) do
                if SlashCmdList and SlashCmdList[key] then
                    SlashCmdList[key]("")
                    return
                end
            end
            if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_EventTrace") end
            if EventTrace and EventTrace.Show then
                if EventTrace:IsShown() then EventTrace:Hide() else EventTrace:Show() end
            else
                out("event trace tool unavailable on this client.")
            end
        end, "toggle Blizzard's event trace (same as /eventtrace)")
    end

    local log = self:Log()
    if log then log:Info("Forge_Inspector v%s registered.", ns.VERSION) end
end
