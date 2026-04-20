local L = LibStub("AceLocale-3.0"):NewLocale("ArtisanNexus", "enUS", true)

if not L then return end

L["ADDON_NAME"] = "Artisan Nexus"
L["ADDON_NOTES"] = "Professions QoL — Midnight"

L["CONFIG_HEADER"] = "Artisan Nexus"
L["CONFIG_HEADER_DESC"] = "Profession QoL (Midnight)."

L["CONFIG_SHOW_LOGIN_CHAT"] = "Login message"
L["CONFIG_SHOW_LOGIN_CHAT_DESC"] = "Print a line to chat when the addon loads."

L["CONFIG_DEBUG"] = "Debug mode"
L["CONFIG_DEBUG_DESC"] = "Print fishing cast/channel notices and other diagnostics to chat."
L["CONFIG_RESET_ALL_SESSION"] = "Reset all session loot (all professions)"
L["CONFIG_RESET_ALL_SESSION_DESC"] = "Clears every tab’s in-memory session list and totals for this login. Use the loot window’s Reset button to clear only the active tab."
L["CONFIG_RESET_ALL_OVERALL"] = "Reset all overall loot history"
L["CONFIG_RESET_ALL_OVERALL_DESC"] = "Deletes saved overall pickup history for every profession. Cannot be undone."

L["SLASH_HELP_HEADER"] = "Commands:"
L["SLASH_HELP_LINE"] = "|cff00ccff/an help|r | |cff00ccff/an loot|r | |cff00ccff/an ah|r | |cff00ccff/an fish|r | |cff00ccff/an gather|r | |cff00ccff/an mine|r | |cff00ccff/an leather|r | |cff00ccff/an de|r | |cff00ccff/an debug|r"

L["LOOT_HISTORY_TITLE"] = "Session loot"
L["LOOT_TAB_FISHING"] = "Fishing"
L["LOOT_SECTION_REFERENCE"] = "Catalog"
L["LOOT_SECTION_TOTAL_FMT"] = "Total: %s"
L["LOOT_REF_TOTAL_FMT"] = "×%d"
L["LOOT_SECTION_SESSION_FMT"] = "Last %d pickups"
L["LOOT_LAST_PICKUPS_EMPTY"] = "No recent pickups yet."
L["LOOT_GATHER_HERB"] = "Herbalism"
L["LOOT_GATHER_MINE"] = "Mining"
L["LOOT_GATHER_LEATHER"] = "Leatherworking"
L["LOOT_GATHER_DE"] = "Disenchanting"
L["LOOT_GATHER_OTHERS"] = "Others"
L["LOOT_RESET_SESSION"] = "Reset session"
L["LOOT_SETTINGS_TOOLTIP"] = "Open settings (reset all data, options)"
L["LOOT_SESSION_EMPTY"] = "Nothing collected this session yet."
L["LOOT_MODE_SESSION"] = "Session"
L["LOOT_MODE_OVERALL"] = "Overall"
L["LOOT_RESET_OVERALL"] = "Reset overall"
L["LOOT_OVERALL_EMPTY"] = "Nothing recorded overall yet."
L["AH_SYNC_PRICES"] = "Sync AH Prices"
L["AH_PRICE_NO_DATA"] = "No AH data"
L["AH_SCAN_STARTED"] = "Starting AH price scan (%d items)."
L["AH_SCAN_BUSY"] = "AH price scan is already running."
L["AH_SCAN_NEED_OPEN"] = "Open the Auction House window first."
L["AH_SCAN_NO_ITEMS"] = "No catalog items to scan."
L["AH_SCAN_QUERY_FAIL"] = "Auction search failed for one item; skipping."
L["AH_SCAN_DONE"] = "AH price scan finished."

L["CONFIG_FISHING_DOUBLE_CLICK"] = "Double right-click fishing"
L["CONFIG_FISHING_DOUBLE_CLICK_DESC"] = "Double right-click world: cast Fishing or use bobber while fishing."

L["CONFIG_GATHERING_LOOT"] = "Gathering loot history"
L["CONFIG_GATHERING_LOOT_DESC"] = "Record herb / ore / skin / DE loot from the loot window."
L["CONFIG_OVERLOAD_NODE_INDICATOR"] = "Overload node indicator"
L["CONFIG_OVERLOAD_NODE_INDICATOR_DESC"] = "Show a world indicator when the hovered herb/ore node appears overloaded."
L["CONFIG_ROUTE_HEATMAP"] = "Gather route heatmap"
L["CONFIG_ROUTE_HEATMAP_DESC"] = "Show a lightweight gather-density overlay on the World Map."
L["CONFIG_BAG_PRESSURE_GUARD"] = "Bag pressure guard"
L["CONFIG_BAG_PRESSURE_GUARD_DESC"] = "Warn when free bag slots drop below your threshold."
L["CONFIG_BAG_PRESSURE_THRESHOLD"] = "Bag free-slot threshold"
L["CONFIG_BAG_PRESSURE_THRESHOLD_DESC"] = "When free slots are at or below this value, show a warning."

L["CONFIG_LOOT_HISTORY_ENABLED"] = "Session loot window"
L["CONFIG_LOOT_HISTORY_ENABLED_DESC"] = "Enable the Session loot UI (tabs, catalog, pickups). When off, the window does not react to loot and stays closed after reload. You can still open it with |cff00ccff/an loot|r or profession slash commands."

L["CONFIG_LOOT_HISTORY_AUTO_OPEN"] = "Auto-open on profession loot"
L["CONFIG_LOOT_HISTORY_AUTO_OPEN_DESC"] = "When enabled, opens Session loot when you loot something tracked (correct tab). Requires Session loot window above. Does not run on login/reload."

L["FISHING_BOBBER_NAME"] = "Fishing Bobber"
L["FISHING_HISTORY_TITLE"] = "Fishing loot history"

L["LOGIN_CHAT"] = "v%s |cff00ccff/an loot|r"

L["FISHING_DEBUG_CHANNEL_START"] = "Fishing channel started (spell %s)."
L["FISHING_DEBUG_CHANNEL_STOP"] = "Fishing channel ended (spell %s)."

L["OVERLOAD_HINT_READY_FMT"] = "Overload ready: %s"
L["OVERLOAD_HINT_COOLDOWN_FMT"] = "Overload in %s: %s"
L["OVERLOAD_HINT_DETECTED"] = "Overloaded node detected"
L["OVERLOAD_CURSOR_TIP"] = "Click to cast overload"
L["BAG_PRESSURE_WARN_FMT"] = "Bag pressure: %d free slots (threshold: %d)."
L["BAG_PRESSURE_WARN_SHORT"] = "Bag pressure"
L["LOOT_EFFICIENCY_FMT"] = "Rate: %.1f items/hr • %s/hr"
