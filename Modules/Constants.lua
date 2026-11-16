--[[
    Artisan Nexus — version, shared game constants, internal message names.
    ADDON_VERSION must match ArtisanNexus.toc ## Version (.github/scripts/preflight_release.py checks it).
]]

local ADDON_NAME, ns = ...

---@class Constants
local Constants = {
    ADDON_VERSION = "0.4.0-beta1",

    --- WoW Forever release line (tag forever-vX.Y.Z, CHANGELOG_FOREVER.md, CHANGELOG_FOREVER_V*).
    --- Must match ## Version in the generated ArtisanNexus_Forever.toc (scripts/build_flavor_tocs.py).
    FOREVER_ADDON_VERSION = "0.1.0",
    FOREVER_ADDON_RELEASE_DATE = "2026-11-12",

    --- Artisan's Acuity (soulbound reagent currency-item; never priced or bought from the AH).
    --- Verified 2026-10-14 via wago.tools ItemSparse build 12.1.5.70391 (Bonding = 1).
    ARTISANS_ACUITY_ITEM_ID = 210814,

    --- Concentration regen: "one per six minutes" (warcraft.wiki.gg/wiki/Concentration, read 2026-10-14).
    CONCENTRATION_REGEN_PER_HOUR = 10,

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

    --- Warband Nexus UI framework media (Modules/UI/*, copied from warband-nexus; same keys as WN Constants).
    --- Main-window / launcher logo (WN: Media/icon.tga).
    ADDON_MEDIA_ICON = "Interface\\AddOns\\ArtisanNexus\\Media\\anlogo.tga",
    --- UI chrome icons (stroke TGAs copied from warband-nexus Media/, tinted via SetVertexColor).
    WN_ICON_REMINDER = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-Reminder.tga",
    WN_ICON_TODO = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-Todo.tga",
    WN_ICON_PIN = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-Pin.tga",
    WN_ICON_BLOCK = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-Block.tga",
    WN_ICON_CHEVRON_UP = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-ChevronUp.tga",
    WN_ICON_CHEVRON_DOWN = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-ChevronDown.tga",
    WN_ICON_LINK = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-Link.tga",
    WN_ICON_CLOSE = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-Close.tga",
    WN_ICON_DISCORD = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-Discord.tga",
    WN_ICON_DONATE = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-Donate.tga",
    WN_ICON_CREDITS = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-Credits.tga",
    WN_ICON_TRACKING = "Interface\\AddOns\\ArtisanNexus\\Media\\Icon-Tracking.tga",

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

        --- Coalesced (0.5s) relay of Warband Nexus item/bag/concentration/recipe/tracking messages.
        --- Payload: `{ items?, bags?, concentration?, recipes?, tracking? }` (true for each kind seen).
        WN_DATA_UPDATED = "AN_WN_DATA_UPDATED",
        --- Bags / bank / warband bank changed (RecipeService BAG_UPDATE bucket, 0.35s). No payload.
        BAG_STOCK_UPDATED = "AN_BAG_STOCK_UPDATED",
        --- ns.CharacterData switched a capability between Warband Nexus and AN-native collection.
        --- Payload: `{ [capability] = "wn"|"native" }` for every capability (characters, concentration,
        --- recipes, items, cooldowns).
        CHARACTER_DATA_SOURCE_CHANGED = "AN_CHARACTER_DATA_SOURCE_CHANGED",
        --- ns.CharacterData persisted the logged-in character's professions and a profession, rank or
        --- cap changed (db.global.charProfessions[guid]). Payload: guid.
        CHARACTER_PROFESSIONS_UPDATED = "AN_CHARACTER_PROFESSIONS_UPDATED",
        --- ns.CharacterData:PurgeCharacter removed a character from every per-character store. Payload: guid.
        CHARACTER_PURGED = "AN_CHARACTER_PURGED",
        --- WN framework keys (SharedWidgets.lua registers them for its class-colour cache at load; a nil
        --- message name errors in AceEvent). AN keeps no db.global.characters roster and never sends them.
        CHARACTER_UPDATED = "AN_CHARACTER_UPDATED",
        CHARACTER_TRACKING_CHANGED = "AN_CHARACTER_TRACKING_CHANGED",

        --- Economy engine (Modules/Economy/*).
        --- profile.economy changed (cut, durations, proc factors, valuations).
        ECONOMY_CONFIG_CHANGED = "AN_ECONOMY_CONFIG_CHANGED",
        --- Vendor buy prices captured from an open merchant. Payload: count of items recorded.
        VENDOR_PRICES_UPDATED = "AN_VENDOR_PRICES_UPDATED",
        --- Per-recipe crafting operation snapshots (tiers, allocations, stats) refreshed. Payload: spellID|nil.
        CRAFT_OPS_UPDATED = "AN_CRAFT_OPS_UPDATED",
        --- Craft result ledger appended (grouped by operationID). Payload: ledger row.
        CRAFT_LEDGER_UPDATED = "AN_CRAFT_LEDGER_UPDATED",
        --- Sales / purchases / money ledger appended. Payload: { kind = "sale"|"buy"|"expired"|"money"|"order" }.
        SALES_LEDGER_UPDATED = "AN_SALES_LEDGER_UPDATED",
        --- Owned auctions re-read (undercut state recomputed).
        OWNED_AUCTIONS_UPDATED = "AN_OWNED_AUCTIONS_UPDATED",
        --- Crafting orders (patron / public / personal) evaluated.
        CRAFTING_ORDERS_UPDATED = "AN_CRAFTING_ORDERS_UPDATED",
        --- Recipe cooldown / charges snapshot changed.
        COOLDOWNS_UPDATED = "AN_COOLDOWNS_UPDATED",
        --- Market intelligence (movers, deals, depletion) recomputed after a scan.
        MARKET_INTEL_UPDATED = "AN_MARKET_INTEL_UPDATED",
        --- Concentration planner finished rebuilding plans / shadow prices.
        CONCENTRATION_PLAN_UPDATED = "AN_CONCENTRATION_PLAN_UPDATED",

        --- Warband Nexus UI framework messages (keys as in WN Constants.EVENTS; AN_ values so the two
        --- addons never receive each other's messages on the shared AceEvent bus).
        FONT_CHANGED = "AN_FONT_CHANGED",
        FONT_LIST_UPDATED = "AN_FONT_LIST_UPDATED",
        SEARCH_STATE_CHANGED = "AN_SEARCH_STATE_CHANGED",
        SEARCH_QUERY_UPDATED = "AN_SEARCH_QUERY_UPDATED",
        UI_MAIN_REFRESH_REQUESTED = "AN_UI_MAIN_REFRESH_REQUESTED",
        MAIN_WINDOW_VISIBILITY_CHANGED = "AN_MAIN_WINDOW_VISIBILITY_CHANGED",
    },
}

--- [WN Constants.lua] One addon, two release lines. On a WoW Forever client the Forever version and
--- its changelog key prefix replace the retail ones at load, so everything that reads ADDON_VERSION
--- (login line, migration stamp) reports the build the player actually installed. Detection is
--- inlined because Constants loads before Modules/Capabilities.lua (same test as IsForeverClient).
do
    local forever = false
    if WOW_PROJECT_ID and WOW_PROJECT_CAMELOT and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT then
        forever = true
    else
        local ok, iv = pcall(function() return (select(4, GetBuildInfo())) end)
        if ok and type(iv) == "string" then iv = tonumber(iv) end
        forever = ok and type(iv) == "number" and iv >= 16000 and iv < 20000 or false
    end
    Constants.IS_FOREVER_BUILD = forever
    Constants.RETAIL_ADDON_VERSION = Constants.ADDON_VERSION
    if forever then
        Constants.ADDON_VERSION = Constants.FOREVER_ADDON_VERSION
        Constants.ADDON_RELEASE_DATE = Constants.FOREVER_ADDON_RELEASE_DATE
        Constants.CHANGELOG_KEY_PREFIX = "CHANGELOG_FOREVER_V"
    else
        Constants.CHANGELOG_KEY_PREFIX = "CHANGELOG_V"
    end
end

ns.Constants = Constants
--- WN SharedWidgets / UI.lua read the main-window logo from here (WN Constants.lua sets the same alias).
ns.WARBAND_ADDON_MEDIA_ICON = Constants.ADDON_MEDIA_ICON
