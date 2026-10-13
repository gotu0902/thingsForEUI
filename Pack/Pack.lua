local _, ns = ...

-- ------------------------------------------------------------ install pack

-- The strings live next to this file, one per addon. HOW TO UPDATE: paste a
-- fresh export between the [==[ ]==] brackets (no escaping needed). Accounts
-- that installed are asked to patch what changed (EllesmereUI: only the
-- modules that differ), found from the strings themselves. An empty string
-- leaves that addon or resolution out; with no EllesmereUI string at all the
-- installer never opens by itself.

ns.PACK = {
    name    = "thingsEUI",
    version = 1,

    eui = {
        -- replaced by other addons in this pack
        disable = { "EllesmereUIDataBars", "EllesmereUIBags" },
        -- modules kept equal between the pack profiles (EllesmereUI sync groups)
        sync = {
            "EllesmereUIActionBars", "EllesmereUINameplates",
            "EllesmereUIQoL", "EllesmereUIAuraBuffReminders", "EllesmereUIQuickdraw",
            "EllesmereUIDragonRiding", -- the Blizzard Skins sync icon
            "EllesmereUIDamageMeters", "EllesmereUIMythicTimer", "EllesmereUIQuestTracker",
            "EllesmereUIFriends", "EllesmereUIMinimap", "EllesmereUIChat",
        },
        profiles = {},
    },
    bigwigs   = { profiles = {} },
    baganator = { strings = {} },
    cdm       = { layouts = {} },
    editmode  = { strings = {} },
}
