local _, ns = ...

local S = ns.S

-- ------------------------------------------------------ "Spell Name - Target"

local function TargetSuffix(channeling)
    if UnitSpellTargetName then
        -- the real cast-target API (what EUI's target/focus bars use); channels
        -- excluded: the API keeps returning the previous hard-cast's target
        if channeling then return nil end
        local tname = UnitSpellTargetName("player")
        if not tname then return nil end
        local hex
        if S().classColorTarget then
            local cls = UnitSpellTargetClass and UnitSpellTargetClass("player")
            local c = cls and C_ClassColor and C_ClassColor.GetClassColor(cls)
            hex = c and c.GenerateHexColor and c:GenerateHexColor() or nil
        end
        return tname, hex
    end
    -- old-client fallback: current target (wrong for @mouseover/@focus casts)
    if not UnitExists("target") then return nil end
    local tname = UnitName("target")
    if not tname or tname == "" then return nil end
    if S().classColorTarget then
        local classFile = UnitClassBase and UnitClassBase("target") or select(2, UnitClass("target"))
        local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
        if c and c.colorStr then return tname, c.colorStr end
    end
    return tname, nil
end

local hookedMini
local function HookCombine()
    local _, cb = ns.MiniBgFrame()
    if not (cb and type(cb.PostCastStart) == "function") then return end
    if cb == hookedMini then return end
    hookedMini = cb

    local function Decorate(self)
        if not S().combineNameTarget then return end
        if not self.Text then return end
        local spell = self.Text:GetText()
        if issecretvalue and issecretvalue(spell) then return end
        if not spell or spell == "" then return end
        local tname, hex = TargetSuffix(self.channeling and true or false)
        if not tname then return end
        if hex then
            self.Text:SetFormattedText("%s - |c%s%s|r", spell, hex, tname)
        else
            self.Text:SetFormattedText("%s - %s", spell, tname)
        end
        self._combineNT = true
        if type(self._layoutTextZones) == "function" then self:_layoutTextZones() end
    end

    hooksecurefunc(cb, "PostCastStart", Decorate)
    if type(cb.PostChannelStart) == "function" and cb.PostChannelStart ~= cb.PostCastStart then
        hooksecurefunc(cb, "PostChannelStart", Decorate)
    end
end

local hookedMainName
local mainWriting

local function DecorateMain(fs, text)
    if mainWriting then return end
    if issecretvalue and issecretvalue(text) then return end
    if not S().mainTargetName then return end
    if not text or text == "" then return end
    local frame = _G.ERB_CastBarFrame
    local start = frame and frame._startTime
    if not start then return end
    -- one decoration (or one decline) per cast start; BuildCastBar's reflow
    -- re-fires this hook with the already-decorated string
    if fs._twStart == start then return end
    fs._twStart = start
    local channeling = UnitChannelInfo and UnitChannelInfo("player") ~= nil
    local tname, hex = TargetSuffix(channeling)
    if not tname then return end
    mainWriting = true
    if hex then
        fs:SetFormattedText("%s - |c%s%s|r", text, hex, tname)
    else
        fs:SetFormattedText("%s - %s", text, tname)
    end
    mainWriting = false
end

local function HookMainName()
    local frame = _G.ERB_CastBarFrame
    local fs = frame and frame._nameText
    if not fs or fs == hookedMainName then return end
    hookedMainName = fs
    hooksecurefunc(fs, "SetText", DecorateMain)
end

-- ------------------------------------------------------- main castbar icon box

local iconBorder, iconBG, iconApplied

function ns.ApplyIconBorder()
    local frame = _G.ERB_CastBarFrame
    local iconFrame = frame and frame._iconFrame
    local icon = frame and frame._icon
    if not (iconFrame and icon) then return end
    local want = S().mainIconBorder and true or false
    if want == iconApplied then return end
    if want and not iconBorder then
        local eui = ns.EUI()
        local PP = eui and eui.PP
        if not (PP and PP.CreateBorder) then return end
        iconBG = iconFrame:CreateTexture(nil, "BACKGROUND")
        iconBG:SetAllPoints()
        iconBG:SetColorTexture(0, 0, 0, 1)
        iconBorder = CreateFrame("Frame", nil, iconFrame)
        iconBorder:SetAllPoints()
        PP.CreateBorder(iconBorder, 0, 0, 0, 1, 1)
    end
    if want then
        iconBorder:SetFrameLevel(iconFrame:GetFrameLevel() + 2)
        iconBorder:Show()
        iconBG:Show()
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
    elseif iconBorder then
        iconBorder:Hide()
        iconBG:Hide()
        icon:ClearAllPoints()
        icon:SetAllPoints(iconFrame)
    end
    iconApplied = want
end

ns.maintainers[#ns.maintainers + 1] = HookCombine
ns.maintainers[#ns.maintainers + 1] = HookMainName
ns.maintainers[#ns.maintainers + 1] = ns.ApplyIconBorder
ns.onSpecApply[#ns.onSpecApply + 1] = ns.ApplyIconBorder
