local ADDON, ns = ...

ns.ADDON = ADDON

ns.defaults = {
    combineNameTarget = true,
    mainTargetName    = true,
    mainIconBorder    = true,
    classColorTarget  = true,
    tbbIconBorder     = true,
    cdmOverflowFirst  = true,
    cdmWrapCount      = 0,
    cdmWrapSide       = "LEFT",
    cdmHidePassive    = false,
    barKeysFollow     = true,
    barAutoFill       = true,
}

function ns.EUI() return _G.EllesmereUI end

function ns.ModuleNS(folder)
    local eui = ns.EUI()
    local reg = eui and eui._ModuleNS
    return reg and reg[folder]
end

function ns.UFProfile()
    local eui = ns.EUI()
    local lite = eui and eui.Lite
    for _, entry in ipairs((lite and lite._dbRegistry) or {}) do
        if entry.folder == "EllesmereUIUnitFrames" and entry.profile then
            return entry.profile
        end
    end
end

function ns.MiniBgFrame()
    local uf = _G.EllesmereUIUnitFrames_Player
    local cb = uf and uf.Castbar
    return cb and cb:GetParent(), cb
end

-- ------------------------------------------------------------------- settings

-- profile-nested so the settings travel with EUI profile export/import;
-- resolved per call (EUI re-points db.profile on every profile switch)
function ns.S()
    local prof = ns.UFProfile()
    if not prof then return ns.legacy or ns.defaults end
    local t = prof.thingsTweaks
    if not t and prof.castbarTweaks then
        t = prof.castbarTweaks
        prof.thingsTweaks = t
        prof.castbarTweaks = nil
    end
    if not t then
        t = {}
        prof.thingsTweaks = t
    end
    for k, v in pairs(ns.defaults) do
        if t[k] == nil then
            local lv = ns.legacy and ns.legacy[k]
            if lv == nil then lv = v end
            t[k] = lv
        end
    end
    return t
end

function ns.SetOpt(k, v)
    ns.S()[k] = v
    if ns.legacy then ns.legacy[k] = v end
end

-- ------------------------------------------------- retired settings cleanup

-- earlier versions planted these; player castbarWidth has no EUI writer,
-- so any value there is ours to remove
local function CleanRetired()
    local prof = ns.UFProfile()
    if prof and prof.player and prof.player.castbarWidth ~= nil then
        prof.player.castbarWidth = nil
    end
    local t = prof and prof.castbarTweaks
    if t then t.keepWidthMatch = nil end
    -- retired in 9.x: fill fixed upstream (differently), seam fix adopted verbatim;
    -- our _sb plant now armed an engine timer EUI's fill paths can't cancel
    local tw = prof and prof.thingsTweaks
    if tw then tw.fixMainFill = nil; tw.ufIconSeam = nil end
    if ns.legacy then
        ns.legacy.keepWidthMatch = nil
        ns.legacy.fixMainFill = nil
        ns.legacy.ufIconSeam = nil
    end
    local bar = _G.ERB_CastBar
    if bar and bar._sb == bar then bar._sb = nil end
end

-- ------------------------------------------------------------- module wiring

-- maintainers: idempotent install/apply passes, run at boot and once per second
-- (hook installation, late frames, profile switches). bootOnly: run once after
-- login. onRegen / onSpecApply: dispatched from the shared handlers below.
ns.maintainers = { CleanRetired }
ns.bootOnly    = {}
ns.onRegen     = {}
ns.onSpecApply = {}

-- Surfaced, deduped error reporting: a chat line (visible with scriptErrors
-- off) plus the standard error handler (BugSack/dialog). Never silent.
local reported = {}
function ns.ReportError(err)
    err = tostring(err)
    if reported[err] then return end
    reported[err] = true
    print("|cff8AC8FFthings|r error: " .. err)
    geterrorhandler()(err)
end

local function RunAll(list)
    for i = 1, #list do
        -- isolation, not silencing: EUI updates mid-week, and one module's
        -- drifted assumption must not kill every module registered after it
        local ok, err = pcall(list[i])
        if not ok then ns.ReportError(err) end
    end
end

local specHooked = false
local function HookSpecApply()
    if specHooked then return end
    local eui = ns.EUI()
    if not (eui and type(eui.SpecOverrides_Apply) == "function") then return end
    specHooked = true
    hooksecurefunc(eui, "SpecOverrides_Apply", function()
        RunAll(ns.onSpecApply)
    end)
end
ns.maintainers[#ns.maintainers + 1] = HookSpecApply

-- ----------------------------------------------------------------------- boot

-- the addon's old folder ships as a TOC-only bridge declaring the same
-- SavedVariables; loading it reads the old settings file into our global
local OLD_FOLDER = "EllesmereUIThings"
local adoptTried = false

function ns.AdoptOldDB()
    if adoptTried or _G.EUI_ThingsTweaksDB ~= nil or ns.ADDON == OLD_FOLDER then return end
    adoptTried = true
    if not C_AddOns.DoesAddOnExist(OLD_FOLDER) then return end
    local ok, reason = C_AddOns.LoadAddOn(OLD_FOLDER)
    if not ok then
        print("|cff8AC8FFthings|r for EUI: could not load your old settings (" .. tostring(reason) .. "). Enable \"things for EUI (old settings)\" and /reload.")
    end
end

local function InitDB()
    ns.AdoptOldDB()
    _G.EUI_ThingsTweaksDB = _G.EUI_ThingsTweaksDB or {}
    ns.legacy = _G.EUI_ThingsTweaksDB
    for k, v in pairs(ns.defaults) do
        if ns.legacy[k] == nil then ns.legacy[k] = v end
    end
end

local function Boot()
    RunAll(ns.maintainers)
    RunAll(ns.bootOnly)
    -- safety net for late frames, profile switches, and retired-key residue
    C_Timer.NewTicker(1, function() RunAll(ns.maintainers) end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        InitDB()
        if ns.InstallConfigPanel then ns.InstallConfigPanel() end
        C_Timer.After(1, Boot)
    elseif event == "PLAYER_REGEN_ENABLED" then
        RunAll(ns.onRegen)
    end
end)
