local _, ns = ...

local S, SetOpt = ns.S, ns.SetOpt

-- ------------------------------------------------------------ EUI config panel

ns.PLUGIN_MODULE = "things"

function ns.InstallConfigPanel()
    local eui = ns.EUI()
    if not (eui and eui.RegisterPlugin) or eui.IsPluginRegistered(ns.ADDON) then return end

    local config = {
        key = ns.PLUGIN_MODULE,
        title = "things",
        description = "Tweaks to EUI that I wanted. Vibed the shit out of it with Fable.",
        pages = { "General", "Action Bars", "Trinkets", "Raid Frame Builder", "Racials", "Anchors" },
        buildPage = function(page, parent, yOffset)
            -- custom pages touch live frames; the search indexes them once opened
            if page ~= "General" and eui.IsSearchPrebuild() then return 0 end
            if page == "Raid Frame Builder" then
                return ns.BuildRaidBuilderPage(parent, yOffset)
            elseif page == "Racials" then
                return ns.BuildRacialsPage(parent, yOffset)
            elseif page == "Action Bars" then
                return ns.BuildActionBarsPage(parent, yOffset)
            elseif page == "Trinkets" then
                return ns.BuildTrinketsPage(parent, yOffset)
            elseif page == "Anchors" then
                return ns.BuildAnchorPointsPage(parent, yOffset)
            end
            local W = eui.Widgets
            if not W then return 0 end
            local y = yOffset
            local _, h
            _, h = W:SectionHeader(parent, "MAIN CASTBAR", y); y = y - h
            _, h = W:Toggle(parent, "Spell + Target Name", y,
                function() return S().mainTargetName end,
                function(v) SetOpt("mainTargetName", v) end); y = y - h
            _, h = W:Toggle(parent, "Icon Border", y,
                function() return S().mainIconBorder end,
                function(v)
                    SetOpt("mainIconBorder", v)
                    ns.ApplyIconBorder()
                end,
                "1px border and inset on the spell icon, matching the unit frame castbars."); y = y - h
            _, h = W:Toggle(parent, "Class Colored Target Name", y,
                function() return S().classColorTarget end,
                function(v) SetOpt("classColorTarget", v) end,
                "Applies to all cast bars."); y = y - h
            _, h = W:SectionHeader(parent, "UNIT FRAME CASTBARS", y); y = y - h
            _, h = W:Toggle(parent, "Mini Bar Spell + Target Name", y,
                function() return S().combineNameTarget end,
                function(v) SetOpt("combineNameTarget", v) end); y = y - h
            _, h = W:SectionHeader(parent, "TRACKING BARS", y); y = y - h
            _, h = W:Toggle(parent, "Icon Border", y,
                function() return S().tbbIconBorder end,
                function(v)
                    SetOpt("tbbIconBorder", v)
                    ns.ApplyTBBIcons()
                end,
                "Completes the border along the icon's bar-facing edge on CDM tracking bars."); y = y - h
            if ns.BuildTotemBarsSection then
                y = ns.BuildTotemBarsSection(parent, y)
            end
            _, h = W:SectionHeader(parent, "CDM BARS", y); y = y - h
            _, h = W:Toggle(parent, "Overflow Icons First", y,
                function() return S().cdmOverflowFirst end,
                function(v)
                    SetOpt("cdmOverflowFirst", v)
                    ns.UpdateCDMOverflow()
                    ns.RepaintCDM()
                end,
                "Places Max Icons overflow at the start of the destination bar instead of the end."); y = y - h
            _, h = W:Slider(parent, "Utility Wrap After (0 = Off)", y, 0, 30, 1,
                function() return S().cdmWrapCount or 0 end,
                function(v)
                    SetOpt("cdmWrapCount", v)
                    ns.UpdateCDMOverflow()
                    ns.RepaintCDM()
                end,
                "After this many icons the utility bar continues sideways, L-style."); y = y - h
            _, h = W:Dropdown(parent, "Utility Wrap Direction", y,
                { LEFT = "Left", RIGHT = "Right" },
                function() return S().cdmWrapSide or "LEFT" end,
                function(v)
                    SetOpt("cdmWrapSide", v)
                    ns.UpdateCDMOverflow()
                    ns.RepaintCDM()
                end,
                { "LEFT", "RIGHT" }); y = y - h
            _, h = W:Toggle(parent, "Hide Passive Cooldowns", y,
                function() return S().cdmHidePassive end,
                function(v)
                    SetOpt("cdmHidePassive", v)
                    if ns.RefreshPassiveHide then ns.RefreshPassiveHide() end
                end,
                "Hides cooldowns a talent turned passive (Crusading Strikes, Radiant Glory). Nothing is removed from your bars: take the talent back and the spell shows again. Marked PASSIVE in the Cooldown Manager preview."); y = y - h
            if ns.OpenInstaller then
                _, h = W:SectionHeader(parent, "INSTALLER", y); y = y - h
                _, h = W:WideButton(parent, "Open Installer", y, function() ns.OpenInstaller() end); y = y - h
            end
            return math.abs(y)
        end,
        onReset = function()
            for k, v in pairs(ns.defaults) do SetOpt(k, v) end
            ns.ApplyIconBorder()
            ns.ApplyTBBIcons()
            ns.UpdateCDMOverflow()
            ns.RepaintCDM()
            if ns.RefreshPassiveHide then ns.RefreshPassiveHide() end
            local e = ns.EUI()
            if e and e.RefreshPage then e:RefreshPage(true) end
        end,
    }

    eui.RegisterPlugin(ns.ADDON, { label = "things for EUI", modules = { config } })
end
