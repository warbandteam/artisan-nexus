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

local defaults = {
    profile = {
        enabled = true,
        --- One line in chat on load so the addon is discoverable without a window yet.
        showLoginChat = true,
        debugMode = false,
        --- Double right-click on the world to /cast Fishing or bobber interact (see FishingInput).
        fishingDoubleClickEnabled = true,
        modulesEnabled = {
            fishing = true,
            gathering = true,
        },
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
        --- World indicator when hovering overloaded herb/ore nodes.
        overloadNodeIndicatorEnabled = true,
        --- Floating herb/mining overload CD tracker (requires Herbalism and/or Mining).
        overloadTrackerHudEnabled = true,
        --- Movable overload tracker frame anchor.
        overloadTrackerFrame = {
            point = "TOP",
            relativePoint = "TOP",
            x = 0,
            y = -140,
        },
        --- Show gathering route density overlay on World Map.
        routeHeatmapEnabled = true,
        --- Warn when bag free slots are low while gathering.
        bagPressureGuardEnabled = true,
        bagPressureThreshold = 8,
        --- LibDBIcon: hide, minimapPos (angle) persisted by the library inside this table.
        minimap = {
            hide = false,
        },
    },
    global = {
        dataVersion = ns.Constants.DB_VERSION,
        _schemaVersion = 1,
        addonVersion = ns.Constants.ADDON_VERSION,
        --- Aggregated fishing loot: [itemID] = { count = number, lastAt = unix, name = string|nil }
        fishingLootHistory = {},
        --- Herb / ore / skinning (gathering) loot totals
        gatheringLootHistory = {},
        --- Overall pickup event log (capped, never reset on login). fishing: { itemID, qty, t }
        overallFishingEvents = {},
        --- Overall pickup event log for gathering: { itemID, qty, t, cat }
        overallGatheringEvents = {},
        --- AH unit prices (copper). [itemID] = { buyout = number, updatedAt = unix }
        ahPrices = {},
        --- Midnight recipe schematics harvested from C_TradeSkillUI.
        --- [spellID] = { name, profession, reagents = { {itemID, qty, slotType}, ... }, updated }
        recipeSchematics = {},
    },
    char = {},
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

    self:RegisterChatCommand("an", "SlashCommand")
    self:RegisterChatCommand("artisan", "SlashCommand")

    if ns.Config and ns.Config.RegisterOptions then
        ns.Config.RegisterOptions(self)
    end

    self:InitializeMinimapButton()

    self:RegisterMessage(E.FISHING_CHANNEL_STARTED, "OnMessageFishingChannelStarted")
    self:RegisterMessage(E.FISHING_CHANNEL_STOPPED, "OnMessageFishingChannelStopped")

    if ns.LootHistoryUI and ns.LootHistoryUI.Init then
        ns.LootHistoryUI:Init()
    end
    if ns.GatheringOverloadIndicator and ns.GatheringOverloadIndicator.Init then
        ns.GatheringOverloadIndicator:Init()
    end
    if ns.GatheringRouteOverlay and ns.GatheringRouteOverlay.Init then
        ns.GatheringRouteOverlay:Init()
    end
    if ns.GatheringOverloadActionButton and ns.GatheringOverloadActionButton.Init then
        ns.GatheringOverloadActionButton:Init()
    end
end

function ArtisanNexus:OnProfileChanged()
    if ns.LootHistoryUI and ns.LootHistoryUI.main and ns.LootHistoryUI.ApplySavedFrameSize then
        ns.LootHistoryUI:ApplySavedFrameSize(ns.LootHistoryUI.main)
        if ns.LootHistoryUI.main:IsShown() and ns.LootHistoryUI.Refresh then
            ns.LootHistoryUI:Refresh()
        end
    end
end

function ArtisanNexus:OnEnable()
    local modules = self.db.profile.modulesEnabled or {}
    if self.db.profile.enabled and modules.fishing ~= false then
        if ns.FishingService then
            ns.FishingService:Enable()
        end
        if ns.FishingInput then
            ns.FishingInput:Enable()
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
        if ns.GatheringRouteOverlay then
            ns.GatheringRouteOverlay:Refresh()
        end
    end
    if self.db.profile.enabled and ns.BagPressureGuard then
        ns.BagPressureGuard:Enable()
    end
    if self.db.profile.enabled and ns.RecipeService then
        ns.RecipeService:Enable()
    end
    self:SendMessage(E.LOADING_COMPLETE)

    if self.db.profile.showLoginChat then
        local ver = (ns.Constants and ns.Constants.ADDON_VERSION) or "?"
        self:Print((L and L["LOGIN_CHAT"]) and string.format(L["LOGIN_CHAT"], ver) or ("v" .. ver .. " loaded"))
    end
end

function ArtisanNexus:OnMessageFishingChannelStarted(_, spellID)
    if not self.db.profile.debugMode then return end
    -- spellID may be nil in edge cases
    local sid = spellID and tostring(spellID) or "?"
    self:Print((L and L["FISHING_DEBUG_CHANNEL_START"]) and string.format(L["FISHING_DEBUG_CHANNEL_START"], sid) or ("Fishing channel " .. sid))
end

function ArtisanNexus:OnMessageFishingChannelStopped(_, spellID)
    if not self.db.profile.debugMode then return end
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
    if ns.FishingInput then
        ns.FishingInput:Disable()
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
        return
    end
    if input == "version" or input == "ver" then
        local ver = (ns.Constants and ns.Constants.ADDON_VERSION) or "?"
        self:Print((L and L["ADDON_NAME"]) or ADDON_NAME .. " " .. ver)
        return
    end
    if input == "help" or input == "?" or input == "" then
        self:Print((L and L["SLASH_HELP_HEADER"]) or "Commands:")
        self:Print((L and L["SLASH_HELP_LINE"]) or "/an debug, /an version")
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
    if input == "recipe" or input == "recipes" or input == "craft" or input == "matcher" then
        if ns.RecipeMatcherUI then
            ns.RecipeMatcherUI:Toggle()
        end
        return
    end
    if input == "scanrecipes" or input == "harvest" then
        if ns.RecipeService then
            local n = ns.RecipeService:HarvestOpenProfession()
            self:Print(string.format("Harvested %d recipe schematics.", n))
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
            ns.ArtisanHubUI:Toggle()
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
