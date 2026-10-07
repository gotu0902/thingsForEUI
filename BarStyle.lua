local _, ns = ...

-- ------------------------------------------------------------- bar styles

-- The pack's bars: 1-2-3 hang down the left column, 4-5-6 down the right.
-- Nala Style hides 4-5-6 and stacks 2 and 3 on top of 1 at the bottom of the
-- same block, plus Move That Stuff. Gruffs Preset puts back what Nala Style
-- replaced, plus Move It Back. The placement spreads like Bar 6/9's (every
-- spec layout, every profile syncing Action Bars), and so does the snapshot.

local STACK = { "MainBar", "Bar2", "Bar3" }
local HIDE = { "Bar4", "Bar5", "Bar6", "Bar9" }
local ALL = { "MainBar", "Bar2", "Bar3", "Bar4", "Bar5", "Bar6", "Bar9" }
local LINKS = { "unlockAnchors", "unlockWidthMatch", "unlockHeightMatch", "unlockWidthMatchExtra", "unlockHeightMatchExtra" }

local function Say(msg) print("|cff8AC8FFthings|r Bar Style: " .. msg) end

local function IsSecret(v) return issecretvalue and issecretvalue(v) end

local function Copy(v) return type(v) == "table" and CopyTable(v) or v end

-- snapshots by EllesmereUI profile name
local function Store()
    local db = ns.legacy
    if not db then return {} end
    db.barStyle = db.barStyle or {}
    return db.barStyle
end

local function ActiveName()
    local db = _G.EllesmereUIDB
    return db and (db.activeProfile or "Default")
end

function ns.NalaStyleOn()
    local name = ActiveName()
    return name ~= nil and Store()[name] ~= nil
end

-- UIParent units, origin at its center
local function FrameRect(key)
    local elem = ns.UnlockElems()[key]
    local f = elem and elem.getFrame and elem.getFrame(key)
    if not (f and f:IsShown()) then return end
    local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if not (l and r and t and b) or IsSecret(l) or IsSecret(r) or IsSecret(t) or IsSecret(b) then return end
    local k = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local ux, uy = UIParent:GetCenter()
    return { L = l * k - ux, R = r * k - ux, T = t * k - uy, B = b * k - uy }
end

-- Action Bar 1 on the stack's bottom row, centred on the bars sharing its rows
local function Plan()
    local r1 = FrameRect("MainBar")
    if not r1 then return nil, "Action Bar 1 has to be on screen." end
    local top, bottom = r1.T, r1.B
    for _, key in ipairs(STACK) do
        local r = FrameRect(key)
        if r then top, bottom = math.max(top, r.T), math.min(bottom, r.B) end
    end
    local L, R = r1.L, r1.R
    for _, key in ipairs(ALL) do
        local r = FrameRect(key)
        if r and r.B < top and r.T > bottom then L, R = math.min(L, r.L), math.max(R, r.R) end
    end
    local w, h = r1.R - r1.L, r1.T - r1.B
    return { x = ns.PixelSnap((L + R) / 2 - w / 2) + w / 2, y = bottom + h / 2 }
end

-- the same seam, on the other side of the target
local function Above(info, target)
    local same = type(info) == "table" and info.target == target and info.side == "BOTTOM"
    return { target = target, side = "TOP",
        offsetX = same and info.offsetX or 0, offsetY = same and -(info.offsetY or 0) or 0 }
end

-- vis: the real visibility (EUI's force-show backup)
local function Capture(p, vis)
    local db = _G.EllesmereUIDB
    local snap = { pos = {}, links = {}, vis = {}, enabled = {} }
    for _, key in ipairs(STACK) do snap.pos[key] = Copy(p.barPositions[key]) end
    for _, live in ipairs(LINKS) do
        local t, saved = db[live], {}
        if type(t) == "table" then
            for _, key in ipairs(STACK) do saved[key] = Copy(t[key]) end
        end
        snap.links[live] = saved
    end
    for _, key in ipairs(ALL) do
        snap.vis[key] = Copy(vis[key])
        snap.enabled[key] = p.bars[key] and p.bars[key].enabled
    end
    return snap
end

local function DoNala()
    local name, p, db = ActiveName(), ns.BarProfile(), _G.EllesmereUIDB
    if not (name and p and p.bars and p.barPositions and db) then return false, "needs EllesmereUI Action Bars." end
    if Store()[name] then return false, "bars are already in Nala Style." end
    local plan, err = Plan()
    if not plan then return false, err end
    local snap
    local ok = ns.EditBarVisibility(function(vis, bars, setMode)
        snap = Capture(p, vis)
        for _, key in ipairs(HIDE) do
            if vis[key] then setMode(vis[key], "never") end
        end
        for _, key in ipairs(STACK) do
            local v = vis[key]
            if v and (v.barVisibility == "never" or v.alwaysHidden) then setMode(v, "always") end
            if bars[key] then bars[key].enabled = nil end
        end
    end)
    if not (ok and snap) then return false, "could not reach the action bar settings." end
    db.unlockAnchors = db.unlockAnchors or {}
    local anchors = db.unlockAnchors
    -- an anchored Action Bar 1 follows its own target
    local main = ns.UnlockElems().MainBar
    if not anchors.MainBar and main and main.savePosition then
        main.savePosition("MainBar", "CENTER", "CENTER", plan.x, plan.y)
    end
    anchors.Bar2 = Above(anchors.Bar2, "MainBar")
    anchors.Bar3 = Above(anchors.Bar3, "Bar2")
    local synced = ns.SpreadBarPlacement(STACK)
    local store = Store()
    store[name] = snap
    for _, n in ipairs(synced) do store[n] = CopyTable(snap) end
    return true, synced
end

local function DoGruff()
    local name, p, db = ActiveName(), ns.BarProfile(), _G.EllesmereUIDB
    local snap = name and Store()[name]
    if not snap then return false, "bars are already in Gruffs Preset." end
    if not (p and p.bars and p.barPositions and db) then return false, "needs EllesmereUI Action Bars." end
    local ok = ns.EditBarVisibility(function(vis, bars)
        for _, key in ipairs(ALL) do
            if snap.vis[key] then vis[key] = CopyTable(snap.vis[key]) end
            if bars[key] then bars[key].enabled = snap.enabled[key] end
        end
    end)
    if not ok then return false, "could not reach the action bar settings." end
    for _, key in ipairs(STACK) do p.barPositions[key] = Copy(snap.pos[key]) end
    for live, saved in pairs(snap.links) do
        if type(db[live]) == "table" then
            for _, key in ipairs(STACK) do db[live][key] = Copy(saved[key]) end
        end
    end
    local synced = ns.SpreadBarPlacement(STACK)
    local store = Store()
    store[name] = nil
    for _, n in ipairs(synced) do store[n] = nil end
    return true, synced
end

local function Also(names)
    if #names == 0 then return "" end
    return " Also in " .. table.concat(names, ", ") .. "."
end

function ns.NalaStyle()
    local why = ns.LayoutBusy()
    if why then Say(why); return end
    local ok, res = DoNala()
    Say(ok and ("bars 1-2-3 stacked, 4-5-6 hidden." .. Also(res)) or res)
    if (ok or ns.NalaStyleOn()) and not ns.MoveStuffMoved() then ns.MoveThatStuff() end
end

function ns.GruffsPreset()
    local why = ns.LayoutBusy()
    if why then Say(why); return end
    local ok, res = DoGruff()
    Say(ok and ("bars are back the way they were." .. Also(res)) or res)
    if (ok or not ns.NalaStyleOn()) and ns.MoveStuffMoved() then ns.MoveItBack() end
end

-- ---------------------------------------------------------------------- page

function ns.BuildBarStyleRow(parent, y)
    local eui = ns.EUI()
    local W = eui and eui.Widgets
    if not W then return y end
    local function Refresh()
        if eui.RefreshPage then eui:RefreshPage(true) end
    end

    local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    desc:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y - 8)
    desc:SetText("Nala Style: bars 1-2-3 stacked with 1 at the bottom, 4-5-6 hidden, plus Move That Stuff.")
    y = y - 28

    local row, h = W:WideDualButton(parent, "Gruffs Preset", "Nala Style", y,
        function() ns.GruffsPreset(); Refresh() end,
        function() ns.NalaStyle(); Refresh() end)
    y = y - h
    local btns = {}
    for _, c in ipairs({ row:GetChildren() }) do
        if c:GetObjectType() == "Button" then btns[#btns + 1] = c end
    end
    local idle = btns[ns.NalaStyleOn() and 2 or 1]
    if idle then idle:SetAlpha(0.4) end
    return y
end
