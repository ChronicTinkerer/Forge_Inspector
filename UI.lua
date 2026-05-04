-- Forge_Inspector.UI: split-pane _G tree browser + watch panel.
--
-- Layout:
--   [Search ............]        [Refresh] [Collapse all]
--   +------------------------+--+----------------------------+
--   | Tree (left ~60%)       |  | Watch (right ~40%)         |
--   |  > _G                  |  |  path     | type | value   |
--   |    > MyAddon  (table)  |  |  ...                        |
--   |        version : "1.0" |  |                             |
--   +------------------------+--+----------------------------+
--
-- Tree behavior:
--   - Root is _G.
--   - Click a row's [+] / [-] to expand/collapse a table.
--   - Each row shows `key : type` and an inline value for primitives.
--   - Right-click a row to pin its path to the Watch panel.
--   - Search box filters keys at the CURRENT visible level (case-insensitive).
--   - 0.5s auto-poll refreshes visible rows' values.
--
-- Watch behavior:
--   - Pinned paths persist in db.profile.watch (per character).
--   - Each row shows path, current value type, and value (truncated).
--   - X button removes from watch.

local ADDON, ns = ...

local UI = {}
ns.UI = UI

local TOOLBAR_H   = 56  -- two rows of 22-px controls
local ROW_H       = 18
local PAD         = 6
local SPLIT_RATIO = 0.6   -- tree pane width fraction

-- The expensive part of expanding `_G` was creating ~10k UI Frames in one
-- tick, not iterating Lua tables. We use a small pool of row buttons
-- (VISIBLE_ROW_BUFFER) and recycle them as the user scrolls. This is the
-- HybridScrollFrame pattern DevTool uses; here we roll our own to stay
-- pure-Lua. With virtualization there is no need to cap children.
--
-- Paranoia cap only - if some addon installs an absurdly large table this
-- still bounds the closure-creation work.
local VISIBLE_ROW_BUFFER = 40   -- ~1.5x a typical viewport's row count

local _activeMod
local _filterText = ""
local _ticker

-- ----- Type colors (ARGB) ------------------------------------------------
local TYPE_COLOR = {
    ["string"]   = "ff80ff80",
    ["number"]   = "ff7fdfff",
    ["boolean"]  = "ffffd87f",
    ["function"] = "ffaaaaaa",
    ["table"]    = "ffd87f3a",
    ["nil"]      = "ffff5050",
    ["userdata"] = "ffaaaaff",
    ["thread"]   = "ffaaaaff",
}

local function escapeBars(s) return (tostring(s)):gsub("|", "||") end

-- ----- Taint-safe helpers ------------------------------------------------
-- Some Blizzard tables are "secret" — calling pairs() on them propagates
-- taint to our addon's execution and blocks secure operations until the
-- next /reload. The Blizzard API exposes detection functions; we check
-- BEFORE iterating, so we never pair() a forbidden table at all.
-- (Reference: DevTool's Utils.lua applies the same guard.)
local function isSecret(v)
    if type(v) ~= "table" then
        if issecretvalue and issecretvalue(v) then return true end
        return false
    end
    if issecrettable and issecrettable(v) then return true end
    if issecretvalue and issecretvalue(v) then return true end
    return false
end

-- Some frame-like tables expose IsForbidden(); skip those too.
local function isForbidden(v)
    if type(v) ~= "table" then return false end
    local fn = rawget(v, "IsForbidden") or (getmetatable(v) and v.IsForbidden)
    if type(fn) ~= "function" then return false end
    local ok, forbidden = pcall(fn, v)
    return ok and forbidden and true or false
end

local function isUntouchable(v)
    return isSecret(v) or isForbidden(v)
end

-- Format a value for inline display. Tables / functions show summary only;
-- strings get truncated.
local function fmtValue(v)
    local t = type(v)
    local color = TYPE_COLOR[t] or "ffffffff"
    if t == "string" then
        local s = v
        if #s > 60 then s = s:sub(1, 57) .. "..." end
        return "|c" .. color .. string.format("%q", s) .. "|r"
    elseif t == "number" or t == "boolean" or t == "nil" then
        return "|c" .. color .. tostring(v) .. "|r"
    elseif t == "function" then
        return "|c" .. color .. "function|r"
    elseif t == "table" then
        if isUntouchable(v) then
            return "|c" .. color .. "table  |cffff8080<protected>|r|r"
        end
        local n = 0
        for _ in pairs(v) do n = n + 1; if n > 10 then break end end
        return "|c" .. color .. "table  |cffaaaaaa(" .. n .. (n >= 10 and "+" or "") .. " keys)|r|r"
    end
    return "|c" .. color .. tostring(v) .. "|r"
end

local function shortType(v)
    return type(v)
end

-- ----- Tree node model ---------------------------------------------------
-- node = {
--   key       = "SomeKey",        -- last path segment (string)
--   keyType   = "string",         -- type of the key
--   getter    = function() return value end,   -- pull current value
--   parent    = parent_node,      -- nil for the root
--   depth     = number,           -- 0 for root
--   expanded  = bool,
--   children  = nil or { node, ... },  -- lazy-built
--   path      = "_G.A.B",         -- display path
-- }

local function buildChildren(node)
    local v = node.getter()
    if type(v) ~= "table" then node.children = {}; return end

    -- CRITICAL: never call pairs() on a secret/forbidden table. Doing so
    -- propagates taint to our addon's execution even if pcall catches the
    -- thrown error - taint is set BEFORE the error fires. Detect first.
    if isUntouchable(v) then
        node.children    = {}
        node._isProtected = true
        return
    end

    -- Pass 1: collect bare keys ONLY. No closures, no nested tables.
    -- This is the cheapest possible iteration of `v`.
    local rawKeys = {}
    local ok, err = pcall(function()
        for k in pairs(v) do
            rawKeys[#rawKeys + 1] = k
        end
    end)
    if not ok then
        node._iterError = tostring(err)
    end

    -- Pass 2: sort the bare keys. String comparator only - no per-element
    -- table allocation in the comparator.
    table.sort(rawKeys, function(a, b)
        local ta, tb = type(a), type(b)
        if ta == tb then
            if ta == "string" then return a < b end
            if ta == "number" then return a < b end
        end
        return tostring(a) < tostring(b)
    end)

    -- Pass 3: build child nodes. With virtualized rendering only ~40 row
    -- frames ever exist regardless of children count - no data-layer cap.
    local total = #rawKeys
    local cap = total
    local kids = {}
    for i = 1, cap do
        local k = rawKeys[i]
        local keyType = type(k)
        local function child_getter()
            local parentVal = node.getter()
            if type(parentVal) ~= "table" then return nil end
            return parentVal[k]
        end
        local keyStr
        if keyType == "string" then
            keyStr = k
        else
            keyStr = "[" .. tostring(k) .. "]"
        end
        kids[i] = {
            key       = keyStr,
            rawKey    = k,
            keyType   = keyType,
            getter    = child_getter,
            parent    = node,
            depth     = node.depth + 1,
            expanded  = false,
            children  = nil,
            path      = node.path .. "." .. keyStr,
        }
    end

    -- Append $metatable / $metatable.__index entries when expanding a real
    -- table (not the synthetic root view). Mirrors DevTool's behavior so
    -- you can drill into Mixin chains (frames, Ace addon objects, etc).
    local mt
    pcall(function() mt = getmetatable(v) end)
    if type(mt) == "table" and not isUntouchable(mt) then
        local mtCount = 0
        for _ in pairs(mt) do mtCount = mtCount + 1 end
        -- If the metatable is just { __index = T }, hop straight to T.
        if mtCount == 1 and type(mt.__index) == "table" then
            local idx = mt.__index
            kids[#kids + 1] = {
                key       = "$metatable.__index",
                rawKey    = "$metatable.__index",
                keyType   = "string",
                getter    = function() return idx end,
                parent    = node,
                depth     = node.depth + 1,
                expanded  = false,
                children  = nil,
                path      = node.path .. ".$metatable.__index",
                _isMeta   = true,
            }
        elseif mtCount > 0 then
            kids[#kids + 1] = {
                key       = "$metatable",
                rawKey    = "$metatable",
                keyType   = "string",
                getter    = function() return mt end,
                parent    = node,
                depth     = node.depth + 1,
                expanded  = false,
                children  = nil,
                path      = node.path .. ".$metatable",
                _isMeta   = true,
            }
        end
    end

    node.children       = kids
    node._totalChildren = total
end

-- ----- Root nodes --------------------------------------------------------
-- A "root" is just a top-level node in the tree. Multiple roots are stacked
-- in the visible list. The first root is always _G; users can pin more via
-- mouseover, /forge inspect <path>, or find/startswith results.
--
-- Spec shape:
--   { kind = "path",     path = "_G.X.Y" }                 -- persistent
--   { kind = "snapshot", name = "find:foo", value = tbl }  -- session-only

local function makeRootFromSpec(spec)
    local name, getter, path
    if spec.kind == "path" then
        path = spec.path or "_G"
        name = path
        if path == "_G" then
            getter = function() return _G end
        else
            -- Walk _G.X.Y at lookup time so the value tracks live updates.
            local segments = {}
            for seg in path:gsub("^_G%.?", ""):gmatch("[^%.]+") do
                segments[#segments + 1] = seg
            end
            getter = function()
                local cur = _G
                for _, seg in ipairs(segments) do
                    if type(cur) ~= "table" then return nil end
                    cur = cur[seg]
                end
                return cur
            end
        end
    elseif spec.kind == "snapshot" then
        name   = spec.name or "snapshot"
        path   = "$" .. name
        local v = spec.value
        getter = function() return v end
    elseif spec.kind == "live_mouseover" then
        name   = "@mouseover"
        path   = "@mouseover"
        getter = function()
            if GetMouseFoci then
                local list = GetMouseFoci() or {}
                return list[1]
            elseif GetMouseFocus then
                return GetMouseFocus()
            end
            return nil
        end
    else
        return nil
    end
    return {
        key      = name,
        keyType  = "string",
        getter   = getter,
        parent   = nil,
        depth    = 0,
        expanded = false,
        path     = path,
        _spec    = spec,  -- so we can identify / remove later
    }
end

local function defaultRoots()
    return { makeRootFromSpec({ kind = "path", path = "_G" }) }
end

-- Walk all roots top-down, returning a flat list of currently-visible nodes.
local function flatten(roots, filterText)
    local out = {}
    local function visit(node)
        out[#out + 1] = node
        if node.expanded then
            if not node.children then buildChildren(node) end
            for _, child in ipairs(node.children or {}) do
                if filterText == "" or node.depth ~= 0
                    or tostring(child.key):lower():find(filterText:lower(), 1, true) then
                    visit(child)
                end
            end
        end
    end
    for _, root in ipairs(roots or {}) do visit(root) end
    return out
end

-- ----- Watch list --------------------------------------------------------
local function resolvePath(pathStr)
    -- Walk from _G via dot-separated keys. No support for keys containing
    -- dots (rare in practice). Brackets like [1] resolve to the numeric key 1.
    if pathStr == "_G" then return _G end
    local cur = _G
    -- Drop the leading "_G." prefix.
    local p = pathStr:gsub("^_G%.", "")
    for seg in p:gmatch("[^%.]+") do
        if type(cur) ~= "table" then return nil end
        if isUntouchable(cur) then return "<protected>" end
        if seg:match("^%[(.-)%]$") then
            local inner = seg:match("^%[(.-)%]$")
            local n = tonumber(inner)
            if n then
                cur = cur[n]
            else
                cur = cur[inner:gsub('^"', ""):gsub('"$', "")]
            end
        else
            cur = cur[seg]
        end
    end
    return cur
end

-- ----- UI builder --------------------------------------------------------
function UI.Build(parent, mod)
    _activeMod = mod
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetAllPoints(parent)
    mod._frame = frame

    -- ===== Toolbar =======================================================
    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  4, -4)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    bar:SetHeight(TOOLBAR_H)

    -- ---------- Toolbar row 1: filter + view controls ------------------
    local searchBg = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    searchBg:SetSize(200, 22)
    searchBg:SetPoint("TOPLEFT", bar, "TOPLEFT", 4, -2)
    searchBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    searchBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    searchBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    local search = CreateFrame("EditBox", nil, searchBg)
    search:SetMultiLine(false); search:SetAutoFocus(false)
    search:SetFontObject("ChatFontNormal")
    search:SetPoint("LEFT", 6, 0); search:SetPoint("RIGHT", -6, 0)
    search:SetHeight(18); search:SetTextInsets(0, 0, 0, 0)
    search:SetScript("OnTextChanged", function(self) _filterText = self:GetText() or ""; UI.RebuildTree() end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText(""); _filterText = ""; UI.RebuildTree() end)
    local hint = searchBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", 8, 0); hint:SetText("Filter top-level keys...")
    search:SetScript("OnEditFocusGained", function() hint:Hide() end)
    search:SetScript("OnEditFocusLost", function(self)
        if (self:GetText() or "") == "" then hint:Show() end
    end)

    local refreshBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    refreshBtn:SetSize(70, 22)
    refreshBtn:SetPoint("LEFT", searchBg, "RIGHT", 6, 0)
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", function() UI.RebuildTree() end)

    -- Live (0.5s auto-poll) toggle.
    local liveCb = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
    liveCb:SetSize(20, 20)
    liveCb:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)
    liveCb:SetChecked((ns.IsLive and ns.IsLive()) or false)
    liveCb:SetScript("OnClick", function(self)
        if ns.SetLive then ns.SetLive(self:GetChecked() and true or false) end
    end)
    liveCb:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("|cffd87f3aLive (0.5s auto-poll)|r")
        GameTooltip:AddLine("Re-renders visible tree rows + the watch list every 0.5s.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    liveCb:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    local liveLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    liveLabel:SetPoint("LEFT", liveCb, "RIGHT", 2, 0)
    liveLabel:SetText("Live")
    liveLabel:SetTextColor(0.85, 0.7, 0.4, 1)

    -- Mouseover (live) toggle.
    local mouseCb = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
    mouseCb:SetSize(20, 20)
    mouseCb:SetPoint("LEFT", liveLabel, "RIGHT", 8, 0)
    mouseCb:SetChecked(false)
    mouseCb:SetScript("OnClick", function(self)
        UI.SetMouseoverEnabled(self:GetChecked() and true or false)
    end)
    mouseCb:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("|cffd87f3aMouseover (live)|r")
        GameTooltip:AddLine("Adds an |cffd87f3a@mouseover|r root that tracks the frame currently", 1, 1, 1, true)
        GameTooltip:AddLine("under your cursor. Updates 5x/sec; expand to drill in.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    mouseCb:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    local mouseLabel = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mouseLabel:SetPoint("LEFT", mouseCb, "RIGHT", 2, 0)
    mouseLabel:SetText("Mouseover")
    mouseLabel:SetTextColor(0.85, 0.7, 0.4, 1)

    local collapseBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    collapseBtn:SetSize(90, 22)
    collapseBtn:SetPoint("LEFT", mouseLabel, "RIGHT", 8, 0)
    collapseBtn:SetText("Collapse all")
    collapseBtn:SetScript("OnClick", function()
        for _, root in ipairs(mod._roots or {}) do
            root.expanded = false
            root.children = nil
        end
        UI.RebuildTree()
    end)

    -- ---------- Toolbar row 2: search + tools ---------------------------
    local findBg = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    findBg:SetSize(180, 22)
    findBg:SetPoint("TOPLEFT", bar, "TOPLEFT", 4, -28)
    findBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    findBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    findBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    local findEdit = CreateFrame("EditBox", nil, findBg)
    findEdit:SetMultiLine(false); findEdit:SetAutoFocus(false)
    findEdit:SetFontObject("ChatFontNormal")
    findEdit:SetPoint("LEFT", 6, 0); findEdit:SetPoint("RIGHT", -6, 0)
    findEdit:SetHeight(18); findEdit:SetTextInsets(0, 0, 0, 0)
    findEdit:SetScript("OnEnterPressed", function(self)
        UI.RunFind(self:GetText(), "contains")
        self:ClearFocus()
    end)
    findEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText("") end)
    local findHint = findBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    findHint:SetPoint("LEFT", 8, 0); findHint:SetText("Search _G for...")
    findEdit:SetScript("OnEditFocusGained", function() findHint:Hide() end)
    findEdit:SetScript("OnEditFocusLost", function(self)
        if (self:GetText() or "") == "" then findHint:Show() end
    end)
    mod._findEdit = findEdit

    local findBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    findBtn:SetSize(50, 22)
    findBtn:SetPoint("LEFT", findBg, "RIGHT", 4, 0)
    findBtn:SetText("Find")
    findBtn:SetScript("OnClick", function() UI.RunFind(findEdit:GetText(), "contains") end)
    findBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("Find: pin a snapshot of _G keys that |cffd87f3acontain|r the term.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    findBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    local startBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    startBtn:SetSize(60, 22)
    startBtn:SetPoint("LEFT", findBtn, "RIGHT", 4, 0)
    startBtn:SetText("Starts")
    startBtn:SetScript("OnClick", function() UI.RunFind(findEdit:GetText(), "prefix") end)
    startBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("Starts: pin a snapshot of _G keys that |cffd87f3astart with|r the term.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    startBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    local fstackBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    fstackBtn:SetSize(70, 22)
    fstackBtn:SetPoint("LEFT", startBtn, "RIGHT", 12, 0)
    fstackBtn:SetText("FStack")
    fstackBtn:SetScript("OnClick", function() UI.OpenFStack() end)
    fstackBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("Toggle Blizzard's Frame Stack tooltip.", 1, 1, 1, true)
        GameTooltip:AddLine("Same thing as |cffd87f3a/framestack|r.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    fstackBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    local etraceBtn = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    etraceBtn:SetSize(70, 22)
    etraceBtn:SetPoint("LEFT", fstackBtn, "RIGHT", 4, 0)
    etraceBtn:SetText("ETrace")
    etraceBtn:SetScript("OnClick", function() UI.OpenETrace() end)
    etraceBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("Toggle Blizzard's Event Trace.", 1, 1, 1, true)
        GameTooltip:AddLine("Same thing as |cffd87f3a/eventtrace|r.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    etraceBtn:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

    -- ===== Tree pane (left) ==============================================
    -- Taint warning banner just below the toolbar.
    local warn = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warn:SetPoint("TOPLEFT",  bar, "BOTTOMLEFT",  4, -2)
    warn:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", -4, -2)
    warn:SetJustifyH("LEFT")
    warn:SetText("|cffffaa00Note:|r protected Blizzard tables show as |cffff8080<protected>|r and can't be expanded (skipping them prevents taint). Click |cffd87f3a>|r to expand any safe table.")

    local treeBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    treeBg:SetPoint("TOPLEFT", warn, "BOTTOMLEFT", 0, -2)
    treeBg:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 4)
    treeBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    treeBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    treeBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    -- Width set on parent resize.
    local function reposTree()
        local fw = frame:GetWidth() or 0
        local treeW = math.floor((fw - 12) * SPLIT_RATIO)
        treeBg:SetWidth(treeW)
    end
    frame:SetScript("OnSizeChanged", function() reposTree() end)
    reposTree()

    local treeScroll = CreateFrame("ScrollFrame", nil, treeBg, "UIPanelScrollFrameTemplate")
    treeScroll:SetPoint("TOPLEFT", 6, -6)
    treeScroll:SetPoint("BOTTOMRIGHT", -28, 6)
    mod._treeScroll = treeScroll
    local treeContent = CreateFrame("Frame", nil, treeScroll); treeContent:SetSize(1,1); treeScroll:SetScrollChild(treeContent)
    mod._treeContent = treeContent
    mod._treeRows = {}

    -- Virtualized rendering: re-render the visible window on every scroll
    -- tick. Only ~40 row frames exist regardless of total node count.
    treeScroll:HookScript("OnVerticalScroll", function() UI.RenderVisibleWindow() end)
    treeScroll:HookScript("OnSizeChanged",    function() UI.RenderVisibleWindow() end)

    -- ===== Right pane (tabbed: Watch | Events) ==========================
    local rightBg = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    rightBg:SetPoint("TOPLEFT", treeBg, "TOPRIGHT", PAD, 0)
    rightBg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
    rightBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    rightBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    rightBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    mod._rightBg = rightBg

    -- Tab strip at the top of the right pane.
    local function makeTabBtn(label, anchorTo, dx)
        local b = CreateFrame("Button", nil, rightBg, "UIPanelButtonTemplate")
        b:SetSize(70, 22)
        if anchorTo then
            b:SetPoint("LEFT", anchorTo, "RIGHT", dx or 4, 0)
        else
            b:SetPoint("TOPLEFT", rightBg, "TOPLEFT", 6, -4)
        end
        b:SetText(label)
        return b
    end
    local watchTabBtn  = makeTabBtn("Watch",  nil, 0)
    local eventsTabBtn = makeTabBtn("Events", watchTabBtn, 4)
    mod._watchTabBtn  = watchTabBtn
    mod._eventsTabBtn = eventsTabBtn

    -- ----- Watch panel (existing watch list, now in a sub-frame) ------
    local watchPanel = CreateFrame("Frame", nil, rightBg)
    watchPanel:SetPoint("TOPLEFT",     watchTabBtn, "BOTTOMLEFT", -2, -4)
    watchPanel:SetPoint("BOTTOMRIGHT", rightBg,     "BOTTOMRIGHT", -6, 6)
    mod._watchPanel = watchPanel

    local watchTitle = watchPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    watchTitle:SetPoint("TOPLEFT", 6, -2)
    watchTitle:SetText("|cffd87f3aWatch list|r  |cffaaaaaaright-click a tree row to pin|r")
    mod._watchTitle = watchTitle

    local watchScroll = CreateFrame("ScrollFrame", nil, watchPanel, "UIPanelScrollFrameTemplate")
    watchScroll:SetPoint("TOPLEFT", 6, -18)
    watchScroll:SetPoint("BOTTOMRIGHT", -28, 6)
    mod._watchScroll = watchScroll
    local watchContent = CreateFrame("Frame", nil, watchScroll); watchContent:SetSize(1,1); watchScroll:SetScrollChild(watchContent)
    mod._watchContent = watchContent
    mod._watchRows = {}

    -- ----- Events panel ------------------------------------------------
    local eventsPanel = CreateFrame("Frame", nil, rightBg)
    eventsPanel:SetPoint("TOPLEFT",     watchTabBtn, "BOTTOMLEFT", -2, -4)
    eventsPanel:SetPoint("BOTTOMRIGHT", rightBg,     "BOTTOMRIGHT", -6, 6)
    eventsPanel:Hide()
    mod._eventsPanel = eventsPanel

    -- Top: input + Add button
    local evtInputBg = CreateFrame("Frame", nil, eventsPanel, "BackdropTemplate")
    evtInputBg:SetPoint("TOPLEFT", 6, -2)
    evtInputBg:SetSize(180, 22)
    evtInputBg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    evtInputBg:SetBackdropColor(0.04, 0.04, 0.04, 0.40)
    evtInputBg:SetBackdropBorderColor(0.4, 0.3, 0.15, 1)
    local evtInput = CreateFrame("EditBox", nil, evtInputBg)
    evtInput:SetMultiLine(false); evtInput:SetAutoFocus(false)
    evtInput:SetFontObject("ChatFontNormal")
    evtInput:SetPoint("LEFT", 6, 0); evtInput:SetPoint("RIGHT", -6, 0); evtInput:SetHeight(18)
    evtInput:SetScript("OnEnterPressed", function(self)
        UI.AddEventWatchFromInput(self:GetText()); self:SetText(""); self:ClearFocus()
    end)
    evtInput:SetScript("OnEscapePressed", function(self) self:ClearFocus(); self:SetText("") end)
    local evtHint = evtInputBg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    evtHint:SetPoint("LEFT", 8, 0); evtHint:SetText("PLAYER_LOGIN, BAG_UPDATE, ...")
    evtInput:SetScript("OnEditFocusGained", function() evtHint:Hide() end)
    evtInput:SetScript("OnEditFocusLost",  function(self)
        if (self:GetText() or "") == "" then evtHint:Show() end
    end)
    mod._evtInput = evtInput

    local addEvtBtn = CreateFrame("Button", nil, eventsPanel, "UIPanelButtonTemplate")
    addEvtBtn:SetSize(50, 22)
    addEvtBtn:SetPoint("LEFT", evtInputBg, "RIGHT", 4, 0)
    addEvtBtn:SetText("Add")
    addEvtBtn:SetScript("OnClick", function()
        UI.AddEventWatchFromInput(evtInput:GetText()); evtInput:SetText("")
    end)

    local clearLogBtn = CreateFrame("Button", nil, eventsPanel, "UIPanelButtonTemplate")
    clearLogBtn:SetSize(60, 22)
    clearLogBtn:SetPoint("LEFT", addEvtBtn, "RIGHT", 4, 0)
    clearLogBtn:SetText("Clear")
    clearLogBtn:SetScript("OnClick", function()
        if ns.ClearEventLog then ns.ClearEventLog() end
        UI.RefreshEventsPane()
    end)

    -- Watched-events list (small)
    local watchListLabel = eventsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    watchListLabel:SetPoint("TOPLEFT", evtInputBg, "BOTTOMLEFT", 0, -8)
    watchListLabel:SetText("|cffd87f3aWatching:|r")

    local watchListScroll = CreateFrame("ScrollFrame", nil, eventsPanel, "UIPanelScrollFrameTemplate")
    watchListScroll:SetPoint("TOPLEFT", watchListLabel, "BOTTOMLEFT", 0, -2)
    watchListScroll:SetPoint("RIGHT", eventsPanel, "RIGHT", -28, 0)
    watchListScroll:SetHeight(90)
    local watchListContent = CreateFrame("Frame", nil, watchListScroll)
    watchListContent:SetSize(1, 1)
    watchListScroll:SetScrollChild(watchListContent)
    mod._evtListScroll  = watchListScroll
    mod._evtListContent = watchListContent
    mod._evtListRows    = {}

    -- Recent fires log
    local logLabel = eventsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    logLabel:SetPoint("TOPLEFT", watchListScroll, "BOTTOMLEFT", 0, -8)
    logLabel:SetText("|cffd87f3aRecent fires|r  |cffaaaaaa(newest at bottom)|r")
    mod._evtLogLabel = logLabel

    local logScroll = CreateFrame("ScrollFrame", nil, eventsPanel, "UIPanelScrollFrameTemplate")
    logScroll:SetPoint("TOPLEFT",     logLabel,    "BOTTOMLEFT", 0, -2)
    logScroll:SetPoint("BOTTOMRIGHT", eventsPanel, "BOTTOMRIGHT", -28, 6)
    local logContent = CreateFrame("Frame", nil, logScroll)
    logContent:SetSize(1, 1)
    logScroll:SetScrollChild(logContent)
    mod._evtLogScroll  = logScroll
    mod._evtLogContent = logContent
    mod._evtLogText = logContent:CreateFontString(nil, "ARTWORK", "ChatFontSmall")
    mod._evtLogText:SetPoint("TOPLEFT", 4, -2)
    mod._evtLogText:SetJustifyH("LEFT"); mod._evtLogText:SetJustifyV("TOP")
    mod._evtLogText:SetWordWrap(true)

    -- Tab handlers
    watchTabBtn:SetScript("OnClick",  function() UI.SelectRightTab("watch") end)
    eventsTabBtn:SetScript("OnClick", function() UI.SelectRightTab("events") end)

    -- Subscribe to event log changes so the panel auto-refreshes.
    if ns.SubscribeEventLog then
        mod._evtUnsub = ns.SubscribeEventLog(function()
            if mod._activeRightTab == "events" then UI.RefreshEventsPane() end
        end)
    end

    mod._activeRightTab = "watch"

    -- ===== Init root + first build =====================================
    mod._roots = defaultRoots()
    UI.RestorePinnedRoots()  -- pull persisted roots from db on first build
    UI.RebuildTree()

    -- 0.5s auto-poll: opt-in via the Live checkbox. Default OFF because
    -- iterating _G and visible nodes propagates taint to anything we touch,
    -- and a persistent ticker that taints once-per-second will eventually
    -- get blamed for blocked secure-code operations downstream. The user
    -- can flip Live on for short bursts, or just hit Refresh on demand.
    if not _ticker and C_Timer and C_Timer.NewTicker then
        _ticker = C_Timer.NewTicker(0.5, function()
            if ns.IsLive and ns.IsLive() then UI.RefreshLive() end
        end)
    end
end

-- Build a tree row.
local function buildTreeRow(parent, mod)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)

    local hov = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    hov:SetColorTexture(0.45, 0.32, 0.15, 0.30); hov:SetAllPoints(); hov:Hide()
    row._hov = hov

    local toggle = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toggle:SetPoint("LEFT", row, "LEFT", 4, 0)
    toggle:SetWidth(14); toggle:SetJustifyH("CENTER")
    toggle:SetTextColor(0.85, 0.7, 0.4, 1)
    row._toggle = toggle

    local text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", toggle, "RIGHT", 2, 0)
    text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    text:SetJustifyH("LEFT"); text:SetWordWrap(false); text:SetMaxLines(1)
    row._text = text

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnEnter", function(self)
        self._hov:Show()
        if self._node then UI.ShowRowTooltip(self) end
    end)
    row:SetScript("OnLeave", function(self)
        self._hov:Hide()
        if GameTooltip then GameTooltip:Hide() end
    end)
    row:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and self._node then
            local n = self._node
            local v = n.getter()
            -- Skip expand on protected tables — iterating them taints us.
            if type(v) == "table" and not isUntouchable(v) then
                n.expanded = not n.expanded
                UI.RebuildTree()
            end
        elseif button == "RightButton" and self._node then
            UI.PinPath(self._node.path)
        end
    end)
    return row
end

local function rowText(node)
    local v = node.getter()
    local prefix = string.rep("  ", node.depth - 1)  -- depth 0 = root, depth 1 = no indent
    if node.depth == 0 then prefix = "" end
    local keyStr = "|cffffe6a8" .. escapeBars(node.key) .. "|r"
    local sep = "  : "
    return prefix .. keyStr .. sep .. fmtValue(v)
end

local function rowToggleSymbol(node)
    local v = node.getter()
    if type(v) ~= "table" then return " " end
    if isUntouchable(v) then return "X" end  -- protected; can't expand
    return node.expanded and "v" or ">"
end

-- Recompute the flat visible list. Called when tree structure changes
-- (expand/collapse/filter/refresh) - not on every scroll.
function UI.RecomputeVisible()
    local mod = _activeMod
    if not mod then return end
    mod._visible = flatten(mod._roots, _filterText or "")
end

-- Render only the rows currently inside the scroll viewport. Re-uses the
-- row buttons in mod._treeRows; creates lazily up to VISIBLE_ROW_BUFFER.
function UI.RenderVisibleWindow()
    local mod = _activeMod
    if not (mod and mod._treeContent and mod._visible) then return end

    local total = #mod._visible
    -- Set virtual content height so the scrollbar reflects the full size.
    mod._treeContent:SetHeight(math.max(1, total * ROW_H))

    local scrollY   = mod._treeScroll:GetVerticalScroll() or 0
    local viewportH = mod._treeScroll:GetHeight() or 0
    local firstIdx  = math.max(1, math.floor(scrollY / ROW_H) + 1)
    local rowsToShow = math.min(
        VISIBLE_ROW_BUFFER,
        math.ceil(viewportH / ROW_H) + 2,   -- +2 for partial top/bottom rows
        total - firstIdx + 1
    )

    -- Hide every pooled row first; we'll re-show only the ones we need.
    for _, row in ipairs(mod._treeRows) do row:Hide() end

    for i = 1, math.max(0, rowsToShow) do
        local nodeIdx = firstIdx + i - 1
        local node = mod._visible[nodeIdx]
        if not node then break end

        local row = mod._treeRows[i]
        if not row then
            row = buildTreeRow(mod._treeContent, mod)
            mod._treeRows[i] = row
        end
        row._node = node
        row._toggle:SetText(rowToggleSymbol(node))
        row._text:SetText(rowText(node))
        row:ClearAllPoints()
        row:SetWidth(mod._treeScroll:GetWidth() - 8)
        -- Position in absolute treeContent coordinates so scrolling the
        -- ScrollFrame moves the row naturally with the content.
        row:SetPoint("TOPLEFT", mod._treeContent, "TOPLEFT", 0, -((nodeIdx - 1) * ROW_H))
        row:Show()
    end

    mod._treeScroll:UpdateScrollChildRect()
end

function UI.RebuildTree()
    UI.RecomputeVisible()
    UI.RenderVisibleWindow()
    UI.RefreshWatch()
end

-- Lighter pass: only update text on visible rows, no rebuild.
function UI.RefreshLive()
    local mod = _activeMod
    if not (mod and mod._treeRows) then return end
    for _, row in ipairs(mod._treeRows) do
        if row:IsShown() and row._node then
            row._toggle:SetText(rowToggleSymbol(row._node))
            row._text:SetText(rowText(row._node))
        end
    end
    UI.RefreshWatchValues()
end

-- ----- Watch list operations --------------------------------------------
function UI.PinPath(path)
    if not path or path == "" then return end
    if path == "_G" then
        if ns.out then ns.out("can't pin _G itself; pin a child key.") end
        return
    end
    if not ns.AddWatch then return end
    if ns.AddWatch(path) then
        if ns.out then ns.out("pinned to watch: " .. path) end
        UI.RefreshWatch()
    end
end

function UI.RefreshWatch()
    local mod = _activeMod
    if not mod or not mod._watchContent then return end
    local watch = (ns.GetWatch and ns.GetWatch()) or {}

    for _, row in ipairs(mod._watchRows) do row:Hide() end
    local y = 0
    for i, path in ipairs(watch) do
        local row = mod._watchRows[i]
        if not row then
            row = CreateFrame("Frame", nil, mod._watchContent)
            row:SetHeight(ROW_H)
            local rmBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            rmBtn:SetSize(18, 18); rmBtn:SetPoint("LEFT", row, "LEFT", 0, 0); rmBtn:SetText("x")
            rmBtn:SetScript("OnClick", function() if ns.RemoveWatch then ns.RemoveWatch(row._path); UI.RefreshWatch() end end)
            local pathFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            pathFs:SetPoint("LEFT", rmBtn, "RIGHT", 4, 0)
            pathFs:SetWidth(180); pathFs:SetJustifyH("LEFT"); pathFs:SetWordWrap(false); pathFs:SetMaxLines(1)
            pathFs:SetTextColor(0.85, 0.7, 0.4, 1)
            row._pathFs = pathFs
            local valFs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            valFs:SetPoint("LEFT", pathFs, "RIGHT", 6, 0)
            valFs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            valFs:SetJustifyH("LEFT"); valFs:SetWordWrap(false); valFs:SetMaxLines(1)
            row._valFs = valFs
            mod._watchRows[i] = row
        end
        row._path = path
        row._pathFs:SetText(escapeBars(path))
        row._valFs:SetText(fmtValue(resolvePath(path)))
        row:ClearAllPoints()
        row:SetWidth(mod._watchScroll:GetWidth() - 8)
        row:SetPoint("TOPLEFT", mod._watchContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + ROW_H
    end
    if y < 1 then y = 1 end
    mod._watchContent:SetHeight(y)
    mod._watchScroll:UpdateScrollChildRect()
end

-- Live-only refresh: just the value text, not the layout.
function UI.RefreshWatchValues()
    local mod = _activeMod
    if not mod or not mod._watchRows then return end
    for _, row in ipairs(mod._watchRows) do
        if row:IsShown() and row._path then
            row._valFs:SetText(fmtValue(resolvePath(row._path)))
        end
    end
end

function UI.OnTabShow(mod)
    _activeMod = mod
    if not mod._roots then
        mod._roots = defaultRoots()
        UI.RestorePinnedRoots()
    end
    UI.RebuildTree()
    if UI.RefreshEventsPane then UI.RefreshEventsPane() end
end

-- ----- Right-pane tabs (Watch | Events) ---------------------------------
function UI.SelectRightTab(name)
    local mod = _activeMod
    if not mod then return end
    mod._activeRightTab = name
    if name == "events" then
        if mod._watchPanel  then mod._watchPanel:Hide()  end
        if mod._eventsPanel then mod._eventsPanel:Show() end
        UI.RefreshEventsPane()
    else
        if mod._eventsPanel then mod._eventsPanel:Hide() end
        if mod._watchPanel  then mod._watchPanel:Show()  end
    end
end

-- ----- Events pane ------------------------------------------------------
function UI.AddEventWatchFromInput(text)
    text = text and text:match("^%s*(.-)%s*$") or ""
    if text == "" then return end
    -- Uppercase WoW event names by convention.
    local eventName = text:upper()
    if not ns.AddEventWatch then return end
    if ns.AddEventWatch(eventName) then
        if ns.out then ns.out("watching event: " .. eventName) end
        UI.RefreshEventsPane()
    else
        if ns.out then ns.out("already watching: " .. eventName) end
    end
end

local function fmtEventTime(ts)
    if not ts then return "?" end
    if date then return date("%H:%M:%S", ts) end
    return tostring(ts)
end

local function buildEventListRow(parent, mod)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(20)

    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(18, 18)
    cb:SetPoint("LEFT", row, "LEFT", 0, 0)
    row._cb = cb

    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    fs:SetJustifyH("LEFT"); fs:SetWordWrap(false); fs:SetMaxLines(1)
    row._fs = fs

    local rm = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    rm:SetSize(18, 18)
    rm:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    rm:SetText("x")
    row._rm = rm

    return row
end

function UI.RefreshEventsPane()
    local mod = _activeMod
    if not (mod and mod._evtListContent) then return end

    -- ---- Watched events list ----
    local watches = ns.GetEventWatches and ns.GetEventWatches() or {}
    local names = {}
    for k in pairs(watches) do names[#names + 1] = k end
    table.sort(names)

    for _, row in ipairs(mod._evtListRows) do row:Hide() end

    local y = 0
    for i, name in ipairs(names) do
        local w = watches[name]
        local row = mod._evtListRows[i]
        if not row then
            row = buildEventListRow(mod._evtListContent, mod)
            mod._evtListRows[i] = row
        end
        row._evtName = name
        row._cb:SetChecked(w.active and true or false)
        row._cb:SetScript("OnClick", function(self)
            if ns.SetEventWatchActive then ns.SetEventWatchActive(name, self:GetChecked() and true or false) end
        end)
        local label = name
        if (w.fireCount or 0) > 0 then
            label = string.format("%s  |cffaaaaaa(%dx)|r", name, w.fireCount)
        end
        if not w.active then
            label = label .. "  |cffff8080(off)|r"
        end
        row._fs:SetText(label)
        row._rm:SetScript("OnClick", function()
            if ns.RemoveEventWatch then ns.RemoveEventWatch(name) end
            UI.RefreshEventsPane()
        end)
        row:ClearAllPoints()
        row:SetWidth(mod._evtListScroll:GetWidth() - 8)
        row:SetPoint("TOPLEFT", mod._evtListContent, "TOPLEFT", 0, -y)
        row:Show()
        y = y + 20
    end
    if y < 1 then y = 1 end
    mod._evtListContent:SetHeight(y)
    mod._evtListScroll:UpdateScrollChildRect()

    -- ---- Recent fires log ----
    local log = ns.GetEventLog and ns.GetEventLog() or {}
    local lines = {}
    for _, e in ipairs(log) do
        lines[#lines + 1] = string.format(
            "|cffaaaaaa[%s]|r |cffd87f3a%s|r %s",
            fmtEventTime(e.ts), e.event, e.args or "")
    end
    if mod._evtLogText then
        mod._evtLogText:SetText(table.concat(lines, "\n"))
        mod._evtLogText:SetWidth(mod._evtLogScroll:GetWidth() - 8)
        local h = mod._evtLogText:GetStringHeight() + 8
        mod._evtLogContent:SetSize(mod._evtLogScroll:GetWidth() - 8, math.max(1, h))
        mod._evtLogScroll:UpdateScrollChildRect()
        -- Auto-scroll to bottom (newest line).
        mod._evtLogScroll:SetVerticalScroll(math.max(0, h - (mod._evtLogScroll:GetHeight() or 0)))
    end

    if mod._evtLogLabel then
        mod._evtLogLabel:SetText(string.format(
            "|cffd87f3aRecent fires|r  |cffaaaaaa(%d entries, newest at bottom)|r", #log))
    end
end

-- ----- Multi-root API ---------------------------------------------------
-- Public helpers used by slash commands (mouseover / find / pin path).
-- All operations rebuild the tree.

local function specMatches(a, b)
    if a.kind ~= b.kind then return false end
    if a.kind == "path" then return a.path == b.path end
    if a.kind == "snapshot" then return a.name == b.name end
    return false
end

function UI.HasRoot(spec)
    local mod = _activeMod
    if not mod or not mod._roots then return false end
    for _, root in ipairs(mod._roots) do
        if root._spec and specMatches(root._spec, spec) then return true end
    end
    return false
end

-- Push a new root. `persist` controls whether to save it to db.profile.
-- Path-kind roots default to persistent; snapshots are session-only.
function UI.AddRoot(spec, persist)
    local mod = _activeMod
    if not mod then
        if ns.out then ns.out("Inspector not built yet; open the tab first.") end
        return false
    end
    mod._roots = mod._roots or defaultRoots()
    if UI.HasRoot(spec) then
        if ns.out then ns.out("already pinned: " .. (spec.path or spec.name or "?")) end
        return false
    end
    local root = makeRootFromSpec(spec)
    if not root then return false end
    mod._roots[#mod._roots + 1] = root
    if persist == nil then persist = (spec.kind == "path") end
    if persist and ns.AddPinnedRoot then ns.AddPinnedRoot(spec) end
    UI.RebuildTree()
    return true
end

-- Remove a root by spec match. The first root (_G) is permanent.
function UI.RemoveRoot(spec)
    local mod = _activeMod
    if not mod or not mod._roots then return false end
    for i = #mod._roots, 2, -1 do  -- never remove index 1 (_G)
        local root = mod._roots[i]
        if root._spec and specMatches(root._spec, spec) then
            table.remove(mod._roots, i)
            if ns.RemovePinnedRoot then ns.RemovePinnedRoot(spec) end
            UI.RebuildTree()
            return true
        end
    end
    return false
end

-- Called once at first build to load persisted roots from db.
function UI.RestorePinnedRoots()
    if not (ns.GetPinnedRoots and _activeMod) then return end
    local saved = ns.GetPinnedRoots()
    for _, spec in ipairs(saved) do
        if not UI.HasRoot(spec) then
            local root = makeRootFromSpec(spec)
            if root then _activeMod._roots[#_activeMod._roots + 1] = root end
        end
    end
end

-- ----- Live mouseover ----------------------------------------------------
local _mouseoverTicker
local _mouseoverEnabled = false

function UI.IsMouseoverEnabled() return _mouseoverEnabled end

function UI.SetMouseoverEnabled(on)
    _mouseoverEnabled = on and true or false
    local mod = _activeMod
    local spec = { kind = "live_mouseover" }

    if _mouseoverEnabled then
        if mod and not UI.HasRoot(spec) then
            UI.AddRoot(spec, false)  -- session-only root
        end
        if not _mouseoverTicker and C_Timer and C_Timer.NewTicker then
            _mouseoverTicker = C_Timer.NewTicker(0.2, function()
                if not _mouseoverEnabled then return end
                -- Cheap refresh of visible row text only - the @mouseover
                -- root's getter resolves to the current focus on every read.
                if UI.RefreshLive then UI.RefreshLive() end
            end)
        end
    else
        UI.RemoveRoot(spec)
        if _mouseoverTicker then
            _mouseoverTicker:Cancel()
            _mouseoverTicker = nil
        end
    end
end

-- ----- Find / Starts entry point (used by toolbar buttons) --------------
function UI.RunFind(pattern, mode)
    pattern = pattern and pattern:match("^%s*(.-)%s*$") or ""
    if pattern == "" then
        if ns.out then ns.out("type a search term in the box first.") end
        return
    end
    local results, count = UI.FindInTable(_G, pattern, mode or "contains")
    if not results or count == 0 then
        if ns.out then ns.out("no matches for '" .. pattern .. "' in _G") end
        return
    end
    local label = string.format("%s '%s' in _G (%d)",
        mode == "prefix" and "starts" or "find", pattern, count)
    UI.AddSnapshotRoot(label, results)
    if ns.out then ns.out("pinned: " .. label) end
end

-- ----- FStack / ETrace pass-throughs ------------------------------------
function UI.OpenFStack()
    if SlashCmdList and SlashCmdList.FRAMESTACK then
        SlashCmdList.FRAMESTACK("")
        return
    end
    if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_DebugTools") end
    if FrameStackTooltip and FrameStackTooltip.Toggle then
        FrameStackTooltip:Toggle()
    elseif ns.out then
        ns.out("frame stack tool unavailable on this client.")
    end
end

function UI.OpenETrace()
    for _, key in ipairs({ "EVENTTRACE", "ETRACE" }) do
        if SlashCmdList and SlashCmdList[key] then
            SlashCmdList[key]("")
            return
        end
    end
    if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_EventTrace") end
    if EventTrace and EventTrace.Show then
        if EventTrace:IsShown() then EventTrace:Hide() else EventTrace:Show() end
    elseif ns.out then
        ns.out("event trace tool unavailable on this client.")
    end
end

function UI.ListRoots()
    local mod = _activeMod
    if not mod or not mod._roots then return {} end
    local out = {}
    for i, root in ipairs(mod._roots) do
        out[i] = { name = root.key, kind = root._spec and root._spec.kind or "?", path = root.path }
    end
    return out
end

-- ----- Snapshot root helper ---------------------------------------------
-- Used by find / startswith / mouseover to pin a synthetic table as a
-- top-level root. Snapshot roots are session-only (not persisted).
function UI.AddSnapshotRoot(name, value)
    if not name or name == "" then return false end
    if type(value) ~= "table" then return false end
    return UI.AddRoot({ kind = "snapshot", name = name, value = value }, false)
end

-- ----- Search helpers ---------------------------------------------------
-- Iterate `parent` and return a synthetic table containing matching keys.
-- `mode` is "contains" (substring) or "prefix" (starts-with). Case-insensitive.
function UI.FindInTable(parent, pattern, mode)
    if type(parent) ~= "table" or isUntouchable(parent) then return nil, 0 end
    if type(pattern) ~= "string" or pattern == "" then return nil, 0 end
    local lpat = pattern:lower()
    local out = {}
    local count = 0
    pcall(function()
        for k, v in pairs(parent) do
            if type(k) == "string" then
                local lk = k:lower()
                local hit
                if mode == "prefix" then
                    hit = lk:sub(1, #lpat) == lpat
                else
                    hit = lk:find(lpat, 1, true) ~= nil
                end
                if hit then
                    out[k] = v
                    count = count + 1
                end
            end
        end
    end)
    return out, count
end

-- ----- Row tooltip ------------------------------------------------------
-- Show a tooltip with frame metadata when hovering a row whose value is a
-- frame-like object. Cheap when the value is a primitive (no tooltip).
function UI.ShowRowTooltip(row)
    local node = row._node
    if not (node and GameTooltip) then return end
    local v
    pcall(function() v = node.getter() end)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(node.path or node.key)
    GameTooltip:AddLine("type: " .. type(v), 0.7, 0.7, 0.7, false)

    if type(v) == "table" and not isUntouchable(v) then
        -- Frame metadata: GetObjectType / GetName / GetText / GetTexture.
        local function tryMethod(name)
            local fn = v[name]
            if type(fn) ~= "function" then return nil end
            local ok, result = pcall(fn, v)
            if ok then return result end
            return nil
        end
        local objType = tryMethod("GetObjectType")
        local frameName = tryMethod("GetName")
        local text     = tryMethod("GetText")
        local texture  = tryMethod("GetTexture")
        if objType    then GameTooltip:AddLine("|cffd87f3aobject:|r  " .. tostring(objType), 1, 1, 1) end
        if frameName  then GameTooltip:AddLine("|cffd87f3aname:|r    " .. tostring(frameName), 1, 1, 1) end
        if text       then GameTooltip:AddLine("|cffd87f3atext:|r    " .. tostring(text), 1, 1, 1, true) end
        if texture    then GameTooltip:AddLine("|cffd87f3atexture:|r " .. tostring(texture), 1, 1, 1, true) end
        if node._totalChildren then
            GameTooltip:AddLine("|cffaaaaaa" .. node._totalChildren .. " keys|r")
        end
    elseif type(v) == "string" and #v > 60 then
        GameTooltip:AddLine(v, 0.85, 0.85, 0.85, true)
    end
    GameTooltip:Show()
end
