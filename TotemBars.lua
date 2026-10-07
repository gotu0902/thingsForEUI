local _, ns = ...

-- ------------------------------------------------ tracking bars: totem duration

-- EUI's Tracking Bars fill from duration handles (spell/charge/aura objects),
-- but totems have none -- the totem carries the clock (GetTotemInfo, plain in
-- 12.1) while the aura looks passive, so totem-backed bars (Consecration &co)
-- fail open to a full bar. This lane drives a marked bar from the totem timer,
-- plus an optional buff-presence color (totem up but player outside it).
-- Settings live ON EUI's bar config, so they ride their per-spec profiles and
-- exports. Runtime cost: a 10Hz ticker that EXISTS only while a marked totem
-- is active (EUI's own self-timed-bar cadence), zero idle.

local function CDM() return ns.ModuleNS("EllesmereUICooldownManager") end

local function Bars()
    local cdm = CDM()
    local t = cdm and cdm.GetTrackedBuffBars and cdm.GetTrackedBuffBars()
    return t and t.bars
end

local nameMemo = {}
local function SpellName(id)
    local n = nameMemo[id]
    if n == nil then
        n = (C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or false
        nameMemo[id] = n
    end
    return n or nil
end

local COLOR_ON  = { r = 0.2,  g = 0.8,  b = 0.3 }
local COLOR_OFF = { r = 0.9,  g = 0.15, b = 0.15 }

-- Active windows per tracked spellID. GetTotemInfo is PLAIN out of combat but
-- SECRET in combat (all four returns), so no Lua math can touch combat reads.
-- Model: OOC scans are the exact truth AND teach each spell's totem duration
-- (persisted account-wide); in combat the window is armed off the player's
-- own UNIT_SPELLCAST_SUCCEEDED (plain spellID) with the learned duration --
-- the same cast-triggered pattern EUI's potion/lust preset bars use.
local windows = {}
local MapBuffChildren   -- defined below, used by the OOC scan
local ScheduleWarnEval  -- defined below, called from every window arm

local function LearnedDur()
    if not ns.legacy then return nil end
    ns.legacy.totemDur = ns.legacy.totemDur or {}
    return ns.legacy.totemDur
end

local function ScanTotems()
    local bars = Bars()
    if not bars then return end
    local map
    for slot = 1, 4 do
        local haveTotem, totemName, startTime, duration = GetTotemInfo(slot)
        -- combat: every return is secret and even the boolean test throws;
        -- bail before touching them and let cast-armed windows carry on
        if issecretvalue and issecretvalue(haveTotem) then return end
        if haveTotem and totemName and totemName ~= "" and duration and duration > 0 then
            map = map or {}
            map[totemName:lower()] = { expiry = (startTime or 0) + duration, duration = duration }
        end
    end
    -- plain read = we are out of combat: refresh the buff-child map too
    MapBuffChildren()
    -- authoritative sync + duration teaching
    local learned = LearnedDur()
    for _, cfg in ipairs(bars) do
        if cfg.twTotem and cfg.spellID then
            local nm = SpellName(cfg.spellID)
            local t = nm and map and map[nm:lower()]
            if t then
                windows[cfg.spellID] = t
                if learned then learned[cfg.spellID] = t.duration end
                if ScheduleWarnEval then ScheduleWarnEval(t.expiry) end
            else
                windows[cfg.spellID] = nil
            end
        end
    end
end

-- Buff presence: direct aura queries are dead for non-whitelisted auras in
-- combat (12.x), but Blizzard's own tracked-buff viewer child knows C-side --
-- IsActive() is plain and combat-callable (EUI reads it every tick). Map
-- buffID -> child while the ids are plain (OOC), then trust the cache.
local buffChild = {}
MapBuffChildren = function()
    local viewer = _G.BuffBarCooldownViewer
    local pool = viewer and viewer.itemFramePool
    if not (pool and pool.EnumerateActive) then return end
    -- full rebuild: released pool frames must not linger as stale mappings
    wipe(buffChild)
    local gci = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
    if not gci then return end
    local function PlainID(v)
        if issecretvalue and issecretvalue(v) then return nil end
        if type(v) == "number" then return v end
    end
    for child in pool:EnumerateActive() do
        local cd = PlainID(child.cooldownID)
        local info = cd and gci(cd)
        if info then
            local a, b = PlainID(info.spellID), PlainID(info.overrideSpellID)
            if a then buffChild[a] = child end
            if b then buffChild[b] = child end
            if info.linkedSpellIDs then
                for _, lid in ipairs(info.linkedSpellIDs) do
                    local pl = PlainID(lid)
                    if pl then buffChild[pl] = child end
                end
            end
        end
    end
end

local function BuffPresent(buffID)
    -- direct query is exact and works out of combat; the viewer child's
    -- C-side IsActive covers combat, where the aura API returns nothing
    if not InCombatLockdown()
        and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        return C_UnitAuras.GetPlayerAuraBySpellID(buffID) ~= nil
    end
    local child = buffChild[buffID]
    if child and child.IsActive then
        return child:IsActive() and true or false
    end
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        return C_UnitAuras.GetPlayerAuraBySpellID(buffID) ~= nil
    end
    return true
end

-- combat arm: own cast edge + learned duration (first OOC cast teaches it)
local function OnPlayerCast(spellID)
    if issecretvalue and issecretvalue(spellID) then return end
    local bars = Bars()
    if not bars then return end
    local learned = LearnedDur()
    local castName = SpellName(spellID)
    for _, cfg in ipairs(bars) do
        if cfg.twTotem and cfg.enabled ~= false and cfg.spellID then
            -- tracked-buff entries carry the AURA's spellID (Consecration buff
            -- 188370) while the cast fires the SPELL id (26573): match by name
            -- too, the same identity the totem scan uses
            local match = cfg.spellID == spellID or cfg.baseSpellID == spellID
            if not match and castName then
                match = castName == SpellName(cfg.spellID)
            end
            if match then
                local dur = learned and learned[cfg.spellID]
                if dur and dur > 0 then
                    local expiry = GetTime() + dur
                    windows[cfg.spellID] = { expiry = expiry, duration = dur }
                    if ScheduleWarnEval then ScheduleWarnEval(expiry) end
                end
            end
        end
    end
end

-- Drives every marked bar with a live totem window; returns true while any is
-- live. Runs AFTER EUI's own tick pass too (wrapper below), so both writers
-- land in the same execution and only our values ever render.
local function DriveTotemBars()
    local bars = Bars()
    if not bars then return false end
    local cdm = CDM()
    if cdm and cdm._tbbPlaceholderMode then return true end
    local now = GetTime()
    local smoothE = Enum and Enum.StatusBarInterpolation
        and Enum.StatusBarInterpolation.ExponentialEaseOut
    local anyLive = false
    for i, cfg in ipairs(bars) do
        if cfg.twTotem and cfg.enabled ~= false and cfg.spellID then
            local bar = _G["ECME_TBBWrap" .. i]
            local sb = bar and bar._bar
            if sb then
                local t = windows[cfg.spellID]
                local remaining = t and (t.expiry - now) or 0
                if remaining > 0 then
                    anyLive = true
                    local wasShown = bar:IsShown()
                    if not wasShown then bar:Show() end
                    sb:SetMinMaxValues(0, t.duration)
                    if wasShown and smoothE then
                        sb:SetValue(remaining, smoothE)
                    else
                        sb:SetValue(remaining)
                    end
                    if cfg.showSpark and bar._spark then bar._spark:Show() end
                    -- unconditional write: EUI's pass blanks/hides this
                    -- FontString every tick for auras it can't time, so a
                    -- dedupe stamp here leaves it empty between bucket flips
                    if cfg.showTimer and bar._timerText then
                        if remaining < 10 then
                            bar._timerText:SetFormattedText("%.1f", remaining)
                        else
                            bar._timerText:SetFormattedText("%d", remaining)
                        end
                        -- invalidate their stamp so their next writer can't
                        -- skip its own rewrite and strand our text
                        bar._stTxtKey = nil
                        bar._timerText:Show()
                    end
                    -- buff-presence color: totem up but the buff missing means
                    -- the player is standing outside their own ground effect
                    local buffID = cfg.twBuffID
                    if buffID and buffID > 0 then
                        local c = BuffPresent(buffID) and (cfg.twColorOn or COLOR_ON)
                            or (cfg.twColorOff or COLOR_OFF)
                        sb:SetStatusBarColor(c.r, c.g, c.b, 1)
                    end
                    bar._twDriving = true
                elseif bar._twDriving then
                    -- window just ended: clear our leftovers once (their idle
                    -- painter never touches timer text or spark), then hands
                    -- off entirely -- EUI's pass owns idle/hide
                    bar._twDriving = nil
                    if bar._timerText then bar._timerText:SetText(""); bar._timerText:Hide() end
                    if bar._spark then bar._spark:Hide() end
                    bar._stTxtKey = nil
                    if cfg.twBuffID then
                        local c = cfg.twColorOn or COLOR_ON
                        sb:SetStatusBarColor(c.r, c.g, c.b, 1)
                    end
                end
            end
        end
    end
    return anyLive
end

-- ------------------------------------------------------------ combat warning

-- "NO CONSECRATION": with the totem window dead and the buff missing, show
-- the bar's custom warning text, anchored to the bar itself (or screen
-- center) at a chosen side + offsets. Fully event-driven, no ticker: combat
-- edges are events, window arms are our own writes, window death is a known
-- plain timestamp (one-shot timer per arm), and buff flips ride UNIT_AURA
-- registered only while a warning could actually show.
local WARN_COLOR = { r = 1, g = 0.1, b = 0.1 }
local warnFrames = {}
local warnPreview = false
local UpdateAuraWatch  -- defined next to the event frame below

-- warn frame sits OUTSIDE the bar on the chosen side (own opposite point)
local WARN_ATTACH = {
    TOP = "BOTTOM", BOTTOM = "TOP", LEFT = "RIGHT", RIGHT = "LEFT",
    CENTER = "CENTER",
}

local function WarnFrame(i, cfg)
    local f = warnFrames[i]
    if not f then
        f = CreateFrame("Frame", nil, UIParent)
        f:SetFrameStrata("HIGH")
        f.text = f:CreateFontString(nil, "OVERLAY")
        f.text:SetPoint("CENTER")
        f:Hide()
        warnFrames[i] = f
    end
    local eui = ns.EUI()
    local fp = eui and eui.GetFontPath and eui.GetFontPath("unitFrames")
    f.text:SetFont(fp or STANDARD_TEXT_FONT, cfg.twWarnSize or 24, "OUTLINE")
    local c = cfg.twWarnColor or WARN_COLOR
    f.text:SetTextColor(c.r, c.g, c.b, 1)
    f.text:SetText(cfg.twWarnText or "")
    f:SetSize(math.max(20, f.text:GetStringWidth() + 8), (cfg.twWarnSize or 24) + 8)
    local point = cfg.twWarnPoint or "TOP"
    local ox, oy = cfg.twWarnX or 0, cfg.twWarnY or 0
    -- anchoring to the (possibly hidden) bar wrap keeps the text glued to
    -- wherever the user placed that bar; rects persist through Hide
    local bar = _G["ECME_TBBWrap" .. i]
    f:ClearAllPoints()
    if point == "SCREEN" or not (bar and bar:GetLeft()) then
        f:SetPoint("CENTER", UIParent, "CENTER", ox, oy)
    else
        f:SetPoint(WARN_ATTACH[point] or "BOTTOM", bar, point, ox, oy)
    end
    return f
end

local function AnyWarnCfg()
    local bars = Bars()
    if not bars then return false end
    for _, cfg in ipairs(bars) do
        if cfg.twTotem and cfg.enabled ~= false and cfg.twWarnText and cfg.twWarnText ~= "" then
            return true
        end
    end
    return false
end

local function UpdateWarnings()
    if warnPreview then return end
    local bars = Bars()
    if not bars then return end
    local now = GetTime()
    local inCombat = UnitAffectingCombat and UnitAffectingCombat("player") or InCombatLockdown()
    for i, cfg in ipairs(bars) do
        local want = false
        -- combat-only is the default; explicit false shows it out of combat too
        if (inCombat or cfg.twWarnCombatOnly == false)
            and cfg.twTotem and cfg.enabled ~= false
            and cfg.twWarnText and cfg.twWarnText ~= "" then
            local t = windows[cfg.spellID or 0]
            local live = t and (t.expiry - now) > 0
            if not live and not (cfg.twBuffID and BuffPresent(cfg.twBuffID)) then
                want = true
            end
        end
        if want then
            WarnFrame(i, cfg):Show()
        elseif warnFrames[i] then
            warnFrames[i]:Hide()
        end
    end
end

-- one-shot re-evaluation at a window's known expiry (plus a hair for the
-- buff to actually drop); stale timers just re-run the idempotent check
ScheduleWarnEval = function(expiry)
    if not AnyWarnCfg() then return end
    local delay = expiry - GetTime() + 0.2
    if delay > 0 then C_Timer.After(delay, UpdateWarnings) end
end

-- any warning configured to also show out of combat (needs UNIT_AURA idle)
local function AnyWarnAlways()
    local bars = Bars()
    if not bars then return false end
    for _, cfg in ipairs(bars) do
        if cfg.twTotem and cfg.enabled ~= false
            and cfg.twWarnText and cfg.twWarnText ~= ""
            and cfg.twWarnCombatOnly == false then
            return true
        end
    end
    return false
end

-- live preview while our config section is on screen, so look and placement
-- are visible while editing; page-wrapper OnShow/OnHide is the exact page
-- lifecycle (leave/close hide it, cached re-show brings it back)
local function SetWarnPreview(on)
    warnPreview = on and true or false
    if warnPreview then
        local bars = Bars()
        for i, cfg in ipairs(bars or {}) do
            if cfg.twTotem and cfg.enabled ~= false
                and cfg.twWarnText and cfg.twWarnText ~= "" then
                WarnFrame(i, cfg):Show()
            elseif warnFrames[i] then
                warnFrames[i]:Hide()
            end
        end
    else
        for _, f in pairs(warnFrames) do f:Hide() end
        UpdateWarnings()
    end
end

-- window ticker: exists only while a marked totem runs
local windowTicker
local function StopWindow()
    if windowTicker then windowTicker:Cancel(); windowTicker = nil end
end
local function StartWindow()
    if windowTicker then return end
    windowTicker = C_Timer.NewTicker(0.1, function()
        if not DriveTotemBars() then StopWindow() end
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_TOTEM_UPDATE")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

-- buff flips are the only warning input without a known timestamp; watch
-- them only while a warning could show (dynamic registration, zero idle
-- with the default combat-only setup)
UpdateAuraWatch = function()
    local inCombat = UnitAffectingCombat and UnitAffectingCombat("player")
    if AnyWarnCfg() and (inCombat or AnyWarnAlways()) then
        ev:RegisterUnitEvent("UNIT_AURA", "player")
    else
        ev:UnregisterEvent("UNIT_AURA")
    end
end

ev:SetScript("OnEvent", function(self, event, _, _, spellID)
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        UpdateAuraWatch()
        UpdateWarnings()
        return
    elseif event == "UNIT_AURA" then
        UpdateWarnings()
        return
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if type(spellID) == "number" then OnPlayerCast(spellID) end
        UpdateWarnings()
    else
        -- PLAYER_TOTEM_UPDATE / PLAYER_ENTERING_WORLD
        ScanTotems()
        UpdateAuraWatch()
        UpdateWarnings()
    end
    if DriveTotemBars() then StartWindow() else StopWindow() end
end)

-- ride EUI's own tick while it is awake: their pass writes first (fail-open /
-- hide), ours overwrites in the same execution -- one render, no flicker
local tbbWrapped
local function WrapTBBTick()
    local cdm = CDM()
    if not cdm then return end
    local cur = cdm.UpdateTrackedBuffBarTimers
    if not cur or cur == tbbWrapped then return end
    local orig = cur
    tbbWrapped = function(...)
        orig(...)
        if windowTicker then DriveTotemBars() end
    end
    cdm.UpdateTrackedBuffBarTimers = tbbWrapped
end
ns.maintainers[#ns.maintainers + 1] = WrapTBBTick

-- retired unlock-drag position field: strip it so exports stay clean
ns.bootOnly[#ns.bootOnly + 1] = function()
    for _, cfg in ipairs(Bars() or {}) do cfg.twWarnPos = nil end
end

-- --------------------------------------------------------------- config section

local selBar = 1

-- Buff candidates: Blizzard's tracked-buff category (what EUI's own picker
-- lists under "Buffs") plus the bar's own spell.
local function PlainID(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function BuffCandidates(ownSpellID)
    local values, order = { NONE = "None" }, { "NONE" }
    local seen = {}
    local function add(sid)
        if not sid or sid <= 0 or seen[sid] then return end
        seen[sid] = true
        local nm = SpellName(sid)
        if not nm then return end
        local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
        local icon = info and info.iconID
        local key = tostring(sid)
        values[key] = icon and ("|T" .. icon .. ":14:14|t " .. nm) or nm
        order[#order + 1] = key
    end
    add(ownSpellID)
    local cat = Enum.CooldownViewerCategory and Enum.CooldownViewerCategory.TrackedBuff
    if cat and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
        local ids = C_CooldownViewer.GetCooldownViewerCategorySet(cat, true)
        for _, cdID in ipairs(ids or {}) do
            local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
            if info then
                add(PlainID(info.overrideSpellID))
                add(PlainID(info.spellID))
            end
        end
    end
    return values, order
end

function ns.BuildTotemBarsSection(parent, y)
    local eui = ns.EUI()
    local W = eui and eui.Widgets
    if not W then return y end
    local _, h

    _, h = W:SectionHeader(parent, "TRACKING BARS - TOTEM DURATION", y); y = y - h

    local bars = Bars()
    if not bars or #bars == 0 then
        local none = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        none:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
        none:SetText("No tracking bars for this spec yet - add one under Cooldown Manager -> Tracking Bars.")
        return y - 26
    end
    if not bars[selBar] then selBar = 1 end

    local function RefreshPanel()
        if eui.RefreshPage then eui:RefreshPage(true) end
    end

    local barValues, barOrder = {}, {}
    for i, cfg in ipairs(bars) do
        local key = tostring(i)
        local nm = cfg.name or ("Bar " .. i)
        local sp = cfg.spellID and SpellName(cfg.spellID)
        barValues[key] = sp and (nm .. "  |cff888888" .. sp .. "|r") or nm
        barOrder[#barOrder + 1] = key
    end
    _, h = W:WideDropdown(parent, "Bar", y, barValues,
        function() return tostring(selBar) end,
        function(v)
            selBar = tonumber(v) or 1
            RefreshPanel()
        end, barOrder); y = y - h

    local cfg = bars[selBar]
    if not cfg then return y end

    _, h = W:Toggle(parent, "Totem Duration", y,
        function() return cfg.twTotem and true or false end,
        function(v)
            cfg.twTotem = v and true or nil
            ScanTotems()
            if DriveTotemBars() then StartWindow() end
            RefreshPanel()
        end,
        "Drives this bar's fill and timer from the totem with the same name as the tracked spell (Consecration-style ground effects, where the buff itself has no duration)."); y = y - h

    if cfg.twTotem then
        local values, order = BuffCandidates(cfg.spellID)
        _, h = W:WideDropdown(parent, "Color by Buff", y, values,
            function() return cfg.twBuffID and tostring(cfg.twBuffID) or "NONE" end,
            function(v)
                cfg.twBuffID = (v ~= "NONE") and tonumber(v) or nil
                RefreshPanel()
            end, order); y = y - h

        if cfg.twBuffID then
            _, h = W:ColorPicker(parent, "Buff Active Color", y,
                function()
                    local c = cfg.twColorOn or COLOR_ON
                    return c.r, c.g, c.b, 1
                end,
                function(r, g, b)
                    cfg.twColorOn = { r = r, g = g, b = b }
                end); y = y - h
            _, h = W:ColorPicker(parent, "Buff Missing Color", y,
                function()
                    local c = cfg.twColorOff or COLOR_OFF
                    return c.r, c.g, c.b, 1
                end,
                function(r, g, b)
                    cfg.twColorOff = { r = r, g = g, b = b }
                end); y = y - h
        end

        -- combat warning text ("NO CONSECRATION")
        local warnBox = CreateFrame("EditBox", nil, parent)
        warnBox:SetSize(280, 22)
        warnBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y - 2)
        warnBox:SetAutoFocus(false)
        warnBox:SetFontObject(GameFontHighlightSmall)
        warnBox:SetTextInsets(6, 6, 0, 0)
        warnBox:SetMaxLetters(60)
        local wbg = warnBox:CreateTexture(nil, "BACKGROUND")
        wbg:SetAllPoints()
        wbg:SetColorTexture(0, 0, 0, 0.4)
        warnBox:SetText(cfg.twWarnText or "")
        local warnHint = warnBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        warnHint:SetPoint("LEFT", 6, 0)
        warnHint:SetText("Combat warning text (empty = off), e.g. NO CONSECRATION...")
        warnHint:SetShown((cfg.twWarnText or "") == "")
        warnBox:SetScript("OnTextChanged", function(self)
            warnHint:SetShown(self:GetText() == "")
        end)
        warnBox:SetScript("OnEscapePressed", warnBox.ClearFocus)
        local function CommitWarn()
            local txt = warnBox:GetText():gsub("^%s+", ""):gsub("%s+$", "")
            cfg.twWarnText = (txt ~= "") and txt or nil
            warnBox:ClearFocus()
            UpdateAuraWatch()
            RefreshPanel()
        end
        warnBox:SetScript("OnEnterPressed", CommitWarn)
        warnBox:SetScript("OnEditFocusLost", CommitWarn)
        y = y - 28

        if cfg.twWarnText and cfg.twWarnText ~= "" then
            _, h = W:Toggle(parent, "Only in Combat", y,
                function() return cfg.twWarnCombatOnly ~= false end,
                function(v)
                    cfg.twWarnCombatOnly = v and nil or false
                    UpdateAuraWatch()
                    SetWarnPreview(true)
                end); y = y - h
            _, h = W:DropdownWithOffsets(parent, y,
                {
                    text = "Position",
                    values = {
                        TOP = "Above Bar", BOTTOM = "Below Bar",
                        LEFT = "Left of Bar", RIGHT = "Right of Bar",
                        CENTER = "On Bar", SCREEN = "Screen Center",
                    },
                    order = { "TOP", "BOTTOM", "LEFT", "RIGHT", "CENTER", "SCREEN" },
                    getValue = function() return cfg.twWarnPoint or "TOP" end,
                    setValue = function(v)
                        cfg.twWarnPoint = (v ~= "TOP") and v or nil
                        SetWarnPreview(true)
                    end,
                },
                {
                    text = "X", min = -500, max = 500, step = 1,
                    getValue = function() return cfg.twWarnX or 0 end,
                    setValue = function(v)
                        cfg.twWarnX = (v ~= 0) and v or nil
                        SetWarnPreview(true)
                    end,
                },
                {
                    text = "Y", min = -500, max = 500, step = 1,
                    getValue = function() return cfg.twWarnY or 0 end,
                    setValue = function(v)
                        cfg.twWarnY = (v ~= 0) and v or nil
                        SetWarnPreview(true)
                    end,
                }); y = y - h
            _, h = W:Slider(parent, "Warning Text Size", y, 10, 48, 1,
                function() return cfg.twWarnSize or 24 end,
                function(v)
                    cfg.twWarnSize = v
                    SetWarnPreview(true)
                end); y = y - h
            _, h = W:ColorPicker(parent, "Warning Text Color", y,
                function()
                    local c = cfg.twWarnColor or WARN_COLOR
                    return c.r, c.g, c.b, 1
                end,
                function(r, g, b)
                    cfg.twWarnColor = { r = r, g = g, b = b }
                    SetWarnPreview(true)
                end); y = y - h
            local hint = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
            hint:SetText("Shows when the totem is down and the buff is missing. Previewed while this window is open.")
            y = y - 22
        end
    end

    -- preview lives and dies with the page wrapper (EUI hides/shows cached pages)
    if not parent._twWarnPreviewHooked then
        parent._twWarnPreviewHooked = true
        parent:HookScript("OnShow", function() SetWarnPreview(true) end)
        parent:HookScript("OnHide", function() SetWarnPreview(false) end)
    end
    SetWarnPreview(true)

    return y
end
