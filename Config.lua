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
                else
                    if ns.GatheringLootService then ns.GatheringLootService:Disable() end
                end
            end,
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
    },
}

local Config = {}

function Config.RegisterOptions(addon)
    LibStub("AceConfig-3.0"):RegisterOptionsTable(ADDON_NAME, options)
    LibStub("AceConfigDialog-3.0"):AddToBlizOptions(ADDON_NAME, ADDON_NAME)
end

ns.Config = Config
