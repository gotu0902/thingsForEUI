local _, ns = ...

local S = ns.S

-- --------------------------------------------------- hide passive cooldowns

-- A talent can turn a tracked cooldown passive (Crusading Strikes over
-- Crusader Strike, Radiant Glory over Avenging Wrath) and it keeps its slot.
-- EUI decides each cooldown's bar in ResolveCDIDToBar, which answers from
-- ns._cdidRouteMap FIRST; RebuildSpellRouteMap wipes that cache on every
-- rebuild. Seeding it right after with EUI's own hidden bar sends the frame
-- where "Remove Spell" sends it -- nothing written to bar data, and the next
-- rebuild recomputes, so taking the talent back shows the spell again.

local function CDM() return ns.ModuleNS("EllesmereUICooldownManager") end

local function Enabled() return S().cdmHidePassive == true end

local function PlainID(v)
    if issecretvalue and issecretvalue(v) then return nil end
    if type(v) == "number" and v > 0 then return v end
end

local function NotSecret(v)
    return not (issecretvalue and issecretvalue(v))
end

local hiddenCd = {}     -- cooldownID -> true
local hiddenSpell = {}  -- every id of a hidden entry, for the options preview

-- nil = unreadable right now (secret in combat): keep whatever was decided
local function IsPassiveCd(gci, cdID)
    local info = gci(cdID)
    if not info then return nil end
    -- equipment rows belong to EUI's own passive-trinket option; a secret
    -- slot is still a slot, and must never reach the comparison
    local es = info.equipSlot
    if (issecretvalue and issecretvalue(es)) or es ~= nil then return false end
    local base = PlainID(info.spellID)
    local sid = PlainID(info.overrideTooltipSpellID) or PlainID(info.overrideSpellID) or base
    -- judge the LIVE override: a granted-active form can carry its passive
    -- talent id in the static fields exactly while it is usable
    if base and C_Spell.GetOverrideSpell then
        local live = PlainID(C_Spell.GetOverrideSpell(base))
        if live and live ~= base then sid = live end
    end
    if not sid then return nil end
    local p = C_Spell.IsSpellPassive(sid)
    if not NotSecret(p) then return nil end
    return p == true, base, sid
end

local function EachCdCooldown(fn)
    local sets = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
    local E = Enum.CooldownViewerCategory
    if not (sets and E) then return end
    for _, cat in ipairs({ E.Essential, E.Utility }) do
        for _, cdID in ipairs(sets(cat) or {}) do
            if PlainID(cdID) then fn(cdID) end
        end
    end
end

local function MarkSpell(base, sid)
    if base then hiddenSpell[base] = true end
    if sid then hiddenSpell[sid] = true end
end

-- other modules' rules for the same route: fn(cooldownInfo) -> true hides it
ns.cdHideChecks = ns.cdHideChecks or {}

-- full pass on a freshly wiped cache
local function Seed(cdm)
    wipe(hiddenCd)
    wipe(hiddenSpell)
    local passiveOn = Enabled() and C_Spell.IsSpellPassive ~= nil
    local checks = ns.cdHideChecks
    if not passiveOn and #checks == 0 then return end
    local map, ghost = cdm._cdidRouteMap, cdm.GHOST_CD_BAR_KEY
    local gci = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
    if not (map and ghost and gci) then return end
    EachCdCooldown(function(cdID)
        if passiveOn then
            local passive, base, sid = IsPassiveCd(gci, cdID)
            if passive then
                hiddenCd[cdID] = true
                MarkSpell(base, sid)
                map[cdID] = ghost
                return
            end
        end
        if #checks > 0 then
            local info = gci(cdID)
            if info then
                for _, fn in ipairs(checks) do
                    if fn(info) then map[cdID] = ghost; return end
                end
            end
        end
    end)
end

-- RebuildSpellRouteMap is only ever called through the module ns
local wrapped
local function WrapRouteMap()
    local cdm = CDM()
    if not cdm then return end
    local cur = cdm.RebuildSpellRouteMap
    if not cur or cur == wrapped then return end
    local orig = cur
    wrapped = function(...)
        orig(...)
        -- inside EUI's rebuild: an error of ours must not abort it halfway
        local ok, err = pcall(Seed, cdm)
        if not ok then ns.ReportError(err) end
    end
    cdm.RebuildSpellRouteMap = wrapped
end
-- CDM is an OptionalDep and loads first, so this beats its login rebuild
WrapRouteMap()
ns.maintainers[#ns.maintainers + 1] = WrapRouteMap

-- EUI's own re-route pattern (AddTrackedSpell): rebuild the map, reanchor
local function Reroute()
    local cdm = CDM()
    if not cdm then return end
    if cdm.RebuildSpellRouteMap then cdm.RebuildSpellRouteMap() end
    if cdm.QueueReanchor then cdm.QueueReanchor() end
end
ns.RefreshPassiveHide = Reroute

-- the login rebuild can run before our profile settings resolve
ns.bootOnly[#ns.bootOnly + 1] = function()
    if Enabled() then Reroute() end
end

-- An override can flip a slot between passive and usable mid-combat (a
-- transformation granting the active form); EUI only bumps a counter there,
-- so re-judge and move just the slots whose verdict changed.
local function Revalidate()
    local cdm = CDM()
    if not (cdm and Enabled()) then return end
    local map, ghost = cdm._cdidRouteMap, cdm.GHOST_CD_BAR_KEY
    local gci = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
    if not (map and ghost and gci and C_Spell.IsSpellPassive) then return end
    local changed = false
    EachCdCooldown(function(cdID)
        local passive, base, sid = IsPassiveCd(gci, cdID)
        if passive == nil then return end
        if passive and not hiddenCd[cdID] then
            hiddenCd[cdID] = true
            MarkSpell(base, sid)
            map[cdID] = ghost
            changed = true
        elseif not passive and hiddenCd[cdID] then
            hiddenCd[cdID] = nil
            -- forget the verdict; EUI resolves the real bar on its own
            map[cdID] = nil
            changed = true
        end
    end)
    if changed and cdm.QueueReanchor then cdm.QueueReanchor() end
end

local ev = CreateFrame("Frame")
if not C_EventUtils or not C_EventUtils.IsEventValid
    or C_EventUtils.IsEventValid("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED") then
    ev:RegisterEvent("COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED")
end
ev:SetScript("OnEvent", function()
    local ok, err = pcall(Revalidate)
    if not ok then ns.ReportError(err) end
end)

-- ------------------------------------------------- options preview marker

-- EUI's CDM bar preview (EllesmereUI._contentHeaderPreview) exposes its icon
-- slots with the spell each shows; mark the ones we hide after every Update.
local marks = setmetatable({}, { __mode = "k" })
local hookedPreviews = setmetatable({}, { __mode = "k" })

local function MarkPreview(pf)
    local slots = pf and pf._previewSlots
    if not slots then return end
    local on = Enabled()
    local eui = ns.EUI()
    local font = eui and eui.GetFontPath and eui.GetFontPath() or STANDARD_TEXT_FONT
    for _, slot in ipairs(slots) do
        local hid = on and slot:IsShown()
            and ((slot._previewCdID and hiddenCd[slot._previewCdID])
                or (slot._previewSpellID and hiddenSpell[slot._previewSpellID]))
        local m = marks[slot]
        if hid then
            if not m then
                -- never mouse-enabled: the slot's own click menu stays reachable
                m = CreateFrame("Frame", nil, slot)
                m:SetAllPoints()
                m:SetFrameLevel(slot:GetFrameLevel() + 5)
                local bg = m:CreateTexture(nil, "OVERLAY")
                bg:SetAllPoints()
                bg:SetColorTexture(0, 0, 0, 0.65)
                m.text = m:CreateFontString(nil, "OVERLAY")
                m.text:SetPoint("CENTER", 0, 0)
                marks[slot] = m
            end
            m.text:SetFont(font, 8, "OUTLINE")
            m.text:SetText("|cffff9966PASSIVE|r")
            m:Show()
        elseif m then
            m:Hide()
        end
    end
end

local headerHooked = false
local function HookPreviews()
    local eui = ns.EUI()
    if headerHooked or not (eui and eui.SetContentHeader) then return end
    headerHooked = true
    -- header builders run synchronously inside, so the new preview is live here
    hooksecurefunc(eui, "SetContentHeader", function()
        local pf = eui._contentHeaderPreview
        if not (pf and pf._previewSlots and type(pf.Update) == "function") then return end
        if eui.GetActiveModule and eui:GetActiveModule() ~= "EllesmereUICooldownManager" then return end
        if not hookedPreviews[pf] then
            hookedPreviews[pf] = true
            hooksecurefunc(pf, "Update", MarkPreview)
        end
        MarkPreview(pf)
    end)
end
ns.maintainers[#ns.maintainers + 1] = HookPreviews
