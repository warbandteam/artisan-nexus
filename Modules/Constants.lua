--[[
    Artisan Nexus — version, interface target, internal message names.
    Keep in sync with ArtisanNexus.toc (## Interface / ## Version).
]]

local ADDON_NAME, ns = ...

---@class Constants
local Constants = {
    ADDON_VERSION = "0.4.8",
    ADDON_RELEASE_DATE = "2026-04-19",

    --- Must match ## Interface in ArtisanNexus.toc (Midnight 12.0.1 retail)
    CURRENT_INTERFACE = 120001,
    CURRENT_EXPANSION_NAME = "Midnight",

    DB_VERSION = 1,

    --==========================================================================
    -- INTERNAL MESSAGES (AceEvent SendMessage / RegisterMessage) — AN_ prefix
    --==========================================================================

    EVENTS = {
        MODULE_TOGGLED = "AN_MODULE_TOGGLED",
        LOADING_COMPLETE = "AN_LOADING_COMPLETE",

        -- Fishing QoL
        FISHING_CHANNEL_STARTED = "AN_FISHING_CHANNEL_STARTED",
        FISHING_CHANNEL_STOPPED = "AN_FISHING_CHANNEL_STOPPED",
        FISHING_LOOT_RECORDED = "AN_FISHING_LOOT_RECORDED",
        FISHING_HISTORY_UPDATED = "AN_FISHING_HISTORY_UPDATED",

        GATHERING_LOOT_RECORDED = "AN_GATHERING_LOOT_RECORDED",
        GATHERING_HISTORY_UPDATED = "AN_GATHERING_HISTORY_UPDATED",
        GATHERING_OVERLOAD_HINT_UPDATED = "AN_GATHERING_OVERLOAD_HINT_UPDATED",

        --- Either fishing or gathering history changed (refresh unified loot UI)
        LOOT_HISTORY_UPDATED = "AN_LOOT_HISTORY_UPDATED",
        SESSION_LOOT_UPDATED = "AN_SESSION_LOOT_UPDATED",

        --- AH price scan completed; UI should refresh price columns.
        AH_PRICES_UPDATED = "AN_AH_PRICES_UPDATED",
    },
}

ns.Constants = Constants
