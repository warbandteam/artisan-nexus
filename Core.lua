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
        --- Loot history window size (nil = theme defaults on first open).
        lootHistoryFrame = {
            width = nil,
            height = nil,
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

    self:RegisterMessage(E.FISHING_CHANNEL_STARTED, "OnMessageFishingChannelStarted")
    self:RegisterMessage(E.FISHING_CHANNEL_STOPPED, "OnMessageFishingChannelStopped")

    if ns.FishingHistoryUI and ns.FishingHistoryUI.Init then
        ns.FishingHistoryUI:Init()
    end
end

function ArtisanNexus:OnProfileChanged()
    if ns.FishingHistoryUI and ns.FishingHistoryUI.main and ns.FishingHistoryUI.ApplySavedFrameSize then
        ns.FishingHistoryUI:ApplySavedFrameSize(ns.FishingHistoryUI.main)
        if ns.FishingHistoryUI.main:IsShown() and ns.FishingHistoryUI.Refresh then
            ns.FishingHistoryUI:Refresh()
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
    if ns.GatheringLootService then
        ns.GatheringLootService:Disable()
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
    if input == "fish" then
        if ns.FishingHistoryUI then
            ns.FishingHistoryUI:Show("fishing")
        end
        return
    end
    if input == "gather" or input == "gathering" or input == "herb" then
        if ns.FishingHistoryUI then
            ns.FishingHistoryUI:Show("herb")
        end
        return
    end
    if input == "mine" or input == "mining" or input == "ore" then
        if ns.FishingHistoryUI then
            ns.FishingHistoryUI:Show("mine")
        end
        return
    end
    if input == "leather" or input == "skinning" or input == "skin" then
        if ns.FishingHistoryUI then
            ns.FishingHistoryUI:Show("leather")
        end
        return
    end
    if input == "disenchant" or input == "de" or input == "enchant" then
        if ns.FishingHistoryUI then
            ns.FishingHistoryUI:Show("disenchant")
        end
        return
    end
    if input == "history" or input == "loot" then
        if ns.FishingHistoryUI then
            ns.FishingHistoryUI:Toggle()
        end
        return
    end
    self:Print((L and L["SLASH_HELP_LINE"]) or "/an help")
end

function ArtisanNexus:Print(msg)
    local name = (L and L["ADDON_NAME"]) or ADDON_NAME
    _G.DEFAULT_CHAT_FRAME:AddMessage("|cff6a0dad" .. name .. "|r: " .. tostring(msg))
end
