local _, ns = ...

local S = ns.S

-- --------------------------------------------------- CDM overflow-first layout

local function CDM() return ns.ModuleNS("EllesmereUICooldownManager") end

local claim = setmetatable({}, { __mode = "k" })
local desired = setmetatable({}, { __mode = "k" })
local hookedIcons = setmetatable({}, { __mode = "k" })
local hookedContainers = setmetatable({}, { __mode = "k" })
local watchedDest = setmetatable({}, { __mode = "k" })
local ovTargets
local reordering = false

-- claims record EUI's own layout write for each icon (the hook fires on their
-- SetPoint BEFORE any re-assert, so the recorded slot is always EUI-canonical)
local function OnIconSetPoint(ic, _, rel, _, x, y)
    if reordering then return end
    if not (rel and watchedDest[rel]) then return end
    local c = claim[ic]
    if not c then c = {}; claim[ic] = c end
    c.rel, c.x, c.y = rel, x or 0, y or 0
    local d = desired[ic]
    if d and d.rel == rel then
        local st = S()
        if not (st.cdmOverflowFirst or (st.cdmWrapCount or 0) > 0) then return end
        if rel._mouseTrack then return end
        local eui = ns.EUI()
        if eui and (eui._unlockActive or eui._unlockModeActive) then return end
        reordering = true
        ic:SetPoint("TOPLEFT", rel, "TOPLEFT", d.x, d.y)
        reordering = false
    end
end

local function InstallIconHook(ic)
    if hookedIcons[ic] then return end
    hookedIcons[ic] = true
    hooksecurefunc(ic, "SetPoint", OnIconSetPoint)
end

-- EUI-canonical slot for a member icon: its recorded claim, else the live anchor
local function IconSlot(ic, container)
    local c = claim[ic]
    if c and c.rel == container then return c.x, c.y end
    for j = 1, ic:GetNumPoints() do
        local point, rel, _, x, y = ic:GetPoint(j)
        if rel == container and point == "TOPLEFT" then return x or 0, y or 0 end
    end
end

local function Reorder(container)
    if reordering then return end
    local destKey = watchedDest[container]
    if not destKey then return end
    local eui = ns.EUI()
    local cdm = CDM()

    local function Disarm()
        for ic, d in pairs(desired) do
            if d.rel == container then desired[ic] = nil end
        end
    end

    if not cdm
        or (eui and (eui._unlockActive or eui._unlockModeActive))
        or container._mouseTrack then
        Disarm()
        return
    end

    -- EUI's own ordered icon list for this bar: every icon family (pool,
    -- custom, hosted buffs) in layout order -- membership and order are theirs
    local list = cdm.GetCDMBarIcons and cdm.GetCDMBarIcons(destKey)
    if not list then Disarm() return end

    local seq, slots = {}, {}
    for _, ic in ipairs(list) do
        if ic and ic:IsShown() then
            local x, y = IconSlot(ic, container)
            if x then
                InstallIconHook(ic)
                local sc = ic:GetScale() or 1
                local w, h = ic:GetSize()
                seq[#seq + 1] = ic
                slots[#seq] = { x = x * sc, y = y * sc, w = w * sc, h = h * sc, sc = sc }
            end
        end
    end

    -- any bail restores EUI's own layout and disarms the re-asserts
    local function Bail()
        Disarm()
        reordering = true
        for k, ic in ipairs(seq) do
            local sl = slots[k]
            ic:SetPoint("TOPLEFT", container, "TOPLEFT", sl.x / sl.sc, sl.y / sl.sc)
        end
        reordering = false
    end

    local st = S()
    local doOv = (st.cdmOverflowFirst and ovTargets and ovTargets[destKey]) and true or false
    local wrapN = (destKey == "utility") and (st.cdmWrapCount or 0) or 0
    local doWrap = wrapN > 0
    if not (doOv or doWrap) then Bail() return end
    if #seq < 2 then Bail() return end

    -- stage 1: EUI appends diverted icons as a contiguous tail, so overflow-first
    -- is a pure rotation; the module's own accessor is the diversion authority
    local finalIcon = seq
    local permuted = false
    if doOv and cdm.CdmFrameOverflowBar then
        local firstOv, contiguous = nil, true
        for idx, ic in ipairs(seq) do
            if cdm.CdmFrameOverflowBar(ic) then
                firstOv = firstOv or idx
            elseif firstOv then
                contiguous = false
                break
            end
        end
        if contiguous and firstOv and firstOv > 1 then
            finalIcon = {}
            for k = firstOv, #seq do finalIcon[#finalIcon + 1] = seq[k] end
            for k = 1, firstOv - 1 do finalIcon[#finalIcon + 1] = seq[k] end
            permuted = true
        end
    end

    -- stage 2: slot geometry; the wrap arm replaces slots past wrapN
    local wrapped = false
    if doWrap and #slots > wrapN then
        -- only meaningful while EUI lays a single vertical column
        local vert = math.abs(slots[2].y - slots[1].y) > 0.5
        for k = 2, #slots do
            if math.abs(slots[k].x - slots[1].x) > 0.5 then vert = false break end
        end
        if vert then
            local base = slots[wrapN]
            local gap = math.abs(slots[2].y - slots[1].y) - slots[1].h
            if gap < 0 then gap = 1 end
            local dir = (st.cdmWrapSide == "RIGHT") and 1 or -1
            for k = wrapN + 1, #slots do
                local i = k - wrapN
                slots[k] = { x = base.x + dir * i * (base.w + gap), y = base.y,
                    w = base.w, h = base.h, sc = slots[k].sc }
            end
            wrapped = true
        end
    end
    if not (permuted or wrapped) then Bail() return end

    reordering = true
    for k, ic in ipairs(finalIcon) do
        local sl = slots[k]
        local sc = (ic:GetScale() or 1)
        local lx, ly = sl.x / sc, sl.y / sc
        ic:SetSize(sl.w / sc, sl.h / sc)
        ic:SetPoint("TOPLEFT", container, "TOPLEFT", lx, ly)
        local c = claim[ic]
        if not c or math.abs(lx - c.x) > 0.01 or math.abs(ly - c.y) > 0.01 then
            local d = desired[ic]
            if not d then d = {}; desired[ic] = d end
            d.rel, d.x, d.y = container, lx, ly
        elseif desired[ic] then
            desired[ic] = nil
        end
    end
    reordering = false
end

function ns.RepaintCDM()
    for ic in pairs(desired) do desired[ic] = nil end
    local cdm = CDM()
    local eui = ns.EUI()
    local layout = (cdm and cdm.LayoutCDMBar) or (eui and eui.LayoutCDMBar)
    if layout then
        for _, destKey in pairs(watchedDest) do layout(destKey) end
    end
end

function ns.UpdateCDMOverflow()
    local db = _G._ECME_AceDB
    local bars = db and db.profile and db.profile.cdmBars and db.profile.cdmBars.bars
    ovTargets = nil
    if bars then
        local byKey = {}
        for _, bd in ipairs(bars) do
            if bd.key then byKey[bd.key] = bd end
        end
        for _, bd in ipairs(bars) do
            local tgt = bd.overflowTarget and byKey[bd.overflowTarget]
            if bd.enabled and not bd.isGhostBar and bd.key
                and (bd.maxIcons or 0) > 0
                and tgt and tgt.enabled and not tgt.isGhostBar and tgt.key ~= bd.key then
                ovTargets = ovTargets or {}
                ovTargets[bd.overflowTarget] = true
            end
        end
    end
    local st = S()
    local wraps = (st.cdmWrapCount or 0) > 0
    local watchKeys
    if ovTargets then
        watchKeys = {}
        for k in pairs(ovTargets) do watchKeys[k] = true end
    end
    if wraps then
        watchKeys = watchKeys or {}
        watchKeys.utility = true
    end
    for ic, d in pairs(desired) do
        local dk = watchedDest[d.rel]
        if not (dk and watchKeys and watchKeys[dk]) then desired[ic] = nil end
    end
    if not watchKeys then return end
    local cdm = CDM()
    for destKey in pairs(watchKeys) do
        local container = (cdm and cdm.GetCDMBarFrame and cdm.GetCDMBarFrame(destKey))
            or _G["ECME_CDMBar_" .. destKey]
        if container then
            watchedDest[container] = destKey
            if not hookedContainers[container] then
                hookedContainers[container] = true
                hooksecurefunc(container, "SetSize", Reorder)
            end
        end
    end
end

ns.maintainers[#ns.maintainers + 1] = ns.UpdateCDMOverflow
ns.onSpecApply[#ns.onSpecApply + 1] = function() ns.UpdateCDMOverflow(); ns.RepaintCDM() end
ns.onRegen[#ns.onRegen + 1] = function() ns.UpdateCDMOverflow(); ns.RepaintCDM() end
