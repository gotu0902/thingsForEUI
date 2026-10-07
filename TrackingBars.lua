local _, ns = ...

local S = ns.S

-- ---------------------------------------------------- tracking bar icon seam

local tbbHolders = setmetatable({}, { __mode = "k" })
local tbbHooked = false

local function StyleTBBIcon(wrap)
    local icon = wrap and wrap._icon
    if not icon then return end
    local eui = ns.EUI()
    local PP = eui and eui.PP
    if not (PP and PP.CreateBorder and PP.GetBorders and PP.SetBorderSize) then return end
    local holder = tbbHolders[wrap]
    if not S().tbbIconBorder then
        if holder then holder:Hide() end
        return
    end
    if not holder then
        holder = CreateFrame("Frame", nil, icon)
        holder:SetAllPoints()
        PP.CreateBorder(holder, 0, 0, 0, 1, 1)
        tbbHolders[wrap] = holder
    end
    holder:Show()
    holder:SetFrameLevel(icon:GetFrameLevel() + 2)
    -- draw only the bar-facing strip; the wrap border owns the outer edges.
    -- the bar-facing edge is read off the fill's actual inset offsets
    local sb = wrap._bar
    if not sb then return end
    local seam
    for j = 1, sb:GetNumPoints() do
        local point, _, _, x, y = sb:GetPoint(j)
        if point == "TOPLEFT" then
            if x > 0.5 then seam = "right"
            elseif y < -0.5 then seam = "bottom" end
        elseif point == "BOTTOMRIGHT" then
            if x < -0.5 then seam = "left"
            elseif y > 0.5 then seam = "top" end
        end
    end
    if not seam then
        holder:Hide()
        return
    end
    local edges = PP.GetBorders(holder)
    if not edges then return end
    local hT = seam ~= "top" or nil
    local hB = seam ~= "bottom" or nil
    local hL = seam ~= "left" or nil
    local hR = seam ~= "right" or nil
    if edges._hideTop ~= hT or edges._hideBottom ~= hB
        or edges._hideLeft ~= hL or edges._hideRight ~= hR then
        edges._hideTop, edges._hideBottom = hT, hB
        edges._hideLeft, edges._hideRight = hL, hR
        PP.SetBorderSize(holder, 1)
    end
end

function ns.ApplyTBBIcons()
    local i, wrap = 1, _G.ECME_TBBWrap1
    while wrap do
        StyleTBBIcon(wrap)
        i = i + 1
        wrap = _G["ECME_TBBWrap" .. i]
    end
end

local function HookTBB()
    if tbbHooked then return end
    local eui = ns.EUI()
    if not (eui and type(eui.ApplyBorderStyle) == "function") then return end
    tbbHooked = true
    -- fires as the last styling step of every tracking-bar apply pass
    hooksecurefunc(eui, "ApplyBorderStyle", function(borderFrame)
        local p = borderFrame and borderFrame.GetParent and borderFrame:GetParent()
        local n = p and p.GetName and p:GetName()
        if n and n:sub(1, 12) == "ECME_TBBWrap" then StyleTBBIcon(p) end
    end)
end

ns.maintainers[#ns.maintainers + 1] = HookTBB
ns.maintainers[#ns.maintainers + 1] = ns.ApplyTBBIcons
ns.onSpecApply[#ns.onSpecApply + 1] = ns.ApplyTBBIcons
