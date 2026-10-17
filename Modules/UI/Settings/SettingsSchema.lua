--[[
    Artisan Nexus — settings rows (data only; rendered with the Warband Nexus settings builders by
    Modules/UI/SettingsUI_Artisan.lua into the WN Settings tab, Modules/UI/SettingsUI.lua).

    One declaration per setting: profile key, control, label / tooltip, and the side effect that
    runs after the write (onChange). Look, fonts, scale, keybinding and debug are WN's own
    General / Theme / Advanced rows; this file holds only the Artisan Nexus rows.

    Sections (id = WN settings category): general (minimap & chat rows appended to WN General) ·
    loot · crafting · auction · advanced (appended under WN's debug card).
    Row fields: type (toggle | slider | dropdown | radio | button | note | header), key (dotted
    profile path), label, desc = tooltip, hint = inline line, get/set, onChange, parent (toggle
    key), enabled, visible, values (dropdown/radio), min/max/step/format/applyOnRelease (slider),
    text/onClick/variant/confirm (button).
]]

local ADDON_NAME, ns = ...

local LT = ns.SafeLocaleString
local E = ns.Constants.EVENTS
--- Dotted keys on ns.db.profile ("economy.postDuration").
local function Path(path)
    local t = ns.db and ns.db.profile
    if not t or type(path) ~= "string" then
        return nil
    end
    for part in path:gmatch("[^%.]+") do
        if type(t) ~= "table" then
            return nil
        end
        t = t[part]
    end
    return t
end

--- Writes ns.db.profile.<path>, creating intermediate tables.
local function PathSet(path, value)
    local t = ns.db and ns.db.profile
    if not t or type(path) ~= "string" then
        return
    end
    local parts = {}
    for part in path:gmatch("[^%.]+") do
        parts[#parts + 1] = part
    end
    for i = 1, #parts - 1 do
        local nxt = t[parts[i]]
        if type(nxt) ~= "table" then
            nxt = {}
            t[parts[i]] = nxt
        end
        t = nxt
    end
    t[parts[#parts]] = value
end
local floor = math.floor

local COPPER_PER_GOLD = 10000

local function Profile()
    return ns.db.profile
end

local function Send(msg, ...)
    ns.ArtisanNexus:SendMessage(msg, ...)
end

-- ─────────────────────────────────────────────────────────────────
-- Value formats
-- ─────────────────────────────────────────────────────────────────

--- 0.7 -> "70%"
local function FmtShare(v)
    return string.format("%d%%", floor(v * 100 + 0.5))
end

--- 0.055 -> "5.5%"
local function FmtRate(v)
    local pct = floor(v * 1000 + 0.5) / 10
    if pct ~= floor(pct) then
        return string.format("%.1f%%", pct)
    end
    return string.format("%d%%", pct)
end

local function FmtMul(v)
    return string.format("%.2fx", v)
end

local function FmtGold(v, zeroText)
    if v <= 0 and zeroText then
        return zeroText
    end
    if v ~= floor(v) then
        return string.format("%.1fg", v)
    end
    return string.format("%dg", v)
end

local function FmtGoldOff(v)
    return FmtGold(v, LT("CONFIG_ECON_VALUE_OFF", "Off"))
end

local function FmtDays(v)
    return string.format(LT("CONFIG_ECON_DAYS_FMT", "%dd"), v)
end

local function FmtHours(v)
    return string.format(LT("CONFIG_HOURS_FMT", "%dh"), v)
end

local function FmtSeconds(v)
    return string.format(LT("CONFIG_SECONDS_FMT", "%ds"), v)
end

-- ─────────────────────────────────────────────────────────────────
-- Shared side effects
-- ─────────────────────────────────────────────────────────────────

local function NotifyShopping()
    ns.ShoppingListService:Notify()
end

--- Briefing options apply to the next build; rebuild now only when a briefing already exists.
local function RebuildBriefing()
    local svc = ns.CraftBriefingService
    local b = svc:GetBriefing()
    if b and b.updatedAt then
        svc:Rebuild("settings")
    end
end

local function InvalidateTooltips()
    ns.TooltipService:Invalidate()
end

-- ─────────────────────────────────────────────────────────────────
-- Row builders
-- ─────────────────────────────────────────────────────────────────

--- Locale label + tooltip from `labelKey` and `labelKey .. "_DESC"` (English fallbacks).
local function Text(row, labelKey, labelFb, descFb)
    row.label = LT(labelKey, labelFb)
    if descFb then
        row.desc = LT(labelKey .. "_DESC", descFb)
    end
    return row
end

local function Toggle(key, labelKey, labelFb, descFb, extra)
    local row = Text({ type = "toggle", key = key }, labelKey, labelFb, descFb)
    for k, v in pairs(extra or {}) do
        row[k] = v
    end
    return row
end

--- Toggle stored as `<path> = true` meaning hidden (checked = shown).
local function ShownToggle(path, labelKey, labelFb, descFb, apply)
    return Toggle(path, labelKey, labelFb, descFb, {
        get = function() return not Path(path) end,
        set = function(on) PathSet(path, not on) end,
        onChange = apply,
    })
end

local function Slider(key, labelKey, labelFb, descFb, opts)
    local row = Text({ type = "slider", key = key }, labelKey, labelFb, descFb)
    for k, v in pairs(opts) do
        row[k] = v
    end
    return row
end

--- Economy keys write through Economy:SetConfig (sends ECONOMY_CONFIG_CHANGED); no-op when unchanged.
local function EconGet(key)
    return ns.Economy:Config()[key]
end

local function EconSet(key, value)
    if EconGet(key) ~= value then
        ns.Economy:SetConfig(key, value)
    end
end

local function EconToggle(key, labelKey, labelFb, descFb)
    return Toggle("economy." .. key, labelKey, labelFb, descFb, {
        get = function() return EconGet(key) ~= false end,
        set = function(on) EconSet(key, on and true or false) end,
    })
end

--- Economy slider in stored units (fractions, days, factors).
local function EconSlider(key, labelKey, labelFb, descFb, opts)
    opts.get = function() return tonumber(EconGet(key)) or opts.min end
    opts.set = function(v) EconSet(key, v) end
    return Slider("economy." .. key, labelKey, labelFb, descFb, opts)
end

--- Economy copper value edited in gold.
local function EconGoldSlider(key, labelKey, labelFb, descFb, opts)
    opts.get = function() return (tonumber(EconGet(key)) or 0) / COPPER_PER_GOLD end
    opts.set = function(v) EconSet(key, floor(v * COPPER_PER_GOLD + 0.5)) end
    return Slider("economy." .. key, labelKey, labelFb, descFb, opts)
end

--- Posting keys: PostingHelperService config, then nudge the open posting panel.
local function PostingGet(key)
    return ns.PostingHelperService:GetConfig()[key]
end

local function PostingSet(key, value)
    if PostingGet(key) == value then
        return
    end
    ns.PostingHelperService:SetConfig({ [key] = value })
    ns.PostingHelperUI:Refresh()
end

local function PostingSlider(key, labelKey, labelFb, descFb, opts)
    opts.get = function() return tonumber(PostingGet(key)) or opts.min end
    opts.set = function(v) PostingSet(key, v) end
    return Slider("posting." .. key, labelKey, labelFb, descFb, opts)
end

local function WallsActive()
    return PostingGet("commodityMode") == "auto"
end

local function TooltipToggle(key, labelKey, labelFb, descFb)
    return Toggle("tooltip." .. key, labelKey, labelFb, descFb, {
        parent = key ~= "enabled" and "tooltip.enabled" or nil,
        onChange = InvalidateTooltips,
    })
end

local function LocaleOptions(list)
    return function()
        local out = {}
        for i = 1, #list do
            local o = list[i]
            out[i] = { value = o[1], text = LT(o[2], o[3]), desc = o[4] and LT(o[4], o[5]) or nil }
        end
        return out
    end
end

-- ─────────────────────────────────────────────────────────────────
-- Read-only lines
-- ─────────────────────────────────────────────────────────────────

--- Observed AH cut (only while Economy:CutRate() actually uses it).
local function ObservedCutHint()
    local rate, source = ns.Economy:CutRate()
    if source ~= "observed" or not rate then
        return ""
    end
    local _, samples = ns.SalesLedgerService:GetObservedCutRate()
    return string.format(LT("CONFIG_ECON_AH_CUT_OBSERVED_FMT", "Observed: %.1f%% (%d sales)"),
        rate * 100, tonumber(samples) or 0)
end

--- Effective concentration value: manual setting or the planner's shadow price.
local function ConcentrationHint()
    local value = ns.Economy:ConcentrationValue() or 0
    if value <= 0 then
        return LT("CONFIG_ECON_CONC_EFFECTIVE_NONE",
            "Effective: no estimate yet")
    end
    local manual = (tonumber(EconGet("concentrationValue")) or 0) > 0
    local source = manual and LT("CONFIG_ECON_SOURCE_MANUAL", "manual") or LT("CONFIG_ECON_SOURCE_PLANNER", "planner estimate")
    return string.format(LT("CONFIG_ECON_CONC_EFFECTIVE_FMT", "Effective: %s per point (%s)"),
        ns.FormatCopper(floor(value + 0.5)), source)
end

-- ─────────────────────────────────────────────────────────────────
-- Sections
-- ─────────────────────────────────────────────────────────────────

--- Appended to the WN General category (look, fonts, scale and keybinding are WN rows).
local GENERAL = {
    id = "general",
    groups = {
        { title = LT("SETTINGS_GROUP_MINIMAP_CHAT", "Minimap & chat"), columns = 2, rows = {
            ShownToggle("minimap.hide", "CONFIG_MINIMAP_BUTTON", "Minimap button", "Left-click opens the Artisan Hub.",
                function(on) ns.ArtisanNexus:SetMinimapButtonVisible(on) end),
            Toggle("showLoginChat", "CONFIG_SHOW_LOGIN_CHAT", "Login message",
                "Prints the version in chat on login."),
        } },
    },
}

local SLS = ns.SessionLootService
local RECENT_MIN, RECENT_MAX = SLS:GetSessionRecentHardLimits()
local OVERALL_MIN, OVERALL_MAX = SLS:GetSessionOverallHardLimits()

local function SessionLootChanged()
    Send(E.SESSION_LOOT_UPDATED)
end


local GATHERING_LOOT = {
    id = "loot",
    title = LT("SETTINGS_SECTION_GATHERING_LOOT", "Gathering & Loot"),
    desc = LT("SETTINGS_SECTION_GATHERING_LOOT_DESC", "Gathering, fishing, overload and session loot."),
    icon = "Interface\\Icons\\Trade_Herbalism",
    groups = {
        { title = LT("SETTINGS_SECTION_GATHERING", "Gathering"), rows = {
            --- Module toggles: one path (MODULE_TOGGLED -> Core:OnModuleToggled); unset counts as on.
            Toggle("modulesEnabled.gathering", "CONFIG_GATHERING_LOOT", "Gathering loot history",
                "Records herbs, ore, skins and disenchants.", {
                    get = function() return Path("modulesEnabled.gathering") ~= false end,
                    onChange = function(on) Send(E.MODULE_TOGGLED, "gathering", on) end,
                }),
            Toggle("modulesEnabled.fishing", "CONFIG_FISHING_MODULE", "Fishing module",
                "Records the fish you catch for Session loot.", {
                    get = function() return Path("modulesEnabled.fishing") ~= false end,
                    onChange = function(on) Send(E.MODULE_TOGGLED, "fishing", on) end,
                }),
            Toggle("fishingLootSoundEnabled", "CONFIG_FISHING_LOOT_SOUND", "Catch sound", nil, { parent = "modulesEnabled.fishing" }),
            Toggle("overloadNodeIndicatorEnabled", "CONFIG_OVERLOAD_NODE_INDICATOR", "Overload node indicator",
                "Marks hovered nodes that look overloaded.", {
                    onChange = function() Send(E.GATHERING_OVERLOAD_HINT_UPDATED, nil) end,
                }),
            Toggle("overloadTrackerHudEnabled", "CONFIG_OVERLOAD_TRACKER_HUD", "Overload Tracker",
                "Floating overload cooldown. Needs Herbalism or Mining.", {
                    parent = "overloadNodeIndicatorEnabled",
                    onChange = function() ns.GatheringOverloadIndicator:RefreshTracker() end,
                }),
            ShownToggle("overloadActionButton.hidden", "CONFIG_OVERLOAD_CAST_BUTTON", "Overload cast button",
                "Floating button that casts the next overload.",
                function(on)
                    if on then
                        ns.GatheringOverloadActionButton:Show()
                    else
                        ns.GatheringOverloadActionButton:Hide()
                    end
                end),
            Toggle("bagPressureGuardEnabled", "CONFIG_BAG_PRESSURE_GUARD", "Bag pressure guard",
                "Warn when free bag slots are low.", {
                    onChange = function(on)
                        if on then
                            ns.BagPressureGuard:Enable()
                        else
                            ns.BagPressureGuard:Disable()
                        end
                    end,
                }),
            Slider("bagPressureThreshold", "CONFIG_BAG_PRESSURE_THRESHOLD", "Free slot threshold",
                "Warn at or below this many free slots.", {
                min = 1, max = 40, step = 1, parent = "bagPressureGuardEnabled",
            }),
        } },
        { title = LT("SETTINGS_SECTION_LOOT", "Session loot"), rows = {
            Toggle("lootHistoryEnabled", "CONFIG_LOOT_HISTORY_ENABLED", "Session loot window",
                "Off: open it with |cff00ccff/an history|r.", {
                    onChange = function(on)
                        if not on then
                            ns.LootHistoryUI:Hide()
                        end
                    end,
                }),
            Toggle("lootHistoryAutoOpen", "CONFIG_LOOT_HISTORY_AUTO_OPEN", "Auto-open on loot",
                "Opens the matching tab when loot arrives.", { parent = "lootHistoryEnabled" }),
            Slider("sessionLootMaxRecent", "CONFIG_SESSION_LOOT_MAX_RECENT", "Recent pickups shown",
                "How many recent pickups each list shows.", {
                min = RECENT_MIN, max = RECENT_MAX, step = 1, applyOnRelease = true,
                get = function() return SLS:GetMaxRecentLoot() end,
                onChange = SessionLootChanged,
            }),
            Slider("sessionLootOverallCap", "CONFIG_SESSION_LOOT_OVERALL_CAP", "Overall history cap",
                "Most pickups kept in saved history.", {
                min = OVERALL_MIN, max = OVERALL_MAX, step = 50, applyOnRelease = true,
                get = function() return SLS:GetOverallEventsCap() end,
                onChange = SessionLootChanged,
            }),
        } },
        { title = LT("SETTINGS_GROUP_OVERLAY", "Loot overlay"), rows = {
            Toggle("sessionLootOverlayEnabled", "CONFIG_LOOT_OVERLAY", "Loot pickup overlay",
                "A short on-screen toast per pickup, with price.", {
                    get = function() return Profile().sessionLootOverlayEnabled == true end,
                    onChange = function(on)
                        if on then
                            ns.SessionLootOverlayUI:Open()
                        else
                            ns.SessionLootOverlayUI:Hide()
                        end
                        ns.LootHistoryUI:UpdateLootOverlayToggle()
                    end,
                }),
            { type = "button", parent = "sessionLootOverlayEnabled",
                text = function()
                    if ns.SessionLootOverlayUI:IsPositionEditing() then
                        return LT("CONFIG_LOOT_OVERLAY_POSITION_ACTIVE", "Done positioning")
                    end
                    return LT("CONFIG_LOOT_OVERLAY_POSITION", "Position overlay")
                end,
                desc = LT("CONFIG_LOOT_OVERLAY_POSITION_DESC", "Shows a sample toast you can drag."),
                onClick = function() ns.SessionLootOverlayUI:TogglePositionEdit() end,
            },
            Slider("sessionLootOverlayScale", "CONFIG_LOOT_OVERLAY_SIZE", "Overlay size", nil, {
                min = 0.75, max = 1.5, step = 0.05, format = FmtShare, parent = "sessionLootOverlayEnabled",
                onChange = function() ns.SessionLootOverlayUI:TriggerScalePreview() end,
            }),
            Slider("sessionLootOverlayHoldSec", "CONFIG_LOOT_OVERLAY_HOLD", "Toast duration", nil, {
                min = 2, max = 12, step = 1, format = FmtSeconds, parent = "sessionLootOverlayEnabled",
            }),
            Slider("sessionLootOverlayStackMax", "CONFIG_LOOT_OVERLAY_STACK", "Toasts on screen", nil, {
                min = 1, max = 6, step = 1, parent = "sessionLootOverlayEnabled",
            }),
        } },
        { title = LT("SETTINGS_GROUP_DATA", "Data"), rows = {
            { type = "button", variant = "danger",
                text = LT("CONFIG_RESET_ALL_SESSION", "Reset session loot"),
                desc = LT("CONFIG_RESET_ALL_SESSION_DESC", "Clears session loot on all tabs."),
                confirm = LT("CONFIG_RESET_ALL_SESSION_CONFIRM", "Clear session loot on every tab?"),
                onClick = function() SLS:ResetSession() end,
            },
            { type = "button", variant = "danger",
                text = LT("CONFIG_RESET_ALL_OVERALL", "Reset overall history"),
                desc = LT("CONFIG_RESET_ALL_OVERALL_DESC", "Deletes saved history on all tabs."),
                confirm = LT("CONFIG_RESET_ALL_OVERALL_CONFIRM",
                    "Delete saved loot history on every tab? This cannot be undone."),
                onClick = function() SLS:ResetAllOverallData() end,
            },
        } },
    },
}

local CRAFTING_ECONOMY = {
    id = "crafting",
    title = LT("SETTINGS_SECTION_CRAFTING_ECONOMY", "Crafting & Economy"),
    desc = LT("SETTINGS_SECTION_CRAFTING_ECONOMY_DESC", "Professions, valuation, briefing and reminders."),
    icon = "Interface\\Icons\\Trade_BlackSmithing",
    groups = {
        { title = LT("SETTINGS_SECTION_PROFESSIONS", "Professions"), rows = {
            ShownToggle("professionSidecar.hidden", "CONFIG_PROFESSION_SIDECAR", "Profession sidecar",
                "Summary panel beside the profession window.",
                function() ns.ProfessionSidecarUI:Refresh() end),
            ShownToggle("craftQueueActionButton.hidden", "CONFIG_CRAFT_QUEUE_CAST_BTN", "Floating craft button",
                "Floating button that crafts the next queued recipe.",
                function(on)
                    if on then
                        ns.CraftQueueActionButton:Show()
                    else
                        ns.CraftQueueActionButton:Hide()
                    end
                end),
            Toggle("includeWarbandBank", "CONFIG_WARBAND_BANK", "Count Warband bank",
                "Counts Warband bank reagents as owned.", {
                    onChange = function()
                        --- The bag cache was built with the old warband-bank setting.
                        ns.RecipeService:InvalidateBagCache()
                        NotifyShopping()
                    end,
                }),
            Toggle("shoppingIncludeFinishing", "CONFIG_SHOPPING_FINISHING", "Shopping: finishing reagents",
                "Adds optional finishing reagents to the list.",
                { onChange = NotifyShopping }),
            Toggle("shoppingSubtractAlts", "CONFIG_SHOPPING_SUBTRACT_ALTS", "Shopping: subtract alt stock",
                "Alts' reagents (Warband Nexus) reduce what to buy.",
                { onChange = NotifyShopping }),
        } },
        { title = LT("SETTINGS_SECTION_ECONOMY", "Valuation"), rows = {
            EconToggle("ownedReagentsAtSellValue", "CONFIG_ECON_OWNED_AT_SELL", "Owned reagents: sell value",
                "Values reagents you own at their net sale price."),
            EconToggle("makeVsBuy", "CONFIG_ECON_MAKE_VS_BUY", "Make vs buy",
                "Uses craft cost when cheaper than buying."),
            EconGoldSlider("concentrationValue", "CONFIG_ECON_CONC_VALUE", "Concentration value",
                "Gold per point. Auto uses the planner's estimate.", {
                min = 0, max = 50, step = 0.5, hint = ConcentrationHint,
                format = function(v) return FmtGold(v, LT("CONFIG_ECON_VALUE_AUTO", "Auto")) end,
            }),
            EconSlider("plannerHorizonDays", "CONFIG_ECON_PLANNER_HORIZON", "Planner horizon",
                "Days of regeneration the planner spends.", {
                min = 1, max = 7, step = 1, format = FmtDays,
            }),
            EconGoldSlider("knowledgePointValue", "CONFIG_ECON_KP_VALUE", "Knowledge point value",
                "Gold per Knowledge point in order rewards.", {
                min = 0, max = 2000, step = 10, format = FmtGoldOff,
            }),
            EconGoldSlider("moxieValue", "CONFIG_ECON_MOXIE_VALUE", "Moxie value",
                "Gold per Moxie in order rewards.", {
                min = 0, max = 500, step = 5, format = FmtGoldOff,
            }),
        } },
        { title = LT("SETTINGS_SECTION_CRAFT_BRIEFING", "Craft briefing"), rows = {
            Toggle("craftBriefingEnabled", "CONFIG_CRAFT_BRIEFING", "Craft briefing",
                "Ranks profitable crafts after each AH sync.", { onChange = RebuildBriefing }),
            Toggle("craftBriefingChatNotify", "CONFIG_CRAFT_BRIEFING_CHAT", "Chat summary",
                "Lists the top crafts in chat.", { parent = "craftBriefingEnabled" }),
            Toggle("craftBriefingOwnedOnly", "CONFIG_CRAFT_BRIEFING_OWNED", "My professions only",
                "Skips professions this character lacks.",
                { parent = "craftBriefingEnabled", onChange = RebuildBriefing }),
            Toggle("craftBriefingConcentrationHints", "CONFIG_CRAFT_BRIEFING_CONC", "Concentration hints",
                "Shows the extra profit from concentration.",
                { parent = "craftBriefingEnabled", onChange = RebuildBriefing }),
            Toggle("craftBriefingEquipmentHints", "CONFIG_CRAFT_BRIEFING_EQUIP", "Profession gear hints",
                "Warn about empty tool slots or better gear in bags.",
                { parent = "craftBriefingEnabled", onChange = RebuildBriefing }),
            Slider("craftBriefingTopN", "CONFIG_CRAFT_BRIEFING_TOP_N", "Briefing list size", nil, {
                min = 3, max = 15, step = 1, applyOnRelease = true, parent = "craftBriefingEnabled",
                onChange = RebuildBriefing,
            }),
            Text({ type = "radio", key = "craftBriefingPriceMode", parent = "craftBriefingEnabled",
                values = LocaleOptions({
                    { "spot", "CONFIG_CRAFT_BRIEFING_PRICE_SPOT", "Latest AH buyout" },
                    { "avg", "CONFIG_CRAFT_BRIEFING_PRICE_AVG", "Rolling average",
                        "CONFIG_CRAFT_BRIEFING_PRICE_AVG_DESC", "7-day average once enough history exists." },
                }),
                get = function() return Profile().craftBriefingPriceMode == "avg" and "avg" or "spot" end,
                onChange = RebuildBriefing,
            }, "CONFIG_CRAFT_BRIEFING_PRICE_LABEL", "Briefing prices"),
            Toggle("craftBriefingProactiveAlert", "CONFIG_CRAFT_BRIEFING_ALERT", "Craft alert",
                "On-screen notice when the top craft beats the threshold.", { parent = "craftBriefingEnabled" }),
            Slider("craftBriefingAlertMinProfit", "CONFIG_CRAFT_BRIEFING_ALERT_MIN", "Alert threshold", nil, {
                min = 0, max = 100, step = 1, format = FmtGold, parent = "craftBriefingProactiveAlert",
                get = function() return (tonumber(Profile().craftBriefingAlertMinProfit) or 0) / COPPER_PER_GOLD end,
                set = function(v) Profile().craftBriefingAlertMinProfit = floor(v * COPPER_PER_GOLD + 0.5) end,
            }),
        } },
        { title = LT("CONFIG_ECON_ALERTS", "Daily reminders"), columns = 2, rows = {
            Toggle("concentrationOverflowAlert", "CONFIG_CONC_OVERFLOW_ALERT", "Concentration cap warning",
                "Daily chat note when a pool is full or nearly full."),
            Toggle("cooldownReadyReminder", "CONFIG_COOLDOWN_READY_REMINDER", "Cooldown reminder",
                "Daily chat note listing ready profession cooldowns."),
        } },
    },
}

--- TSM custom price source names from TSM's price-source documentation (read 2026-10-14).
local TSM_SOURCES = {
    { "dbmarket", "CONFIG_TSM_SOURCE_DBMARKET", "Market value (DBMarket)" },
    { "dbminbuyout", "CONFIG_TSM_SOURCE_DBMINBUYOUT", "Min buyout (DBMinBuyout)" },
    { "dbrecent", "CONFIG_TSM_SOURCE_DBRECENT", "Latest scan (DBRecent)" },
    { "dbhistorical", "CONFIG_TSM_SOURCE_DBHISTORICAL", "60-day history (DBHistorical)" },
    { "dbregionmarketavg", "CONFIG_TSM_SOURCE_DBREGIONMARKETAVG", "Region market avg (DBRegionMarketAvg)" },
    { "dbregionsaleavg", "CONFIG_TSM_SOURCE_DBREGIONSALEAVG", "Region sale avg (DBRegionSaleAvg)" },
}

local AUCTION_HOUSE = {
    id = "auction",
    title = LT("SETTINGS_SECTION_AUCTION_HOUSE", "Auction House"),
    desc = LT("SETTINGS_SECTION_AUCTION_HOUSE_DESC", "Price data, posting and item tooltips."),
    icon = "Interface\\Icons\\INV_Misc_Coin_02",
    groups = {
        { title = LT("SETTINGS_GROUP_PRICES", "Price data"), rows = {
            Text({ type = "dropdown", key = "priceSourceProvider",
                values = LocaleOptions({
                    { "auto", "CONFIG_PRICE_SOURCE_AUTO", "Auto (AN -> Auctionator -> TSM)" },
                    { "an", "CONFIG_PRICE_SOURCE_AN", "Artisan Nexus only" },
                    { "tsm", "CONFIG_PRICE_SOURCE_TSM", "TradeSkillMaster (TSM)" },
                    { "auctionator", "CONFIG_PRICE_SOURCE_AUCTIONATOR", "Auctionator" },
                }),
                --- Prices re-resolve on ECONOMY_CONFIG_CHANGED (tooltips, market intel, planner, open Hub page).
                onChange = function()
                    Send(E.ECONOMY_CONFIG_CHANGED, "priceSourceProvider")
                    NotifyShopping()
                end,
            }, "CONFIG_PRICE_SOURCE_PROVIDER", "Price data provider",
                "Prices used for profit, shopping and tooltips."),
            Text({ type = "dropdown", key = "tsmPriceSource", values = LocaleOptions(TSM_SOURCES),
                enabled = function()
                    local p = Profile().priceSourceProvider
                    return p == "auto" or p == "tsm"
                end,
                onChange = function() Send(E.ECONOMY_CONFIG_CHANGED, "tsmPriceSource") end,
            }, "CONFIG_TSM_SOURCE", "TSM price source",
                "TSM price read by the TSM and Auto providers."),
            Slider("ahFreshTTL", "CONFIG_AH_FRESHNESS_HOURS", "AH price freshness",
                "Prices older than this are refreshed on sync.", {
                min = 1, max = 72, step = 1, format = FmtHours,
                get = function() return (tonumber(Profile().ahFreshTTL) or 0) / 3600 end,
                set = function(v) Profile().ahFreshTTL = v * 3600 end,
            }),
            EconSlider("dealRatio", "CONFIG_ECON_DEAL_RATIO", "Deal threshold",
                "Listings at or below this share of the 7-day average.", {
                min = 0.3, max = 0.95, step = 0.05, format = FmtShare,
            }),
        } },
        { title = LT("SETTINGS_SECTION_POSTING", "Auction posting"), rows = {
            --- Post duration index (1/2/3) as used by C_AuctionHouse post calls and Economy:EstimateDeposit.
            Text({ type = "dropdown", key = "economy.postDuration",
                values = LocaleOptions({
                    { 1, "CONFIG_ECON_DURATION_12H", "12 hours" },
                    { 2, "CONFIG_ECON_DURATION_24H", "24 hours" },
                    { 3, "CONFIG_ECON_DURATION_48H", "48 hours" },
                }),
                get = function() return tonumber(EconGet("postDuration")) or 2 end,
                set = function(v) EconSet("postDuration", v) end,
            }, "CONFIG_ECON_POST_DURATION", "Default post duration",
                "Used for deposit estimates outside the AH."),
            EconSlider("sellThroughRate", "CONFIG_ECON_SELL_THROUGH", "Sell-through rate",
                "Share of auctions you expect to sell.", {
                min = 0.1, max = 1, step = 0.05, format = FmtShare,
            }),
            EconSlider("ahCutRate", "CONFIG_ECON_AH_CUT", "Auction house cut",
                "Your observed cut is used after 5 sales.", {
                min = 0, max = 0.15, step = 0.005, format = FmtRate, hint = ObservedCutHint,
            }),
            Text({ type = "dropdown", key = "posting.commodityMode",
                values = LocaleOptions({
                    { "auto", "CONFIG_POSTING_COMMODITY_AUTO", "Auto (match deep walls)" },
                    { "match", "CONFIG_POSTING_COMMODITY_MATCH", "Always match" },
                    { "undercut", "CONFIG_POSTING_COMMODITY_UNDERCUT", "Always undercut" },
                }),
                get = function() return PostingGet("commodityMode") or "auto" end,
                set = function(v) PostingSet("commodityMode", v) end,
            }, "CONFIG_POSTING_COMMODITY_MODE", "Commodity pricing",
                "Auto matches deep walls and undercuts otherwise."),
            PostingSlider("wallShare", "CONFIG_POSTING_WALL_SHARE", "Wall: listing share",
                "Lowest price is a wall above this share of listings.", {
                min = 0.1, max = 0.9, step = 0.05, format = FmtShare, enabled = WallsActive,
            }),
            PostingSlider("wallDurations", "CONFIG_POSTING_WALL_DURATIONS", "Wall: time to sell",
                "A wall takes more post durations than this to sell.", {
                min = 0.25, max = 4, step = 0.25, format = FmtMul, enabled = WallsActive,
            }),
            PostingSlider("floorMul", "CONFIG_POSTING_FLOOR_MUL", "Price floor",
                "Minimum price as a multiple of the 7-day average.", {
                min = 0, max = 1.5, step = 0.05, format = FmtMul,
            }),
            PostingSlider("averageMul", "CONFIG_POSTING_AVERAGE_MUL", "Average multiplier",
                "Average and Max price at the 7-day average times this.", {
                min = 0.5, max = 1.5, step = 0.05, format = FmtMul,
            }),
        } },
        { title = LT("SETTINGS_SECTION_TOOLTIP", "Item tooltip"), columns = 2, rows = {
            TooltipToggle("enabled", "CONFIG_TOOLTIP_ENABLED", "Item tooltip lines",
                "Shows prices, stock and craft numbers on item tooltips."),
            TooltipToggle("compactMode", "CONFIG_TOOLTIP_COMPACT", "Compact tooltip",
                "One summary line; hold Shift for details."),
            TooltipToggle("hideInCombat", "CONFIG_TOOLTIP_HIDE_COMBAT", "Hide in combat"),
            { type = "header", label = LT("CONFIG_TOOLTIP_LINES", "Detail lines") },
            TooltipToggle("showAhMin", "CONFIG_TOOLTIP_SHOW_AH_MIN", "AH minimum price"),
            TooltipToggle("showAvg7d", "CONFIG_TOOLTIP_SHOW_AVG7D", "7-day average"),
            TooltipToggle("showListedQty", "CONFIG_TOOLTIP_SHOW_LISTED_QTY", "Listed quantity",
                "Units on the auction house at the last scan."),
            TooltipToggle("showNetAfterCut", "CONFIG_TOOLTIP_SHOW_NET_AFTER_CUT", "Net after AH cut",
                "What a sale pays after the AH cut."),
            TooltipToggle("showVendorSell", "CONFIG_TOOLTIP_SHOW_VENDOR_SELL", "Vendor sell price"),
            TooltipToggle("showVendorBuy", "CONFIG_TOOLTIP_SHOW_VENDOR_BUY", "Vendor buy price",
                "For items seen at a merchant."),
            TooltipToggle("showStock", "CONFIG_TOOLTIP_SHOW_STOCK", "Your stock",
                "In bags and in total, banks included."),
            TooltipToggle("showAltStock", "CONFIG_TOOLTIP_SHOW_ALT_STOCK", "Alt stock",
                "Held by your alts (needs Warband Nexus)."),
            TooltipToggle("showAvgBuyCost", "CONFIG_TOOLTIP_SHOW_AVG_BUY_COST", "Average purchase cost",
                "Your average price paid on the AH."),
            TooltipToggle("showCraft", "CONFIG_TOOLTIP_SHOW_CRAFT", "Craft cost and profit",
                "Cost, profit and gold per concentration."),
        } },
    },
}

local ADVANCED = {
    id = "advanced",
    title = LT("SETTINGS_SECTION_ADVANCED", "Advanced"),
    desc = LT("SETTINGS_SECTION_ADVANCED_DESC", "Proc fallbacks and debug output."),
    icon = "Interface\\Icons\\INV_Misc_Enggizmos_19",
    groups = {
        { title = LT("CONFIG_ECON_ADVANCED", "Proc factors"), rows = {
            { type = "note", text = LT("CONFIG_ECON_CALIBRATION_NOTE", "Observed values replace these after enough crafts.") },
            EconSlider("multicraftExtraFactor", "CONFIG_ECON_MULTICRAFT", "Multicraft extra yield",
                "Extra output per Multicraft proc.", {
                min = 0, max = 2, step = 0.05, format = FmtShare,
            }),
            EconSlider("resourcefulnessSaveFactor", "CONFIG_ECON_RESOURCEFULNESS", "Resourcefulness reagent saving",
                "Share of reagents returned per Resourcefulness proc.", {
                min = 0, max = 1, step = 0.05, format = FmtShare,
            }),
            EconSlider("ingenuityRefundFactor", "CONFIG_ECON_INGENUITY", "Ingenuity concentration refund",
                "Share of concentration refunded per Ingenuity proc.", {
                min = 0, max = 1, step = 0.05, format = FmtShare,
            }),
        } },
    },
}

ns.SettingsSchema = { GENERAL, GATHERING_LOOT, CRAFTING_ECONOMY, AUCTION_HOUSE, ADVANCED }
ns.SettingsSchemaPath = { Get = Path, Set = PathSet }
