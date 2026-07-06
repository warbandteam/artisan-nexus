--[[
    Artisan Nexus — version, interface target, internal message names.
    Keep in sync with ArtisanNexus.toc (## Interface / ## Version).
]]

local ADDON_NAME, ns = ...

---@class Constants
local Constants = {
    ADDON_VERSION = "0.1.1",
    ADDON_RELEASE_DATE = "2026-07-06",

    --- Must match ## Interface in ArtisanNexus.toc (Midnight 12.0.1 retail)
    CURRENT_INTERFACE = 120001,
    CURRENT_EXPANSION_NAME = "Midnight",

    DB_VERSION = 1,

    --- Hub + Recipe Matcher profession filter cycle (English catalog keys; RecipeService:GetProfession).
    CRAFT_PROFESSION_FILTERS = {
        "All",
        "Alchemy",
        "Blacksmithing",
        "Cooking",
        "Enchanting",
        "Engineering",
        "Inscription",
        "Jewelcrafting",
        "Leatherworking",
        "Tailoring",
    },

    --==========================================================================
    -- INTERNAL MESSAGES (AceEvent SendMessage / RegisterMessage) — AN_ prefix
    --==========================================================================

    EVENTS = {
        --- Payload: `moduleKey` (`"fishing"` | `"gathering"`), `enabled` (bool). Emitted when profile toggles change module wiring.
        MODULE_TOGGLED = "AN_MODULE_TOGGLED",
        --- Fired from Core OnEnable after optional modules start; internal listeners / extensions may hook here.
        LOADING_COMPLETE = "AN_LOADING_COMPLETE",

        -- Fishing QoL
        FISHING_CHANNEL_STARTED = "AN_FISHING_CHANNEL_STARTED",
        FISHING_CHANNEL_STOPPED = "AN_FISHING_CHANNEL_STOPPED",
        --- Payload: `{ primaryItemId, totalQuantity, distinctItems }` — one emit per processed `CHAT_MSG_LOOT` line.
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
        --- AH scan queue finished (not emitted per-item during scan).
        AH_SCAN_COMPLETE = "AN_AH_SCAN_COMPLETE",

        --- CraftBriefingService rebuilt top profitable crafts (`db.global.craftBriefing`).
        CRAFT_BRIEFING_UPDATED = "AN_CRAFT_BRIEFING_UPDATED",

        --- ProfessionEquipmentService refreshed gear hints (`db.char.professionEquipmentHints`).
        PROFESSION_EQUIPMENT_UPDATED = "AN_PROFESSION_EQUIPMENT_UPDATED",

        --- RecipeService harvested schematics from an open profession window.
        RECIPE_SCHEMATICS_UPDATED = "AN_RECIPE_SCHEMATICS_UPDATED",

        CRAFT_QUEUE_UPDATED = "AN_CRAFT_QUEUE_UPDATED",
        --- Payload: `{ itemID, qty, spellID?, profession? }` after craft output session write.
        CRAFT_LOOT_RECORDED = "AN_CRAFT_LOOT_RECORDED",
        SHOPPING_LIST_UPDATED = "AN_SHOPPING_LIST_UPDATED",

        --- Profession window snapshot (concentration / knowledge chip text).
        PROFESSION_SNAPSHOT_UPDATED = "AN_PROFESSION_SNAPSHOT_UPDATED",

        --- Profile themeMode changed; UI panels refresh chrome when visible.
        THEME_CHANGED = "AN_THEME_CHANGED",
    },
}

ns.Constants = Constants
