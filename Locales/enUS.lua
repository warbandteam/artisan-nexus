local L = LibStub("AceLocale-3.0"):NewLocale("ArtisanNexus", "enUS", true)

if not L then return end

L["ADDON_NAME"] = "Artisan Nexus"
L["ADDON_NOTES"] = "Professions QoL — Midnight"

L["CONFIG_HEADER"] = "Artisan Nexus"
L["CONFIG_HEADER_DESC"] = "Crafting and profession quality-of-life. Event-driven architecture; Midnight-targeted APIs."

L["CONFIG_SHOW_LOGIN_CHAT"] = "Login message"
L["CONFIG_SHOW_LOGIN_CHAT_DESC"] = "Print a short line to chat when the addon loads (character login / reload)."

L["CONFIG_DEBUG"] = "Debug mode"
L["CONFIG_DEBUG_DESC"] = "Print fishing cast/channel notices and other diagnostics to chat."

L["SLASH_HELP_HEADER"] = "Commands:"
L["SLASH_HELP_LINE"] = "|cff00ccff/an help|r — this list\n|cff00ccff/an debug|r — toggle debug (fishing channel notices)\n|cff00ccff/an version|r — addon version\n|cff00ccff/an fish|r / |cff00ccff/an gather|r (herb) / |cff00ccff/an mine|r / |cff00ccff/an leather|r / |cff00ccff/an de|r — loot history tab\n|cff00ccff/an loot|r — toggle history window\nDouble |cffffffffright-click|r on the world: cast Fishing, or interact with bobber while fishing."

L["LOOT_HISTORY_TITLE"] = "Session loot"
L["LOOT_TAB_FISHING"] = "Fishing"
L["LOOT_SECTION_REFERENCE"] = "Reference (totals this session)"
L["LOOT_REF_TOTAL_FMT"] = "x(%d)"
L["LOOT_SECTION_SESSION"] = "Last loot (10)"
L["LOOT_GATHER_HERB"] = "Herbalism"
L["LOOT_GATHER_MINE"] = "Mining"
L["LOOT_GATHER_LEATHER"] = "Leatherworking"
L["LOOT_GATHER_DE"] = "Disenchanting"
L["LOOT_RESET_SESSION"] = "Reset session"
L["LOOT_SESSION_EMPTY"] = "Nothing collected this session yet."

L["CONFIG_FISHING_DOUBLE_CLICK"] = "Double right-click fishing"
L["CONFIG_FISHING_DOUBLE_CLICK_DESC"] = "Double right-click on the game world: cast Fishing, or (while fishing) interact with the bobber. Uses secure buttons; disable if another addon conflicts."

L["CONFIG_GATHERING_LOOT"] = "Gathering loot history"
L["CONFIG_GATHERING_LOOT_DESC"] = "Track herbs, ore, skinning, and disenchant loot per profession tab using the Blizzard Loot window (no chat parsing)."

L["FISHING_BOBBER_NAME"] = "Fishing Bobber"
L["FISHING_HISTORY_TITLE"] = "Fishing loot history"

L["LOGIN_CHAT"] = "v%s loaded. |cff00ccff/an help|r — commands. |cff00ccff/an loot|r — history (per profession tab)."

L["FISHING_DEBUG_CHANNEL_START"] = "Fishing channel started (spell %s)."
L["FISHING_DEBUG_CHANNEL_STOP"] = "Fishing channel ended (spell %s)."
