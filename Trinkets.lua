local _, ns = ...

-- ------------------------------------------------------- trinket blacklist

-- Use trinkets that should never show on the Cooldown Manager. EUI shows a
-- trinket two ways: its own slot frame (slot 13/14 on a bar), kept only while
-- that frame reads as on-use, and Blizzard's native equipment rows, routed like
-- any cooldown. A blacklisted item reads as passive to the first and routes to
-- EUI's hidden bar in the second: both are EUI's own hiding paths.

local SLOTS = { 13, 14 }

local function Say(msg) print("|cff8AC8FFthings|r Trinkets: " .. msg) end

-- account-wide: a trinket you never want to see is not a per-profile thing
local function List()
    local db = ns.legacy
    if not db then return {} end
    db.trinketBlacklist = db.trinketBlacklist or {}
    return db.trinketBlacklist
end

local function Blocked(itemID)
    return itemID ~= nil and List()[itemID] == true
end

local function CDM() return ns.ModuleNS("EllesmereUICooldownManager") end

-- slot frames: EUI re-derives _trinketIsOnUse and then queues a reanchor, so
-- setting it right behind every queue lands before the layout reads it
local forced = {}
local function ApplyFrames()
    local cdm = CDM()
    local frames = cdm and cdm._trinketFrames
    if not frames then return end
    for _, slot in ipairs(SLOTS) do
        local f = frames[slot]
        if f then
            if Blocked(GetInventoryItemID("player", slot)) then
                f._trinketIsOnUse = false
                forced[slot] = true
            elseif forced[slot] then
                forced[slot] = nil
                -- nil makes EUI's next layout re-run its own on-use scan
                f._trinketIsOnUse = nil
            end
        end
    end
end

-- native equipment rows: the passive-hide route, see PassiveCDs.lua
ns.cdHideChecks = ns.cdHideChecks or {}
ns.cdHideChecks[#ns.cdHideChecks + 1] = function(info)
    local es = info.equipSlot
    if es == nil or (issecretvalue and issecretvalue(es)) then return false end
    return Blocked(GetInventoryItemID("player", es))
end

local function Refresh()
    ApplyFrames()
    -- rebuilds the route map (and the check above) and queues a reanchor
    if ns.RefreshPassiveHide then ns.RefreshPassiveHide() end
end

local hooked = false
ns.maintainers[#ns.maintainers + 1] = function()
    local cdm = CDM()
    if hooked or not (cdm and type(cdm.QueueReanchor) == "function") then return end
    hooked = true
    hooksecurefunc(cdm, "QueueReanchor", ApplyFrames)
    ApplyFrames()
end
ns.bootOnly[#ns.bootOnly + 1] = function()
    if next(List()) then Refresh() end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:SetScript("OnEvent", function(_, _, slot)
    if (slot == 13 or slot == 14) and next(List()) then Refresh() end
    local eui = ns.EUI()
    if eui and eui:IsShown() and eui.RefreshPage and eui.GetPluginModuleKey
        and eui:GetActiveModule() == eui.GetPluginModuleKey(ns.ADDON, ns.PLUGIN_MODULE) then
        eui:RefreshPage(true)
    end
end)

local function SetBlocked(itemID, on)
    List()[itemID] = on and true or nil
    Refresh()
end

-- ---------------------------------------------------------------------- page

local ICON, GAP = 34, 4

local function ItemLabel(itemID, fs, prefix)
    local item = Item:CreateFromItemID(itemID)
    fs:SetText(prefix .. "item " .. itemID)
    item:ContinueOnItemLoad(function()
        fs:SetText(prefix .. (item:GetItemName() or ("item " .. itemID)) .. "  |cff888888" .. itemID .. "|r")
    end)
end

local function Icon(parent, eui, x, y, texture, r, g, b, a)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(ICON, ICON)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    tex:SetTexture(texture)
    btn.tex = tex
    eui.MakeBorder(btn, r, g, b, a, eui.PanelPP)
    return btn
end

function ns.BuildTrinketsPage(parent, yOffset)
    local eui = ns.EUI()
    local W = eui and eui.Widgets
    if not W then return 0 end
    local y = yOffset
    local _, h
    local function RefreshPanel()
        if eui.RefreshPage then eui:RefreshPage(true) end
    end

    _, h = W:SectionHeader(parent, "TRINKET BLACKLIST", y); y = y - h
    local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    desc:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    desc:SetJustifyH("LEFT")
    desc:SetWidth(440)
    desc:SetText("Blacklisted trinkets never show on the Cooldown Manager bars, in either trinket slot. Saved for your whole account. Bars with Show Passive Trinkets on still show them.")
    y = y - 40

    -- equipped
    _, h = W:SectionHeader(parent, "EQUIPPED", y); y = y - h
    for i, slot in ipairs(SLOTS) do
        local itemID = GetInventoryItemID("player", slot)
        local blocked = Blocked(itemID)
        local tex = itemID and GetInventoryItemTexture("player", slot) or nil
        local btn = blocked and Icon(parent, eui, 20, y, tex, 1, 0.3, 0.3, 1)
            or Icon(parent, eui, 20, y, tex, 1, 1, 1, 0.15)
        if itemID then
            btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetInventoryItem("player", slot)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", btn, "RIGHT", 10, 0)
        local prefix = ("Trinket %d:  "):format(i)
        if itemID then
            ItemLabel(itemID, fs, prefix .. (blocked and "|cffff5555[blacklisted]|r  " or ""))
        else
            fs:SetText(prefix .. "|cff888888empty|r")
        end
        y = y - ICON - GAP
    end
    y = y - 8

    local function SlotLabel(i)
        local id = GetInventoryItemID("player", SLOTS[i])
        return (Blocked(id) and "Unblock Trinket " or "Blacklist Trinket ") .. i
    end
    local function ToggleSlot(i)
        local id = GetInventoryItemID("player", SLOTS[i])
        if not id then Say("trinket slot " .. i .. " is empty."); return end
        SetBlocked(id, not Blocked(id))
        RefreshPanel()
    end
    _, h = W:WideDualButton(parent, SlotLabel(1), SlotLabel(2), y,
        function() ToggleSlot(1) end,
        function() ToggleSlot(2) end); y = y - h

    -- the list
    _, h = W:SectionHeader(parent, "BLACKLISTED", y); y = y - h
    _, h = W:WideButton(parent, "Add by Item ID", y, function()
        if not eui.ShowInputPopup then return end
        eui:ShowInputPopup({
            title = "Blacklist Trinket",
            message = "Item ID of the trinket to hide:",
            placeholder = "e.g. 219314",
            confirmText = "Add",
            cancelText = "Cancel",
            onConfirm = function(text)
                local id = tonumber(text and strtrim(text) or "")
                if not (id and C_Item.GetItemInfoInstant(id)) then
                    Say("'" .. tostring(text) .. "' is not an item ID.")
                    return
                end
                SetBlocked(id, true)
                RefreshPanel()
            end,
        })
    end); y = y - h

    local ids = {}
    for id in pairs(List()) do ids[#ids + 1] = id end
    table.sort(ids)
    if #ids == 0 then
        local none = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        none:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
        none:SetText("Nothing blacklisted.")
        return math.abs(y - 30)
    end

    local hint = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    hint:SetText("Click a trinket to take it off the list.")
    y = y - 20
    for _, id in ipairs(ids) do
        local btn = Icon(parent, eui, 20, y, C_Item.GetItemIconByID(id), 1, 0.3, 0.3, 1)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(id)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click to remove from the blacklist.", 1, 0.82, 0)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        btn:SetScript("OnClick", function()
            GameTooltip:Hide()
            SetBlocked(id, false)
            RefreshPanel()
        end)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", btn, "RIGHT", 10, 0)
        ItemLabel(id, fs, "")
        y = y - ICON - GAP
    end
    return math.abs(y - 10)
end
