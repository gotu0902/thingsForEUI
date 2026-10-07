local _, ns = ...

local S = ns.S

-- ------------------------------------------------- action bars 6 and 9

-- ElvUI's Bar 6 sits on action page 2, which EUI shows as Action Bar 9
-- (slots 13-24); Blizzard's Action Bar 6 is MultiBar5 (slots 145-156).
-- Which bar shows is a profile setting, the spells are per spec (WoW keeps
-- action bars per specialization) and a key drives only one bar. A copy
-- leaves its source intact, so a spec holding its spells on both works under
-- any profile; the keys follow whichever of the two the profile shows, and
-- the placement of both is kept identical in every spec layout.

local COUNT = 12
local ORDER = { "Bar6", "Bar9" }
local BARS = {
    Bar6 = { label = "Action Bar 6", note = "Blizzard", base = 144, cmd = "MULTIACTIONBAR5BUTTON" },
    Bar9 = { label = "Action Bar 9", note = "ElvUI's Bar 6", base = 12, cmd = "EUI_BAR9_BUTTON" },
}
local OTHER = { Bar6 = "Bar9", Bar9 = "Bar6" }

local function Say(msg) print("|cff8AC8FFthings|r Action Bars: " .. msg) end

local function IsSecret(v) return issecretvalue and issecretvalue(v) end

local function EAB()
    local abns = ns.ModuleNS("EllesmereUIActionBars")
    return abns and abns.EAB
end

local function Profile()
    local eab = EAB()
    return eab and eab.db and eab.db.profile
end

-- ----------------------------------------------------------------- state

local function Slot(key, i) return BARS[key].base + i end

local function ModeOf(s)
    return s and (s.barVisibility or (s.alwaysHidden and "never")) or "always"
end

-- the real setting, also while EUI's force-show has it swapped out
local function RealVis(key)
    local p = Profile()
    if not p then return end
    local vis = p._myslotVisBackup
    return (vis and vis[key]) or (p.bars and p.bars[key])
end

local function IsShown(key)
    local p = Profile()
    -- enabled = false hides a bar outside the visibility fields
    if p and p.bars and p.bars[key] and p.bars[key].enabled == false then return false end
    local v = RealVis(key)
    return v ~= nil and ModeOf(v) ~= "never"
end

-- the one of 6/9 the profile shows; nil when both or neither
local function ShownBar()
    local s6, s9 = IsShown("Bar6"), IsShown("Bar9")
    if s6 == s9 then return nil end
    return s6 and "Bar6" or "Bar9"
end

local function SameAction(a, b)
    local ta, ia = GetActionInfo(a)
    local tb, ib = GetActionInfo(b)
    if IsSecret(ta) or IsSecret(ia) or IsSecret(tb) or IsSecret(ib) then return false end
    return ta == tb and ia == ib
end

local function CountSpells(key)
    local n = 0
    for i = 1, COUNT do
        if HasAction(Slot(key, i)) then n = n + 1 end
    end
    return n
end

local function KeysOf(key, i)
    return { GetBindingKey(BARS[key].cmd .. i) }
end

local function CountKeys(key)
    local n = 0
    for i = 1, COUNT do n = n + #KeysOf(key, i) end
    return n
end

-- buttons of toKey that a copy from fromKey would change
local function Changes(fromKey, toKey)
    local list = {}
    for i = 1, COUNT do
        if not SameAction(Slot(fromKey, i), Slot(toKey, i)) then list[#list + 1] = i end
    end
    return list
end

-- ----------------------------------------------------------------- keys

local keysAtRegen
local function MoveKeysTo(toKey)
    if InCombatLockdown() then keysAtRegen = toKey; return 0 end
    local from = OTHER[toKey]
    local moves = {}
    for i = 1, COUNT do
        for _, k in ipairs(KeysOf(from, i)) do moves[#moves + 1] = { k, BARS[toKey].cmd .. i } end
    end
    if #moves == 0 then return 0 end
    for _, m in ipairs(moves) do SetBinding(m[1], m[2]) end
    SaveBindings(GetCurrentBindingSet())
    return #moves
end

local function FollowKeys()
    if not S().barKeysFollow then return 0, nil end
    local shown = ShownBar()
    if not shown then return 0, nil end
    return MoveKeysTo(shown), shown
end

local function AutoFollow()
    local n, shown = FollowKeys()
    if n > 0 then
        Say(("moved %d keybind(s) to %s, the bar this profile shows."):format(n, BARS[shown].label))
    end
end

-- ------------------------------------------------------------ force-show

-- EUI's own guard for slot automation (its Myslot support): bars forced to
-- Always + Always Show Buttons so each pickup/place skips the secure
-- show/hide pass; the backup is persisted and restored at login if we die
local releaseAtRegen = false
local function EndForceShow()
    if InCombatLockdown() then releaseAtRegen = true; return end
    releaseAtRegen = false
    local eab = EAB()
    if eab and eab.SetMyslotForceShow then eab:SetMyslotForceShow(false) end
end

-- false when forcing already ran (Myslot's window owns it)
local function BeginForceShow()
    local eab, p = EAB(), Profile()
    if not (eab and eab.SetMyslotForceShow and p) or p._myslotVisBackup ~= nil then return false end
    eab:SetMyslotForceShow(true)
    return true
end

-- ---------------------------------------------------------------- placement

-- EUI stores a bar's place (position, grow, anchor and size links) in the live
-- stores and again in every spec/conditional unlock layout, applying a
-- layout's own copy on each spec swap. Bars 6 and 9 are kept identical in all
-- of them, and in the profiles that sync Action Bars, so the shown bar sits
-- in the same spot whatever the spec.

-- layer field -> live EllesmereUIDB table
local LINKS = {
    anchors = "unlockAnchors", widthMatch = "unlockWidthMatch", heightMatch = "unlockHeightMatch",
    widthMatchExtra = "unlockWidthMatchExtra", heightMatchExtra = "unlockHeightMatchExtra",
}

local function Copy(v) return type(v) == "table" and CopyTable(v) or v end

local function SwapTargets(links, a, b)
    local anchors = links.anchors
    for _, info in pairs(anchors or {}) do
        if type(info) == "table" then
            if info.target == a then info.target = b elseif info.target == b then info.target = a end
            local fb = info.fallback
            if type(fb) == "table" then
                if fb.target == a then fb.target = b elseif fb.target == b then fb.target = a end
            end
        end
    end
    for _, name in ipairs({ "widthMatch", "heightMatch" }) do
        local m = links[name]
        for child, target in pairs(m or {}) do
            if target == a then m[child] = b elseif target == b then m[child] = a end
        end
    end
end

-- a takes b's place in the live stores and b takes a's
local function SwapLive(a, b)
    local p, db = Profile(), _G.EllesmereUIDB
    local pos = p.barPositions
    if pos then pos[a], pos[b] = pos[b], pos[a] end
    local ba, bb = p.bars[a], p.bars[b]
    ba.growDirection, bb.growDirection = bb.growDirection, ba.growDirection
    local links = {}
    for name, live in pairs(LINKS) do
        local t = db[live]
        if type(t) == "table" then
            t[a], t[b] = t[b], t[a]
            links[name] = t
        end
    end
    SwapTargets(links, a, b)
end

local function LayersOf(prof)
    local out = {}
    local s = prof.specUnlockOverrides
    if s then
        if s.baselineLayout then out[#out + 1] = s.baselineLayout end
        for _, l in pairs(s.layouts or {}) do out[#out + 1] = l end
    end
    local cs = prof.condUnlockOverrides
    for _, l in pairs((cs and cs.layouts) or {}) do out[#out + 1] = l end
    return out
end

-- the live place of these bars into every stored copy of a profile
local function Broadcast(prof, isActive, keys)
    local p, db = Profile(), _G.EllesmereUIDB
    for _, key in ipairs(keys) do
        local pos = Copy(p.barPositions and p.barPositions[key])
        local grow = p.bars[key].growDirection
        for _, layer in ipairs(LayersOf(prof)) do
            if layer.abPos then layer.abPos[key] = Copy(pos) end
            if layer.abGrow then layer.abGrow[key] = grow end
            for name, live in pairs(LINKS) do
                local t = layer[name]
                if type(t) == "table" then t[key] = Copy(db[live] and db[live][key]) end
            end
        end
        local ul = prof.unlockLayout
        if type(ul) == "table" then
            for name, live in pairs(LINKS) do
                local t = ul[name]
                if type(t) == "table" then t[key] = Copy(db[live] and db[live][key]) end
            end
        end
        -- another profile's own module data; the active one IS the live store
        local ab = not isActive and prof.addons and prof.addons.EllesmereUIActionBars
        if type(ab) == "table" then
            ab.barPositions = ab.barPositions or {}
            ab.barPositions[key] = Copy(pos)
            if type(ab.bars) == "table" and type(ab.bars[key]) == "table" then
                ab.bars[key].growDirection = grow
            end
        end
    end
end

-- the active profile plus every profile syncing Action Bars with it
local function PlacementProfiles()
    local eui, db = ns.EUI(), _G.EllesmereUIDB
    local active = db and (db.activeProfile or "Default")
    local out = {}
    if not (active and db.profiles and db.profiles[active]) then return out end
    out[#out + 1] = { prof = db.profiles[active], active = true }
    local g = eui.GetSyncedProfiles and eui.GetSyncedProfiles("EllesmereUIActionBars") or {}
    if g[active] then
        for name, on in pairs(g) do
            if on and name ~= active and type(db.profiles[name]) == "table" then
                out[#out + 1] = { prof = db.profiles[name], name = name }
            end
        end
    end
    return out
end

-- returns the synced profiles that got it too
function ns.SpreadBarPlacement(keys)
    local synced = {}
    for _, t in ipairs(PlacementProfiles()) do
        Broadcast(t.prof, t.active, keys)
        if t.name then synced[#synced + 1] = t.name end
    end
    local eui = ns.EUI()
    eui._anchorLinksStamp = (eui._anchorLinksStamp or 0) + 1
    if eui._applySavedPositions then eui._applySavedPositions() end
    return synced
end

ns.BarProfile = Profile

-- ------------------------------------------------------------------ actions

local function RefreshPanel()
    local eui = ns.EUI()
    if eui and eui:IsShown() and eui.RefreshPage then eui:RefreshPage(true) end
end

-- auto: the per-spec fill, which only ever runs onto an empty bar
local function DoCopy(fromKey, toKey, auto)
    if InCombatLockdown() then Say("not in combat."); return end
    ClearCursor()
    local forced = BeginForceShow()
    for i = 1, COUNT do
        local s, d = Slot(fromKey, i), Slot(toKey, i)
        if not SameAction(s, d) then
            if HasAction(s) then
                -- true: a copy, the source keeps its action
                PickupAction(s, true)
                PlaceAction(d)
            elseif HasAction(d) then
                PickupAction(d)
            end
            -- only ever the target's old action or an undelivered copy
            ClearCursor()
        end
    end
    local keys = FollowKeys()
    if forced then C_Timer.After(1.5, EndForceShow) end
    -- the slots settle a moment later; report what actually arrived
    C_Timer.After(0.5, function()
        if InCombatLockdown() then return end
        local missed = Changes(fromKey, toKey)
        local msg
        if #missed == 0 and auto then
            msg = ("%s was empty on this spec: filled it from %s."):format(BARS[toKey].label, BARS[fromKey].label)
        elseif #missed == 0 then
            msg = ("copied %s onto %s for this spec."):format(BARS[fromKey].label, BARS[toKey].label)
        else
            msg = ("%d button(s) did not copy onto %s: %s."):format(#missed, BARS[toKey].label, table.concat(missed, ", "))
        end
        if keys > 0 then msg = msg .. (" %d keybind(s) moved to the shown bar."):format(keys) end
        Say(msg)
        RefreshPanel()
    end)
end

function ns.CopyActionBar(fromKey, toKey)
    if InCombatLockdown() then Say("not in combat."); return end
    local changes = Changes(fromKey, toKey)
    if #changes == 0 then Say(BARS[toKey].label .. " already matches " .. BARS[fromKey].label .. "."); return end
    local lost = 0
    for _, i in ipairs(changes) do
        if HasAction(Slot(toKey, i)) then lost = lost + 1 end
    end
    local eui = ns.EUI()
    if lost == 0 or not (eui and eui.ShowConfirmPopup) then
        DoCopy(fromKey, toKey)
        return
    end
    eui:ShowConfirmPopup({
        title = "Copy " .. BARS[fromKey].label,
        message = ("%d button(s) on %s will be replaced or cleared. %s stays as it is."):format(
            lost, BARS[toKey].label, BARS[fromKey].label),
        confirmText = "Copy",
        cancelText = "Cancel",
        onConfirm = function() DoCopy(fromKey, toKey) end,
    })
end

-- a simple Always/Never, clearing what would override the scalar
local function SetSimpleMode(eab, entry, mode)
    eab.VisibilityCompat.ApplyMode(entry, mode)
    entry.visibilityModes, entry.visibilityMatch = nil, nil
    for _, k in ipairs(EllesmereUI.VIS_OPT_KEYS or {}) do entry[k] = nil end
end

-- EUI's force-show backup holds the real visibility and its release writes and
-- applies it: fn(vis, bars, setMode) edits it there. False when unavailable.
function ns.EditBarVisibility(fn)
    local eab, p = EAB(), Profile()
    if not (eab and p and p.bars and eab.SetMyslotForceShow and eab.VisibilityCompat) then return false end
    local own = p._myslotVisBackup == nil
    if own then eab:SetMyslotForceShow(true) end
    local vis = p._myslotVisBackup
    if vis then
        fn(vis, p.bars, function(entry, mode) SetSimpleMode(eab, entry, mode) end)
    end
    if own then eab:SetMyslotForceShow(false) end
    return vis ~= nil
end

-- Pressing it on the bar that already shows re-spreads its place: that is the
-- repair for layouts that drifted apart before this existed.
function ns.ShowActionBar(key)
    if InCombatLockdown() then Say("not in combat."); return end
    local eab, p = EAB(), Profile()
    if not (eab and p and p.bars and eab.SetMyslotForceShow and eab.VisibilityCompat) then return end
    local other = OTHER[key]
    local wasShown = ShownBar() == key
    -- the newly shown bar takes the old one's spot
    local takeOver = IsShown(other) and not IsShown(key)

    if not wasShown then
        ns.EditBarVisibility(function(vis, bars, setMode)
            local s, o = bars[key], bars[other]
            if not (vis[key] and vis[other]) then return end
            if takeOver then
                -- the shown setup moves over whole (mouseover, conditions)
                vis[key], vis[other] = vis[other], vis[key]
                s.dragShow, o.dragShow = o.dragShow, s.dragShow
                s.spellbookShow, o.spellbookShow = o.spellbookShow, s.spellbookShow
                s.enabled, o.enabled = o.enabled, s.enabled
            else
                setMode(vis[key], "always")
                setMode(vis[other], "never")
                s.enabled = nil
            end
        end)
    end

    if takeOver then SwapLive(key, other) end
    local synced = ns.SpreadBarPlacement(ORDER)

    -- one Toggle Action Bar key, on the shown bar
    local s, o = p.bars[key], p.bars[other]
    if o.toggleVisKey ~= nil and (s.toggleVisKey == nil or s.toggleVisKey == o.toggleVisKey) then
        s.toggleVisKey, o.toggleVisKey = o.toggleVisKey, nil
    end
    if eab.RebuildVisToggleBindings then eab:RebuildVisToggleBindings() end

    local keys = FollowKeys()
    local msg = wasShown and (BARS[key].label .. " already shows; its place now matches in every spec layout.")
        or (BARS[key].label .. " is now the shown bar, in the same place in every spec layout.")
    if #synced > 0 then msg = msg .. " Also placed in " .. table.concat(synced, ", ") .. "." end
    if keys > 0 then msg = msg .. (" %d keybind(s) moved to it."):format(keys) end
    if CountSpells(key) == 0 then msg = msg .. " It is empty on this spec: copy onto it." end
    Say(msg)
    RefreshPanel()
end

-- WoW keeps action bars per spec: a spec never set up still has its spells
-- on the other bar. Only ever fills a bar with nothing on it.
local fillAtRegen = false
local function AutoFill()
    if not S().barAutoFill then return end
    if InCombatLockdown() then fillAtRegen = true; return end
    fillAtRegen = false
    local shown = ShownBar()
    if not shown then return end
    local other = OTHER[shown]
    if CountSpells(shown) == 0 and CountSpells(other) > 0 then
        DoCopy(other, shown, true)
    end
end

-- ---------------------------------------------------------------- wiring

local hooked = false
ns.maintainers[#ns.maintainers + 1] = function()
    local eui = ns.EUI()
    if hooked or not (eui and type(eui.RefreshAllAddons) == "function") then return end
    hooked = true
    -- a profile showing the other bar: after the swap has settled
    hooksecurefunc(eui, "RefreshAllAddons", function()
        C_Timer.After(1, AutoFollow)
        C_Timer.After(2, AutoFill)
    end)
end
ns.bootOnly[#ns.bootOnly + 1] = function()
    C_Timer.After(3, AutoFollow)
    C_Timer.After(4, AutoFill)
end

-- the new spec's action bars arrive a moment after the event
local specEv = CreateFrame("Frame")
specEv:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
specEv:SetScript("OnEvent", function(_, _, unit)
    if unit == "player" then C_Timer.After(2, AutoFill) end
end)

ns.onRegen[#ns.onRegen + 1] = function()
    if fillAtRegen then AutoFill() end
    if releaseAtRegen then EndForceShow() end
    if keysAtRegen then
        local k = keysAtRegen
        keysAtRegen = nil
        MoveKeysTo(k)
    end
end

-- ---------------------------------------------------------------------- page

local ICON, GAP = 34, 3
local cards = {}   -- key -> { icons, status } of the page on screen

local function KeyText(key, i)
    local k = KeysOf(key, i)[1]
    return k and GetBindingText(k, true) or ""
end

local function UpdateCard(key)
    local c = cards[key]
    if not c then return end
    for i, icon in ipairs(c.icons) do
        local slot = Slot(key, i)
        icon.tex:SetTexture(HasAction(slot) and GetActionTexture(slot) or nil)
        icon.key:SetText(KeyText(key, i))
    end
    local shown = IsShown(key)
    local eui = ns.EUI()
    local ar, ag, ab = 0.05, 0.82, 0.62
    if eui and eui.GetAccentColor then ar, ag, ab = eui.GetAccentColor() end
    local state = shown and ("|cff%02x%02x%02xShown in this profile|r"):format(ar * 255, ag * 255, ab * 255)
        or "|cff888888Hidden in this profile|r"
    c.status:SetText(("%s   %d/12 buttons on this spec   %d keybind(s)"):format(state, CountSpells(key), CountKeys(key)))
end

-- highlight: the buttons a copy onto this bar would change
local function MarkChanges(key, on)
    local c = cards[key]
    if not c then return end
    local changed = {}
    if on then
        for _, i in ipairs(Changes(OTHER[key], key)) do changed[i] = true end
    end
    for i, icon in ipairs(c.icons) do
        if changed[i] then
            icon.border:SetColor(1, 0.3, 0.3, 1)
        else
            icon.border:SetColor(1, 1, 1, 0.15)
        end
    end
end

local updater = CreateFrame("Frame")
updater:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
updater:RegisterEvent("UPDATE_BINDINGS")
updater:RegisterEvent("PLAYER_REGEN_ENABLED")
updater:SetScript("OnEvent", function()
    -- action info can be secret in combat; the regen event catches up
    if InCombatLockdown() then return end
    for key, c in pairs(cards) do
        if c.row:IsVisible() then UpdateCard(key) end
    end
end)

local function BuildCard(parent, y, key)
    local eui = ns.EUI()
    local W = eui.Widgets
    local pp = eui.PanelPP
    local bar, other = BARS[key], BARS[OTHER[key]]
    local _, h
    _, h = W:SectionHeader(parent, (bar.label .. " (" .. bar.note .. ")"):upper(), y); y = y - h

    local status = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    y = y - 20

    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(COUNT * (ICON + GAP), ICON)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    local icons = {}
    for i = 1, COUNT do
        local b = CreateFrame("Button", nil, row)
        b:SetSize(ICON, ICON)
        b:SetPoint("TOPLEFT", row, "TOPLEFT", (i - 1) * (ICON + GAP), 0)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.5)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        b.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.key = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
        b.key:SetPoint("TOPRIGHT", b, "TOPRIGHT", -1, -2)
        b.border = eui.MakeBorder(b, 1, 1, 1, 0.15, pp)
        local slot = Slot(key, i)
        b:SetScript("OnEnter", function(self)
            if not HasAction(slot) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetAction(slot)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        icons[i] = b
    end
    y = y - ICON - 12
    cards[key] = { icons = icons, status = status, row = row }
    UpdateCard(key)

    local btnRow
    btnRow, h = W:WideDualButton(parent, "Copy From " .. other.label, "Show This Bar", y,
        function() ns.CopyActionBar(OTHER[key], key) end,
        function() ns.ShowActionBar(key) end); y = y - h
    local btns = {}
    for _, c in ipairs({ btnRow:GetChildren() }) do
        if c:GetObjectType() == "Button" then btns[#btns + 1] = c end
    end
    if btns[1] then
        btns[1]:HookScript("OnEnter", function() MarkChanges(key, true) end)
        btns[1]:HookScript("OnLeave", function() MarkChanges(key, false) end)
    end
    if btns[2] and ShownBar() == key then btns[2]:SetAlpha(0.4) end
    return y
end

function ns.BuildActionBarsPage(parent, yOffset)
    local eui = ns.EUI()
    local W = eui and eui.Widgets
    if not W then return 0 end
    local y = yOffset
    local _, h
    wipe(cards)

    _, h = W:SectionHeader(parent, "ACTION BAR 6 AND 9", y); y = y - h
    local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    desc:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    desc:SetJustifyH("LEFT")
    desc:SetWidth(440)
    desc:SetText("ElvUI's Bar 6 is EUI's Action Bar 9. The shown bar is set per profile, its place is kept the same in every spec layout, and WoW keeps the spells per spec. Copy keeps the source bar, so a spec holding its spells on both works under any profile. Hover a Copy button to see which buttons change.")
    y = y - 64

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Keybinds Follow the Shown Bar",
          getValue = function() return S().barKeysFollow end,
          setValue = function(v)
              S().barKeysFollow = v
              if v then AutoFollow() end
              for key in pairs(cards) do UpdateCard(key) end
          end },
        { type = "toggle", text = "Fill the Shown Bar on Each Spec",
          getValue = function() return S().barAutoFill end,
          setValue = function(v)
              S().barAutoFill = v
              if v then AutoFill() end
          end }); y = y - h

    for _, key in ipairs(ORDER) do
        y = BuildCard(parent, y, key)
    end
    return math.abs(y)
end
