local _, ns = ...

local S = ns.S

-- ------------------------------------------------------- raid frame builder

-- Custom raid frame order via the secure header's own nameList sorting -- the
-- same mechanism EUI's Self First / merged Self Position features use. Listed
-- names sort first (list order), everyone else follows by raid index. Applied
-- OOC only; the secure engine does all per-frame work, zero runtime cost.
local function RF() return ns.ModuleNS("EllesmereUIRaidFrames") end

-- account-wide storage: raid rosters are account reality, and living OUTSIDE
-- the UF profile blob keeps layouts out of profile exports and safe from
-- profile imports overwriting them
function ns.RFB()
    local db = ns.legacy
    if not db then
        return { active = "Layout 1", layouts = { ["Layout 1"] = {} } }
    end
    local r = db.rfb
    if not r then
        r = { active = "Layout 1", layouts = { ["Layout 1"] = {} } }
        db.rfb = r
    end
    if type(r.layouts) ~= "table" then r.layouts = {} end
    if not r.active or type(r.layouts[r.active]) ~= "table" then
        local first
        for k, v in pairs(r.layouts) do
            if type(v) == "table" then first = k break end
        end
        if not first then first = "Layout 1"; r.layouts[first] = {} end
        r.active = first
    end
    return r
end
local RFB = ns.RFB

-- on/off is per-profile (rides spec-profile swaps and exports: FHT on, NHT
-- off lands by itself); only the layout lists live account-wide
function ns.RFBEnabled()
    return S().rfbEnabled == true
end

local function RFProfile()
    local eui = ns.EUI()
    local lite = eui and eui.Lite
    for _, entry in ipairs((lite and lite._dbRegistry) or {}) do
        if entry.folder == "EllesmereUIRaidFrames" and entry.profile then
            return entry.profile
        end
    end
end

-- EUI's LayoutGroups only PARKS its merged groupFilter -- instead of writing
-- it back every layout pass, which refill-fought our nameList every ~5s --
-- while their Self First/Last "owns" the header, and that gate reads the raw
-- setting (RaidFrames :7380). Keep Self First on while RFB is enabled on
-- this profile: our list overrides the order anyway, and the user's original
-- value comes back on disable.
local function EnforceSelfFirst()
    local p = RFProfile()
    if not p then return end
    local s = S()
    if ns.RFBEnabled() and p.mergeGroups then
        if p.showSelfFirst ~= true then
            if s.rfbSelfFirstWas == nil then
                s.rfbSelfFirstWas = p.showSelfFirst == true
            end
            p.showSelfFirst = true
        end
    elseif s.rfbSelfFirstWas ~= nil then
        if s.rfbSelfFirstWas == false then p.showSelfFirst = false end
        s.rfbSelfFirstWas = nil
    end
end
ns.maintainers[#ns.maintainers + 1] = EnforceSelfFirst

-- one-time migration: layouts used to live in each profile's UF blob (and so
-- rode profile exports); harvest every profile's copy into the account store
ns.bootOnly[#ns.bootOnly + 1] = function()
    local profs = _G.EllesmereUIDB and _G.EllesmereUIDB.profiles
    if not (profs and ns.legacy) then return end
    local dst
    local function Harvest(tw)
        local src = tw and tw.rfb
        if type(src) ~= "table" then return end
        dst = dst or RFB()
        for name, list in pairs(src.layouts or {}) do
            if type(list) == "table" and type(dst.layouts[name]) ~= "table" then
                dst.layouts[name] = list
            end
        end
        if src.active and type(dst.layouts[src.active]) == "table" then
            dst.active = src.active
        end
        tw.rfb = nil
    end
    for _, p in pairs(profs) do
        local uf = p.addons and p.addons.EllesmereUIUnitFrames
        Harvest(uf and uf.thingsTweaks)
    end
    Harvest(S())
    -- the interim account-wide enabled flag moves to the ACTIVE profile once;
    -- other profiles start off and get toggled where wanted
    local acc = ns.legacy.rfb
    if acc and acc.enabled ~= nil then
        if acc.enabled then S().rfbEnabled = true end
        acc.enabled = nil
    end
    -- drop the fresh-seed placeholder if real layouts came over
    if dst then
        local l1 = dst.layouts["Layout 1"]
        if type(l1) == "table" and #l1 == 0 then
            local other
            for k in pairs(dst.layouts) do
                if k ~= "Layout 1" then other = k break end
            end
            if other then
                dst.layouts["Layout 1"] = nil
                if dst.active == "Layout 1" then dst.active = other end
            end
        end
    end
end

local function StripRealm(n)
    local dash = n:find("-", 1, true)
    return dash and n:sub(1, dash - 1) or n
end

-- rank by exact full name, with a realm-stripped fallback so entries survive
-- realm transfers/merges in either direction
local function BuildRanks(list)
    local full, short = {}, {}
    for i, entry in ipairs(list) do
        local l = entry:lower()
        if full[l] == nil then full[l] = i end
        local s = StripRealm(l)
        if short[s] == nil then short[s] = i end
    end
    return full, short
end

local applyingOrder = false

local function OrderApplyTo(hdr, nl)
    -- mirror of EUI's applySortTo: nameList is only honored with groupFilter
    -- cleared and groupBy nil; expensive Hide/Show only on a real change
    if hdr:GetAttribute("nameList") == nl
        and hdr:GetAttribute("sortMethod") == "NAMELIST"
        and hdr:GetAttribute("groupBy") == nil
        and hdr:GetAttribute("groupFilter") == nil then
        return
    end
    applyingOrder = true
    hdr:Hide()
    hdr:SetAttribute("groupFilter", nil)
    hdr:SetAttribute("groupBy", nil)
    hdr:SetAttribute("sortMethod", "NAMELIST")
    hdr:SetAttribute("groupingOrder", "")
    hdr:SetAttribute("nameList", nl)
    hdr:Show()
    applyingOrder = false
end

-- Profile swaps rebuild the raid frames from scratch; writing our nameList
-- into half-built headers (or silencing their base sort mid-rebuild)
-- scrambles the whole layout. Stand down through the rebuild -- EUI owns the
-- headers -- then reassert once, settled.
local standUntil = 0
local standTimer
function ns.RaidBuilderStanddown(sec)
    sec = sec or 3
    standUntil = GetTime() + sec
    if standTimer then standTimer:Cancel() end
    standTimer = C_Timer.NewTimer(sec + 0.1, function()
        standTimer = nil
        ns.ApplyRaidOrder()
    end)
end
local function StandingDown() return GetTime() < standUntil end

-- ordered roster snapshot; nil while any name is unresolved (an omitted or
-- placeholder name would HIDE that member's frame -- same rule as EUI's own
-- nameList builders)
local function OrderedMembers()
    local r = RFB()
    local list = r.layouts[r.active]
    if not list or #list == 0 then return end
    local full, short = BuildRanks(list)
    local members = {}
    for i = 1, GetNumGroupMembers() do
        local name, _, subgroup = GetRaidRosterInfo(i)
        if not name or name == UNKNOWNOBJECT then return end
        local l = name:lower()
        members[#members + 1] = {
            name = name, subgroup = subgroup,
            rank = full[l] or short[StripRealm(l)] or 10000,
        }
    end
    if #members == 0 then return end
    -- name tiebreak, NOT raid index: subgroup moves shuffle everyone's index,
    -- so an index tiebreak turned one leader reshuffle into changed nameLists
    -- (= full frame refills) for every header; names are stable through moves
    table.sort(members, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.name < b.name
    end)
    return members
end

-- whole-raid list for the merged header, honoring the visible-groups filter
-- parked in ns._flatGfStr while a nameList owns the header
local function MergedNames(members)
    local rf = RF()
    local flat = _G.ERFFlatHeader
    local gf = (rf and rf._flatGfStr) or (flat and flat:GetAttribute("groupFilter"))
    local visible
    if gf and gf ~= "" then
        visible = {}
        for g in tostring(gf):gmatch("%d+") do visible[tonumber(g)] = true end
    end
    local names = {}
    for _, m in ipairs(members) do
        if not visible or visible[m.subgroup] then names[#names + 1] = m.name end
    end
    if #names > 0 then return table.concat(names, ",") end
end

local function GroupNames(members, g)
    local names = {}
    for _, m in ipairs(members) do
        if m.subgroup == g then names[#names + 1] = m.name end
    end
    if #names > 0 then return table.concat(names, ",") end
end

function ns.ApplyRaidOrder()
    if InCombatLockdown() or StandingDown() then return end
    if not (ns.RFBEnabled() and IsInRaid()) then return end
    local members = OrderedMembers()
    if not members then return end

    local flat = _G.ERFFlatHeader
    if flat and flat:IsShown() then
        local nl = MergedNames(members)
        if nl then OrderApplyTo(flat, nl) end
        return
    end

    -- separated mode: the list orders members within each subgroup
    for g = 1, 8 do
        local hdr = _G["ERFGroupHeader" .. g]
        if hdr and hdr:IsShown() then
            local nl = GroupNames(members, g)
            if nl then OrderApplyTo(hdr, nl) end
        end
    end
end

-- hand the headers back to EUI's own sorter (runs our wrapper; ApplyRaidOrder
-- no-ops while disabled, so their pass wins)
function ns.RestoreRaidOrder()
    local rf = RF()
    if rf and rf._ApplySortToHeaders and not InCombatLockdown() then
        rf._ApplySortToHeaders()
    end
end

-- RFB owns header sorting only while all of these hold; otherwise EUI's own
-- sorter must run untouched
local function Owns()
    if InCombatLockdown() or StandingDown() then return false end
    local r = RFB()
    if not (ns.RFBEnabled() and IsInRaid()) then return false end
    local list = r.layouts[r.active]
    return (list and #list > 0) and true or false
end

-- Roster-driven applies are throttled: a join/leave burst fires several
-- sorter passes per second and every REAL list change refills the header
-- (the expensive part), so a burst collapses to one leading + one trailing
-- apply; the trailing shot always lands the final roster state.
local lastApply = 0
local trailing
local function ThrottledApply()
    if GetTime() - lastApply >= 0.25 then
        lastApply = GetTime()
        ns.ApplyRaidOrder()
    elseif not trailing then
        trailing = C_Timer.NewTimer(0.3, function()
            trailing = nil
            lastApply = GetTime()
            ns.ApplyRaidOrder()
        end)
    end
end

-- EUI's LayoutGroups calls its sorter LOCALLY at the end of every merged
-- pass (out of reach of the ns re-point), and with Self First on that path
-- applied THEIR merged list -- a refill war with ours every ~5s. The list
-- BUILDERS are ns-called, so re-point those: while RFB owns, every path
-- (local calls included) builds OUR list, and their content-gated applier
-- then sees identical attributes and writes nothing at all.
local bmWrapped, bmOrig, bsWrapped, bsOrig
local function WrapSelfListBuilders()
    local rf = RF()
    if not rf then return end
    local cm = rf._BuildMergedSelfNameList
    if cm and cm ~= bmWrapped then
        bmOrig = cm
        bmWrapped = function(...)
            if Owns() then
                local m = OrderedMembers()
                local nl = m and MergedNames(m)
                if nl then return nl end
            end
            return bmOrig(...)
        end
        rf._BuildMergedSelfNameList = bmWrapped
    end
    local cs = rf._BuildSelfFirstNameList
    if cs and cs ~= bsWrapped then
        bsOrig = cs
        bsWrapped = function(playerGroup, ...)
            if Owns() then
                local m = OrderedMembers()
                local nl = m and GroupNames(m, playerGroup)
                if nl then return nl end
            end
            return bsOrig(playerGroup, ...)
        end
        rf._BuildSelfFirstNameList = bsWrapped
    end
end
ns.maintainers[#ns.maintainers + 1] = WrapSelfListBuilders

-- EUI's event paths call the sorter VIA the module ns, so re-pointing the ns
-- entry composes with every roster/settings pass; the two load-time local
-- calls are covered by the header attribute hooks below
local rfWrapped
local function WrapRaidSort()
    local rf = RF()
    if not rf then return end
    local cur = rf._ApplySortToHeaders
    if not cur or cur == rfWrapped then return end
    local orig = cur
    rfWrapped = function(...)
        -- while RFB owns, their sorter must not write AT ALL: alternating
        -- INDEX/NAMELIST attrs made every roster event two full header
        -- refills (the join/leave lag spike) and defeated both change-gates
        if Owns() then
            ThrottledApply()
        else
            orig(...)
        end
    end
    rf._ApplySortToHeaders = rfWrapped
end

local orderQueued = false
function ns.QueueRaidOrder()
    if orderQueued then return end
    orderQueued = true
    C_Timer.After(0, function()
        orderQueued = false
        ns.ApplyRaidOrder()
    end)
end

local hookedHeaders = setmetatable({}, { __mode = "k" })
local ORDER_ATTRS = { nameList = true, groupBy = true, sortMethod = true, groupFilter = true }

local function HookRaidHeaders()
    local function hook(hdr)
        if not hdr or hookedHeaders[hdr] then return end
        hookedHeaders[hdr] = true
        hooksecurefunc(hdr, "SetAttribute", function(_, attr)
            if applyingOrder then return end
            if type(attr) == "string" and ORDER_ATTRS[attr] and ns.RFBEnabled() then
                ns.QueueRaidOrder()
            end
        end)
        -- a newly discovered header was laid out before we could see it
        ns.QueueRaidOrder()
    end
    hook(_G.ERFFlatHeader)
    for g = 1, 8 do hook(_G["ERFGroupHeader" .. g]) end
end

ns.maintainers[#ns.maintainers + 1] = WrapRaidSort
ns.maintainers[#ns.maintainers + 1] = HookRaidHeaders
ns.bootOnly[#ns.bootOnly + 1] = ns.QueueRaidOrder
ns.onSpecApply[#ns.onSpecApply + 1] = ns.QueueRaidOrder

-- ------------------------------------------------ raid frame builder: editor

local function FullUnitName(unit)
    local n, realm = UnitName(unit)
    if not n or n == "" or n == UNKNOWNOBJECT then return nil end
    if realm and realm ~= "" then n = n .. "-" .. realm end
    return n
end

-- roster name -> class color escape (editor coloring only, resolved per refresh)
local function RosterClassColors()
    local map = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name, _, _, _, _, classFile = GetRaidRosterInfo(i)
            if name and classFile then
                local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
                if c and c.colorStr then map[name:lower()] = c.colorStr end
            end
        end
    elseif IsInGroup() then
        local units = { "player" }
        for i = 1, 4 do units[#units + 1] = "party" .. i end
        for _, unit in ipairs(units) do
            local full = UnitExists(unit) and FullUnitName(unit)
            if full then
                local _, classFile = UnitClass(unit)
                local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
                if c and c.colorStr then map[full:lower()] = c.colorStr end
            end
        end
    end
    return map
end

local function ListAdd(list, entry)
    entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
    if entry == "" then return false end
    local l = entry:lower()
    for _, e in ipairs(list) do
        if e:lower() == l then return false end
    end
    list[#list + 1] = entry
    return true
end

local ROW_H = 22

-- shared drag ghost (one per session, shown only while dragging)
local dragGhost
local function DragGhost()
    if dragGhost then return dragGhost end
    local g = CreateFrame("Frame", nil, UIParent)
    g:SetFrameStrata("TOOLTIP")
    g:SetSize(180, ROW_H)
    g:Hide()
    local bg = g:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.75)
    g.text = g:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    g.text:SetPoint("LEFT", 6, 0)
    g.line = g:CreateTexture(nil, "OVERLAY")
    g.line:SetColorTexture(0.05, 0.82, 0.62, 0.9)
    g.line:SetSize(200, 2)
    g.line:Hide()
    g:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / s + 12, y / s - 8)
        if self.slotFn then self.slotFn(y) end
    end)
    dragGhost = g
    return g
end

function ns.BuildRaidBuilderPage(parent, yOffset)
    local eui = ns.EUI()
    local W = eui and eui.Widgets
    if not W then return 0 end
    local y = yOffset
    local _, h

    local rows = {}
    local listBox           -- container the rows anchor into
    local RefreshRows       -- forward decl

    local function RefreshPanel()
        if eui.RefreshPage then eui:RefreshPage(true) end
    end

    local function Mutated(structural)
        ns.ApplyRaidOrder()
        if structural then RefreshPanel() else RefreshRows() end
    end

    _, h = W:SectionHeader(parent, "RAID FRAME BUILDER", y); y = y - h
    _, h = W:Toggle(parent, "Enable Custom Raid Order", y,
        function() return ns.RFBEnabled() end,
        function(v)
            S().rfbEnabled = v and true or nil
            EnforceSelfFirst()
            if v then ns.ApplyRaidOrder() else ns.RestoreRaidOrder() end
        end,
        "Sorts the raid frames by the active name list. Listed names come first, in list order; everyone else follows alphabetically. With Merge Groups the whole raid follows one order; with separated groups the order applies within each group. Keeps EUI's Show Self First on while enabled (EUI then parks its group filter instead of fighting the custom order)."); y = y - h

    -- active layout picker
    local names, order = {}, {}
    do
        local r = RFB()
        for k in pairs(r.layouts) do order[#order + 1] = k end
        table.sort(order)
        for _, k in ipairs(order) do
            names[k] = ("%s  |cff888888(%d)|r"):format(k, #r.layouts[k])
        end
    end
    _, h = W:WideDropdown(parent, "Active Layout", y, names,
        function() return RFB().active end,
        function(v)
            local r = RFB()
            if r.layouts[v] then r.active = v end
            ns.ApplyRaidOrder()
            RefreshPanel()
        end, order); y = y - h

    -- new-layout name + New/Copy/Delete
    local nameBox = CreateFrame("EditBox", nil, parent)
    nameBox:SetSize(180, 22)
    nameBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y - 2)
    nameBox:SetAutoFocus(false)
    nameBox:SetFontObject(GameFontHighlightSmall)
    nameBox:SetTextInsets(6, 6, 0, 0)
    nameBox:SetMaxLetters(40)
    local nbg = nameBox:CreateTexture(nil, "BACKGROUND")
    nbg:SetAllPoints()
    nbg:SetColorTexture(0, 0, 0, 0.4)
    nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
    nameBox:SetScript("OnEnterPressed", nameBox.ClearFocus)
    local nameHint = nameBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    nameHint:SetPoint("LEFT", 6, 0)
    nameHint:SetText("new layout name...")
    nameBox:SetScript("OnTextChanged", function(self)
        nameHint:SetShown(self:GetText() == "")
    end)
    y = y - 26

    local function NewLayout(copyActive)
        local r = RFB()
        local nm = nameBox:GetText():gsub("^%s+", ""):gsub("%s+$", "")
        if nm == "" or r.layouts[nm] then return end
        local src = copyActive and r.layouts[r.active] or nil
        local t = {}
        if src then for i, e in ipairs(src) do t[i] = e end end
        r.layouts[nm] = t
        r.active = nm
        nameBox:SetText("")
        ns.ApplyRaidOrder()
        RefreshPanel()
    end
    _, h = W:WideTripleButton(parent, "New", "Copy To New", "Delete Layout", y,
        function() NewLayout(false) end,
        function() NewLayout(true) end,
        function()
            local r = RFB()
            r.layouts[r.active] = nil
            RFB()  -- re-seeds active (and a layout if none left)
            ns.ApplyRaidOrder()
            RefreshPanel()
        end); y = y - h

    _, h = W:Spacer(parent, y, 8); y = y - h
    _, h = W:SectionHeader(parent, "NAMES", y); y = y - h

    -- add-name box: single names or a pasted comma-separated list
    local addBox = CreateFrame("EditBox", nil, parent)
    addBox:SetSize(280, 22)
    addBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y - 2)
    addBox:SetAutoFocus(false)
    addBox:SetFontObject(GameFontHighlightSmall)
    addBox:SetTextInsets(6, 6, 0, 0)
    addBox:SetMaxLetters(4000)
    local abg = addBox:CreateTexture(nil, "BACKGROUND")
    abg:SetAllPoints()
    abg:SetColorTexture(0, 0, 0, 0.4)
    local addHint = addBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    addHint:SetPoint("LEFT", 6, 0)
    addHint:SetText("Name or Name-Realm, or paste a comma-separated list...")
    addBox:SetScript("OnTextChanged", function(self)
        addHint:SetShown(self:GetText() == "")
    end)
    addBox:SetScript("OnEscapePressed", addBox.ClearFocus)
    local function CommitAdd()
        local r = RFB()
        local list = r.layouts[r.active]
        local txt = addBox:GetText()
        local added = false
        for entry in txt:gmatch("[^,]+") do
            if ListAdd(list, entry) then added = true end
        end
        addBox:SetText("")
        addBox:ClearFocus()
        if added then Mutated(true) end
    end
    addBox:SetScript("OnEnterPressed", CommitAdd)
    y = y - 26

    _, h = W:WideTripleButton(parent, "Add Names", "Add Raid Roster", "Add Target", y,
        CommitAdd,
        function()
            local r = RFB()
            local list = r.layouts[r.active]
            local added = false
            if IsInRaid() then
                for i = 1, GetNumGroupMembers() do
                    local name = GetRaidRosterInfo(i)
                    if name and name ~= UNKNOWNOBJECT and ListAdd(list, name) then added = true end
                end
            elseif IsInGroup() then
                local units = { "player" }
                for i = 1, 4 do units[#units + 1] = "party" .. i end
                for _, unit in ipairs(units) do
                    local full = UnitExists(unit) and FullUnitName(unit)
                    if full and ListAdd(list, full) then added = true end
                end
            end
            if added then Mutated(true) end
        end,
        function()
            if not UnitExists("target") or not UnitIsPlayer("target") then return end
            local full = FullUnitName("target")
            local r = RFB()
            if full and ListAdd(r.layouts[r.active], full) then Mutated(true) end
        end); y = y - h

    -- the ordered list
    local r0 = RFB()
    local list0 = r0.layouts[r0.active]
    listBox = CreateFrame("Frame", nil, parent)
    listBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    listBox:SetSize(430, math.max(1, #list0 * ROW_H))

    local function MoveEntry(from, to)
        local r = RFB()
        local list = r.layouts[r.active]
        if not list[from] then return end
        to = math.max(1, math.min(to, #list))
        if from == to then return end
        local e = table.remove(list, from)
        table.insert(list, to, e)
        Mutated(false)
    end

    local dragIdx
    local function StopDrag(commit)
        local g = DragGhost()
        g.slotFn = nil
        g:Hide()
        g.line:Hide()
        if commit and dragIdx and g.dropSlot then
            local to = g.dropSlot
            if to > dragIdx then to = to - 1 end
            MoveEntry(dragIdx, to)
        end
        dragIdx = nil
    end

    local function RowForIndex(i)
        local row = rows[i]
        if row then return row end
        row = CreateFrame("Button", nil, listBox)
        row:SetSize(430, ROW_H)
        row:SetPoint("TOPLEFT", listBox, "TOPLEFT", 0, -(i - 1) * ROW_H)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0.015)
        row.num = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.num:SetPoint("LEFT", 4, 0)
        row.num:SetWidth(24)
        row.num:SetJustifyH("RIGHT")
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 34, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWidth(300)

        local function SmallBtn(offX, label, onClick)
            local b = CreateFrame("Button", nil, row)
            b:SetSize(18, 18)
            b:SetPoint("RIGHT", row, "RIGHT", offX, 0)
            b.t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.t:SetPoint("CENTER")
            b.t:SetText(label)
            b:SetScript("OnEnter", function(s) s.t:SetTextColor(0.05, 0.82, 0.62) end)
            b:SetScript("OnLeave", function(s) s.t:SetTextColor(1, 1, 1) end)
            b:SetScript("OnClick", function() onClick(row.idx) end)
            return b
        end
        SmallBtn(-4,  "x", function(idx)
            local r = RFB()
            table.remove(r.layouts[r.active], idx)
            Mutated(true)
        end)
        SmallBtn(-26, "v", function(idx) MoveEntry(idx, idx + 1) end)
        SmallBtn(-46, "^", function(idx) MoveEntry(idx, idx - 1) end)

        row:RegisterForDrag("LeftButton")
        row:SetScript("OnClick", function(s)
            if IsShiftKeyDown() then MoveEntry(s.idx, 1) end
        end)
        row:SetScript("OnDragStart", function(s)
            dragIdx = s.idx
            local g = DragGhost()
            g.text:SetText(s.name:GetText() or "")
            g:Show()
            g.dropSlot = s.idx
            g.slotFn = function(rawY)
                -- cursor is physical; GetTop is in the frame's effective scale
                local es = listBox:GetEffectiveScale()
                local top = listBox:GetTop()
                if not (top and es and es > 0) then return end
                local cy = rawY / es
                local r = RFB()
                local cnt = #r.layouts[r.active]
                local slot = math.floor((top - cy) / ROW_H + 0.5) + 1
                slot = math.max(1, math.min(slot, cnt + 1))
                g.dropSlot = slot
                g.line:ClearAllPoints()
                g.line:SetPoint("TOPLEFT", listBox, "TOPLEFT", -2, -(slot - 1) * ROW_H + 1)
                g.line:SetWidth(434)
                g.line:Show()
            end
        end)
        row:SetScript("OnDragStop", function() StopDrag(true) end)
        row:SetScript("OnHide", function() if dragIdx then StopDrag(false) end end)
        rows[i] = row
        return row
    end

    RefreshRows = function()
        local r = RFB()
        local list = r.layouts[r.active]
        local colors = RosterClassColors()
        for i, entry in ipairs(list) do
            local row = RowForIndex(i)
            row.idx = i
            row.num:SetText(i .. ".")
            local hex = colors[entry:lower()]
            if not hex then
                -- realm-stripped match (same fallback the sorter uses)
                for full, c in pairs(colors) do
                    if StripRealm(full) == StripRealm(entry:lower()) then hex = c break end
                end
            end
            if hex then
                row.name:SetFormattedText("|c%s%s|r", hex, entry)
            else
                row.name:SetFormattedText("|cff9d9d9d%s|r", entry)
            end
            row:Show()
        end
        for i = #list + 1, #rows do rows[i]:Hide() end
        listBox:SetHeight(math.max(1, #list * ROW_H))
    end
    RefreshRows()
    y = y - #list0 * ROW_H - 8

    local footer = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    footer:SetJustifyH("LEFT")
    footer:SetWidth(430)
    footer:SetText("Drag rows (or use ^ / v) to reorder - shift-click sends a name to the top - x removes.\nColored names are in your current group. Cross-realm players need Name-Realm, exactly like the raid roster shows them.\nFull cross-group ordering needs Raid Frames -> Merge Groups; with separated groups the order applies inside each group.")
    y = y - 44

    return math.abs(y)
end
