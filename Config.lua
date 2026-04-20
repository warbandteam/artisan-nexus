--[[
    Artisan Nexus — AceConfig options (minimal; expand with Fishing QoL toggles later).
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local L = ns.L

local options = {
    name = ADDON_NAME,
    type = "group",
    args = {
        header = {
            order = 1,
            type = "description",
            name = function()
                return "|cff00ccff" .. ((L and L["CONFIG_HEADER"]) or "Artisan Nexus") .. "|r\n"
                    .. ((L and L["CONFIG_HEADER_DESC"]) or "") .. "\n\n"
            end,
            fontSize = "medium",
        },
        showLoginChat = {
            order = 10,
            type = "toggle",
            name = function() return (L and L["CONFIG_SHOW_LOGIN_CHAT"]) or "Login message" end,
            desc = function() return (L and L["CONFIG_SHOW_LOGIN_CHAT_DESC"]) or "" end,
            get = function() return ArtisanNexus.db.profile.showLoginChat end,
            set = function(_, v)
                ArtisanNexus.db.profile.showLoginChat = v
            end,
        },
        fishingDoubleClick = {
            order = 11,
            type = "toggle",
            name = function() return (L and L["CONFIG_FISHING_DOUBLE_CLICK"]) or "Double right-click fishing" end,
            desc = function() return (L and L["CONFIG_FISHING_DOUBLE_CLICK_DESC"]) or "" end,
            get = function() return ArtisanNexus.db.profile.fishingDoubleClickEnabled end,
            set = function(_, v)
                ArtisanNexus.db.profile.fishingDoubleClickEnabled = v
            end,
        },
        gatheringLoot = {
            order = 12,
            type = "toggle",
            name = function() return (L and L["CONFIG_GATHERING_LOOT"]) or "Gathering loot history" end,
            desc = function() return (L and L["CONFIG_GATHERING_LOOT_DESC"]) or "" end,
            get = function()
                local m = ArtisanNexus.db.profile.modulesEnabled
                return m and m.gathering ~= false
            end,
            set = function(_, v)
                ArtisanNexus.db.profile.modulesEnabled = ArtisanNexus.db.profile.modulesEnabled or {}
                ArtisanNexus.db.profile.modulesEnabled.gathering = v
                if v then
                    if ns.GatheringLootService then ns.GatheringLootService:Enable() end
                    if ns.GatheringOverloadService then ns.GatheringOverloadService:Enable() end
                else
                    if ns.GatheringLootService then ns.GatheringLootService:Disable() end
                    if ns.GatheringOverloadService then ns.GatheringOverloadService:Disable() end
                end
            end,
        },
        overloadNodeIndicator = {
            order = 12.2,
            type = "toggle",
            name = function() return (L and L["CONFIG_OVERLOAD_NODE_INDICATOR"]) or "Overload node indicator" end,
            desc = function() return (L and L["CONFIG_OVERLOAD_NODE_INDICATOR_DESC"]) or "" end,
            get = function() return ArtisanNexus.db.profile.overloadNodeIndicatorEnabled ~= false end,
            set = function(_, v)
                ArtisanNexus.db.profile.overloadNodeIndicatorEnabled = v and true or false
                if ns.ArtisanNexus and ns.Constants and ns.Constants.EVENTS and ns.Constants.EVENTS.GATHERING_OVERLOAD_HINT_UPDATED then
                    ns.ArtisanNexus:SendMessage(ns.Constants.EVENTS.GATHERING_OVERLOAD_HINT_UPDATED, nil)
                end
            end,
        },
        routeHeatmap = {
            order = 12.3,
            type = "toggle",
            name = function() return (L and L["CONFIG_ROUTE_HEATMAP"]) or "Gather route heatmap" end,
            desc = function() return (L and L["CONFIG_ROUTE_HEATMAP_DESC"]) or "" end,
            get = function() return ArtisanNexus.db.profile.routeHeatmapEnabled == true end,
            set = function(_, v)
                ArtisanNexus.db.profile.routeHeatmapEnabled = v and true or false
                if ns.GatheringRouteOverlay and ns.GatheringRouteOverlay.Refresh then
                    ns.GatheringRouteOverlay:Refresh()
                end
            end,
        },
        bagPressureGuard = {
            order = 12.35,
            type = "toggle",
            name = function() return (L and L["CONFIG_BAG_PRESSURE_GUARD"]) or "Bag pressure guard" end,
            desc = function() return (L and L["CONFIG_BAG_PRESSURE_GUARD_DESC"]) or "" end,
            get = function() return ArtisanNexus.db.profile.bagPressureGuardEnabled ~= false end,
            set = function(_, v)
                ArtisanNexus.db.profile.bagPressureGuardEnabled = v and true or false
                if ns.BagPressureGuard then
                    if v then ns.BagPressureGuard:Enable() else ns.BagPressureGuard:Disable() end
                end
            end,
        },
        bagPressureThreshold = {
            order = 12.36,
            type = "range",
            min = 1,
            max = 40,
            step = 1,
            name = function() return (L and L["CONFIG_BAG_PRESSURE_THRESHOLD"]) or "Bag pressure threshold" end,
            desc = function() return (L and L["CONFIG_BAG_PRESSURE_THRESHOLD_DESC"]) or "" end,
            get = function() return ArtisanNexus.db.profile.bagPressureThreshold or 8 end,
            set = function(_, v)
                ArtisanNexus.db.profile.bagPressureThreshold = math.max(1, math.floor(v or 8))
            end,
            disabled = function() return ArtisanNexus.db.profile.bagPressureGuardEnabled == false end,
        },
        lootHistoryEnabled = {
            order = 12.45,
            type = "toggle",
            name = function() return (L and L["CONFIG_LOOT_HISTORY_ENABLED"]) or "Session loot window" end,
            desc = function() return (L and L["CONFIG_LOOT_HISTORY_ENABLED_DESC"]) or "" end,
            get = function() return ArtisanNexus.db.profile.lootHistoryEnabled ~= false end,
            set = function(_, v)
                ArtisanNexus.db.profile.lootHistoryEnabled = v and true or false
                if not v and ns.LootHistoryUI and ns.LootHistoryUI.Hide then
                    ns.LootHistoryUI:Hide()
                end
            end,
        },
        lootHistoryAutoOpen = {
            order = 12.5,
            type = "toggle",
            name = function() return (L and L["CONFIG_LOOT_HISTORY_AUTO_OPEN"]) or "Auto-open on profession loot" end,
            desc = function() return (L and L["CONFIG_LOOT_HISTORY_AUTO_OPEN_DESC"]) or "" end,
            get = function() return ArtisanNexus.db.profile.lootHistoryAutoOpen end,
            set = function(_, v)
                ArtisanNexus.db.profile.lootHistoryAutoOpen = v
            end,
            disabled = function() return ArtisanNexus.db.profile.lootHistoryEnabled == false end,
        },
        debugMode = {
            order = 13,
            type = "toggle",
            name = function() return (L and L["CONFIG_DEBUG"]) or "Debug mode" end,
            desc = function() return (L and L["CONFIG_DEBUG_DESC"]) or "" end,
            get = function() return ArtisanNexus.db.profile.debugMode end,
            set = function(_, v)
                ArtisanNexus.db.profile.debugMode = v
            end,
        },
        resetAllSession = {
            order = 19,
            type = "execute",
            name = function() return (L and L["CONFIG_RESET_ALL_SESSION"]) or "Reset all session loot" end,
            desc = function() return (L and L["CONFIG_RESET_ALL_SESSION_DESC"]) or "" end,
            func = function()
                if ns.SessionLootService and ns.SessionLootService.ResetSession then
                    ns.SessionLootService:ResetSession()
                end
            end,
        },
        resetAllOverall = {
            order = 20,
            type = "execute",
            name = function() return (L and L["CONFIG_RESET_ALL_OVERALL"]) or "Reset all overall loot history" end,
            desc = function() return (L and L["CONFIG_RESET_ALL_OVERALL_DESC"]) or "" end,
            func = function()
                if ns.SessionLootService and ns.SessionLootService.ResetAllOverallData then
                    ns.SessionLootService:ResetAllOverallData()
                end
            end,
        },
    },
}

local Config = {}

function Config.RegisterOptions(addon)
    LibStub("AceConfig-3.0"):RegisterOptionsTable(ADDON_NAME, options)
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions(ADDON_NAME, ADDON_NAME)
end

ns.Config = Config
