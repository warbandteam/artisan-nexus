--[[
    Artisan Nexus — AceAddon bootstrap (Midnight 12.0.1).
    Data → Service → View: services use SendMessage; UI subscribes (see .cursor/rules).
]]

local ADDON_NAME, ns = ...

---@class ArtisanNexus : AceAddon, AceEvent-3.0, AceConsole-3.0, AceHook-3.0, AceTimer-3.0, AceBucket-3.0
local ArtisanNexus = LibStub("AceAddon-3.0"):NewAddon(
    ADDON_NAME,
    "AceEvent-3.0",
    "AceConsole-3.0",
    "AceHook-3.0",
    "AceTimer-3.0",
    "AceBucket-3.0"
)

ns.ArtisanNexus = ArtisanNexus

local L = LibStub("AceLocale-3.0"):GetLocale("ArtisanNexus")
ns.L = L

local E = ns.Constants.EVENTS

--- Maps ADDON_VERSION x.y.z to locale key CHANGELOG_Vxyz (WN parity).
local function VersionToChangelogKey(version)
    if not version or type(version) ~= "string" then
        return nil
    end
    local a, b, c = version:match("^(%d+)%.(%d+)%.(%d+)")
    if not a then
        return nil
    end
    return "CHANGELOG_V" .. a .. b .. c
end

local defaults = {
    profile = {
        enabled = true,
        --- One line in chat on load so the addon is discoverable without a window yet.
        showLoginChat = true,
        --- "dark" | "light" — see `Modules/UI/ArtisanTheme.lua`.
        themeMode = "dark",
        --- "modern" | "classic" — classic uses plain Blizzard panel/button templates (no themed chrome).
        uiMode = "modern",
        --- Accent preset for modern themed chrome: default | violet | gold | teal | rose | cobalt | custom
        accentPreset = "default",
        --- RGB when accentPreset == "custom" (0–1).
        accentCustom = { 0.44, 0.32, 0.58 },
        --- When true, accent (and derived tab/border tones) follows the logged-in character's class color.
        useClassColorAccent = false,
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
        --- Session loot window + loot-driven UI (catalog, auto-open). Slash /an loot still works when off.
        lootHistoryEnabled = true,
        --- Open Session loot window when fishing or gathering records a pickup (per-tab); requires lootHistoryEnabled.
        lootHistoryAutoOpen = false,
        --- Last Session loot tab (fishing / herb / mine / …); restored on reload + auto-open.
        lootHistoryActiveTab = nil,
        --- Artisan Hub (/an hub): profit | shop | queue; restored when reopening the hub.
        hubActiveTab = nil,
        --- When true, Profitability tab lists only recipes craftable from current session loot (not bags).
        hubSessionOnly = false,
        --- Artisan Hub profession filter ("All" or Midnight craft profession name from catalog).
        hubProfessionFilter = "All",
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
        sessionLootOverlayEnabled = false,
        sessionLootOverlayHoldSec = 4,
        sessionLootOverlayStackMax = 3,
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
        posting = {
            strategy = "undercut",
            undercutBy = 0.01,
            averageMul = 1.0,
            floorMul = 0.5,
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
        dataVersion = ns.Constants.DB_VERSION,
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
        --- AH unit prices (copper). [itemID] = { buyout = number, updatedAt = unix }
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
        --- [guid] = { profession, skillLineID, concCurrent, concMax, knowledgeUnspent, at }
        professionSnapshots = {},
    },
    char = {
        professionEquipmentHints = {},
    },
}

function ArtisanNexus:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("ArtisanNexusDB", defaults, true)
    ns.db = self.db

    self.db.RegisterCallback(self, "OnProfileChanged", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileCopied", "OnProfileChanged")
    self.db.RegisterCallback(self, "OnProfileReset", "OnProfileChanged")

    if ns.MigrationService then
        ns.MigrationService:CheckAddonVersion(self.db, self)
        local didReset = ns.MigrationService:RunMigrations(self.db)
        if didReset then
            for k, v in pairs(defaults.global) do
                if self.db.global[k] == nil then
                    if type(v) == "table" then
                        self.db.global[k] = {}
                    else
                        self.db.global[k] = v
                    end
                end
            end
            for k, v in pairs(defaults.char) do
                if self.db.char[k] == nil then
                    if type(v) == "table" then
                        self.db.char[k] = {}
                    else
                        self.db.char[k] = v
                    end
                end
            end
        end
    end

    do
        local p = self.db.profile
        if not p._gatherLogRemoved202606 then
            p._gatherLogRemoved202606 = true
            --- Clear only the orphan SV left by our removed module; never touch a
            --- standalone GatherLog addon's SavedVariables.
            local gatherLogLoaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("GatherLog")
            if not gatherLogLoaded and _G.GatherLogDB and wipe then
                wipe(_G.GatherLogDB)
            end
        end
        if not p._settingsAlwaysEnabled202606 then
            p._settingsAlwaysEnabled202606 = true
            p.enabled = true
        end
        if not p._mapOverlayRemoved202606 then
            p._mapOverlayRemoved202606 = true
            p.routeHeatmapEnabled = nil
            p.minimapGatherPinsEnabled = nil
            p.farmTargetHighlightEnabled = nil
            p.gatherLootAutoWaypoint = nil
            p.farmTargetAutoWaypoint = nil
            local g = self.db.global
            if g then
                g.gatherRoutePoints = nil
                g.farmTargetRoutePoints = nil
            end
        end
    end

    self:RegisterChatCommand("an", "SlashCommand")
    self:RegisterChatCommand("artisan", "SlashCommand")

    if ns.Config and ns.Config.RegisterOptions then
        ns.Config.RegisterOptions(self)
    end

    self:InitializeMinimapButton()

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
    if ns.ArtisanSettingsUI and ns.ArtisanSettingsUI.Init then
        ns.ArtisanSettingsUI:Init()
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

function ArtisanNexus:RefreshTheme()
    if ns.UI_RefreshColors then
        ns.UI_RefreshColors()
    end
    if ns.ArtisanSettingsUI and ns.ArtisanSettingsUI.RefreshIfShown then
        ns.ArtisanSettingsUI:RefreshIfShown()
    end
    if E and E.THEME_CHANGED then
        self:SendMessage(E.THEME_CHANGED)
    end
end

function ArtisanNexus:RefreshUiMode()
    if ns.UI_ResetMainWindowsForUiMode then
        ns.UI_ResetMainWindowsForUiMode()
    end
    if ns.ArtisanSettingsUI and ns.ArtisanSettingsUI.RefreshIfShown then
        ns.ArtisanSettingsUI:RefreshIfShown()
    end
    if E and E.THEME_CHANGED then
        self:SendMessage(E.THEME_CHANGED)
    end
end

function ArtisanNexus:OnProfileChanged()
    if ns.UI_RefreshColors then
        ns.UI_RefreshColors()
    end
    if ns.LootHistoryUI and ns.LootHistoryUI.main and ns.LootHistoryUI.ApplySavedFrameSize then
        ns.LootHistoryUI:ApplySavedFrameSize(ns.LootHistoryUI.main)
        if ns.LootHistoryUI.main:IsShown() and ns.LootHistoryUI.Refresh then
            ns.LootHistoryUI:Refresh()
        end
    end
    if ns.ArtisanSettingsUI and ns.ArtisanSettingsUI.RefreshIfShown then
        ns.ArtisanSettingsUI:RefreshIfShown()
    end
    if ns.SessionLootOverlayUI and ns.SessionLootOverlayUI.ApplySettingsAnchor then
        ns.SessionLootOverlayUI:ApplySettingsAnchor()
    end
    if E and E.THEME_CHANGED then
        self:SendMessage(E.THEME_CHANGED)
    end
end

function ArtisanNexus:OnEnable()
    if ns.Utilities and ns.Utilities.TouchCharRegistry then
        ns.Utilities:TouchCharRegistry()
    end
    local modules = self.db.profile.modulesEnabled or {}
    if self.db.profile.enabled and modules.fishing ~= false then
        if ns.FishingService then
            ns.FishingService:Enable()
        end
        if ns.FishingLootService then
            ns.FishingLootService:Enable()
        end
    end
    if self.db.profile.enabled and modules.gathering ~= false then
        if ns.GatheringLootService then
            ns.GatheringLootService:Enable()
        end
        if ns.GatheringOverloadService then
            ns.GatheringOverloadService:Enable()
        end
    end
    if self.db.profile.enabled and ns.BagPressureGuard then
        ns.BagPressureGuard:Enable()
    end
    if self.db.profile.enabled and ns.RecipeService then
        ns.RecipeService:Enable()
    end
    if self.db.profile.enabled and ns.CraftLootService then
        ns.CraftLootService:Enable()
    end
    if self.db.profile.enabled and ns.ProfessionSnapshotService then
        ns.ProfessionSnapshotService:Enable()
    end
    if self.db.profile.enabled and ns.CraftBriefingService then
        ns.CraftBriefingService:Enable()
    end
    if self.db.profile.enabled and ns.ProfessionEquipmentService then
        ns.ProfessionEquipmentService:Enable()
    end
    if self.db.profile.enabled and ns.ProfessionSidecarUI then
        ns.ProfessionSidecarUI:Enable()
    end
    if self.db.profile.enabled and ns.CraftQueueActionButton then
        ns.CraftQueueActionButton:Enable()
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
    if not self.db.profile.enabled then
        return
    end
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
end

function ArtisanNexus:SlashCommand(input)
    input = (input or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if input == "debug" then
        self.db.profile.debugMode = not self.db.profile.debugMode
        self:Print("Debug: " .. (self.db.profile.debugMode and "on" or "off"))
        if ns.UI_RefreshAllViewportDebugChrome then
            ns.UI_RefreshAllViewportDebugChrome()
        end
        return
    end
    if input == "version" or input == "ver" then
        local ver = (ns.Constants and ns.Constants.ADDON_VERSION) or "?"
        self:Print((L and L["ADDON_NAME"]) or ADDON_NAME .. " " .. ver)
        return
    end
    if input == "changelog" or input == "whatsnew" or input == "news" then
        local ver = (ns.Constants and ns.Constants.ADDON_VERSION) or "0.1.0"
        local key = VersionToChangelogKey(ver)
        local text = key and L and L[key]
        if text and text ~= "" then
            for line in text:gmatch("[^\n]+") do
                self:Print(line)
            end
        else
            self:Print("No in-game changelog for v" .. ver .. ". See CHANGELOG.md.")
        end
        return
    end
    if input == "help" or input == "?" or input == "" then
        self:Print((L and L["SLASH_HELP_HEADER"]) or "Commands:")
        self:Print((L and L["SLASH_HELP_LINE"]) or "/an debug, /an version")
        if L and L["SLASH_HELP_LINE2"] and L["SLASH_HELP_LINE2"] ~= "" then
            self:Print(L["SLASH_HELP_LINE2"])
        end
        return
    end
    if input == "config" or input == "settings" or input == "options" then
        if ns.OpenAddonSettings then
            ns.OpenAddonSettings()
        end
        return
    end
    if input == "minimap" or input == "minimapbutton" or input == "icon" then
        self:ToggleMinimapButton()
        return
    end
    if input == "fish" then
        if ns.LootHistoryUI then
            ns.LootHistoryUI:Show("fishing")
        end
        return
    end
    if input == "gather" or input == "gathering" or input == "herb" then
        if ns.LootHistoryUI then
            ns.LootHistoryUI:Show("herb")
        end
        return
    end
    if input == "mine" or input == "mining" or input == "ore" then
        if ns.LootHistoryUI then
            ns.LootHistoryUI:Show("mine")
        end
        return
    end
    if input == "leather" or input == "skinning" or input == "skin" then
        if ns.LootHistoryUI then
            ns.LootHistoryUI:Show("leather")
        end
        return
    end
    if input == "disenchant" or input == "de" or input == "enchant" then
        if ns.LootHistoryUI then
            ns.LootHistoryUI:Show("disenchant")
        end
        return
    end
    if input == "others" or input == "other" or input == "mote" or input == "shared" then
        if ns.LootHistoryUI then
            ns.LootHistoryUI:Show("others")
        end
        return
    end
    if input == "history" or input == "loot" then
        if ns.LootHistoryUI then
            ns.LootHistoryUI:Toggle()
        end
        return
    end
    if input == "overlay" or input == "lootoverlay" or input == "loothud"
        or input:match("^overlay%s+")
        or input:match("^lootoverlay%s+")
        or input:match("^loothud%s+") then
        local O = ns.SessionLootOverlayUI
        if not O then
            self:Print((L and L["SLASH_OVERLAY_UNAVAILABLE"]) or "Session loot overlay is unavailable.")
            return
        end
        local sub = input:match("^%S+%s+(.+)$") or ""
        sub = sub:match("^%s*(.-)%s*$") or ""
        if sub == "move" or sub == "position" or sub == "pos" then
            if O.TogglePositionEdit then
                O:TogglePositionEdit()
            end
            return
        end
        if sub ~= "" then
            return
        end
        local on
        if O.Toggle then
            on = O:Toggle()
        end
        if on then
            self:Print((L and L["SLASH_OVERLAY_ON"]) or "Session loot overlay shown.")
        else
            self:Print((L and L["SLASH_OVERLAY_OFF"]) or "Session loot overlay hidden.")
        end
        return
    end
    if input == "recipe" or input == "recipes" or input == "craft" or input == "matcher" then
        if ns.RecipeMatcherUI then
            ns.RecipeMatcherUI:Toggle()
        end
        return
    end
    if input == "scanrecipes" or input == "harvest" then
        if ns.RecipeService then
            local svc = ns.RecipeService
            if svc.IsHarvestChunkActive and svc:IsHarvestChunkActive() then
                self:Print("Recipe scan already in progress.")
                return
            end
            if svc.HarvestOpenProfessionChunked then
                svc:HarvestOpenProfessionChunked(function(n)
                    self:Print(string.format("Harvested %d recipe schematics.", n))
                end)
            else
                local n = svc:HarvestOpenProfession()
                self:Print(string.format("Harvested %d recipe schematics.", n))
            end
        end
        return
    end
    if input == "ah" or input == "ahprice" or input == "ahscan" then
        if ns.AHPriceService and ns.AHPriceService.StartScan then
            --- force + full catalog (same as AH window “Sync AH Prices” button)
            ns.AHPriceService:StartScan(true, true)
        else
            self:Print("AH price scan is unavailable.")
        end
        return
    end
    if input == "hub" or input == "profit" or input == "profitability" or input == "shop" or input == "shopping" or input == "queue" then
        if ns.ArtisanHubUI then
            if input == "hub" then
                ns.ArtisanHubUI:Toggle()
            else
                --- Route the alias straight to its tab (Show normalizes the key).
                ns.ArtisanHubUI:Show(input)
            end
        else
            self:Print("Artisan Hub is unavailable.")
        end
        return
    end
    self:Print((L and L["SLASH_HELP_LINE"]) or "/an help")
end

function ArtisanNexus:Print(msg)
    local name = (L and L["ADDON_NAME"]) or ADDON_NAME
    _G.DEFAULT_CHAT_FRAME:AddMessage("|cff6a0dad" .. name .. "|r: " .. tostring(msg))
end
