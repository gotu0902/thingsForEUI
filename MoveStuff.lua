local _, ns = ...

local S = ns.S

-- ------------------------------------------------------------ move that stuff

-- Minimap (and whatever sits on it) to the top-right corner, player buffs and
-- debuffs mirrored in beside it, damage meter windows into the bottom-right
-- corner it left, BNet toast under it. Every write goes through the element's
-- own unlock writer, and every stored unlock layout that carries the key gets
-- the same position -- EUI paints a layout's own positions on spec swaps.
-- Both states are snapshotted when left, so tweaks made in either survive.

local MM, BUFFS, DEBUFFS, TOAST = "EBS_Minimap", "PAB_Buffs", "PAB_Debuffs", "ECHAT_BNToast"
local UF = "EllesmereUIUnitFrames"

local GROW = {
    buffs   = { key = BUFFS,   sub = "defaultBuffs",   isBuff = true },
    debuffs = { key = DEBUFFS, sub = "defaultDebuffs", isBuff = false },
}

-- minimap button row, mirrored top <-> bottom with the map
local ROW_FLIP = {
    trLeft = "brLeft", brLeft = "trLeft", trDown = "brUp", brUp = "trDown",
    tlDown = "blUp", blUp = "tlDown", tlRight = "blRight", blRight = "tlRight",
}

local function Say(msg) print("|cff8AC8FFthings|r Move That Stuff: " .. msg) end

local function IsSecret(v) return issecretvalue and issecretvalue(v) end

local function Elems()
    local eui = ns.EUI()
    return (eui and eui._unlockRegisteredElements) or {}
end

local function Anchored(key)
    local db = _G.EllesmereUIDB
    local a = db and db.unlockAnchors
    local info = a and a[key]
    return type(info) == "table" and info.target ~= nil
end

-- anchored elements follow their target through EUI's own chain
local function Usable(key)
    local elem = Elems()[key]
    if not (elem and elem.savePosition) then return end
    if elem.isHidden and elem.isHidden(key) then return end
    if Anchored(key) or (elem.isAnchored and elem.isAnchored(key)) then return end
    return elem
end

local function MinimapCfg()
    local db = _G._EMM_DB
    return db and db.profile and db.profile.minimap
end

local function Snap(v)
    local pp = ns.EUI().PP
    if pp and pp.Snap then return pp.Snap(v) end
    return math.floor(v + 0.5)
end

-- an edge gap the layout already uses, else one physical pixel
local function Gap(v)
    if v and v >= 0 and v <= 64 then return v end
    local pp = ns.EUI().PP
    return (pp and pp.mult) or 1
end

-- UIParent units, origin at UIParent's center: EUI's CENTER/CENTER space
local function Rect(key, elem)
    local eui = ns.EUI()
    local frame = elem.getFrame and elem.getFrame(key)
    local ratio = frame and (frame:GetEffectiveScale() / UIParent:GetEffectiveScale()) or 1
    local w, h
    if elem.getSize then w, h = elem.getSize(key) end
    if IsSecret(w) or IsSecret(h) or type(w) ~= "number" or type(h) ~= "number" then return end
    w, h = w * ratio, h * ratio
    local cx, cy
    local pos = elem.loadPosition and elem.loadPosition(key)
    if pos and pos.point and pos.x and pos.y then
        local rp = pos.relPoint or pos.point
        if pos.point == "CENTER" and rp == "CENTER" then
            cx, cy = pos.x, pos.y
        elseif eui.ConvertToCenterPos then
            local _, _, x, y = eui.ConvertToCenterPos(key, pos.point, rp, pos.x, pos.y)
            cx, cy = x, y
        end
    end
    if not cx and frame then
        local fx, fy = frame:GetCenter()
        if not fx or IsSecret(fx) or IsSecret(fy) then return end
        local ux, uy = UIParent:GetCenter()
        cx, cy = fx * ratio - ux, fy * ratio - uy
    end
    if not cx then return end
    return { cx = cx, cy = cy, w = w, h = h,
        L = cx - w / 2, R = cx + w / 2, T = cy + h / 2, B = cy - h / 2 }
end

local function Union(rects)
    local u
    for _, r in pairs(rects) do
        if not u then
            u = { L = r.L, R = r.R, T = r.T, B = r.B }
        else
            u.L, u.R = math.min(u.L, r.L), math.max(u.R, r.R)
            u.T, u.B = math.max(u.T, r.T), math.min(u.B, r.B)
        end
    end
    return u
end

local function Overlaps(a, b)
    return a.L < b.R and a.R > b.L and a.B < b.T and a.T > b.B
end

-- bars with their own position systems never ride along
local NO_RIDE = { "CDM_", "TBB_", "TBBG_", "EDM_", "PAB_" }
local function RiderCandidate(key)
    if type(key) ~= "string" or key == MM or key == TOAST then return false end
    for _, p in ipairs(NO_RIDE) do
        if key:sub(1, #p) == p then return false end
    end
    local abk = ns.EUI()._abBarKeys
    return not (abk and abk[key])
end

-- --------------------------------------------------------------- the plan

local function Plan()
    local elems = Elems()
    local mmElem = Usable(MM)
    local mm = mmElem and Rect(MM, mmElem)
    if not mm then return nil, "needs the EUI Minimap (enabled, not anchored)." end
    local halfW, halfH = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
    local T, flip = {}, {}

    -- minimap: same edge gaps, flipped to the top
    local gapR = Gap(halfW - mm.R)
    local gapV = Gap(mm.cy < 0 and (mm.B + halfH) or (halfH - mm.T))
    local mdx = Snap((halfW - gapR) - mm.R)
    local mdy = Snap((halfH - gapV) - mm.T)
    T[MM] = { mm.cx + mdx, mm.cy + mdy }
    local newMm = { L = mm.L + mdx, R = mm.R + mdx, T = mm.T + mdy, B = mm.B + mdy }
    local mcfg = MinimapCfg()
    local row = mm.cy < 0 and mcfg and ROW_FLIP[mcfg.btnRowPosition or "blUp"] or nil
    for key, elem in pairs(elems) do
        if RiderCandidate(key) and Usable(key) then
            local r = Rect(key, elem)
            if r and r.L >= mm.L - 1 and r.R <= mm.R + 1 and r.B >= mm.B - 1 and r.T <= mm.T + 1 then
                T[key] = { r.cx + mdx, r.cy + mdy }
            end
        end
    end

    -- auras: mirrored off the left side, same gap to the minimap they had to the edge
    local auras, placed = {}, {}
    for which, g in pairs(GROW) do
        local elem = Usable(g.key)
        local r = elem and Rect(g.key, elem)
        if r then auras[which] = r end
    end
    local block = Union(auras)
    if block then
        local mirror = (block.L + block.R) / 2 < 0
        for which, r in pairs(auras) do
            local L
            if mirror then
                L = Snap(-r.R + (newMm.L - Gap(block.L + halfW) + block.L))
                flip[which] = true
            else
                L = r.L + Snap((newMm.L - Gap(halfW - block.R)) - block.R)
            end
            T[GROW[which].key] = { L + r.w / 2, r.cy }
            placed[#placed + 1] = { L = L, R = L + r.w, T = r.T, B = r.B }
        end
    end

    -- damage meter: the free windows as one block into the bottom-right corner
    local dms = {}
    for key, elem in pairs(elems) do
        if type(key) == "string" and key:match("^EDM_Win%d+$") and Usable(key) then
            dms[key] = Rect(key, elem)
        end
    end
    local dmU = Union(dms)
    if dmU then
        local ddx = Snap((halfW - gapR) - dmU.R)
        local ddy = Snap((gapV - halfH) - dmU.B)
        for key, r in pairs(dms) do T[key] = { r.cx + ddx, r.cy + ddy } end
    end

    -- toast: only when the minimap lands on it; below the minimap and the auras
    local tElem = Usable(TOAST)
    local tr = tElem and Rect(TOAST, tElem)
    if tr and Overlaps(tr, newMm) then
        local gapT = Gap(halfH - tr.T)
        local top = newMm.B - gapT
        for _ = 1, #placed + 1 do
            local cand = { L = tr.L, R = tr.R, T = top, B = top - tr.h }
            local hit
            for _, p in ipairs(placed) do
                if Overlaps(cand, p) then hit = p; break end
            end
            if not hit then break end
            top = hit.B - gapT
        end
        T[TOAST] = { tr.cx, Snap(top) - tr.h / 2 }
    end

    return { targets = T, flip = flip, row = row }
end

-- ------------------------------------------------------------ store access

local function ActiveLid(s)
    local a = s and s.active
    if a == nil then return "base" end
    if type(a) == "string" then return a end
    return "spec:" .. a
end

-- every stored unlock layout of the active profile, and the one live now
local function Layers()
    local eui = ns.EUI()
    local prof = eui.GetActiveProfileData and eui.GetActiveProfileData()
    local out = {}
    local s = prof and prof.specUnlockOverrides
    if s then
        if s.baselineLayout then out.base = s.baselineLayout end
        for gid, l in pairs(s.layouts or {}) do out["spec:" .. gid] = l end
    end
    local cs = prof and prof.condUnlockOverrides
    for gid, l in pairs((cs and cs.layouts) or {}) do out["cond:" .. gid] = l end
    return out, ActiveLid(s)
end

-- QueueStatus-style extras keep a second copy in the action bar store
local function ABPositions()
    local lite = ns.EUI().Lite
    local ab = lite and lite.GetAddon and lite.GetAddon("EllesmereUIActionBars", true)
    local prof = ab and ab.db and ab.db.profile
    return prof and prof.barPositions
end

-- the entry EUI's layer harvest banks for this key
local function LiveEntry(key, elem)
    if elem.loadRawPosition and elem.saveRawPosition then
        local p = elem.loadRawPosition(key)
        if type(p) ~= "table" or not p.point then return end
        local e = {}
        for k, v in pairs(p) do
            if type(v) ~= "table" then e[k] = v end
        end
        e.relPoint = e.relPoint or e.point
        e.rawPos = true
        return e
    end
    local p = elem.loadPosition and elem.loadPosition(key)
    if p and p.point then
        return { point = p.point, relPoint = p.relPoint or p.point, x = p.x, y = p.y }
    end
end

-- position fields only: each layout keeps its own size stamp
local function SetPosFields(dst, src)
    for k in pairs(dst) do
        if k ~= "w" and k ~= "h" then dst[k] = nil end
    end
    for k, v in pairs(src) do
        if k ~= "w" and k ~= "h" and type(v) ~= "table" then dst[k] = v end
    end
end

local function PABCfg(which)
    local uf = ns.ModuleNS(UF)
    local prof = ns.UFProfile()
    local s = prof and prof.playerAuraBars
    if not (uf and s and uf.PAB_DefaultBuffsCfg and uf.PAB_DefaultDebuffsCfg) then return end
    if which == "buffs" then return uf.PAB_DefaultBuffsCfg(s), uf end
    return uf.PAB_DefaultDebuffsCfg(s), uf
end

-- a growth held by a spec/conditional override is theirs to set
local function GrowLocked(which)
    local eui = ns.EUI()
    return eui.SpecOverrides_IsCaptured
        and eui.SpecOverrides_IsCaptured(UF, "playerAuraBars", GROW[which].sub, "growDirection")
end

-- dir false = module default
local function SetGrow(which, dir)
    local cfg, uf = PABCfg(which)
    if not cfg or GrowLocked(which) then return end
    local want = dir or nil
    if cfg.growDirection == want then return end
    cfg.growDirection = want
    if uf.PAB_ApplyLiveConfig then uf.PAB_ApplyLiveConfig(GROW[which].isBuff) end
end

-- v false = module default; never onto the corner the element row holds
local function SetBtnRow(v)
    local m = MinimapCfg()
    local eui = ns.EUI()
    if not m or (eui.SpecOverrides_IsCaptured
        and eui.SpecOverrides_IsCaptured("EllesmereUIMinimap", "minimap", "btnRowPosition")) then
        return
    end
    local want = v or nil
    if m.btnRowPosition == want then return end
    if want and want == m.elementRowPosition then
        Say("button row left alone, the element row uses that corner.")
        return
    end
    m.btnRowPosition = want
    if _G._EMM_ApplyMinimap then _G._EMM_ApplyMinimap() end
end

-- ----------------------------------------------------------------- writes

-- e = false: the element had no saved position, hand it back to its default
local function Write(key, e)
    local elem = Elems()[key]
    if not elem or e == nil or Anchored(key) then return false end
    if e == false and not elem.clearPosition then return false end
    local eui = ns.EUI()
    -- foreign module writer: one throw must not strand the rest half-moved
    local ok, err = pcall(function()
        if e == false then
            elem.clearPosition(key)
        elseif e.rawPos and elem.saveRawPosition then
            elem.saveRawPosition(key, e)
        else
            elem.savePosition(key, e.point, e.relPoint or e.point, e.x, e.y)
        end
        if elem.applyPosition then elem.applyPosition(key) end
        -- same pass as EUI's ApplySavedPositions: the minimap only self-places once
        if not elem.noInitHook and eui.ApplyCenterPosition then
            local pos = elem.loadPosition and elem.loadPosition(key)
            if pos then eui.ApplyCenterPosition(key, pos) end
        end
    end)
    if not ok then ns.ReportError(err) end
    return ok
end

local function SyncLayers(key, live, liveAb, rec)
    local layers, active = Layers()
    for lid, l in pairs(layers) do
        local src = (lid ~= active) and rec and rec.layers[lid]
        local le = l.elems and l.elems[key]
        local e = (src and src.elem) or live
        if le and e then SetPosFields(le, e) end
        if l.abPos and l.abPos[key] ~= nil then
            local a = (src and src.ab) or liveAb
            if a then l.abPos[key] = CopyTable(a) end
        end
    end
end

local function Finish(keys, snap)
    local eui = ns.EUI()
    local ab = ABPositions()
    for _, key in ipairs(keys) do
        local elem = Elems()[key]
        local live = elem and LiveEntry(key, elem)
        local rec = snap and snap.keys[key]
        if live or rec then SyncLayers(key, live, ab and ab[key], rec) end
        if eui.PropagateAnchorChain then eui.PropagateAnchorChain(key) end
    end
end

local function Capture(keys)
    local layers, active = Layers()
    local ab = ABPositions()
    local snap = { active = active, w = UIParent:GetWidth(), h = UIParent:GetHeight(),
        keys = {}, grow = {} }
    for _, key in ipairs(keys) do
        local elem = Elems()[key]
        if elem then
            local live = LiveEntry(key, elem) or false
            local liveAb = ab and ab[key] and CopyTable(ab[key]) or nil
            local rec = { live = live, ab = liveAb, layers = {} }
            for lid, l in pairs(layers) do
                local le = l.elems and l.elems[key]
                local la = l.abPos and l.abPos[key]
                if le or la then
                    local r = { elem = le and CopyTable(le) or nil, ab = la and CopyTable(la) or nil }
                    -- live is the truth for the layout it belongs to
                    if lid == active then
                        if r.elem and live then SetPosFields(r.elem, live) end
                        if r.ab and liveAb then r.ab = CopyTable(liveAb) end
                    end
                    rec.layers[lid] = r
                end
            end
            snap.keys[key] = rec
        end
    end
    for which in pairs(GROW) do
        local cfg = PABCfg(which)
        if cfg then snap.grow[which] = cfg.growDirection or false end
    end
    local m = MinimapCfg()
    if m then snap.row = m.btnRowPosition or false end
    return snap
end

-- shared: values a sync group already holds for this profile (see Propagate)
local function Restore(snap, shared)
    -- growth first: PAB stores a mover position through its growth origin
    if not (shared and shared.growMoved) then
        for which, dir in pairs(snap.grow or {}) do SetGrow(which, dir) end
    end
    if snap.row ~= nil and not (shared and shared.rowMoved ~= nil) then SetBtnRow(snap.row) end
    local _, active = Layers()
    local moved = {}
    for key, rec in pairs(snap.keys) do
        local src = rec.layers[active]
        local e = (active ~= snap.active and src and src.elem) or rec.live
        if Write(key, e) then moved[#moved + 1] = key end
    end
    Finish(moved, snap)
end

-- --------------------------------------------------------------- actions

local function Busy()
    local eui = ns.EUI()
    if not eui then return "EllesmereUI is not loaded." end
    if InCombatLockdown() then return "can't move things in combat." end
    if eui.IsUnlockModeActive and eui:IsUnlockModeActive() then return "close Unlock Mode first." end
    if eui.SpecOverrides_EditSessionActive and eui.SpecOverrides_EditSessionActive() then
        return "leave Editing As first."
    end
    if (eui.Conditions_EstablishPending and eui.Conditions_EstablishPending())
        or eui._unlockResetConvergePending then
        return "EUI is still applying a layout, try again in a moment."
    end
end

ns.UnlockElems, ns.LayoutBusy, ns.PixelSnap = Elems, Busy, Snap

local function SameScreen(snap)
    return snap and math.abs((snap.w or 0) - UIParent:GetWidth()) < 0.5
        and math.abs((snap.h or 0) - UIParent:GetHeight()) < 0.5
end

function ns.MoveStuffMoved()
    local ms = S().moveStuff
    return ms and ms.moved == true
end

-- shared: set when a sync partner moved first; its row/growth already arrived
-- through sync, so they are taken as given instead of flipped again
local function DoMove(shared)
    local st = S()
    local ms = st.moveStuff or {}
    if ms.moved then return false, "already moved." end
    local plan, err = Plan()
    if not plan then return false, err end
    local rowShared = shared and shared.rowMoved ~= nil
    local growShared = shared and shared.growMoved

    local keys, seen = {}, {}
    local function Add(k)
        if not seen[k] then seen[k] = true; keys[#keys + 1] = k end
    end
    for k in pairs(plan.targets) do Add(k) end
    -- the last moved layout comes back as you left it
    local away = SameScreen(ms.away) and ms.away or nil
    if away then
        for k in pairs(plan.targets) do
            if not away.keys[k] then away = nil; break end
        end
    end
    if away then
        for k in pairs(away.keys) do Add(k) end
    end

    local home = Capture(keys)
    if rowShared then home.row = shared.rowHome end
    if growShared then home.grow = CopyTable(shared.growHome or {}) end
    -- growth first, same as Restore
    if growShared then
        for which, dir in pairs(shared.growMoved) do SetGrow(which, dir) end
    end
    if rowShared then SetBtnRow(shared.rowMoved) end
    if away then
        Restore(away, shared)
    else
        if not growShared then
            for which in pairs(plan.flip) do
                local cfg = PABCfg(which)
                if cfg and cfg.growDirection == "RIGHT" then SetGrow(which, "LEFT") end
            end
        end
        if plan.row and not rowShared then SetBtnRow(plan.row) end
        local moved = {}
        for key, t in pairs(plan.targets) do
            if Write(key, { point = "CENTER", relPoint = "CENTER", x = t[1], y = t[2] }) then
                moved[#moved + 1] = key
            end
        end
        Finish(moved)
    end
    st.moveStuff = { moved = true, home = home }
    return true, home
end

local function DoBack()
    local st = S()
    local ms = st.moveStuff
    if not (ms and ms.moved and ms.home) then return false, "nothing to move back." end
    local keys = {}
    for k in pairs(ms.home.keys) do keys[#keys + 1] = k end
    local away = Capture(keys)
    Restore(ms.home)
    -- a home from before the button row was tracked: let the next Move recompute
    if ms.home.row == nil then away = nil end
    st.moveStuff = { away = away }
    return true
end

-- --------------------------------------------------------- sync partners

-- Positions never sync in EUI; these settings do. A profile sharing them with
-- the active one would get the new row/growth under its old positions, so it
-- follows. Read at click time: EUI keeps membership through renames/deletes.
local SHARED_BY = { row = "EllesmereUIMinimap", grow = UF }

local function Partners()
    local eui = ns.EUI()
    local db = _G.EllesmereUIDB
    local active = db and (db.activeProfile or "Default")
    local out = {}
    if not (active and db.profiles and eui.GetSyncedProfiles) then return out end
    for kind, folder in pairs(SHARED_BY) do
        local g = eui.GetSyncedProfiles(folder)
        if g[active] then
            for name, on in pairs(g) do
                if on and name ~= active and db.profiles[name] then
                    out[name] = out[name] or {}
                    out[name][kind] = true
                end
            end
        end
    end
    return out
end

local function PartnerNames()
    local names = {}
    for name in pairs(Partners()) do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- the partner's own settings table (what S() is while it is active)
local function StateFor(name)
    local db = _G.EllesmereUIDB
    local p = db and db.profiles and db.profiles[name]
    if not p then return end
    p.addons = p.addons or {}
    local uf = p.addons[UF]
    if type(uf) ~= "table" then uf = {}; p.addons[UF] = uf end
    if uf.thingsTweaks == nil and type(uf.castbarTweaks) == "table" then
        uf.thingsTweaks, uf.castbarTweaks = uf.castbarTweaks, nil
    end
    if type(uf.thingsTweaks) ~= "table" then uf.thingsTweaks = {} end
    return uf.thingsTweaks
end

local function Propagate(action, home)
    local m = MinimapCfg()
    local rowNow = m and (m.btnRowPosition or false)
    local growNow = {}
    for which in pairs(GROW) do
        local cfg = PABCfg(which)
        if cfg then growNow[which] = cfg.growDirection or false end
    end
    for name, kinds in pairs(Partners()) do
        local t = StateFor(name)
        if t then
            local ms = t.moveStuff or {}
            local want = (action == "move")
            if (ms.moved == true) == want then
                ms.pending = nil
            elseif action == "move" then
                local p = { action = "move" }
                if kinds.row and home and rowNow ~= nil then
                    p.rowHome, p.rowMoved = home.row, rowNow
                end
                if kinds.grow and home then
                    p.growHome, p.growMoved = CopyTable(home.grow or {}), growNow
                end
                ms.pending = p
            else
                ms.pending = { action = "back" }
            end
            t.moveStuff = ms
        end
    end
end

-- a partner's queued move runs once it is the active profile
local pendingTries = 0
function ns.ApplyPendingMove()
    local ms = S().moveStuff
    local p = ms and ms.pending
    if not p then return end
    if Busy() then
        -- combat resumes at regen; anything else gets a few more looks
        if not InCombatLockdown() and pendingTries < 5 then
            pendingTries = pendingTries + 1
            C_Timer.After(2, ns.ApplyPendingMove)
        end
        return
    end
    pendingTries = 0
    ms.pending = nil
    local ok, err
    if p.action == "move" then ok, err = DoMove(p) else ok, err = DoBack() end
    if ok then
        Say(p.action == "move" and "applied to this profile too." or "moved this profile back too.")
    elseif err then
        Say(err)
    end
    local eui = ns.EUI()
    if eui:IsShown() and eui.RefreshPage then eui:RefreshPage(true) end
end

local function QueuedNote(names)
    if #names == 0 then return "" end
    if #names == 1 then return " " .. names[1] .. " follows when you switch to it." end
    return " " .. table.concat(names, ", ") .. " follow when you switch to them."
end

function ns.MoveThatStuff()
    local why = Busy()
    if why then Say(why); return end
    local ok, res = DoMove(nil)
    if not ok then Say(res); return end
    Propagate("move", res)
    Say("done." .. QueuedNote(PartnerNames()))
end

function ns.MoveItBack()
    local why = Busy()
    if why then Say(why); return end
    local ms = S().moveStuff
    if ms and not ms.moved and ms.pending then
        ms.pending = nil
        Say("cancelled the queued move.")
        return
    end
    local ok, err = DoBack()
    if not ok then Say(err); return end
    Propagate("back")
    Say("moved back." .. QueuedNote(PartnerNames()))
end

-- ---------------------------------------------------------------- wiring

-- per-profile state, like the positions it describes
do
    local eui = ns.EUI()
    if eui and eui.RegisterSyncExclusions then
        eui.RegisterSyncExclusions(UF, { "thingsTweaks.moveStuff" })
    end
end

local swapHooked = false
ns.maintainers[#ns.maintainers + 1] = function()
    local eui = ns.EUI()
    if swapHooked or not (eui and type(eui.RefreshAllAddons) == "function") then return end
    swapHooked = true
    -- after the swap's layer flush and settle have landed
    hooksecurefunc(eui, "RefreshAllAddons", function() C_Timer.After(1, ns.ApplyPendingMove) end)
end
ns.bootOnly[#ns.bootOnly + 1] = function() C_Timer.After(3, ns.ApplyPendingMove) end
ns.onRegen[#ns.onRegen + 1] = ns.ApplyPendingMove

-- ---------------------------------------------------------------------- page

function ns.BuildMoveStuffSection(parent, y)
    local eui = ns.EUI()
    local W = eui and eui.Widgets
    if not W then return y end
    local _, h
    local function Refresh()
        if eui.RefreshPage then eui:RefreshPage(true) end
    end

    _, h = W:SectionHeader(parent, "MOVE THAT STUFF", y); y = y - h

    local desc = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    desc:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
    desc:SetJustifyH("LEFT")
    desc:SetWidth(440)
    desc:SetText("Minimap and buffs/debuffs to the top right, damage meter into the bottom right corner. Move It Back returns everything to where you had it. Tweaks you make in either state are kept.")
    y = y - 40

    local row
    row, h = W:WideDualButton(parent, "Move That Stuff", "Move It Back", y,
        function() ns.MoveThatStuff(); Refresh() end,
        function() ns.MoveItBack(); Refresh() end); y = y - h
    local btns = {}
    for _, c in ipairs({ row:GetChildren() }) do
        if c:GetObjectType() == "Button" then btns[#btns + 1] = c end
    end
    local idle = btns[ns.MoveStuffMoved() and 1 or 2]
    if idle then idle:SetAlpha(0.4) end

    local names = PartnerNames()
    if #names > 0 then
        local also = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        also:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, y)
        also:SetText("Also applies to (synced): " .. table.concat(names, ", "))
        y = y - 20
    end

    if ns.BuildBarStyleRow then y = ns.BuildBarStyleRow(parent, y) end
    return y
end
