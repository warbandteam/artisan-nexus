--[[
    Artisan Nexus — AceAddon bootstrap (Midnight 12.1.5).
    Data → Service → View: services use SendMessage; UI subscribes (see README "Developer guide").
]]

local ADDON_NAME, ns = ...

---@class ArtisanNexus : AceAddon, AceEvent-3.0, AceConsole-3.0, AceTimer-3.0, AceBucket-3.0
local ArtisanNexus = LibStub("AceAddon-3.0"):NewAddon(
    ADDON_NAME,
    "AceEvent-3.0",
    "AceConsole-3.0",
    "AceTimer-3.0",
    "AceBucket-3.0"
)

ns.ArtisanNexus = ArtisanNexus

local L = LibStub("AceLocale-3.0"):GetLocale("ArtisanNexus")
--- Warband Nexus UI framework convention (Modules/UI/*): `ns.L[key]` is nil for a missing key and
--- the caller supplies the English fallback. AceLocale's read metatable returns the key itself
--- (plus a warning) instead, so drop it once every locale file has loaded.
setmetatable(L, nil)
ns.L = L

local E = ns.Constants.EVENTS

local defaults = {
    profile = {
        --- One line in chat on load so the addon is discoverable without a window yet.
        showLoginChat = true,
        -- Warband Nexus UI framework settings (keys, shapes and defaults as in warband-nexus Core.lua).
        -- Display settings
        scrollSpeed = 1.0,         -- Scroll speed multiplier (1.0 = default 28px per step)
        uiScale = 1.0,            -- Global UI scale for the entire addon window (0.6 - 1.5)
        --- "standard" | "compact" --- tighter resize mins + modest default footprints (`API_*` geometry wrappers).
        mainWindowDensity = "standard",
        --- Main window nav: vertical "rail" icon column (left) | horizontal "top" strip (Settings; /reload).
        mainNavLayout = "rail",
        --- Settings tab: in-content category (`SettingsUI_Shell`); not a main-window tab id.
        settingsPanel = "general",
        -- Theme Colors (RGB 0-1 format) - All calculated from master color
        themeColors = {
            accent = {0.40, 0.20, 0.58},      -- Master theme color (purple)
            accentDark = {0.28, 0.14, 0.41},  -- Darker variation (0.7x)
            border = {0.20, 0.20, 0.25},      -- Desaturated border
            tabActive = {0.20, 0.12, 0.30},   -- Active tab background (0.5x)
            tabHover = {0.24, 0.14, 0.35},    -- Hover tab background (0.6x)
        },
        -- When true, UI accent (and derived tab/border tones) follows the logged-in character's class color; falls back to themeColors.accent if class is unavailable.
        useClassColorAccent = false,
        uiTheme = "modern",  -- "modern" | "classic" — UI chrome family (Settings > Theme)
        themeMode = "dark",  -- "dark" | "light" — Modern surface palette only
        modernColorMode = "dark",  -- last Modern dark/light choice (restored when leaving Classic)
        shellBackgroundOpacity = 1.0,  -- Main window shell fill alpha (0.2-1.0; Settings > Theme)
        -- Keybinding (override binding, saved in addon DB)
        toggleKeybind = nil,  -- e.g. "CTRL-SHIFT-N" or nil = unbound
        -- Font Management (Resolution-aware scaling)
        fonts = {
            fontFace = "Expressway",  -- LSM key; bundled default font
            scalePreset = "normal",            -- Preset: tiny/small/normal/large/xlarge
            scaleCustom = 1.0,                 -- Custom scale multiplier
            useCustomScale = false,            -- Use custom scale instead of preset
            antiAliasing = "OUTLINE",          -- AA flags: none/OUTLINE/THICKOUTLINE
            usePixelNormalization = true,      -- Enable resolution-aware scaling
            baseSizes = {
                header = 16,    -- Section headers, tab labels
                title = 14,     -- Card titles, character names
                subtitle = 12,  -- Type badges, progress labels
                body = 12,      -- Description text, source info
                small = 10,     -- Requirements, tooltips, fine print
            },
        },
        debugVerbose = false,      -- When true, show cache/scan/tooltip logs; when false, only critical debug
        -- Profiler (dev/perf): persisted so /reload keeps measurement + optional dev HUD.
        -- Defaults keep everything off for production installs.
        profilerPersist = {
            measuring = false,
            liveOutput = false,
            frameTracking = false,
            devMode = false,
            tabPerfMonitor = false, -- /wn profiler tabperf on — main-tab switch ms lines (not debugVerbose)
            traceVerbose = false,   -- /wn profiler verbose on — phase splits (GearOpen, profiler START/STOP)
            devWindowVisible = false,
            point = "CENTER",
            relPoint = "CENTER",
            x = 0,
            y = 0,
            width = 400,
            height = 260,
            docked = false,
        },
        debugMode = false,
        modulesEnabled = {
            fishing = true,
            gathering = true,
        },
        --- Short UI sound when a catalog fish line is recorded (off by default).
        fishingLootSoundEnabled = false,
        --- Loot history window size + anchor (nil = theme defaults / first open centered).
        lootHistoryFrame = {
            width = nil,
            height = nil,
            point = nil,
            relativePoint = nil,
            relativeTo = nil,
            x = nil,
            y = nil,
        },
        --- Session loot window + loot-driven UI (catalog, auto-open). /an history still opens it when off.
        lootHistoryEnabled = true,
        --- Open Session loot window when fishing or gathering records a pickup (per-tab); requires lootHistoryEnabled.
        lootHistoryAutoOpen = false,
        --- Last Session loot tab (fishing / herb / mine / …); restored on reload + auto-open.
        lootHistoryActiveTab = nil,
        --- Recipes (matcher) window anchor (nil = first open centered; else last-left position).
        recipeMatcherFrame = {
            point = nil,
            relativePoint = nil,
            relativeTo = nil,
            x = nil,
            y = nil,
        },
        --- When true, the Hub Crafting page lists only recipes craftable from current session loot (not bags).
        hubSessionOnly = false,
        --- Artisan Hub profession filter ("All" or Midnight craft profession name from catalog).
        hubProfessionFilter = "All",
        --- Hub Crafting page sort: "margin" or "concentration" (gold per concentration point).
        hubProfitSort = "margin",
        --- Hub Crafting page: list recipes known by "me" (current character) or "any" tracked character.
        hubKnownBy = "any",
        --- Crafting page price basis: "spot" (current AH) or "avg" (7-day average) for outputs and reagents.
        hubPriceBasis = "spot",
        --- Ledger tab period in days (7 or 30).
        hubLedgerDays = 7,
        --- When true, Shopping list also counts Finishing slots (e.g. Cooking "Secret Ingredient" / Bazaar Bites).
        shoppingIncludeFinishing = false,
        --- When true, alt stock (ns.CharacterData: Warband Nexus or AN snapshot) is subtracted from Shopping "short" (it still has to be mailed over).
        shoppingSubtractAlts = false,
        --- When true, RecipeService:ScanBags includes warband bank tabs (AccountBankTab_1..5).
        includeWarbandBank = true,
        --- Floating secure button: craft next queued recipe (requires profession window).
        craftQueueActionButton = {
            hidden = false,
            point = "CENTER",
            relativePoint = "CENTER",
            x = 120,
            y = -120,
        },
        --- Anchor profession sidecar beside the trade skill window.
        professionSidecar = {
            hidden = false,
        },
        --- Session loot: “Last N pickups” rows (clamped in SessionLootService when read).
        sessionLootMaxRecent = 15,
        --- Cap for persisted overall fishing/gathering event lists in SavedVariables.
        sessionLootOverallCap = 200,
        --- World indicator when hovering overloaded herb/ore nodes.
        overloadNodeIndicatorEnabled = true,
        --- Floating herb/mining overload CD tracker (requires Herbalism and/or Mining).
        overloadTrackerHudEnabled = true,
        --- Movable overload tracker frame anchor.
        overloadTrackerFrame = {
            point = "BOTTOMRIGHT",
            relativePoint = "BOTTOMRIGHT",
            x = -24,
            y = 120,
        },
        --- Floating session loot overlay (recent pickups + prices); independent of Session loot window visibility.
        sessionLootOverlayEnabled = true,
        sessionLootOverlayHoldSec = 4,
        sessionLootOverlayStackMax = 3,
        sessionLootOverlayScale = 1.15,
        sessionLootOverlayFrame = {
            point = "TOPRIGHT",
            relativePoint = "TOPRIGHT",
            x = -24,
            y = -120,
        },
        --- Warn when bag free slots are low while gathering.
        bagPressureGuardEnabled = true,
        bagPressureThreshold = 8,
        
        --- LibDBIcon: hide, minimapPos (angle) persisted by the library inside this table.
        minimap = {
            hide = false,
        },
        --- AH cache freshness window (seconds). Used by AH scans / profitability staleness.
        ahFreshTTL = 60 * 60 * 6,
        --- Market price data provider: "auto" (AN -> Auctionator -> TSM), "an" (Artisan Nexus only), "tsm" (TSM dbmarket prioritized), "auctionator" (Auctionator prioritized).
        priceSourceProvider = "auto",
        --- TSM price source read when TSM supplies prices (Settings > Auction House).
        tsmPriceSource = "dbmarket",
        --- Post-AH-scan craft briefing (owned professions, harvested recipes).
        craftBriefingEnabled = true,
        craftBriefingChatNotify = true,
        craftBriefingOwnedOnly = true,
        craftBriefingTopN = 5,
        --- "spot" (latest AH) or "avg" (7-day rolling average when available).
        craftBriefingPriceMode = "spot",
        --- Proactive chat alert when top craft profit crosses threshold after AH sync.
        craftBriefingProactiveAlert = true,
        --- Minimum profit (copper) for proactive top-craft alert (default 1g).
        craftBriefingAlertMinProfit = 10000,
        --- Include concentration ROI hints when profession window is open.
        craftBriefingConcentrationHints = true,
        --- Show profession equipment advisor hints in briefing.
        craftBriefingEquipmentHints = true,
        --- PostingHelperService strategy knobs (see PostingHelperService.lua).
        --- Economy engine tunables (Modules/Economy/EconomyCore.lua). Fee figures are fallbacks only:
        --- live values come from C_AuctionHouse.Calculate*Deposit and mail invoice consignment.
        economy = {
            --- AH house cut on sale; replaced by the ledger-observed rate once invoices exist.
            ahCutRate = 0.05,
            --- Post duration index for deposit estimates: 1 = 12h, 2 = 24h, 3 = 48h.
            postDuration = 2,
            --- Share of postings expected to sell before expiry (deposit amortization).
            sellThroughRate = 0.7,
            --- Average extra output per multicraft proc as a fraction of base yield (calibrated from crafts).
            multicraftExtraFactor = 0.5,
            --- Average reagent share returned per resourcefulness proc (calibrated from crafts).
            resourcefulnessSaveFactor = 0.3,
            --- Average concentration share refunded per ingenuity proc (calibrated from crafts).
            ingenuityRefundFactor = 0.5,
            --- Copper value of one concentration point; 0 = derive from the best plan (shadow price).
            concentrationValue = 0,
            --- Copper value assigned to one Knowledge point / one Moxie (patron order rewards).
            knowledgePointValue = 0,
            moxieValue = 0,
            --- Value self-gathered / owned reagents at net sell value instead of purchase price.
            ownedReagentsAtSellValue = true,
            --- Use intermediate crafted reagents' craft cost when cheaper than buying (make vs buy).
            makeVsBuy = true,
            --- Concentration planner horizon (days of regen + current pool to allocate).
            plannerHorizonDays = 2,
            --- Market deals: current min at or below this share of the 7-day mean.
            dealRatio = 0.7,
        },
        --- One chat line per day when a tracked concentration pool is capped or caps within 12h.
        concentrationOverflowAlert = true,
        --- One chat line per day listing profession cooldowns that are ready.
        cooldownReadyReminder = true,
        posting = {
            --- "undercut" | "average" | "max" (cycled from the posting helper panel).
            strategy = "undercut",
            averageMul = 1.0,
            floorMul = 0.5,
            --- Commodities: "auto" (match a deep wall, else undercut one step), "match", "undercut".
            commodityMode = "auto",
            --- Wall is "deep" when it holds this share of the visible book (no demand data)...
            wallShare = 0.3,
            --- ...or covers this many post durations of estimated demand.
            wallDurations = 1.0,
        },
        --- Item tooltip lines (Modules/Economy/TooltipService.lua). Shift shows the detailed block.
        tooltip = {
            enabled = true,
            compactMode = true,
            hideInCombat = false,
            showAhMin = true,
            showAvg7d = true,
            showListedQty = true,
            showVendorSell = true,
            showVendorBuy = true,
            showNetAfterCut = true,
            showStock = true,
            showAltStock = true,
            showAvgBuyCost = true,
            showCraft = true,
        },
        --- Overload secure action button visibility + anchor (GatheringOverloadActionButton.lua).
        overloadActionButton = {
            hidden = false,
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = -160,
        },
    },
    global = {
        -- NOTE: _schemaVersion / addonVersion are intentionally NOT in defaults:
        -- AceDB strips stored values equal to defaults at logout, which would make
        -- the version stamps unreadable. MigrationService stamps them explicitly.
        --- Aggregated fishing loot: [itemID] = { count = number, lastAt = unix, name = string|nil }
        fishingLootHistory = {},
        --- Herb / ore / skinning (gathering) loot totals
        gatheringLootHistory = {},
        --- Overall pickup event log (capped, never reset on login). fishing: { itemID, qty, t }
        overallFishingEvents = {},
        --- Overall pickup event log for gathering: { itemID, qty, t, cat }
        overallGatheringEvents = {},
        --- Craft output session (overall mode): { itemID, qty, t, spellID?, profession? }
        overallCraftedEvents = {},
        --- Craft output lifetime totals: [itemID] = { count, lastAt, name? }
        craftedLootHistory = {},
        --- AH unit prices (copper), written by AHPriceService.SavePrice:
        --- [itemID] = { buyout, updatedAt, qty?, book? = { {p, q}, ... } cheapest-first levels,
        ---   qsrc? = "c" commodity book | "b" browse summary | "i" one item listing,
        ---   byIlvl? = { [itemLevel] = copper } for equipment }
        ahPrices = {},
        --- RecipeService harvested schematics from C_TradeSkillUI.
        --- [spellID] = { name, profession, reagents = { {itemID, qty, slotType}, ... }, updated }
        recipeSchematics = {},
        --- CraftBriefingService last top-N profitable crafts after AH scan.
        craftBriefing = {},

        -- Keys below default to empty containers; services populate at runtime.
        ahPriceHistory = {},
        craftQueue = { entries = {} },
        shoppingList = { entries = {} },
        --- [guid] = { name, realm, class, lastSeen } — GUID-keyed character registry
        --- (GUID survives renames/realm transfers; display names resolved from here).
        charRegistry = {},
        --- AN-native concentration snapshots (written only while Warband Nexus does not cover them):
        --- [guid][baseSkillLineID] = { catalogKey, childSkillLineID, concCurrent, concMax, concCycleMS, concPerCycle, concAt, at, ... }
        professionSnapshots = {},
    },
    char = {
        professionEquipmentHints = {},
    },
}

--- Single source of SavedVariables defaults; services read fallbacks from here instead of re-declaring.
ns.DEFAULTS = defaults

function ArtisanNexus:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("ArtisanNexusDB", defaults, true)
    ns.db = self.db

    self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileReset", "OnProfileChanged")

    --- Migrations transform in place and never reset (MigrationService:RunMigrations).
    ns.MigrationService:CheckAddonVersion(self.db, self)
    ns.MigrationService:RunMigrations(self.db)

    self:RegisterChatCommand("an", "SlashCommand")
    self:RegisterChatCommand("artisan", "SlashCommand")

    if ns.Config and ns.Config.RegisterOptions then
        ns.Config.RegisterOptions(self)
    end

    self:InitializeMinimapButton()

    -- Create hidden button for keybind toggle (override binding target)  [WN Core.lua]
    if not _G["ArtisanNexusToggleButton"] then
        local btn = CreateFrame("Button", "ArtisanNexusToggleButton", UIParent)
        btn:Hide()
        btn:SetScript("OnClick", function()
            if ArtisanNexus and ArtisanNexus.ToggleMainWindow then
                ArtisanNexus:ToggleMainWindow()
            end
        end)
    end

    -- Apply saved keybind (override binding)
    self:ApplyToggleKeybind()
    -- WN Core.lua OnCombatEnd: keybind apply requested during combat was deferred (protected calls).
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        if self._pendingToggleKeybindApply and self.ApplyToggleKeybind then
            self:ApplyToggleKeybind()
        end
    end)

    self:RegisterMessage(E.FISHING_CHANNEL_STARTED, "OnMessageFishingChannelStarted")
    self:RegisterMessage(E.FISHING_CHANNEL_STOPPED, "OnMessageFishingChannelStopped")
    self:RegisterMessage(E.LOADING_COMPLETE, "OnMessageLoadingComplete")
    if E.MODULE_TOGGLED then
        self:RegisterMessage(E.MODULE_TOGGLED, "OnModuleToggled")
    end
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnPlayerEnteringWorld")

    if ns.LootHistoryUI and ns.LootHistoryUI.Init then
        ns.LootHistoryUI:Init()
    end
    if ns.SessionLootOverlayUI and ns.SessionLootOverlayUI.Init then
        ns.SessionLootOverlayUI:Init()
    end
    if ns.GatheringOverloadIndicator and ns.GatheringOverloadIndicator.Init then
        ns.GatheringOverloadIndicator:Init()
    end
    if ns.GatheringOverloadActionButton and ns.GatheringOverloadActionButton.Init then
        ns.GatheringOverloadActionButton:Init()
    end

    if ns.UI_RefreshColors then
        ns.UI_RefreshColors()
    end
end

--- Warband Nexus Core.lua RefreshTheme (verbatim body, frame global renamed), plus AN's THEME_CHANGED
--- message for the standalone windows that repaint their own chrome.
function ArtisanNexus:RefreshTheme()
    local wasClassic = ns._wnThemeWasClassic
    local isClassic = ns.UI_IsClassicMode and ns.UI_IsClassicMode()
    local chromeKindChanged = (wasClassic ~= isClassic)
    ns._wnThemeWasClassic = isClassic

    local mf = _G.ArtisanNexusFrame
    if chromeKindChanged and mf then
        if mf._wnRebuildCloseButton then
            mf._wnRebuildCloseButton()
        end
        if mf._wnRebuildNavButtons then
            mf._wnRebuildNavButtons()
        end
        if ns.UI_RefreshMainShellChrome then
            ns.UI_RefreshMainShellChrome(mf)
        end
    end

    -- Refresh colors (handled by SharedWidgets.RefreshColors)
    if ns.UI_RefreshColors then
        ns.UI_RefreshColors()
    end

    -- Full content rebuild when widget class changes (Blizzard vs custom nav/cards).
    if mf and mf:IsShown() and ArtisanNexus.PopulateContent then
        if chromeKindChanged or (mf.currentTab == "settings") then
            ArtisanNexus:PopulateContent(true)
        end
    end

    if E and E.THEME_CHANGED then
        self:SendMessage(E.THEME_CHANGED)
    end
end

--- Warband Nexus Core.lua ApplyToggleKeybind (verbatim; toggle button global renamed).
---Apply (or clear) the toggle keybind from db.profile.toggleKeybind using override binding.
---Safe to call multiple times; clears previous binding first.
function ArtisanNexus:ApplyToggleKeybind()
    local btn = _G["ArtisanNexusToggleButton"]
    if not btn then return end

    -- Override bindings are protected in combat: ClearOverrideBindings /
    -- SetOverrideBindingClick would be blocked and taint the binding system
    -- (action bars stop updating for the rest of the fight). Defer to
    -- OnCombatEnd instead.
    if InCombatLockdown() then
        self._pendingToggleKeybindApply = true
        return
    end
    self._pendingToggleKeybindApply = nil

    ClearOverrideBindings(btn)

    local key = self.db and self.db.profile and self.db.profile.toggleKeybind
    if key then
        local normalized = tostring(key):upper()
        if normalized == "ESC" or normalized == "ESCAPE" or normalized == "ESCAPEKEY" then
            -- Safety migration: ESC is reserved for game menu / close flows.
            self.db.profile.toggleKeybind = nil
            if self.Print then
                self:Print("|cffff6600Esc cannot be the toggle key; binding removed.|r")
            end
            return
        end
    end
    if key and key ~= "" and not InCombatLockdown() then
        SetOverrideBindingClick(btn, true, key, "ArtisanNexusToggleButton")
    end
end

--- Warband Nexus Core.lua IsStillOnTab (verbatim).
function ArtisanNexus:IsStillOnTab(expectedTab)
    if not self.UI or not self.UI.mainFrame then return false end
    local mf = self.UI.mainFrame
    return mf:IsShown() and mf.currentTab == expectedTab
end

function ArtisanNexus:OnProfileChanged()
    --- The new profile carries its own window scale (WN ApplyUIScale) and fonts (FontManager).
    if self.ApplyUIScale and self.db and self.db.profile then
        self:ApplyUIScale(self.db.profile.uiScale or 1.0)
    end
    if ns.FontManager and ns.FontManager.RefreshAllFonts then
        ns.FontManager:RefreshAllFonts()
    end
    if ns.UI_RefreshColors then
        ns.UI_RefreshColors()
    end
    if ns.LootHistoryUI and ns.LootHistoryUI.main and ns.LootHistoryUI.ApplySavedFrameSize then
        ns.LootHistoryUI:ApplySavedFrameSize(ns.LootHistoryUI.main)
        if ns.LootHistoryUI.main:IsShown() and ns.LootHistoryUI.Refresh then
            ns.LootHistoryUI:Refresh()
        end
    end
    if ns.SessionLootOverlayUI and ns.SessionLootOverlayUI.ApplySettingsAnchor then
        ns.SessionLootOverlayUI:ApplySettingsAnchor()
    end
    if ns.SessionLootOverlayUI and ns.SessionLootOverlayUI.ApplySettingsScale then
        ns.SessionLootOverlayUI:ApplySettingsScale()
    end
    if self.RefreshMinimapButton then
        self:RefreshMinimapButton()
    end
    --- profile.economy is a different table now: economy services drop their cached results.
    --- No key payload = every economy setting may have changed.
    if E and E.ECONOMY_CONFIG_CHANGED then
        self:SendMessage(E.ECONOMY_CONFIG_CHANGED)
    end
    if E and E.THEME_CHANGED then
        self:SendMessage(E.THEME_CHANGED)
    end
    -- WN Core.lua OnProfileChanged: repaint the main window from the new profile.
    if E and E.UI_MAIN_REFRESH_REQUESTED then
        self:SendMessage(E.UI_MAIN_REFRESH_REQUESTED, { skipCooldown = true })
    end
end

--- Economy engine services (Modules/Economy/*): enabled in this order, disabled in reverse.
--- Missing modules are skipped, so a service can ship without touching Core.lua.
local ECONOMY_SERVICES = {
    "VendorPriceService",
    "CraftOpsService",
    "CraftLedgerService",
    "SalesLedgerService",
    "OwnedAuctionsService",
    "CooldownService",
    "ConcentrationPlannerService",
    "CraftingOrdersService",
    "MarketIntelService",
    "TooltipService",
}

function ArtisanNexus:OnEnable()
    -- Apply the persisted theme (accent + light/dark surfaces) now that the DB is
    -- loaded: SharedWidgets builds its palette at file load, before SavedVariables
    -- exist, so light mode would otherwise only apply after a manual re-theme.  [WN Core.lua OnEnable]
    if ns.UI_RefreshColors then
        ns.UI_RefreshColors()
    end
    ns._wnThemeWasClassic = ns.UI_IsClassicMode and ns.UI_IsClassicMode()

    --- Character data backends (Warband Nexus or AN-native) are picked before any collector starts.
    ns.WarbandNexusBridge:Init()
    ns.CharacterData:Enable()
    local modules = self.db.profile.modulesEnabled or {}
    if modules.fishing ~= false then
        if ns.FishingService then
            ns.FishingService:Enable()
        end
        if ns.FishingLootService then
            ns.FishingLootService:Enable()
        end
    end
    if modules.gathering ~= false then
        if ns.GatheringLootService then
            ns.GatheringLootService:Enable()
        end
        if ns.GatheringOverloadService then
            ns.GatheringOverloadService:Enable()
        end
    end
    if ns.BagPressureGuard then
        ns.BagPressureGuard:Enable()
    end
    if ns.RecipeService then
        ns.RecipeService:Enable()
    end
    if ns.CraftLootService then
        ns.CraftLootService:Enable()
    end
    if ns.ProfessionSnapshotService then
        ns.ProfessionSnapshotService:Enable()
    end
    if ns.CraftBriefingService then
        ns.CraftBriefingService:Enable()
    end
    if ns.ProfessionEquipmentService then
        ns.ProfessionEquipmentService:Enable()
    end
    if ns.ProfessionSidecarUI then
        ns.ProfessionSidecarUI:Enable()
    end
    if ns.CraftQueueActionButton then
        ns.CraftQueueActionButton:Enable()
    end
    for i = 1, #ECONOMY_SERVICES do
        local svc = ns[ECONOMY_SERVICES[i]]
        if svc and svc.Enable then
            svc:Enable()
        end
    end
    self:SendMessage(E.LOADING_COMPLETE)

    if self.db.profile.showLoginChat then
        local ver = (ns.Constants and ns.Constants.ADDON_VERSION) or "?"
        self:Print((L and L["LOGIN_CHAT"]) and string.format(L["LOGIN_CHAT"], ver) or ("v" .. ver .. " loaded"))
    end
end

function ArtisanNexus:OnMessageLoadingComplete()
    if ns.DebugPrint then
        ns.DebugPrint("AN_LOADING_COMPLETE")
    end
end

function ArtisanNexus:OnPlayerEnteringWorld(_, isInitialLogin, isReloadingUi)
    if self.db and self.db.profile and self.db.profile.useClassColorAccent then
        self:RefreshTheme()
    end
end

function ArtisanNexus:OnModuleToggled(_, moduleKey, enabled)
    local on = enabled ~= false
    if moduleKey == "fishing" then
        if on then
            if ns.FishingService then ns.FishingService:Enable() end
            if ns.FishingLootService then ns.FishingLootService:Enable() end
        else
            if ns.FishingLootService then ns.FishingLootService:Disable() end
            if ns.FishingService then ns.FishingService:Disable() end
        end
    elseif moduleKey == "gathering" then
        if on then
            if ns.GatheringLootService then ns.GatheringLootService:Enable() end
            if ns.GatheringOverloadService then ns.GatheringOverloadService:Enable() end
        else
            if ns.GatheringLootService then ns.GatheringLootService:Disable() end
            if ns.GatheringOverloadService then ns.GatheringOverloadService:Disable() end
        end
    end
end

function ArtisanNexus:OnMessageFishingChannelStarted(_, spellID)
    if not self.db.profile.debugMode then
        return
    end
    local sid = spellID and tostring(spellID) or "?"
    self:Print((L and L["FISHING_DEBUG_CHANNEL_START"]) and string.format(L["FISHING_DEBUG_CHANNEL_START"], sid) or ("Fishing channel " .. sid))
end

function ArtisanNexus:OnMessageFishingChannelStopped(_, spellID)
    if not self.db.profile.debugMode then
        return
    end
    local sid = spellID and tostring(spellID) or "?"
    self:Print((L and L["FISHING_DEBUG_CHANNEL_STOP"]) and string.format(L["FISHING_DEBUG_CHANNEL_STOP"], sid) or ("Fishing channel stop " .. sid))
end

function ArtisanNexus:OnDisable()
    if ns.RecipeService then
        ns.RecipeService:Disable()
    end
    if ns.GatheringLootService then
        ns.GatheringLootService:Disable()
    end
    if ns.GatheringOverloadService then
        ns.GatheringOverloadService:Disable()
    end
    if ns.BagPressureGuard then
        ns.BagPressureGuard:Disable()
    end
    if ns.FishingLootService then
        ns.FishingLootService:Disable()
    end
    if ns.FishingService then
        ns.FishingService:Disable()
    end
    if ns.CraftLootService and ns.CraftLootService.Disable then
        ns.CraftLootService:Disable()
    end
    if ns.ProfessionSnapshotService and ns.ProfessionSnapshotService.Disable then
        ns.ProfessionSnapshotService:Disable()
    end
    if ns.CraftBriefingService and ns.CraftBriefingService.Disable then
        ns.CraftBriefingService:Disable()
    end
    if ns.ProfessionEquipmentService and ns.ProfessionEquipmentService.Disable then
        ns.ProfessionEquipmentService:Disable()
    end
    if ns.ProfessionSidecarUI and ns.ProfessionSidecarUI.Disable then
        ns.ProfessionSidecarUI:Disable()
    end
    if ns.CraftQueueActionButton and ns.CraftQueueActionButton.Disable then
        ns.CraftQueueActionButton:Disable()
    end
    for i = #ECONOMY_SERVICES, 1, -1 do
        local svc = ns[ECONOMY_SERVICES[i]]
        if svc and svc.Disable then
            svc:Disable()
        end
    end
    ns.CharacterData:Disable()
end

--- Three commands only; everything else lives in the Hub rail, Settings or the AH/profession windows.
---   /an          toggle the Artisan Hub
---   /an history  toggle the session loot history
---   /an config   open Settings
function ArtisanNexus:SlashCommand(input)
    input = (input or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if input == "" then
        self:ToggleMainWindow()
        return
    end
    if input == "history" then
        if ns.LootHistoryUI then
            ns.LootHistoryUI:Toggle()
        end
        return
    end
    if input == "config" then
        if ns.OpenAddonSettings then
            ns.OpenAddonSettings()
        end
        return
    end
    self:Print((L and L["SLASH_HELP_LINE"]) or "|cff00ccff/an|r Artisan Hub  ·  |cff00ccff/an history|r Session Loot  ·  |cff00ccff/an config|r Settings")
end

function ArtisanNexus:Print(msg)
    local name = (L and L["ADDON_NAME"]) or ADDON_NAME
    _G.DEFAULT_CHAT_FRAME:AddMessage("|cff6a0dad" .. name .. "|r: " .. tostring(msg))
end
