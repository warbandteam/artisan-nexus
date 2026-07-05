--[[
    Artisan Nexus — LootHistoryUI bootstrap (message listeners + Init).
    Loaded after LootHistoryUI.lua; Core calls `ns.LootHistoryUI:Init()` on AceDB init.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants and ns.Constants.EVENTS
local M = ns.LootHistoryUI

assert(M and ArtisanNexus, "LootHistoryUI_Init: load LootHistoryUI.lua first")

local professionTabsRefreshFrame = nil
local lootUiRefreshSeq = 0

local function RefreshIfVisibleImmediate()
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return
    end
    if M.main and M.main:IsShown() then
        M:Refresh()
    end
end

--- Coalesce burst loot signals (gathering multi-drop) into one list paint per frame bucket.
local function ScheduleLootHistoryRefresh()
    if not (C_Timer and C_Timer.After) then
        RefreshIfVisibleImmediate()
        return
    end
    if not (M.main and M.main:IsShown()) then
        return
    end
    lootUiRefreshSeq = lootUiRefreshSeq + 1
    local token = lootUiRefreshSeq
    C_Timer.After(0.12, function()
        if token ~= lootUiRefreshSeq then
            return
        end
        if M.main and M.main:IsShown() then
            M:Refresh()
        end
    end)
end

local function RegisterProfessionTabsRefresh()
    if professionTabsRefreshFrame then
        return
    end
    professionTabsRefreshFrame = CreateFrame("Frame")
    professionTabsRefreshFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    professionTabsRefreshFrame:RegisterEvent("SKILL_LINES_CHANGED")
    professionTabsRefreshFrame:SetScript("OnEvent", function()
        if not (M.main and M.main:IsShown()) then
            return
        end
        M:LayoutTabs()
        M:Refresh()
    end)
end

local function RefreshIfVisible()
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return
    end
    ScheduleLootHistoryRefresh()
end

local function OnModuleToggled()
    if not M.main or not M.main:IsShown() then
        return
    end
    M:LayoutTabs()
    M:Refresh()
end

--- AH prices apply everywhere (cities, instances); do **not** gate on `IsOpenWorld`.
local ahLootUiRefreshSeq = 0
local function RefreshLootHistoryAfterAhPriceTick()
    if M.main and M.main:IsShown() then
        M:Refresh()
    end
end

local function OnAhPricesUpdatedForLootUi()
    ahLootUiRefreshSeq = ahLootUiRefreshSeq + 1
    local token = ahLootUiRefreshSeq
    if C_Timer and C_Timer.After then
        C_Timer.After(0.12, function()
            if token ~= ahLootUiRefreshSeq then
                return
            end
            RefreshLootHistoryAfterAhPriceTick()
        end)
    else
        RefreshLootHistoryAfterAhPriceTick()
    end
end

local function OnSessionLootUpdated(_, payload)
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return
    end
    local prof = ns.db and ns.db.profile
    if prof and prof.lootHistoryEnabled == false then
        ScheduleLootHistoryRefresh()
        return
    end
    if payload == nil then
        ScheduleLootHistoryRefresh()
        return
    end
    local main = M.main
    local visible = main and main:IsShown()
    local autoOpen = prof and prof.lootHistoryAutoOpen

    local singleTab = nil
    if type(payload) == "table" then
        if payload.multi then
            if visible then
                ScheduleLootHistoryRefresh()
            elseif autoOpen then
                M:Show()
            end
            return
        end
        if type(payload.singleTab) == "string" and payload.singleTab ~= "" then
            singleTab = payload.singleTab
        end
    elseif type(payload) == "string" and payload ~= "" then
        singleTab = payload
    end

    if singleTab and M:IsValidTab(singleTab) then
        if visible then
            if M.activeTab == singleTab then
                if ns.SessionLootService and ns.SessionLootService.ClearTabAttentionForTab then
                    ns.SessionLootService:ClearTabAttentionForTab(singleTab)
                end
                ScheduleLootHistoryRefresh()
            else
                M:SetTab(singleTab)
            end
        elseif autoOpen then
            M:Show(singleTab)
        end
        return
    end

    if visible then
        ScheduleLootHistoryRefresh()
    elseif autoOpen then
        M:Show()
    end
end

local function OnThemeChanged()
    if M.RefreshTheme then
        M:RefreshTheme()
    end
end

function M:Init()
    local saved = ns.db and ns.db.profile and ns.db.profile.lootHistoryActiveTab
    if saved and self:IsValidTab(saved) then
        M.activeTab = saved
    else
        local order = self:GetVisibleTabOrder()
        M.activeTab = order[1] or "fishing"
    end
    RegisterProfessionTabsRefresh()
    local owner = ns.NewEventOwner("LootHistoryUI")
    M._eventOwner = owner
    owner:RegisterMessage(E.FISHING_HISTORY_UPDATED, RefreshIfVisible)
    owner:RegisterMessage(E.GATHERING_HISTORY_UPDATED, RefreshIfVisible)
    owner:RegisterMessage(E.LOOT_HISTORY_UPDATED, RefreshIfVisible)
    owner:RegisterMessage(E.SESSION_LOOT_UPDATED, OnSessionLootUpdated)
    owner:RegisterMessage(E.AH_PRICES_UPDATED, OnAhPricesUpdatedForLootUi)
    if E.RECIPE_SCHEMATICS_UPDATED then
        owner:RegisterMessage(E.RECIPE_SCHEMATICS_UPDATED, RefreshIfVisible)
    end
    if E.MODULE_TOGGLED then
        owner:RegisterMessage(E.MODULE_TOGGLED, OnModuleToggled)
    end
    if E and E.CRAFT_LOOT_RECORDED then
        owner:RegisterMessage(E.CRAFT_LOOT_RECORDED, RefreshIfVisible)
    end
    if E.THEME_CHANGED then
        owner:RegisterMessage(E.THEME_CHANGED, OnThemeChanged)
    end
end
