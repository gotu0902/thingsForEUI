local _, ns = ...

local S = ns.S

-- ------------------------------------------------ utility overflow offset

-- When Utility is wider than Cooldowns, push whatever is side-anchored to the
-- Cooldowns bar outward by the measured overhang (zero while Utility fits).
-- Rides EUI's _anchorExtraOffset registry, the surface their own CDM
-- "Additional Bar Offset" uses: folded into their placement before its
-- idempotent guard, so their writer renders everything and nothing ticks.

local CD_KEY, UT_KEY = "CDM_cooldowns", "CDM_utility"

local function AnchorInfo(key)
    local db = _G.EllesmereUIDB
    local a = db and db.unlockAnchors
    local info = a and a[key]
    if info and info.target then return info end
end

local function ElemFrame(key)
    local eui = ns.EUI()
    local elems = eui and eui._unlockRegisteredElements
    local e = elems and elems[key]
    return e and e.getFrame and e.getFrame(key)
end

local function OverflowOn() return S().utilOverflow == true end
local function MinWidth() return tonumber(S().cdMinWidth) or 0 end
local function MinOn() return MinWidth() > 0 end
local function Active() return OverflowOn() or MinOn() end

-- rects persist through Hide, so visibility flips never jump anchors
local function Overhang(side)
    local cd = ElemFrame(CD_KEY)
    local ut = ElemFrame(UT_KEY)
    if not (cd and cd:GetLeft() and ut and ut:GetLeft()) then return end
    local uiS = UIParent:GetEffectiveScale()
    local cS = cd:GetEffectiveScale() / uiS
    local uS = ut:GetEffectiveScale() / uiS
    if side == "LEFT" then
        local c, u = cd:GetLeft() * cS, ut:GetLeft() * uS
        return (u < c) and (u - c) or 0
    elseif side == "RIGHT" then
        local c, u = cd:GetRight() * cS, ut:GetRight() * uS
        return (u > c) and (u - c) or 0
    end
end

-- whole pixels: EUI snaps after folding this in, so a fraction would round
-- differently per element
local function Snap(v)
    local eui = ns.EUI()
    local s = eui and eui.PP and eui.PP.Snap
    if s then return s(v) end
    return math.floor(v + 0.5)
end

-- Cooldowns counted as at least the minimum width, centred on itself
local function MinOverhang(side)
    local cd = MinOn() and ElemFrame(CD_KEY)
    if not (cd and cd:GetLeft()) then return 0 end
    local w = cd:GetWidth() * cd:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local half = (MinWidth() - w) / 2
    if half <= 0 then return 0 end
    return side == "LEFT" and -half or half
end

local function OverflowDelta(childKey)
    local eui = ns.EUI()
    -- EUI's getter convention: movers show and save the BASE
    if eui and eui._unlockActive then return 0, 0 end
    if not Active() or childKey == UT_KEY then return 0, 0 end
    local info = AnchorInfo(childKey)
    if not (info and info.target == CD_KEY) then return 0, 0 end
    if info.side ~= "LEFT" and info.side ~= "RIGHT" then return 0, 0 end
    local o = OverflowOn() and Overhang(info.side) or 0
    local m = MinOverhang(info.side)
    -- whichever reaches further out
    if info.side == "LEFT" then o = math.min(o, m) else o = math.max(o, m) end
    if o > -0.5 and o < 0.5 then return 0, 0 end
    return Snap(o), 0
end

-- width matches to Cooldowns: EUI sets _propagatingMatch around the child's
-- setWidth, so only a matched width is raised, never one the user sets
local wrapped = setmetatable({}, { __mode = "k" })

local function MinFor(key, e)
    local eui = ns.EUI()
    local f = (e.getFrame and e.getFrame(key)) or ElemFrame(key)
    local es = f and f:GetEffectiveScale()
    if not (es and es > 0) then return MinWidth() end
    local w = MinWidth() * UIParent:GetEffectiveScale() / es
    local snap = eui and eui.PP and eui.PP.SnapForES
    if snap then return snap(w, es) end
    return math.floor(w + 0.5)
end

local function WrapMatchChildren()
    local eui = ns.EUI()
    local elems = eui and eui._unlockRegisteredElements
    local wm = _G.EllesmereUIDB and _G.EllesmereUIDB.unlockWidthMatch
    if not (elems and wm) then return end
    for childKey, target in pairs(wm) do
        local e = elems[childKey]
        if target == CD_KEY and e and type(e.setWidth) == "function" and e.setWidth ~= wrapped[e] then
            local orig = e.setWidth
            local fn = function(k, w, ...)
                local live = _G.EllesmereUIDB.unlockWidthMatch
                if eui._propagatingMatch and MinOn() and type(w) == "number"
                    and live and live[k] == CD_KEY then
                    w = math.max(w, MinFor(k, e))
                end
                return orig(k, w, ...)
            end
            wrapped[e] = fn
            e.setWidth = fn
        end
    end
end

local function EachChild(fn)
    local db = _G.EllesmereUIDB
    for childKey, info in pairs((db and db.unlockAnchors) or {}) do
        if info and info.target == CD_KEY and childKey ~= UT_KEY
            and (info.side == "LEFT" or info.side == "RIGHT") then
            fn(childKey)
        end
    end
end

local getters, prevGetter = {}, {}
local function InstallGetters()
    local eui = ns.EUI()
    if not (eui and Active()) then return end
    eui._anchorExtraOffset = eui._anchorExtraOffset or {}
    local xoff = eui._anchorExtraOffset
    EachChild(function(childKey)
        -- never installed reads as "equal" too (nil == nil)
        if getters[childKey] == nil or xoff[childKey] ~= getters[childKey] then
            prevGetter[childKey] = xoff[childKey]
            local fn = function(k)
                local dx, dy = OverflowDelta(childKey)
                local prev = prevGetter[childKey]
                if prev then
                    -- foreign getter, isolated the way EUI isolates these
                    local ok, px, py = pcall(prev, k)
                    if ok and type(px) == "number" and type(py) == "number" then
                        dx, dy = dx + px, dy + py
                    end
                end
                return dx, dy
            end
            getters[childKey] = fn
            xoff[childKey] = fn
        end
    end)
end

local function ReapplyChildren()
    -- keep pushing once installed, so switching the toggle off lands too
    if not (Active() or next(getters)) then return end
    local eui = ns.EUI()
    local reapply = eui and (eui.ReapplyUnlockAnchor or eui.ReapplyOwnAnchor)
    if not reapply then return end
    EachChild(function(childKey) pcall(reapply, childKey) end)
end

local inPass = false
local function RunPass()
    inPass = true
    local ok, err = pcall(InstallGetters)
    if not ok then ns.ReportError(err) end
    if MinOn() then
        ok, err = pcall(WrapMatchChildren)
        if not ok then ns.ReportError(err) end
    end
    ok, err = pcall(ReapplyChildren)
    if not ok then ns.ReportError(err) end
    inPass = false
end

-- ------------------------------------------------- unlock-mode badges

local badges = {}
local function UpdateBadges(show)
    for _, b in pairs(badges) do b:Hide() end
    if not (show and Active()) then return end
    local label = (OverflowOn() and MinOn()) and "Utility Overflow + Min Width"
        or (MinOn() and "Min Width") or "Utility Overflow"
    EachChild(function(childKey)
        local child = ElemFrame(childKey)
        if not child then return end
        local b = badges[childKey]
        if not b then
            b = CreateFrame("Frame", nil, UIParent)
            b:SetFrameStrata("TOOLTIP")
            b:SetFrameLevel(3)
            local bg = b:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(0, 0, 0, 0.85)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.text:SetPoint("CENTER", 0, 0)
            badges[childKey] = b
        end
        b.text:SetText("|cff0dd29f" .. label .. "|r")
        b:SetSize(b.text:GetStringWidth() + 10, 16)
        b:ClearAllPoints()
        b:SetPoint("CENTER", child, "BOTTOM", 0, -10)
        b:Show()
    end)
end

local queued = false
local function QueueAP()
    if inPass or queued then return end
    queued = true
    C_Timer.After(0.05, function()
        queued = false
        local eui = ns.EUI()
        if eui and eui.IsUnlockModeActive and eui:IsUnlockModeActive() then
            UpdateBadges(true)
            return
        end
        RunPass()
    end)
end

-- ------------------------------------------------------------------ triggers

local hookedSize = setmetatable({}, { __mode = "k" })
local hookedMove = setmetatable({}, { __mode = "k" })
local function HookFrame(f, withMoves)
    if f and not hookedSize[f] then
        hookedSize[f] = true
        hooksecurefunc(f, "SetSize", QueueAP)
        hooksecurefunc(f, "SetWidth", QueueAP)
        hooksecurefunc(f, "SetHeight", QueueAP)
    end
    if f and withMoves and not hookedMove[f] then
        hookedMove[f] = true
        hooksecurefunc(f, "SetPoint", QueueAP)
    end
end

local listenerOn, regHooked, unlockHooked = false, false, false
local function Install()
    local eui = ns.EUI()
    if not eui then return end
    if Active() then
        HookFrame(ElemFrame(CD_KEY))
        HookFrame(ElemFrame(UT_KEY), true)
        InstallGetters()
    end
    if MinOn() then WrapMatchChildren() end
    if not listenerOn and eui.RegisterUnlockModeListener then
        listenerOn = true
        eui:RegisterUnlockModeListener(ns.ADDON .. "_AnchorPoints", function(active)
            UpdateBadges(active)
            if not active then QueueAP() end
        end)
    end
    -- CDM re-assigns its own getter for every CDM bar right before registering
    -- elements; re-wrap in that same execution so ours is never missing
    if not regHooked and type(eui.RegisterUnlockElements) == "function" then
        regHooked = true
        hooksecurefunc(eui, "RegisterUnlockElements", function()
            InstallGetters()
            if MinOn() then WrapMatchChildren() end
            QueueAP()
        end)
    end
    -- a Custom Unlock Mode swap refills the whole anchor store
    if not unlockHooked and type(eui.SpecOverrides_ApplyUnlock) == "function" then
        unlockHooked = true
        hooksecurefunc(eui, "SpecOverrides_ApplyUnlock", function()
            C_Timer.After(0.1, QueueAP)
        end)
    end
end

ns.maintainers[#ns.maintainers + 1] = Install
ns.bootOnly[#ns.bootOnly + 1] = QueueAP
ns.onSpecApply[#ns.onSpecApply + 1] = QueueAP

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function()
    -- sizes settle late at login (width matches, CDM population)
    C_Timer.After(3, RunPass)
    C_Timer.After(8, RunPass)
    C_Timer.After(14, RunPass)
end)

-- ------------------------------------------------- retired: anchor points

-- Follow-point pins and "Place With thingsTweaks" are gone (native EUI
-- anchoring + grow direction covers them). Owned elements had their EUI
-- anchor stashed in our settings: hand each back before the settings go.
-- Runs for whichever profile is active; the live store is the only safe one.
local function CopyAnchor(t)
    if type(t) ~= "table" then return nil end
    local c = {}
    for k, v in pairs(t) do
        c[k] = (type(v) == "table") and CopyAnchor(v) or v
    end
    return c
end

local function RetireAnchorPoints()
    local t = S()
    if t.anchorOwn == nil and t.anchorPoints == nil and t.anchorExtents == nil then return end
    local db = _G.EllesmereUIDB
    if not db then return end
    if type(t.anchorOwn) == "table" then
        db.unlockAnchors = db.unlockAnchors or {}
        local anchors = db.unlockAnchors
        local restored = {}
        for key, own in pairs(t.anchorOwn) do
            local st = type(own) == "table" and own.stashed
            -- never overwrite an anchor the user has set since
            if type(st) == "table" and st.target and not anchors[key] then
                anchors[key] = CopyAnchor(st)
                restored[#restored + 1] = key
            end
        end
        if #restored > 0 then
            local eui = ns.EUI()
            if eui then
                -- what EUI's own ClearAnchorInfo bumps; invalidates their link caches
                eui._anchorLinksStamp = (eui._anchorLinksStamp or 0) + 1
                local reapply = eui.ReapplyUnlockAnchor or eui.ReapplyOwnAnchor
                if reapply then
                    for _, key in ipairs(restored) do pcall(reapply, key) end
                end
            end
        end
    end
    t.anchorOwn, t.anchorPoints, t.anchorExtents = nil, nil, nil
end
ns.maintainers[#ns.maintainers + 1] = RetireAnchorPoints

-- ---------------------------------------------------------------------- page

function ns.BuildAnchorPointsPage(parent, yOffset)
    local eui = ns.EUI()
    local W = eui and eui.Widgets
    if not W then return 0 end
    local y = yOffset
    local _, h

    _, h = W:SectionHeader(parent, "COOLDOWNS WIDTH", y); y = y - h
    _, h = W:Toggle(parent, "Offset Cooldowns Anchors", y,
        function() return OverflowOn() end,
        function(v)
            S().utilOverflow = v and true or nil
            Install()
            ReapplyChildren()
        end,
        "When the Utility bar sticks out wider than the Cooldowns bar (more icons), everything anchored to the Cooldowns bar's left/right moves outward by the excess. Back to normal when Utility fits."); y = y - h
    _, h = W:Slider(parent, "Minimum Cooldowns Width (0 = Off)", y, 0, 600, 1,
        function() return MinWidth() end,
        function(v)
            S().cdMinWidth = (v and v > 0) and v or nil
            Install()
            if eui.PropagateWidthMatch then eui.PropagateWidthMatch(CD_KEY) end
            ReapplyChildren()
        end,
        "Bars width-matched to Cooldowns are at least this wide, and frames anchored to its sides sit as if it were."); y = y - h

    if ns.BuildMoveStuffSection then y = ns.BuildMoveStuffSection(parent, y) end

    return math.abs(y)
end
