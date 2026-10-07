local _, ns = ...

local S = ns.S

-- ---------------------------------------------------------- racial routing

-- EUI keeps exactly ONE racial slot across all CDM bars and remaps it to each
-- character's own racial, so a profile shared by several races puts every
-- race's racial on the same bar. This routes it per RACE instead: EUI runs its
-- one-racial rule first, then we move that single slot to the bar picked for
-- this race. EUI's keeper rule (prefer the custom-bar copy, keep one where it
-- sits) then holds the placement on every later rebuild.

local function CDM() return ns.ModuleNS("EllesmereUICooldownManager") end

local function PlayerRace()
    local _, raceFile = UnitRace("player")
    return raceFile
end

local function BarList()
    local db = _G._ECME_AceDB
    local p = db and db.profile
    return p and p.cdmBars and p.cdmBars.bars
end

-- same buff test EUI's NormalizeRacialAssignments uses
local function IsBuffBar(cdm, b)
    if b.barType == "custom_buff" then return true end
    return (cdm.IsBarBuffFamily and cdm.IsBarBuffFamily(b)) and true or false
end

-- a legal home: any enabled cooldown-type bar, Cooldowns and Utility included
-- (EUI's own "Racial" picker entry targets those the same way); buff bars
-- never hold it and FocusKick is kick-only
local function RoutableBar(cdm, b)
    return b and b.key and b.enabled ~= false and not b.isGhostBar
        and b.key ~= (cdm.FOCUSKICK_BAR_KEY or "focuskick")
        and not IsBuffBar(cdm, b)
end

-- read-only: a not-yet-ready profile resolves to shared defaults
local function RouteFor(race)
    local r = S().racialRoute
    return r and race and r[race]
end

local function PosFor(race)
    local p = S().racialPos
    return (p and race and p[race] == "START") and "START" or "END"
end

-- default bars list only what the user has ordered; the rest spills to the
-- tail behind any listed entry
local MAIN_BARS = { cooldowns = true, utility = true }

local function RacialIndex(cdm, list)
    local all = cdm.ALL_RACIAL_SPELLS
    for i, sid in ipairs(list or {}) do
        if all[sid] then return i end
    end
end

-- a racial the user hid on this character (ghost bar) stays hidden
local function RacialHidden(cdm, bars)
    for _, b in ipairs(bars) do
        if b.key and b.isGhostBar then
            local sd = cdm.GetBarSpellData(b.key)
            if RacialIndex(cdm, sd and sd.assignedSpells) then return true end
        end
    end
    return false
end

-- where the racial actually renders on the bar: EUI's ordered icon list
local function RacialOnScreen(cdm, barKey)
    local icons = cdm.GetCDMBarIcons and cdm.GetCDMBarIcons(barKey)
    local fcs = cdm._ecmeFC
    if not (icons and fcs) then return end
    local all = cdm.ALL_RACIAL_SPELLS
    for i, icon in ipairs(icons) do
        local fc = fcs[icon]
        if fc and fc.spellID and all[fc.spellID] then return i, #icons end
    end
end

local function PlaceOnBar(cdm, barKey, pos)
    -- "End" on a default bar needs its live order written down first, or
    -- everything unlisted still lands behind us; EUI's own materializer,
    -- with its ghost/owner/one-racial guards
    if pos == "END" and MAIN_BARS[barKey] and cdm.ReseedAssignedSpellsFromLiveIcons then
        cdm.ReseedAssignedSpellsFromLiveIcons(true)
    end
    local sd = cdm.GetBarSpellData(barKey)
    local list = sd and sd.assignedSpells
    local idx = RacialIndex(cdm, list)
    if not idx then return end
    local to = (pos == "START") and 1 or #list
    if idx ~= to then
        table.insert(list, to, table.remove(list, idx))
        cdm._spellOrderDirty = true
    end
end

local function ApplyRoute(cdm)
    local want = RouteFor(PlayerRace())
    if not want then return end
    local active = cdm._activeRacialSpellID
    local all = cdm.ALL_RACIAL_SPELLS
    if not (active and active > 0 and all and cdm.GetBarSpellData) then return end
    local bars = BarList()
    if not bars then return end
    local target
    for _, b in ipairs(bars) do
        if b.key == want then target = b; break end
    end
    -- a deleted or disabled target leaves the racial wherever EUI has it
    if not (RoutableBar(cdm, target) and cdm.AddTrackedSpell) then return end
    -- AddTrackedSpell would restore a hidden racial by design
    if RacialHidden(cdm, bars) then return end

    -- EUI's own add path, the one its "Racial" picker entry calls: no-op when
    -- already on the target, otherwise moves it off every other bar
    cdm.AddTrackedSpell(want, active)
    PlaceOnBar(cdm, want, PosFor(PlayerRace()))
end

-- FullCDMRebuild calls this via the module ns BEFORE the route map and bar
-- build read assignedSpells, so our move renders in that same rebuild
local wrapped
local function WrapNormalize()
    local cdm = CDM()
    if not cdm then return end
    local cur = cdm.NormalizeRacialAssignments
    if not cur or cur == wrapped then return end
    local orig = cur
    wrapped = function(...)
        orig(...)
        -- inside their rebuild: an error of ours must not abort it halfway
        local ok, err = pcall(ApplyRoute, cdm)
        if not ok then ns.ReportError(err) end
    end
    cdm.NormalizeRacialAssignments = wrapped
end
-- CDM is an OptionalDep and loads first, so this beats its login rebuild
WrapNormalize()
ns.maintainers[#ns.maintainers + 1] = WrapNormalize

local function Rebuild()
    local cdm = CDM()
    if cdm and cdm.FullCDMRebuild then cdm.FullCDMRebuild("apply") end
end

-- The login rebuild runs before live icons exist, so a default bar's order
-- can't be materialized then; one rebuild once they do, only when needed.
ns.bootOnly[#ns.bootOnly + 1] = function()
    local cdm = CDM()
    local race = PlayerRace()
    local want = RouteFor(race)
    if not (cdm and want and cdm._activeRacialSpellID and cdm.GetBarSpellData) then return end
    local bars = BarList() or {}
    if RacialHidden(cdm, bars) then return end
    local target
    for _, b in ipairs(bars) do
        if b.key == want then target = b; break end
    end
    if not RoutableBar(cdm, target) then return end
    -- judge by what is on screen, not by the list: a list can look right while
    -- unlisted spills still render behind the racial
    local i, n = RacialOnScreen(cdm, want)
    if i then
        local pos = PosFor(race)
        if (pos == "START" and i == 1) or (pos == "END" and i == n) then return end
    end
    Rebuild()
end

-- ------------------------------------------------------------------ presets

-- The recommended setup, by ROLE rather than bar key: Cooldowns and Utility
-- exist for everyone, a defensive bar is each user's own custom bar (picked
-- when applying). { role, "START" } -- no position means end.
local PRESET = {
    BloodElf           = { "UTIL" },
    DarkIronDwarf      = { "DEF" },
    Dracthyr           = { "UTIL" },
    Draenei            = { "DEF", "START" },
    Dwarf              = { "DEF", "START" },
    EarthenDwarf       = { "OFF" },
    Gnome              = { "DEF", "START" },
    Goblin             = { "UTIL" },
    Haranir            = { "OFF" },
    HighmountainTauren = { "UTIL" },
    Human              = { "DEF", "START" },
    KulTiran           = { "UTIL" },
    LightforgedDraenei = { "OFF" },
    MagharOrc          = { "OFF" },
    Mechagnome         = { "DEF", "START" },
    NightElf           = { "DEF" },
    Nightborne         = { "OFF" },
    Orc                = { "OFF" },
    Pandaren           = { "UTIL" },
    Scourge            = { "DEF", "START" },
    Tauren             = { "UTIL" },
    Troll              = { "OFF" },
    VoidElf            = { "OFF" },
    Vulpera            = { "OFF" },
    Worgen             = { "UTIL" },
    ZandalariTroll     = { "DEF", "START" },
}

-- a full reset: races the preset doesn't know go back to EUI Default
local function ApplyPreset(defBar)
    local t = S()
    local route, pos = {}, {}
    for race, p in pairs(PRESET) do
        local role = p[1]
        route[race] = (role == "OFF" and "cooldowns") or (role == "UTIL" and "utility") or defBar
        if p[2] == "START" then pos[race] = "START" end
    end
    t.racialRoute, t.racialPos = route, pos
    Rebuild()
end

-- positions are left as they are: they only say where on the bar
local function ApplyAll(barKey, races)
    local t = S()
    if not barKey then
        t.racialRoute = nil
    else
        local route = {}
        for _, race in ipairs(races) do route[race] = barKey end
        t.racialRoute = route
    end
    Rebuild()
end

-- ---------------------------------------------------------------------- page

local RACE_LABEL = { Scourge = "Undead" }

local function RaceLabel(race)
    return RACE_LABEL[race] or race:gsub("(%l)(%u)", "%1 %2")
end

-- first listed id: class variants (Blood Fury, Arcane Torrent, Gift of the
-- Naaru) share a race, and a route belongs to the race
local function RaceSpell(ids)
    local e = ids and ids[1]
    return type(e) == "table" and e[1] or e
end

local ICON, GAP = 34, 5

function ns.BuildRacialsPage(parent, yOffset)
    local eui = ns.EUI()
    local W = eui and eui.Widgets
    if not W then return 0 end
    local cdm = CDM()
    local y = yOffset
    local _, h

    local function RefreshPanel()
        if eui.RefreshPage then eui:RefreshPage(true) end
    end

    -- the shared pick menu outlives page switches; EUI's own pages close it too
    local function ClosePickMenu()
        if eui._pickMenu then eui._pickMenu:Hide() end
    end
    ClosePickMenu()
    if not parent._tweaksPickMenuHook then
        parent._tweaksPickMenuHook = true
        parent:HookScript("OnHide", ClosePickMenu)
    end

    _, h = W:SectionHeader(parent, "RACIALS", y); y = y - h

    local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    desc:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    desc:SetJustifyH("LEFT")
    desc:SetWidth(440)
    desc:SetText("Pick which CDM bar each race's racial goes to. A profile shared by several races then puts every character's racial on the bar you chose for it. Load Defaults puts offensive racials on Cooldowns, utility on Utility and defensive on a bar you pick. Saved per profile.")
    y = y - 52

    if not (cdm and cdm.RACE_RACIALS) then
        local none = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        none:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
        none:SetText("The Cooldown Manager is not loaded.")
        return math.abs(y - 30)
    end

    local races = {}
    for race, ids in pairs(cdm.RACE_RACIALS) do
        if RaceSpell(ids) then races[#races + 1] = race end
    end
    table.sort(races, function(a, b) return RaceLabel(a) < RaceLabel(b) end)

    local bars = BarList() or {}
    local barName = {}
    for _, b in ipairs(bars) do
        if b.key then barName[b.key] = b.name or b.key end
    end

    local fontPath = eui.GetFontPath and eui.GetFontPath() or nil
    local function BarItems()
        local items = {}
        for _, b in ipairs(bars) do
            if RoutableBar(cdm, b) then
                items[#items + 1] = { key = b.key, label = b.name or b.key }
            end
        end
        return items
    end

    _, h = W:WideDualButton(parent, "All On One Bar", "Load Defaults", y,
        function()
            if not eui.ShowPickMenu then return end
            local items = BarItems()
            table.insert(items, 1, { key = "__default", label = "EUI Default (clear all)" })
            eui.ShowPickMenu(parent, {
                title = "Put every racial on",
                fontPath = fontPath,
                items = items,
                onPick = function(key)
                    ApplyAll((key ~= "__default") and key or nil, races)
                    RefreshPanel()
                end,
            })
        end,
        function()
            if not eui.ShowPickMenu then return end
            eui.ShowPickMenu(parent, {
                title = "Defensive racials go to",
                fontPath = fontPath,
                items = BarItems(),
                onPick = function(key)
                    ApplyPreset(key)
                    RefreshPanel()
                end,
            })
        end); y = y - h

    local mine = PlayerRace()
    local ar, ag, ab = 0.05, 0.82, 0.62
    if eui.GetAccentColor then ar, ag, ab = eui.GetAccentColor() end
    local pp = eui.PanelPP

    local usable = math.max(200, (parent:GetWidth() or 600) - 40)
    local perRow = math.max(1, math.floor((usable + GAP) / (ICON + GAP)))

    for i, race in ipairs(races) do
        local sid = RaceSpell(cdm.RACE_RACIALS[race])
        local col, row = (i - 1) % perRow, math.floor((i - 1) / perRow)
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(ICON, ICON)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 20 + col * (ICON + GAP), y - row * (ICON + GAP))

        local tex = btn:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints()
        tex:SetTexture(C_Spell.GetSpellTexture(sid))
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        local route = RouteFor(race)
        -- unrouted races read as "EUI decides"; routed ones stand out
        if not route then
            tex:SetDesaturated(true)
            tex:SetAlpha(0.55)
        end
        if race == mine then
            eui.MakeBorder(btn, ar, ag, ab, 1, pp)
        else
            eui.MakeBorder(btn, 1, 1, 1, route and 0.35 or 0.12, pp)
        end

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(sid)
            GameTooltip:AddLine(" ")
            local r = RouteFor(race)
            GameTooltip:AddLine(RaceLabel(race) .. (race == mine and "  (this character)" or ""), 1, 1, 1)
            if r then
                GameTooltip:AddLine("Goes to: " .. (barName[r] or (r .. " (bar missing)"))
                    .. (PosFor(race) == "START" and ", start" or ", end"), ar, ag, ab)
            else
                GameTooltip:AddLine("Goes to: EUI Default", 0.6, 0.6, 0.6)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        btn:SetScript("OnClick", function(self)
            if not eui.ShowPickMenu then return end
            local cur = RouteFor(race)
            local function Mark(label, on)
                return on and ("|cff0dd29f" .. label .. "|r") or label
            end
            local items = { { key = "__default", label = Mark("EUI Default", not cur) } }
            for _, b in ipairs(bars) do
                if RoutableBar(cdm, b) then
                    items[#items + 1] = { key = b.key, label = Mark(b.name or b.key, cur == b.key) }
                end
            end
            -- position only means something once a bar is picked
            local pos = PosFor(race)
            items[#items + 1] = { key = "__hdr", label = "|cff888888Position on bar|r", disabled = true }
            items[#items + 1] = { key = "__start", label = Mark("Start", pos == "START"), disabled = not cur }
            items[#items + 1] = { key = "__end", label = Mark("End", pos == "END"), disabled = not cur }
            eui.ShowPickMenu(self, {
                title = C_Spell.GetSpellName(sid) or RaceLabel(race),
                fontPath = eui.GetFontPath and eui.GetFontPath() or nil,
                items = items,
                onPick = function(key)
                    local t = S()
                    if key == "__start" or key == "__end" then
                        if type(t.racialPos) ~= "table" then t.racialPos = {} end
                        t.racialPos[race] = (key == "__start") and "START" or nil
                    else
                        if type(t.racialRoute) ~= "table" then t.racialRoute = {} end
                        t.racialRoute[race] = (key ~= "__default") and key or nil
                    end
                    Rebuild()
                    RefreshPanel()
                end,
            })
        end)
    end

    local rows = math.ceil(#races / perRow)
    y = y - rows * (ICON + GAP) - 10

    -- plain-text summary: the grid alone makes routes easy to miss
    local any = false
    for _, race in ipairs(races) do
        local r = RouteFor(race)
        if r then
            any = true
            local sid = RaceSpell(cdm.RACE_RACIALS[race])
            local line = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            line:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
            line:SetFormattedText("|T%s:14:14|t  %s  |cff888888(%s)|r  ->  %s  |cff888888%s|r",
                tostring(C_Spell.GetSpellTexture(sid) or ""), C_Spell.GetSpellName(sid) or "?",
                RaceLabel(race),
                barName[r] and ("|cff0dd29f" .. barName[r] .. "|r") or ("|cffff5555" .. r .. " (bar missing)|r"),
                PosFor(race) == "START" and "start" or "end")
            y = y - 18
        end
    end
    if not any then
        local none = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        none:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
        none:SetText("No racials routed yet - click an icon to pick its bar.")
        y = y - 18
    end

    return math.abs(y - 10)
end
