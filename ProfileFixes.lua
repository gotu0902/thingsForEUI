local _, ns = ...

-- ------------------------------------------- spec-profile swap: mini frames

-- EUI bug: on a spec-driven profile swap, a mini frame's "Enable X Frame"
-- state only lands if the unit happens to exist (enable) or the frame happens
-- to be shown (disable) at the exact ReloadFrames moment -- ToggleFrame gates
-- both edges on live state. The unit watch itself is registered once at spawn
-- and polls the "unit" attribute live, so the ATTRIBUTE is the whole switch:
-- enforce it from the DB and the watch does the rest within its poll tick.
local MINIS = {
    targettarget = "EllesmereUIUnitFrames_TargetTarget",
    focustarget  = "EllesmereUIUnitFrames_FocusTarget",
    pet          = "EllesmereUIUnitFrames_Pet",
}

local function EnforceMiniFrames()
    if InCombatLockdown() then return end
    local prof = ns.UFProfile()
    local ef = prof and prof.enabledFrames
    if not ef then return end
    local touched = false
    for unit, gname in pairs(MINIS) do
        local frame = _G[gname]
        -- driver-owned minis (parent visibility conditions) are EUI's to manage
        if frame and not frame._euiVisDriver then
            local want = ef[unit] ~= false
            local attr = frame:GetAttribute("unit")
            if want and attr == nil then
                frame:SetAttribute("unit", unit)
                -- idempotent; also heals a frame left watchless by older builds
                RegisterUnitWatch(frame)
                touched = true
            elseif not want and attr ~= nil then
                frame:SetAttribute("unit", nil)
                frame:Hide()
                touched = true
            end
        end
    end
    if touched then
        local uf = ns.ModuleNS("EllesmereUIUnitFrames")
        if uf and uf.ReloadFrames then uf.ReloadFrames() end
    end
end

-- EUI only spawns a mini frame at login when the profile active THEN has it
-- enabled, and registers its mover once right after. Log in on a profile with
-- it off and a swap to one with it on has no frame to show until a reload.
-- While that login build runs, a mini frame some other profile uses resolves
-- as EUI's own, so EUI spawns and registers it as usual; afterwards every
-- reader sees the real value and the live toggles above do the rest.
local function EnabledElsewhere(unit)
    local db = _G.EllesmereUIDB
    local active = db and (db.activeProfile or "Default")
    for name, p in pairs((db and db.profiles) or {}) do
        if name ~= active and type(p) == "table" then
            local uf = p.addons and p.addons.EllesmereUIUnitFrames
            local ef = type(uf) == "table" and uf.enabledFrames
            if type(ef) == "table" and ef[unit] ~= false then return true end
        end
    end
    return false
end

do
    local uf = ns.ModuleNS("EllesmereUIUnitFrames")
    local orig = uf and uf.GetUnitFrameSource
    if type(orig) == "function" then
        uf.GetUnitFrameSource = function(unit, ...)
            local src = orig(unit, ...)
            local gname = MINIS[unit]
            if src == "hidden" and gname then
                local eui = ns.EUI()
                local reg = eui and eui._unlockRegisteredElements
                if (not _G[gname] or not (reg and reg[unit])) and EnabledElsewhere(unit) then
                    return "eui"
                end
            end
            return src
        end
    end
end

-- its mover only knows Visibility "never"; a disabled frame has nothing to drag
local function WrapMiniMovers()
    local eui = ns.EUI()
    local reg = eui and eui._unlockRegisteredElements
    if not reg then return end
    for unit in pairs(MINIS) do
        local elem = reg[unit]
        if elem and not elem._tweaksEnableAware then
            local orig = elem.isHidden
            elem.isHidden = function(...)
                local prof = ns.UFProfile()
                local ef = prof and prof.enabledFrames
                if ef and ef[unit] == false then return true end
                if orig then return orig(...) end
                return false
            end
            elem._tweaksEnableAware = true
        end
    end
end
ns.maintainers[#ns.maintainers + 1] = WrapMiniMovers

local enforceQueued = false
local function QueueEnforce(delay)
    if enforceQueued then return end
    enforceQueued = true
    C_Timer.After(delay or 0.6, function()
        enforceQueued = false
        EnforceMiniFrames()
    end)
end

-- ------------------------------------------------- login width/height match

-- EUI bug: a height/width match against a CDM bar (e.g. target castbar ->
-- utility) can read the target before it reaches its final login size, and
-- the settle pass fires too early to catch it. Re-run EUI's own idempotent
-- match + anchor passes after everything has landed; mirrors the flags and
-- pcall of EUI's own settle block (mid-load target states are theirs).
local function ReapplyMatches()
    if InCombatLockdown() then return end
    local eui = ns.EUI()
    if not eui then return end
    local wdb = _G.EllesmereUIDB and _G.EllesmereUIDB.unlockWidthMatch
    local hdb = _G.EllesmereUIDB and _G.EllesmereUIDB.unlockHeightMatch
    if not ((wdb and next(wdb)) or (hdb and next(hdb))) then return end
    if eui.ApplyAllWidthHeightMatches then
        eui._settleReapplyInProgress = true
        eui._settleSuppressUntil = GetTime() + 0.75
        pcall(eui.ApplyAllWidthHeightMatches)
        eui._settleReapplyInProgress = false
    end
    if eui.ReapplyAllUnlockAnchorsForced then
        eui._settleReapplyInProgress = true
        eui._settleSuppressUntil = GetTime() + 0.75
        pcall(eui.ReapplyAllUnlockAnchorsForced)
        eui._settleReapplyInProgress = false
    end
end
ns.ReapplyMatches = ReapplyMatches

-- ------------------------------------- spec-profile swap: unit frame sizes

-- EUI bug: UF caches each unit's settings table and only re-reads it in its
-- throttled ReloadFrames tick, while a profile swap repoints the DB at once.
-- A size write in between (the spec-layer flush CDM's SPELLS_CHANGED rebuild
-- runs, match propagation) lands in the profile being LEFT, which then shows
-- the other profile's width next time. Nothing may write a profile after it
-- is left, so whatever changed there is put back.
local UF_UNITS = { "player", "target", "focus", "pet", "targettarget", "focustarget", "boss" }
local UF_SIZE_KEYS = { "frameWidth", "healthHeight" }

local function UFData(profName)
    local db = _G.EllesmereUIDB
    local p = db and db.profiles and db.profiles[profName]
    return p and p.addons and p.addons.EllesmereUIUnitFrames
end

local function SizeSnapshot(profName)
    local uf = UFData(profName)
    if not uf then return end
    local snap = {}
    for _, unit in ipairs(UF_UNITS) do
        local s = uf[unit]
        if type(s) == "table" then
            snap[unit] = { frameWidth = s.frameWidth, healthHeight = s.healthHeight }
        end
    end
    return snap
end

local function ActiveName()
    local db = _G.EllesmereUIDB
    return db and (db.activeProfile or "Default")
end

-- UF sync excludes these keys, so even synced profiles never share them
local function RestoreLeft(name, snap)
    local active = ActiveName()
    if not active or active == name then return end
    local uf = UFData(name)
    if not uf then return end
    local fixed = false
    for unit, vals in pairs(snap) do
        local s = uf[unit]
        if type(s) == "table" then
            for _, k in ipairs(UF_SIZE_KEYS) do
                if s[k] ~= vals[k] then
                    s[k] = vals[k]
                    fixed = true
                end
            end
        end
    end
    if fixed then
        print("|cff8AC8FFthings|r undid EUI writing unit frame sizes into " .. name .. " after leaving it.")
    end
end

local leaving
local guardHooked = false
local function HookSizeGuard()
    if guardHooked then return end
    local eui = ns.EUI()
    if not (eui and type(eui.SwitchProfile) == "function"
        and type(eui.SpecOverrides_HarvestCurrent) == "function") then return end
    guardHooked = true
    -- SwitchProfile runs this before it repoints: the outgoing data is still clean
    hooksecurefunc(eui, "SpecOverrides_HarvestCurrent", function()
        local name = ActiveName()
        leaving = name and { name = name, snap = SizeSnapshot(name) }
    end)
    hooksecurefunc(eui, "SwitchProfile", function()
        local l = leaving
        leaving = nil
        if not (l and l.snap) or ActiveName() == l.name then return end
        -- UF's reload tick, the SPELLS_CHANGED burst and a budgeted refresh all land inside this
        for _, t in ipairs({ 1, 3, 6 }) do
            C_Timer.After(t, function() RestoreLeft(l.name, l.snap) end)
        end
    end)
end
ns.maintainers[#ns.maintainers + 1] = HookSizeGuard

-- ------------------------------------------------------------------ triggers

local swapHooked = false
local function HookProfileSwap()
    if swapHooked then return end
    local eui = ns.EUI()
    if not (eui and type(eui.RefreshAllAddons) == "function") then return end
    swapHooked = true
    hooksecurefunc(eui, "RefreshAllAddons", function()
        -- raid headers rebuild during the swap; RFB stands down through it
        if ns.RaidBuilderStanddown then ns.RaidBuilderStanddown(3) end
        QueueEnforce(0.6)
        C_Timer.After(1.5, ReapplyMatches)
    end)
end
ns.maintainers[#ns.maintainers + 1] = HookProfileSwap

-- same-profile spec changes never call RefreshAllAddons; SpecOverrides_Apply
-- fires on every spec transition, so this covers both swap flavors
ns.onSpecApply[#ns.onSpecApply + 1] = function()
    QueueEnforce(1)
end

local regenOnce = false
ns.onRegen[#ns.onRegen + 1] = function()
    QueueEnforce(0.2)
    if not regenOnce then
        regenOnce = true
        C_Timer.After(1, ReapplyMatches)
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function()
    QueueEnforce(2)
    C_Timer.After(5, ReapplyMatches)
    C_Timer.After(12, ReapplyMatches)
end)
