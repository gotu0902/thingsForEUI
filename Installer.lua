local _, ns = ...

-- ---------------------------------------------------------------- installer

-- Imports the pack (Pack/*.lua) through each addon's own public API:
-- EllesmereUI.ImportProfileSilent, BigWigsAPI.RegisterProfile (BigWigs asks
-- the user itself) and Baganator.API.ImportString. EllesmereUI profiles are
-- account-wide and spec-assigned; BigWigs and Baganator keep a profile per
-- character, so on alts the window loads the picked profile instead, and a
-- login check offers that when a character is on something else.

local PACK = ns.PACK
local RES = { "1440p", "1080p" }
-- announced but not shipped yet: shown, never selectable
local SOON = {}

local function Say(msg) print("|cff8AC8FFthings|r Installer: " .. msg) end

local function CharKey() return (UnitName("player") or "?") .. " - " .. (GetRealmName() or "?") end

local function ResString(t, res)
    local s = t and (t[res] or t.all)
    s = s and strtrim(s)
    if s and s ~= "" then return s end
end

local function StringFor(def, res) return ResString(def and def.strings, res) end

local function DB()
    local db = ns.legacy
    if not db then return end
    local i = db.install
    if type(i) ~= "table" then i = {}; db.install = i end
    i.done = i.done or {}
    i.pick = i.pick or {}
    i.charNoAsk = i.charNoAsk or {}
    return i
end

local function AnyString(list, res)
    for _, p in ipairs(list) do
        if StringFor(p, res) then return true end
    end
    return false
end

local function EUIHasString(res) return AnyString(PACK.eui.profiles, res) end

local function AvailableRes()
    local out = {}
    for _, r in ipairs(RES) do
        if not SOON[r] and (EUIHasString(r) or AnyString(PACK.bigwigs.profiles, r) or StringFor(PACK.editmode, r)) then out[#out + 1] = r end
    end
    return out
end

local function DetectRes()
    local _, h = GetPhysicalScreenSize()
    return (h and h >= 1300) and "1440p" or "1080p"
end

-- the stored pick, else this screen, else whatever the pack has
local function Res()
    local avail = AvailableRes()
    local i = DB()
    for _, want in ipairs({ i and i.res, DetectRes() }) do
        for _, r in ipairs(avail) do
            if r == want then return r end
        end
    end
    return avail[1] or DetectRes()
end

local needReload = false

local function Confirm(title, message, onYes, onNo)
    local eui = ns.EUI()
    eui:ShowConfirmPopup({
        title = title, message = message,
        confirmText = "Overwrite", cancelText = "Keep Mine",
        onConfirm = onYes, onCancel = onNo,
    })
end

-- ------------------------------------------------------ cooldown manager

-- Blizzard's Cooldown Manager layouts live per character (max 5), one per
-- string in the pack.

local function LM()
    local s = _G.CooldownViewerSettings
    return s and s.GetLayoutManager and C_EncodingUtil and s:GetLayoutManager()
end

local function CurrentTag()
    return _G.CooldownViewerUtil and tonumber(_G.CooldownViewerUtil.GetCurrentClassAndSpecTag())
end

local function Fingerprint(str)
    local h = 2166136261
    for n = 1, #str do
        h = bit.bxor(h, str:byte(n)) % 4294967296
        -- FNV-1a prime 2^24 + 403, split so the product stays exact in a double
        h = (h * 403 + (h % 256) * 16777216) % 4294967296
    end
    return ("%08x-%d"):format(h, #str)
end

-- Blizzard's own reader: "1|" .. Base64(Deflate(CBOR))
local function DecodeLayouts(str)
    local sep = str:find("|", 1, true)
    if not sep then return end
    -- pasted data: the C decoders throw on anything malformed
    local ok, t = pcall(function()
        local raw = C_EncodingUtil.DecodeBase64(str:sub(sep + 1))
        return C_EncodingUtil.DeserializeCBOR(C_EncodingUtil.DecompressString(raw, Enum.CompressionMethod.Deflate))
    end)
    if not (ok and type(t) == "table" and type(t[3]) == "table") then return end
    local out = {}
    for tag, byID in pairs(t[3]) do
        for id in pairs(byID) do
            out[#out + 1] = { tag = tonumber(tag), name = type(t[4]) == "table" and t[4][id] or nil }
        end
    end
    return out
end

local cdmEntries
local function CDMEntries()
    if cdmEntries then return cdmEntries end
    if not LM() then return {} end
    cdmEntries = {}
    for _, s in ipairs(PACK.cdm and PACK.cdm.layouts or {}) do
        s = strtrim(s)
        if s ~= "" then
            local list = DecodeLayouts(s)
            local l = list and list[1]
            if l and l.tag and l.name then
                cdmEntries[#cdmEntries + 1] = { str = s, fp = Fingerprint(s), tag = l.tag, name = l.name }
            else
                Say("a Cooldown Manager string in the pack could not be read.")
            end
        end
    end
    return cdmEntries
end

local function ClassEntries()
    local out = {}
    local classID = select(3, UnitClass("player"))
    for _, e in ipairs(CDMEntries()) do
        if math.floor(e.tag / 10) == classID then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return a.tag < b.tag end)
    return out
end

local function CDMStore()
    local i = DB()
    i.cdm = i.cdm or {}
    local k = CharKey()
    i.cdm[k] = i.cdm[k] or {}
    return i.cdm[k]
end

-- "ok" | "outdated" | "missing"; a kept same-name layout counts as handled
local function EntryState(e)
    local held = CDMStore()[e.tag]
    local lm = LM()
    if not (held and lm and lm:GetLayoutByName(e.name, e.tag)) then return "missing" end
    if held == e.fp or held == "kept:" .. e.fp then return "ok" end
    return "outdated"
end

local function SpecName(tag)
    local _, name = GetSpecializationInfoForClassID(math.floor(tag / 10), tag % 10)
    return name or tostring(tag)
end

local function HideForbiddenPopup()
    if StaticPopup_Hide then StaticPopup_Hide("ADDON_ACTION_FORBIDDEN") end
end

local function ImportLayout(lm, e, cur)
    local old = lm:GetLayoutByName(e.name, e.tag)
    if old then
        lm:RemoveLayout(CooldownManagerLayout_GetID(old))
    elseif lm:AreLayoutsFullyMaxed() then
        return false, "maxed"
    end
    local ids = lm:CreateLayoutsFromSerializedData(e.str)
    local layout = ids and ids[1] and lm:GetLayout(ids[1])
    if not layout then return false end
    -- saved before the one call that can be refused
    lm:SaveLayouts()
    if e.tag == cur then
        lm:SetActiveLayoutByID(ids[1])
        HideForbiddenPopup()
        C_Timer.After(0, HideForbiddenPopup)
    else
        lm:SetPreviouslyActiveLayout(layout)
    end
    lm:SaveLayouts()
    return true
end

-- EUI keeps one sync group per module: EllesmereUIDB.syncedModules[folder] = {[profile] = true}
local function SyncMembers()
    local profs = _G.EllesmereUIDB and _G.EllesmereUIDB.profiles or {}
    local out, n = {}, 0
    for _, p in ipairs(PACK.eui.profiles) do
        if profs[p.name] then out[p.name] = true; n = n + 1 end
    end
    return out, n
end

local function SyncDone()
    local members, n = SyncMembers()
    if n < 2 then return false end
    local sm = _G.EllesmereUIDB.syncedModules or {}
    for _, folder in ipairs(PACK.eui.sync or {}) do
        local g = sm[folder]
        if type(g) ~= "table" then return false end
        for name in pairs(members) do
            if not g[name] then return false end
        end
    end
    return true
end

-- a group holding the user's own profiles is left alone
local function ApplySync()
    local db = _G.EllesmereUIDB
    local members, n = SyncMembers()
    if n < 2 or not PACK.eui.sync then return end
    db.syncedModules = db.syncedModules or {}
    local kept = {}
    for _, folder in ipairs(PACK.eui.sync) do
        local g = db.syncedModules[folder]
        local foreign = false
        if type(g) == "table" then
            for name, on in pairs(g) do
                if on and db.profiles[name] and not members[name] then foreign = true end
            end
        end
        if foreign then
            kept[#kept + 1] = (folder:gsub("^EllesmereUI", ""))
        else
            db.syncedModules[folder] = CopyTable(members)
        end
    end
    if #kept > 0 then Say("kept your own EllesmereUI sync groups for " .. table.concat(kept, ", ") .. ".") end
end

-- ---------------------------------------------------------------- providers

local PROVIDERS = {}

PROVIDERS[#PROVIDERS + 1] = {
    key = "eui", title = "EllesmereUI",
    loaded = function()
        local eui = ns.EUI()
        return eui and eui.ImportProfileSilent and _G.EllesmereUIDB ~= nil
    end,
    has = function(res) return EUIHasString(res) end,
    installed = function()
        local profs = _G.EllesmereUIDB and _G.EllesmereUIDB.profiles or {}
        for _, p in ipairs(PACK.eui.profiles) do
            if not profs[p.name] then return false end
        end
        return true
    end,
    detail = function()
        local db = _G.EllesmereUIDB or {}
        local names = {}
        for _, p in ipairs(PACK.eui.profiles) do
            local have = db.profiles and db.profiles[p.name]
            names[#names + 1] = have and p.name or ("|cffff5555" .. p.name .. " (missing)|r")
        end
        return "Profiles: " .. table.concat(names, ", ") .. "   Active: " .. tostring(db.activeProfile or "Default")
    end,
    extra = {
        label = "Sync Groups", done = SyncDone, run = ApplySync,
        usable = function() return (select(2, SyncMembers())) >= 2 end,
    },
    install = function(res, done)
        local eui = ns.EUI()
        local profs = _G.EllesmereUIDB.profiles or {}
        local todo, existing = {}, {}
        for _, p in ipairs(PACK.eui.profiles) do
            if StringFor(p, res) then
                todo[#todo + 1] = p
                if profs[p.name] then existing[#existing + 1] = p.name end
            end
        end
        if #todo == 0 then done(false); return end
        local function Run(overwrite)
            local fails, imported = {}, 0
            for _, p in ipairs(todo) do
                if overwrite or not (_G.EllesmereUIDB.profiles or {})[p.name] then
                    local ok, err = eui.ImportProfileSilent({
                        importString = StringFor(p, res),
                        profileName = p.name,
                        disableAddons = PACK.eui.disable,
                        autoAssignSpecs = true,
                    })
                    if ok then imported = imported + 1 else fails[#fails + 1] = p.name .. " (" .. tostring(err) .. ")" end
                end
            end
            if #fails > 0 then Say("EllesmereUI could not import " .. table.concat(fails, ", ") .. ".") end
            ApplySync()
            -- EUI applies an import on the next load
            if imported > 0 then needReload = true end
            done(#fails == 0)
        end
        if #existing > 0 then
            Confirm("EllesmereUI", table.concat(existing, " and ") .. " already exist. Overwrite them with the pack's version?",
                function() Run(true) end, function() Run(false) end)
        else
            Run(false)
        end
    end,
}

-- Edit Mode layouts are account-wide (EUI imports ours as an Account layout);
-- the active one is per character, so alts only switch to it.

-- the list the game indexes: Blizzard's presets first, then saved layouts
local function EMLayouts()
    local info = C_EditMode.GetLayouts()
    local out = EditModePresetLayoutManager:GetCopyOfPresetLayouts()
    for _, l in ipairs(info and info.layouts or {}) do out[#out + 1] = l end
    return out, info and info.activeLayout
end

local function EMIndex(name)
    for n, l in ipairs((EMLayouts())) do
        if l.layoutName == name then return n end
    end
end

local function EMAccountFull()
    local max = Constants.EditModeConsts and Constants.EditModeConsts.EditModeMaxLayoutsPerType
    local count = 0
    for _, l in ipairs((C_EditMode.GetLayouts() or {}).layouts or {}) do
        if l.layoutType == Enum.EditModeLayoutType.Account then count = count + 1 end
    end
    return max ~= nil and count >= max, count, max
end

PROVIDERS[#PROVIDERS + 1] = {
    key = "editmode", title = "Edit Mode (Blizzard)", perChar = true,
    loaded = function()
        local mgr, eui = _G.EditModeManagerFrame, ns.EUI()
        return mgr ~= nil and mgr.accountSettings ~= nil and _G.EditModePresetLayoutManager ~= nil
            and eui ~= nil and eui.ApplyPresetEditMode ~= nil
    end,
    has = function(res) return StringFor(PACK.editmode, res) ~= nil end,
    pack = function() return PACK.editmode.layout end,
    list = function()
        local out = {}
        for _, l in ipairs((EMLayouts())) do out[#out + 1] = l.layoutName end
        return out
    end,
    exists = function(name) return EMIndex(name) ~= nil end,
    current = function()
        local list, active = EMLayouts()
        local l = active and list[active]
        return l and l.layoutName
    end,
    installed = function() return EMIndex(PACK.editmode.layout) ~= nil end,
    install = function(res, done)
        local name = PACK.editmode.layout
        local function Run()
            -- never free a slot by removing one of the user's layouts
            local full, count, max = EMAccountFull()
            if full and not EMIndex(name) then
                Say(("Edit Mode has no free account layout (%d of %d). Delete one in Edit Mode and install again.")
                    :format(count, max))
                done(false)
                return
            end
            -- guarded like EUI's own preset import calls it
            local ok, applied = pcall(ns.EUI().ApplyPresetEditMode, StringFor(PACK.editmode, res), name)
            HideForbiddenPopup()
            if ok and applied then
                -- Edit Mode stays tainted until a reload
                needReload = true
            else
                Say("Edit Mode could not import the layout" .. (ok and "." or (": " .. tostring(applied))))
            end
            done(ok and applied)
        end
        if EMIndex(name) then
            Confirm("Edit Mode", "The Edit Mode layout " .. name .. " already exists. Overwrite it with the pack's version?",
                Run, function() done(true) end)
        else
            Run()
        end
    end,
    load = function(name)
        local idx = EMIndex(name)
        if not idx then return end
        C_EditMode.SetActiveLayout(idx)
        HideForbiddenPopup()
        needReload = true
    end,
}

-- BigWigs profiles are named like their EllesmereUI profile; FOLLOW (a pick
-- value) turns on BigWigs' spec profiles (LibDualSpec) with EllesmereUI's
-- spec assignment, so both switch together.
local FOLLOW = "\001follow"

local function BWDB() return _G.BigWigsLoader and _G.BigWigsLoader.db end

-- the pack's BigWigs profile for an EllesmereUI profile (`eui`), else the same name
local function BWFor(euiName)
    for _, bp in ipairs(PACK.bigwigs.profiles) do
        if (bp.eui or bp.name) == euiName then return bp.name end
    end
    return euiName
end

-- spec index -> the BigWigs profile that goes with that spec's EllesmereUI profile
local function FollowMap()
    local eui, map = ns.EUI(), {}
    if not (eui and eui.GetSpecProfile) then return map end
    for n = 1, GetNumSpecializations() do
        local specID = GetSpecializationInfo(n)
        local euiName = specID and eui.GetSpecProfile(specID)
        local name = euiName and BWFor(euiName)
        if name and _G.BigWigsAPI.IsValidProfile(name) then map[n] = name end
    end
    return map
end

local function Following()
    local db, map = BWDB(), FollowMap()
    if not (db.IsDualSpecEnabled and db:IsDualSpecEnabled() and next(map)) then return false end
    for n, name in pairs(map) do
        if db:GetDualSpecProfile(n) ~= name then return false end
    end
    return true
end

local function ApplyFollow()
    local db, map = BWDB(), FollowMap()
    if not (db.SetDualSpecProfile and next(map)) then return end
    if not db:IsDualSpecEnabled() then db:SetDualSpecEnabled(true) end
    for n, name in pairs(map) do db:SetDualSpecProfile(name, n) end
end

-- several profiles follow EllesmereUI per spec; a single one is just used
local function BWDefault()
    local list = PACK.bigwigs.profiles
    if #list > 1 then return FOLLOW end
    return list[1] and list[1].name
end

-- BigWigs' export leaves out Auras (Boss Debuffs); we carry them ourselves
local AURA_NS, AURA_PREFIX = "BigWigs_Plugins_Auras", "TUIBWA1:"

local function AuraProfiles()
    local sv = _G.BigWigs3DB
    sv.namespaces = sv.namespaces or {}
    sv.namespaces[AURA_NS] = sv.namespaces[AURA_NS] or {}
    local n = sv.namespaces[AURA_NS]
    n.profiles = n.profiles or {}
    return n.profiles
end

local function EncodeAuras(t)
    local packed = C_EncodingUtil.CompressString(C_EncodingUtil.SerializeCBOR(t), Enum.CompressionMethod.Deflate)
    return AURA_PREFIX .. C_EncodingUtil.EncodeBase64(packed)
end

local function DecodeAuras(str)
    if str:sub(1, #AURA_PREFIX) ~= AURA_PREFIX then return end
    -- pasted data: the C decoders throw on anything malformed
    local ok, t = pcall(function()
        local raw = C_EncodingUtil.DecodeBase64(str:sub(#AURA_PREFIX + 1))
        return C_EncodingUtil.DeserializeCBOR(C_EncodingUtil.DecompressString(raw, Enum.CompressionMethod.Deflate))
    end)
    if ok and type(t) == "table" then return t end
end

local function Merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            Merge(dst[k], v)
        else
            dst[k] = v
        end
    end
end

local function WriteAuras(name, data)
    local db = BWDB()
    local live = db.GetNamespace and db:GetNamespace(AURA_NS, true)
    if live and db:GetCurrentProfile() == name then
        -- the loaded profile: reset to defaults, then layer ours on top
        live:ResetProfile()
        Merge(live.profile, data)
        _G.BigWigsLoader:SendMessage("BigWigs_ProfileUpdate")
    else
        -- AceDB fills in the defaults when this profile loads
        AuraProfiles()[name] = CopyTable(data)
    end
end

function ns.CaptureBigWigsAuras()
    local eui = ns.EUI()
    if not (_G.BigWigsAPI and _G.BigWigs3DB and eui and eui.ShowCopyPopup) then
        Say("BigWigs is not loaded.")
        return
    end
    local name = _G.BigWigsAPI.GetProfileName()
    local str = EncodeAuras(CopyTable(AuraProfiles()[name] or {}))
    eui:ShowCopyPopup("BigWigs Auras", "Profile " .. name .. ": paste into Pack/BigWigs.lua as its auras.", str)
end

PROVIDERS[#PROVIDERS + 1] = {
    key = "bigwigs", title = "BigWigs", perChar = true,
    loaded = function() return _G.BigWigsAPI ~= nil and _G.BigWigsAPI.RegisterProfile ~= nil and BWDB() ~= nil end,
    has = function(res) return AnyString(PACK.bigwigs.profiles, res) end,
    pack = BWDefault,
    label = function(name) return name == FOLLOW and "Per spec (EllesmereUI)" or name end,
    list = function()
        local out = { FOLLOW }
        for _, n in ipairs(_G.BigWigsAPI.GetProfileList()) do out[#out + 1] = n end
        return out
    end,
    exists = function(name)
        if name == FOLLOW then return BWDB().SetDualSpecProfile ~= nil and next(FollowMap()) ~= nil end
        return _G.BigWigsAPI.IsValidProfile(name)
    end,
    current = function() return Following() and FOLLOW or _G.BigWigsAPI.GetProfileName() end,
    installed = function()
        for _, bp in ipairs(PACK.bigwigs.profiles) do
            if StringFor(bp, Res()) and not _G.BigWigsAPI.IsValidProfile(bp.name) then return false end
        end
        return true
    end,
    install = function(res, done)
        local todo, existing = {}, {}
        for _, bp in ipairs(PACK.bigwigs.profiles) do
            if StringFor(bp, res) then
                todo[#todo + 1] = bp
                if _G.BigWigsAPI.IsValidProfile(bp.name) then existing[#existing + 1] = bp.name end
            end
        end
        if #todo == 0 then done(false); return end
        -- BigWigs swaps to each import; the one this spec uses goes last
        local eui, spec = ns.EUI(), GetSpecialization()
        local specID = spec and GetSpecializationInfo(spec)
        local mine = specID and eui.GetSpecProfile and eui.GetSpecProfile(specID)
        for i, bp in ipairs(todo) do
            if (bp.eui or bp.name) == mine then table.insert(todo, table.remove(todo, i)); break end
        end
        local function Run(overwrite)
            if #todo > 1 then
                Say("BigWigs asks once per profile and says it will swap to it. Each spec gets the right one afterwards.")
            end
            local n, tried, accepted = 0, 0, 0
            -- one at a time: every import raises BigWigs' own popup
            local function Next()
                n = n + 1
                local bp = todo[n]
                if not bp then
                    local pick = DB().pick.bigwigs
                    if accepted > 0 and (pick or BWDefault()) == FOLLOW then ApplyFollow() end
                    done(tried == 0 or accepted > 0)
                    return
                end
                if not overwrite and _G.BigWigsAPI.IsValidProfile(bp.name) then Next(); return end
                tried = tried + 1
                -- BigWigs rejects a bad string with error()
                local ok, err = pcall(_G.BigWigsAPI.RegisterProfile, PACK.name, StringFor(bp, res), bp.name,
                    function(yes)
                        if yes then
                            accepted = accepted + 1
                            local auras = DecodeAuras(ResString(bp.auras, res) or "")
                            if auras then WriteAuras(bp.name, auras) end
                        end
                        C_Timer.After(0, Next)
                    end)
                if not ok then Say("BigWigs: " .. tostring(err)); Next() end
            end
            Next()
        end
        if #existing > 0 then
            Confirm("BigWigs", table.concat(existing, " and ") .. " already exist. Overwrite with the pack's version?",
                function() Run(true) end, function() Run(false) end)
        else
            Run(false)
        end
    end,
    load = function(name)
        local db = BWDB()
        if name == FOLLOW then ApplyFollow(); return end
        -- a fixed profile: spec profiles would undo it on the next spec change
        if db.IsDualSpecEnabled and db:IsDualSpecEnabled() then db:SetDualSpecEnabled(false) end
        db:SetProfile(name)
    end,
}

PROVIDERS[#PROVIDERS + 1] = {
    key = "baganator", title = "Baganator", perChar = true,
    loaded = function()
        return _G.Baganator and _G.Baganator.API and _G.Baganator.API.ImportString and _G.BAGANATOR_CONFIG ~= nil
    end,
    has = function(res) return StringFor(PACK.baganator, res) ~= nil end,
    pack = function() return PACK.baganator.profile end,
    list = function()
        local out = {}
        for name in pairs(_G.BAGANATOR_CONFIG.Profiles or {}) do out[#out + 1] = name end
        table.sort(out)
        return out
    end,
    exists = function(name) return (_G.BAGANATOR_CONFIG.Profiles or {})[name] ~= nil end,
    current = function() return _G.BAGANATOR_CURRENT_PROFILE end,
    installed = function() return (_G.BAGANATOR_CONFIG.Profiles or {})[PACK.baganator.profile] ~= nil end,
    install = function(res, done)
        local name = PACK.baganator.profile
        local function Run()
            -- Baganator rejects a bad string with error()
            local ok, err = pcall(_G.Baganator.API.ImportString, StringFor(PACK.baganator, res), name)
            if not ok then Say("Baganator: " .. tostring(err)) end
            done(ok)
        end
        if (_G.BAGANATOR_CONFIG.Profiles or {})[name] then
            Confirm("Baganator", "The Baganator profile " .. name .. " already exists. Overwrite it with the pack's version?",
                Run, function() done(true) end)
        else
            Run()
        end
    end,
    -- no public switch: the per-character key is read at load
    load = function(name)
        _G.BAGANATOR_CURRENT_PROFILE = name
        needReload = true
    end,
}

PROVIDERS[#PROVIDERS + 1] = {
    key = "cdm", title = "Cooldown Manager (Blizzard)", charInstall = true,
    none = "No layouts for your class in the pack.",
    loaded = function() return LM() ~= nil end,
    has = function() return #ClassEntries() > 0 end,
    installed = function()
        for _, e in ipairs(ClassEntries()) do
            if EntryState(e) ~= "ok" then return false end
        end
        return true
    end,
    outdated = function()
        for _, e in ipairs(ClassEntries()) do
            if EntryState(e) == "outdated" then return true end
        end
        return false
    end,
    -- one button per spec of this character's class
    parts = function()
        local out = {}
        for _, e in ipairs(ClassEntries()) do
            out[#out + 1] = { label = SpecName(e.tag), state = EntryState(e), arg = e }
        end
        return out
    end,
    install = function(_, done, only)
        local lm, store, cur = LM(), CDMStore(), CurrentTag()
        local all, todo = ClassEntries(), {}
        for _, e in ipairs(only and { only } or all) do
            if only or EntryState(e) ~= "ok" then todo[#todo + 1] = e end
        end
        if #todo == 0 then todo = all end
        -- the active spec first, so a full character never leaves it out
        table.sort(todo, function(a, b) return a.tag == cur and b.tag ~= cur end)
        local foreign, names = {}, {}
        for _, e in ipairs(todo) do
            local held = store[e.tag]
            if lm:GetLayoutByName(e.name, e.tag) and not (held and not held:find("^kept:")) then
                foreign[e] = true
                names[#names + 1] = e.name .. " (" .. SpecName(e.tag) .. ")"
            end
        end
        local function Run(overwrite)
            local maxed, failed, imported = {}, {}, 0
            local function Batch()
                for _, e in ipairs(todo) do
                    if foreign[e] and not overwrite then
                        store[e.tag] = "kept:" .. e.fp
                    else
                        local ok, why = ImportLayout(lm, e, cur)
                        if ok then
                            store[e.tag] = e.fp
                            imported = imported + 1
                        else
                            local list = (why == "maxed") and maxed or failed
                            list[#list + 1] = SpecName(e.tag)
                        end
                    end
                end
            end
            lm:LockNotifications()
            -- the lock must be released even if Blizzard's reader throws
            local ok, err = pcall(Batch)
            -- no listener may run inside our execution
            lm.needsNotificationAfterUnlock = false
            lm:UnlockNotifications()
            if not ok then geterrorhandler()(err) end
            if #maxed > 0 then
                Say("no room for " .. table.concat(maxed, ", ") .. " (5 Cooldown Manager layouts per character). "
                    .. "Delete one in the Cooldown Manager settings and install again.")
            end
            if #failed > 0 then Say("Cooldown Manager could not import " .. table.concat(failed, ", ") .. ".") end
            -- imported layouts stay tainted until a reload
            if imported > 0 then needReload = true end
            done(ok and (imported > 0 or (#maxed == 0 and #failed == 0)))
        end
        if #names > 0 then
            Confirm("Cooldown Manager", "This character already has " .. table.concat(names, ", ")
                .. ". Overwrite with the pack's version?", function() Run(true) end, function() Run(false) end)
        else
            Run(false)
        end
    end,
}

-- ------------------------------------------------------------------ state

local function Want(p)
    local i = DB()
    local pick = i and i.pick[p.key]
    if pick and p.exists(pick) then return pick end
    local pk = p.pack()
    if p.exists(pk) then return pk end
end

local function Usable(p, res) return p.loaded() and p.has(res) end

local function UpdateFor(p)
    if p.outdated then return p.loaded() and p.outdated() end
    local i = DB()
    local v = i and i.done[p.key]
    return v ~= nil and v < PACK.version
end

local function Mismatched(p)
    -- per-character installs: offered to alts once the account has used them
    if p.charInstall then
        return DB().done[p.key] ~= nil and Usable(p, Res()) and not p.installed()
    end
    if not (p.perChar and p.loaded()) then return false end
    local want = Want(p)
    return want ~= nil and p.current() ~= want
end

local function AnyMismatch()
    for _, p in ipairs(PROVIDERS) do
        if Mismatched(p) then return true end
    end
    return false
end

local function RunInstall(p, res, after, only)
    if InCombatLockdown() then Say("not in combat."); return end
    p.install(res, function(ok)
        if ok then
            local i = DB()
            i.done[p.key] = PACK.version
            i.res = res
        end
        if after then after(ok) end
    end, only)
end

-- installed by hand or before this tracked it: counts as the current pack
local function Adopt(res)
    local i = DB()
    for _, p in ipairs(PROVIDERS) do
        if i.done[p.key] == nil and Usable(p, res) and p.installed() then i.done[p.key] = PACK.version end
    end
end

local function LoadFor(p, after)
    if p.charInstall then RunInstall(p, Res(), after); return end
    local want = Want(p)
    if want and p.current() ~= want then p.load(want) end
end

-- ----------------------------------------------------------------- window

local win
local Refresh

local function CloseWindow()
    if win then win.dimmer:Hide() end
end

local function Btn(parent, text, point, rel, relPoint, x, y, onClick, enabled)
    local eui = ns.EUI()
    local ar, ag, ab = eui.GetAccentColor()
    local b = eui.MakePopupButton(parent, point, rel, relPoint, x, y,
        1, 1, 1, 0.8, ar, ag, ab, 1,
        1, 1, 1, 0.2, ar, ag, ab, 0.9)
    b._lbl:SetText(text)
    if enabled == false then
        b:SetAlpha(0.35)
        b:SetScript("OnEnter", nil)
        b:SetScript("OnLeave", nil)
    else
        b:SetScript("OnClick", onClick)
    end
    return b
end

local function Text(parent, size, r, g, b)
    return ns.EUI().MakeFont(parent, size, nil, r or 1, g or 1, b or 1)
end

local PART_COLOR = { ok = "|cff0dd29f", outdated = "|cffffd100", missing = "|cffff5555" }

local function Label(p, name) return p.label and p.label(name) or name end

local function StatusOf(p, res)
    if not p.loaded() then return "|cff888888" .. p.title .. " is not installed or not enabled.|r" end
    if not p.has(res) then return "|cff888888" .. (p.none or ("Not part of the pack for " .. res .. ".")) .. "|r" end
    local i = DB()
    if UpdateFor(p) then
        if p.outdated then return "|cffffd100Update available on this character.|r" end
        return ("|cffffd100Update available (pack v%d, you have v%d).|r"):format(PACK.version, i.done[p.key])
    end
    if p.installed() then return "|cff0dd29fInstalled.|r" end
    return "|cffff5555Not installed.|r"
end

local function BuildRow(c, p, y, res)
    local eui = ns.EUI()
    local name = Text(c, 14)
    name:SetPoint("TOPLEFT", c, "TOPLEFT", 24, y)
    name:SetText(p.title)
    local status = Text(c, 11)
    status:SetPoint("TOPLEFT", c, "TOPLEFT", 24, y - 20)
    status:SetText(StatusOf(p, res))

    local usable = Usable(p, res)
    local detail = Text(c, 11, 0.6, 0.6, 0.6)
    detail:SetPoint("TOPLEFT", c, "TOPLEFT", 24, y - 36)
    detail:SetWidth(300)
    detail:SetJustifyH("LEFT")
    if p.loaded() then
        if p.perChar then
            local want = Want(p)
            local cur = p.current() or "?"
            local curText = (want and cur ~= want) and ("|cffffd100" .. Label(p, cur) .. "|r") or Label(p, cur)
            detail:SetText("This character: " .. curText .. "   Use: " .. (want and Label(p, want) or "-"))
        elseif p.detail then
            detail:SetText(p.detail())
        end
    end

    if p.parts and usable then
        local parts = p.parts()
        local w = math.min(120, math.floor((380 - 6 * (#parts - 1)) / #parts))
        for n, part in ipairs(parts) do
            local b = Btn(c, PART_COLOR[part.state] .. part.label .. "|r", "TOPLEFT", c, "TOPLEFT",
                24 + (n - 1) * (w + 6), y - 38, function()
                    RunInstall(p, res, function() Refresh() end, part.arg)
                end, true)
            b:SetWidth(w)
        end
    end

    local label = (UpdateFor(p) and "Update") or ((p.loaded() and p.installed()) and "Reinstall") or "Install"
    Btn(c, label, "TOPRIGHT", c, "TOPRIGHT", -24, y, function()
        RunInstall(p, res, function() Refresh() end)
    end, usable)

    if p.extra and p.loaded() then
        local x = p.extra
        Btn(c, (x.done() and PART_COLOR.ok or PART_COLOR.missing) .. x.label .. "|r", "TOPRIGHT", c, "TOPRIGHT", -24, y - 32, function()
            x.run()
            Refresh()
        end, x.usable())
    end

    if p.perChar and p.loaded() then
        Btn(c, "Load", "TOPRIGHT", c, "TOPRIGHT", -24, y - 32, function()
            LoadFor(p)
            Refresh()
        end, Mismatched(p))
        -- the profile alts should use: any existing one, the pack's by default
        Btn(c, "Profile...", "TOPRIGHT", c, "TOPRIGHT", -155, y - 32, function(self)
            local items = {}
            local want = Want(p)
            for _, n in ipairs(p.list()) do
                items[#items + 1] = { key = n, label = (n == want) and ("|cff0dd29f" .. Label(p, n) .. "|r") or Label(p, n) }
            end
            eui.ShowPickMenu(self, {
                title = p.title .. " profile for your characters",
                fontPath = eui.GetFontPath and eui.GetFontPath() or nil,
                items = items,
                onPick = function(key)
                    DB().pick[p.key] = key
                    Refresh()
                end,
            })
        end, true)
    end
end

Refresh = function()
    if not win then return end
    local eui = ns.EUI()
    if win.content then win.content:Hide(); win.content:SetParent(nil) end
    local c = CreateFrame("Frame", nil, win.popup)
    c:SetAllPoints()
    c:SetFrameLevel(win.popup:GetFrameLevel() + 1)
    win.content = c
    local res = Res()
    local i = DB()
    Adopt(res)

    local title = Text(c, 18)
    title:SetPoint("TOPLEFT", c, "TOPLEFT", 24, -20)
    title:SetText(PACK.name)
    local sub = Text(c, 11, 0.6, 0.6, 0.6)
    sub:SetPoint("TOPLEFT", c, "TOPLEFT", 24, -44)
    local screen = DetectRes()
    local note = (screen ~= res) and ("   |cffffd100(your screen: " .. screen .. ")|r") or ""
    sub:SetText(("Installer   pack v%d   %s   %s"):format(PACK.version, res, CharKey()) .. note)

    -- resolution, only where the pack has strings for it
    local x = -24
    for idx = #RES, 1, -1 do
        local r = RES[idx]
        local have = false
        for _, a in ipairs(AvailableRes()) do if a == r then have = true end end
        local label = (r == res) and ("|cff0dd29f" .. r .. "|r") or r
        if SOON[r] then label = r .. "  |cff888888Coming Soon|r" end
        local b = Btn(c, label, "TOPRIGHT", c, "TOPRIGHT", x, -20, function()
            DB().res = r
            Refresh()
        end, have)
        local w = SOON[r] and 150 or 70
        b:SetWidth(w)
        x = x - w - 6
    end

    local y = -80
    for _, p in ipairs(PROVIDERS) do
        BuildRow(c, p, y, res)
        y = y - 92
    end

    -- bottom actions
    local ar, ag, ab = eui.GetAccentColor()
    local font = eui.GetFontPath and eui.GetFontPath() or STANDARD_TEXT_FONT
    local installAll = eui.MakeActionButton(c, font, "Install All", ar, ag, ab, { w = 170 })
    installAll:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 24, 58)
    installAll:SetScript("OnClick", function()
        local queue = {}
        for _, p in ipairs(PROVIDERS) do
            if Usable(p, res) and (UpdateFor(p) or not p.installed()) then queue[#queue + 1] = p end
        end
        if #queue == 0 then Say("everything in the pack is already installed."); return end
        local n = 0
        local function Next()
            n = n + 1
            local p = queue[n]
            if not p then Refresh(); return end
            RunInstall(p, res, Next)
        end
        Next()
    end)

    local loadAll = eui.MakeActionButton(c, font, "Load for This Character", ar, ag, ab, { w = 200, secondary = not AnyMismatch() })
    loadAll:SetPoint("BOTTOM", c, "BOTTOM", 0, 58)
    loadAll:SetScript("OnClick", function()
        for _, p in ipairs(PROVIDERS) do
            if Mismatched(p) then LoadFor(p, Refresh) end
        end
        Refresh()
    end)

    local reload = eui.MakeActionButton(c, font, "Reload UI", ar, ag, ab, { w = 170, secondary = not needReload })
    reload:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -24, 58)
    reload:SetScript("OnClick", ReloadUI)

    Btn(c, "Close", "BOTTOMRIGHT", c, "BOTTOMRIGHT", -24, 18, function()
        i.updateSeen = PACK.version
        CloseWindow()
        if needReload then
            eui:ShowConfirmPopup({
                title = "Reload Required", message = "What you installed takes effect after a reload.",
                confirmText = "Reload Now", cancelText = "Later", reload = true,
            })
        end
    end, true)
    Btn(c, "Don't Show Again", "BOTTOMLEFT", c, "BOTTOMLEFT", 24, 18, function()
        i.declined = true
        Say("won't open by itself anymore. /tui install opens it.")
        CloseWindow()
    end, true):SetWidth(150)
    Btn(c, "Skip This Character", "BOTTOMLEFT", c, "BOTTOMLEFT", 180, 18, function()
        i.charNoAsk[CharKey()] = true
        Say("won't open by itself on this character. /tui install opens it.")
        CloseWindow()
    end, true):SetWidth(150)
end

function ns.OpenInstaller()
    local eui = ns.EUI()
    if not (eui and eui.BuildPopupShell and DB()) then return end
    if InCombatLockdown() then Say("not in combat."); return end
    if not win then
        local dimmer, popup = eui.BuildPopupShell("ThingsTweaksInstaller", {
            w = 620, h = 654, bump = 1.3, strata = "DIALOG", clamp = true,
            onEscape = CloseWindow,
        })
        win = { dimmer = dimmer, popup = popup }
    end
    Refresh()
    win.dimmer:Show()
end

-- ----------------------------------------------------------------- wiring

-- while the pack is not installed, it owns the first run instead of EUI's
-- own module picker (which returns once this stops registering)
local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:SetScript("OnEvent", function(self, _, name)
    if name ~= ns.ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    ns.AdoptOldDB()
    local inst = _G.EUI_ThingsTweaksDB and _G.EUI_ThingsTweaksDB.install
    local eui = ns.EUI()
    if eui and eui.RegisterExternalInstaller and (EUIHasString("1440p") or EUIHasString("1080p"))
        and not (inst and (inst.declined or (inst.done and inst.done.eui))) then
        eui.RegisterExternalInstaller(PACK.name)
    end
end)

local openAtRegen = false
local function AutoOpen()
    if InCombatLockdown() then openAtRegen = true; return end
    openAtRegen = false
    local i = DB()
    if not i or i.declined or i.charNoAsk[CharKey()] or (win and win.dimmer:IsShown()) then return end
    local res = Res()
    Adopt(res)
    if EUIHasString(res) and not i.done.eui then
        ns.OpenInstaller()
        return
    end
    if i.updateSeen ~= PACK.version then
        for _, p in ipairs(PROVIDERS) do
            if Usable(p, res) and UpdateFor(p) then ns.OpenInstaller(); return end
        end
    end
    if AnyMismatch() then ns.OpenInstaller() end
end

ns.bootOnly[#ns.bootOnly + 1] = function() C_Timer.After(4, AutoOpen) end
ns.onRegen[#ns.onRegen + 1] = function()
    if openAtRegen then AutoOpen() end
end

SLASH_THINGSTWEAKS1 = "/tui"
SlashCmdList.THINGSTWEAKS = function(msg)
    local cmd = strlower(strtrim(msg or ""))
    if cmd == "install" then
        ns.OpenInstaller()
    elseif cmd == "bwauras" then
        ns.CaptureBigWigsAuras()
    elseif cmd == "" and ns.EUI() and ns.EUI().OpenPlugin then
        ns.EUI().OpenPlugin(ns.ADDON)
    else
        Say("/tui opens the options, /tui install the installer.")
    end
end
