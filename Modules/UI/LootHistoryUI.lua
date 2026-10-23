--[[
    Session Loot window: per-tab catalog (Session vs Overall totals) + Last N pickups (always
    the in-memory session feed). Footer: per-tab reset (confirmed) + session rate status line.

    Built exactly like a Warband Nexus floating window (PlansTrackerWindow.lua) through
    ns.ArtisanWindow (ArtisanWindow.lua):
      shell / title band / close / resize / position  -> ns.ArtisanWindow.Create
      header utility buttons (gear = IconRegistry "settings", PlansTrackerWindow.lua:2390-2409)
                                                       -> ns.ArtisanWindow.AddHeaderButton
      profession tabs + Session/Overall switch         -> ns.UI_CreateSubTabBar (wrapRows, PvPUI
                                                          recent-filter metrics)
      catalog grid + pickup list                       -> two ns.ArtisanWindow.CreateScrollViewport
      reset (footer, small)                            -> ns.UI_CreateThemedButton + ns.ArtisanWindow.Confirm
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus

local function LT(key, fallback)
    return (ns.L and ns.L[key]) or fallback
end

-- Window-specific metrics.
local WIN_W, WIN_H = 600, 720
local MIN_W, MIN_H = 360, 440
local MAX_W, MAX_H = 960, 920
local SESSION_FRAC = 0.34        -- pickup list share of the window height
local SESSION_MIN_H = 140
local SECTION_ROW_H = 24         -- "Catalog" / "Last N pickups" heading rows
local BLOCK_GAP = 8
local FOOTER_RIGHT_RESERVE = 16  -- keep the status text clear of the resize grip
local RESET_BTN_W = 110
-- Compact sub-tab metrics (PvPUI.lua:58-60 recent-filter bar).
local TAB_BTN_H = 26
local TAB_BTN_GAP = 6
local TAB_PAD_H = 8

local function GetLastLootListCap()
    local s = ns.SessionLootService
    if s and s.GetMaxRecentLoot then
        return s:GetMaxRecentLoot()
    end
    return 15
end

local FormatCopper = ns.FormatCopper
--- Single loot valuation helper (Utilities.GetLootValueCopper): current market unit, gross
--- and net-of-AH-cut (cut only on AH-priced units). Grid / rows / overlay / per-character
--- show GROSS; the session rate shows NET.
local LootValueCopper = ns.GetLootValueCopper

local function FormatGross(copper)
    if copper and copper > 0 then
        local s = FormatCopper(copper)
        if s then return s end
    end
    return (ns.UI_FormatMoney and ns.UI_FormatMoney(0, 12)) or "0"
end

--- Grid total = gross value at the CURRENT price (counts stay historical; mark-to-market).
local function ComputeTotalsCopper(totals)
    local sum = 0
    if type(totals) ~= "table" then
        return 0
    end
    for rawId, qty in pairs(totals) do
        local q = tonumber(qty) or 0
        --- SavedVariables / DB pairs may use string keys — normalize before price lookup.
        local nid = tonumber(rawId)
        if q > 0 and nid then
            sum = sum + (LootValueCopper(nid, q))
        end
    end
    return sum
end

local function ComputeSessionEfficiencyText(events)
    if type(events) ~= "table" or #events < 1 then
        return nil
    end
    local newestT = tonumber(events[1] and events[1].t) or time()
    local oldestT = newestT
    local qty = 0
    local valueCopper = 0
    for i = 1, #events do
        local e = events[i]
        if e then
            local q = math.max(0, tonumber(e.qty) or 0)
            qty = qty + q
            local nid = tonumber(e.itemID)
            if q > 0 and nid then
                local _, net = LootValueCopper(nid, q)
                valueCopper = valueCopper + net
            end
            local et = tonumber(e.t)
            if et and et < oldestT then
                oldestT = et
            end
        end
    end
    if qty <= 0 then
        return nil
    end
    --- Under a minute of span extrapolates absurd rates — show none until there is one.
    local spanSec = newestT - oldestT
    if spanSec < 60 then
        return nil
    end
    local hours = spanSec / 3600
    local iph = qty / hours
    local goldText = FormatCopper and FormatCopper(math.floor(valueCopper / hours), 12) or nil
    if goldText then
        return string.format(LT("LOOT_EFFICIENCY_NET_SHORT_FMT", "Rate: %.1f items/hr • %s/hr net"), iph, goldText)
    end
    return string.format(LT("LOOT_EFFICIENCY_ITEMS_FMT", "Rate: %.1f items/hr"), iph)
end

--- Session rate from the active-time clock (idle gaps > 5 min excluded) over ALL session
--- pickups of the tab, valued net of the AH cut. Falls back to the recent-pickups rate when
--- the clock has under a minute of active time.
local function ComputeSessionRateText(tabKey, sessionTotals, recentEvents)
    local svc = ns.SessionLootService
    local clock = svc and svc.GetSessionClock and svc:GetSessionClock(tabKey)
    local active = clock and tonumber(clock.active) or 0
    if active < 60 or type(sessionTotals) ~= "table" then
        return ComputeSessionEfficiencyText(recentEvents)
    end
    local qty, net = 0, 0
    for rawId, q in pairs(sessionTotals) do
        q = tonumber(q) or 0
        local nid = tonumber(rawId)
        if q > 0 and nid then
            qty = qty + q
            local _, n = LootValueCopper(nid, q)
            net = net + n
        end
    end
    if qty <= 0 then
        return nil
    end
    local hours = active / 3600
    local iph = qty / hours
    local goldText = FormatCopper and FormatCopper(math.floor(net / hours), 12) or nil
    if goldText then
        return string.format(LT("LOOT_EFFICIENCY_NET_FMT", "Rate: %.1f items/hr • %s/hr net (%d min active)"),
            iph, goldText, math.floor(active / 60))
    end
    return string.format(LT("LOOT_EFFICIENCY_ITEMS_FMT", "Rate: %.1f items/hr"), iph)
end

--- Top-level tab template; rendered set is filtered by owned professions.
local TAB_ORDER = { "fishing", "herb", "mine", "leather", "disenchant", "others", "crafted" }

local function GetOwnedTabMap()
    local U = ns
    local herb = U.PlayerOwnsHerbalism and U.PlayerOwnsHerbalism() or false
    local mine = U.PlayerOwnsMining and U.PlayerOwnsMining() or false
    local fishing = U.PlayerOwnsFishing and U.PlayerOwnsFishing() or false
    if not fishing then
        --- Fishing API can fail to report on some clients; show the tab whenever the module is
        --- enabled so reset actions don't make the tab vanish.
        local profile = ns.db and ns.db.profile
        local modEnabled = not (profile and profile.modulesEnabled and profile.modulesEnabled.fishing == false)
        if modEnabled then
            fishing = true
        end
    end
    local leather = U.PlayerOwnsLeatherTabProfessions and U.PlayerOwnsLeatherTabProfessions() or false
    local disenchant = U.PlayerOwnsEnchanting and U.PlayerOwnsEnchanting() or false
    local owned = {
        fishing = fishing,
        herb = herb,
        mine = mine,
        leather = leather,
        disenchant = disenchant,
    }
    --- "Others": shared motes / non-primary-tab mats.
    if herb or mine or leather or disenchant then
        owned.others = true
    end
    --- Craft outputs: always available (not a gathering catalog tab).
    owned.crafted = true
    return owned
end

--- Crafted "last pickups": one row per craft operation from the craft ledger (this character, since
--- the crafted session started), so each row carries its realized profit and proc breakdown
--- (CraftLedgerService:Breakdown). nil when the ledger is unavailable (falls back to loot events).
local function CraftedLedgerEvents(svc)
    local ledger = ns.CraftLedgerService
    if not (ledger and ledger.GetCraftsSince) then
        return nil
    end
    local guid = ns.Utilities and ns.Utilities.GetCharacterGUID and ns.Utilities:GetCharacterGUID() or nil
    local cap = svc.GetMaxRecentLoot and svc:GetMaxRecentLoot() or 15
    local rows = ledger:GetCraftsSince(svc.craftedSince or 0, guid, cap)
    local now, nowT = GetTime(), time()
    local out = {}
    for i = 1, #rows do
        local r = rows[i]
        local first = r.outputs and r.outputs[1]
        if first and first.itemID then
            local qty = 0
            for _, o in ipairs(r.outputs) do qty = qty + (tonumber(o.qty) or 0) end
            out[#out + 1] = {
                itemID = first.itemID, qty = qty, spellID = r.spellID, profession = r.profession,
                t = r.t, rt = now - (nowT - (tonumber(r.t) or nowT)), ledger = r,
            }
        end
    end
    return out
end

local function BuildCraftedCatalogEntries(totals)
    local entries = {}
    if type(totals) ~= "table" then
        return entries
    end
    for itemID, qty in pairs(totals) do
        local id = tonumber(itemID)
        local n = tonumber(qty)
        if id and n and n > 0 then
            entries[#entries + 1] = { id = id }
        end
    end
    table.sort(entries, function(a, b)
        local qa = totals[a.id] or totals[tostring(a.id)] or 0
        local qb = totals[b.id] or totals[tostring(b.id)] or 0
        return qa > qb
    end)
    return entries
end

local function GetVisibleTabOrder()
    local owned = GetOwnedTabMap()
    local out = {}
    for i = 1, #TAB_ORDER do
        local key = TAB_ORDER[i]
        if owned[key] then
            out[#out + 1] = key
        end
    end
    --- Minimal placeholder until SKILL_LINES_CHANGED / PLAYER_ENTERING_WORLD refreshes.
    if #out == 0 then
        out[1] = "fishing"
    end
    return out
end

local function IsValidTab(tab)
    local order = GetVisibleTabOrder()
    for i = 1, #order do
        if order[i] == tab then
            return true
        end
    end
    return false
end

local function NormalizeShowArg(which)
    if not which or which == "" then
        return nil
    end
    if which == "gathering" or which == "gather" or which == "herb" then
        return "herb"
    end
    if which == "fish" or which == "fishing" then
        return "fishing"
    end
    if which == "mine" or which == "mining" or which == "ore" then
        return "mine"
    end
    if which == "leather" or which == "skinning" or which == "skin" then
        return "leather"
    end
    if which == "disenchant" or which == "de" or which == "enchant" or which == "enchanting" then
        return "disenchant"
    end
    if which == "others" or which == "other" or which == "shared" or which == "mote" then
        return "others"
    end
    if IsValidTab(which) then
        return which
    end
    return nil
end

local function Draw()
    return ns.LootHistoryUIDraw
end

local function AW()
    return ns.ArtisanWindow
end

---@class LootHistoryUI
local LootHistoryUI = {
    main = nil,
    activeTab = "fishing",
    --- "session" = in-memory (resets on login/manual); "overall" = persisted db.global
    activeMode = "session",
    tabBar = nil,
    modeBar = nil,
    catalogVp = nil,
    sessionVp = nil,
    catalogContent = nil,
    sessionContent = nil,
    footerStatus = nil,
    resetBtn = nil,
    overloadTrackerBtn = nil,
    lootOverlayBtn = nil,
    --- Draw checks this to pause the pickup pulse (kept for the Draw OnUpdate contract).
    _pauseLootFx = false,
}

-- ── Sub-tab bars ──

--- Re-wrap a ns.UI_CreateSubTabBar for the visible keys and current width (same row-wrap rule
--- as UI_CreateSubTabBar's wrapRows; the bar keeps every button, hidden ones are skipped).
local function ReflowSubTabBar(bar, keys, maxW)
    if not bar or not bar.buttons then return end
    for _, btn in pairs(bar.buttons) do
        btn:Hide()
    end
    local x, row = 0, 0
    for i = 1, #keys do
        local btn = bar.buttons[keys[i]]
        if btn then
            local bw = btn:GetWidth() or 0
            if maxW and maxW > 0 and x + bw > maxW and x > 0 then
                x = 0
                row = row + 1
            end
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", btn:GetParent(), "TOPLEFT", x, -(row * (TAB_BTN_H + TAB_BTN_GAP)))
            btn:Show()
            x = x + bw + TAB_BTN_GAP
        end
    end
    bar:SetHeight((row + 1) * TAB_BTN_H + row * TAB_BTN_GAP)
end

local function CreateBar(parent, tabs, activeKey, onSelect)
    return ns.UI_CreateSubTabBar(parent, {
        tabs = tabs,
        activeKey = activeKey,
        onSelect = onSelect,
        wrapRows = true,
        btnHeight = TAB_BTN_H,
        btnSpacing = TAB_BTN_GAP,
        iconLeft = TAB_PAD_H,
        textRight = TAB_PAD_H,
        activeBarInset = 4,
        activeBarBottom = 2,
    })
end

local function BodyWidth()
    local f = LootHistoryUI.main
    local ca = f and f.contentArea
    local w = ca and ca:GetWidth() or 0
    if w < 1 and f then
        w = (f:GetWidth() or WIN_W) - 2 * ((AW() and AW().PADDING) or 10)
    end
    return w
end

function LootHistoryUI:LayoutTabs()
    if not self.main then return end
    local w = BodyWidth()
    ReflowSubTabBar(self.tabBar, GetVisibleTabOrder(), w)
    ReflowSubTabBar(self.modeBar, { "session", "overall" }, w)
end

--- Pickup list height follows the window height; the catalog takes the rest.
function LootHistoryUI:LayoutBody()
    if not self.main or not self.sessionVp then return end
    local fh = self.main:GetHeight() or WIN_H
    self.sessionVp.shell:SetHeight(math.max(SESSION_MIN_H, math.floor(fh * SESSION_FRAC)))
    self:LayoutTabs()
    local W = AW()
    W.SyncScrollChildWidth(self.catalogVp)
    W.SyncScrollChildWidth(self.sessionVp)
end

-- ── Header toggles ──

--- Dim the overlay toast toggle when the floating overlay is off.
function LootHistoryUI:UpdateLootOverlayToggle()
    local b = self.lootOverlayBtn
    if not b then
        return
    end
    local on = ns.db and ns.db.profile and ns.db.profile.sessionLootOverlayEnabled == true
    b:SetAlpha(on and 1 or 0.45)
end

--- Overload HUD toggle: hidden unless Herbalism or Mining; dimmed while the HUD is off.
function LootHistoryUI:UpdateOverloadTrackerToggle()
    local b = self.overloadTrackerBtn
    if not b then
        return
    end
    local U = ns.Utilities
    local owns = (U and U.PlayerOwnsAnyOverloadTrackerProfession and U.PlayerOwnsAnyOverloadTrackerProfession()) and true or false
    if owns ~= b:IsShown() then
        b:SetShown(owns)
        AW().LayoutHeaderButtons(self.main)
    end
    if not owns then
        return
    end
    local on = ns.db and ns.db.profile and ns.db.profile.overloadTrackerHudEnabled ~= false
    b:SetAlpha(on and 1 or 0.45)
end

-- ── Tab / mode visuals ──

--- Active tab + "other tab just got loot" attention (gold border + text on that tab).
function LootHistoryUI:RefreshTabButtonVisuals()
    local bar = self.tabBar
    if not bar then return end
    bar:SetActiveTab(self.activeTab)
    local svc = ns.SessionLootService
    if not (svc and svc.IsTabAttentionActive) then return end
    for key, btn in pairs(bar.buttons) do
        if key ~= self.activeTab and btn:IsShown() and svc:IsTabAttentionActive(key) then
            local r, g, b = 1, 0.82, 0
            if ns.UI_GetSemanticGoldColor then r, g, b = ns.UI_GetSemanticGoldColor() end
            if ns.UI_UpdateBorderColor and not btn._wnBlizzardButton then
                ns.UI_UpdateBorderColor(btn, { r, g, b, 1 })
            end
            if btn._text then
                btn._text:SetTextColor(r, g, b)
            end
        end
    end
end

local function SetButtonLabel(btn, text)
    if btn.text then
        btn.text:SetText(text)
        btn:SetWidth(math.max(RESET_BTN_W, (btn.text:GetStringWidth() or 0) + 20))
    elseif btn.SetText then
        btn:SetText(text)
    end
end

function LootHistoryUI:RefreshModeButtonVisuals()
    if self.modeBar then
        self.modeBar:SetActiveTab(self.activeMode)
    end
    if self.resetBtn then
        if self.activeMode == "overall" then
            SetButtonLabel(self.resetBtn, LT("LOOT_RESET_OVERALL", "Reset overall"))
        else
            SetButtonLabel(self.resetBtn, LT("LOOT_RESET_SESSION", "Reset session"))
        end
    end
end

-- ── Paint ──

--- Catalog reference glow fade only — no list rebuild (hot path during gathering).
function LootHistoryUI:RefreshCatalogGlowsOnly()
    if not self.main or not self.main:IsShown() or self._pauseLootFx then
        return
    end
    local D = Draw()
    if D and D.RefreshCatalogGlowStrengths and self.catalogContent then
        D.RefreshCatalogGlowStrengths(self.catalogContent, self.activeTab)
    end
end

function LootHistoryUI:ScheduleDeferredRefresh()
    if self._deferLootRefresh or not (C_Timer and C_Timer.After) then
        return
    end
    self._deferLootRefresh = true
    C_Timer.After(0, function()
        self._deferLootRefresh = nil
        if self.main and self.main:IsShown() then
            self:LayoutBody()
            self:Refresh()
        end
    end)
end

function LootHistoryUI:Refresh()
    if not self.main or not self.catalogContent or not self.sessionContent then return end
    local D = Draw()
    if not D then return end
    if not IsValidTab(self.activeTab) then
        self.activeTab = GetVisibleTabOrder()[1] or "fishing"
    end

    local isOverall = self.activeMode == "overall"
    local svc = ns.SessionLootService
    local entries
    if self.activeTab == "fishing" then
        entries = (ns.GetFishingCatalogEntries and ns.GetFishingCatalogEntries()) or {}
    elseif self.activeTab == "crafted" then
        entries = {}
    else
        entries = (ns.GetGatheringCatalogByCategory and ns.GetGatheringCatalogByCategory(self.activeTab)) or {}
    end

    --- Catalog: Session vs Overall totals. Last pickups: always the session event list.
    local totals, events = {}, {}
    if svc then
        if self.activeTab == "fishing" then
            totals = svc:GetItemTotals("fishing", nil, isOverall) or {}
            events = svc:GetRecentEvents("fishing", nil, false) or {}
        elseif self.activeTab == "crafted" then
            totals = svc:GetItemTotals("crafted", nil, isOverall) or {}
            events = CraftedLedgerEvents(svc) or svc:GetRecentEvents("crafted", nil, false) or {}
            entries = BuildCraftedCatalogEntries(totals)
        else
            totals = svc:GetItemTotals("gathering", self.activeTab, isOverall) or {}
            events = svc:GetRecentEvents("gathering", self.activeTab, false) or {}
        end
    end
    if self.activeTab == "fishing" and type(entries) == "table" then
        entries = D.SortFishingCatalogEntries(entries, totals)
    end
    if self.catalogTotalLabel then
        self.catalogTotalLabel:SetFormattedText(LT("LOOT_SECTION_TOTAL_GROSS_FMT", "Total (gross): %s"),
            FormatGross(ComputeTotalsCopper(totals)))
    end

    D.ReleaseContent(self.catalogContent)
    D.ReleaseContent(self.sessionContent)
    self:LayoutBody()

    local W = AW()
    local cw = W.SyncScrollChildWidth(self.catalogVp)
    D.PopulateCatalog(self.catalogContent, entries, totals, self.activeTab, math.max(80, cw))

    local sw = W.SyncScrollChildWidth(self.sessionVp)
    if sw < 80 then sw = 280 end
    self.sessionContent:SetWidth(sw)
    local cap = GetLastLootListCap()
    if self.sessionSectionLabel then
        if isOverall then
            self.sessionSectionLabel:SetText(LT("LOOT_CHAR_VALUE_HEADER", "Value by character (gross)"))
        else
            self.sessionSectionLabel:SetFormattedText(LT("LOOT_SECTION_SESSION_FMT", "Last %d pickups"), cap)
        end
    end
    --- One empty message per window: an empty catalog already says so (its pickups are empty too).
    local emptyLastPickups = false
    if #entries > 0 then
        if self.activeTab == "crafted" then
            emptyLastPickups = LT("LOOT_CRAFTED_EMPTY", "Nothing crafted yet.")
        else
            emptyLastPickups = LT("LOOT_LAST_PICKUPS_EMPTY", "No recent pickups yet.")
        end
    end
    --- Overall mode: per-character gross value of THIS tab above the pickup list.
    local startY = 0
    if isOverall and svc and svc.GetPerCharacterEarnings then
        startY = D.PopulateCharEarnings(self.sessionContent, svc:GetPerCharacterEarnings(self.activeTab)) or 0
    end
    D.PopulateSessionList(self.sessionContent, events, entries, cap, emptyLastPickups, self.activeTab, startY,
        { contentWidth = sw })
    W.SyncScroll(self.catalogVp)
    W.SyncScroll(self.sessionVp)
    if cw < 80 then
        self:ScheduleDeferredRefresh()
    end

    if self.footerStatus then
        local sessionTotals = totals
        if isOverall and svc then
            if self.activeTab == "fishing" then
                sessionTotals = svc:GetItemTotals("fishing", nil, false) or {}
            elseif self.activeTab == "crafted" then
                sessionTotals = svc:GetItemTotals("crafted", nil, false) or {}
            else
                sessionTotals = svc:GetItemTotals("gathering", self.activeTab, false) or {}
            end
        end
        self.footerStatus:SetText(ComputeSessionRateText(self.activeTab, sessionTotals, events) or "")
    end

    self:RefreshTabButtonVisuals()
    self:RefreshModeButtonVisuals()
    self:UpdateOverloadTrackerToggle()
    self:UpdateLootOverlayToggle()
end

--- Theme / font switch (PlansTrackerWindow.lua:2807-2844): re-skin the shell, then repaint.
function LootHistoryUI:RefreshTheme()
    if not self.main then
        return
    end
    AW().RefreshChrome(self.main)
    local D = Draw()
    if D and D.RestyleContent then
        D.RestyleContent(self.catalogContent)
        D.RestyleContent(self.sessionContent)
    end
    if self.catalogSectionLabel then ns.UI_SetTextColorRole(self.catalogSectionLabel, "Bright") end
    if self.catalogTotalLabel then ns.UI_SetTextColorRole(self.catalogTotalLabel, "Normal") end
    if self.sessionSectionLabel then ns.UI_SetTextColorRole(self.sessionSectionLabel, "Bright") end
    if self.footerStatus then ns.UI_SetTextColorRole(self.footerStatus, "Dim") end
    if self.main:IsShown() then
        self:Refresh()
    end
end

function LootHistoryUI:SetMode(mode)
    if mode ~= "session" and mode ~= "overall" then return end
    self.activeMode = mode
    self:Refresh()
end

---@param tab "fishing"|"herb"|"mine"|"leather"|"disenchant"|"others"|"crafted"
function LootHistoryUI:SetTab(tab)
    if not IsValidTab(tab) then
        return
    end
    self.activeTab = tab
    if ns.db and ns.db.profile then
        ns.db.profile.lootHistoryActiveTab = tab
    end
    if ns.SessionLootService and ns.SessionLootService.ClearTabAttentionForTab then
        ns.SessionLootService:ClearTabAttentionForTab(tab)
    end
    self:Refresh()
end

function LootHistoryUI:IsValidTab(tab)
    return IsValidTab(tab)
end

function LootHistoryUI:GetVisibleTabOrder()
    return GetVisibleTabOrder()
end

-- ── Reset (footer) ──

local function OnResetClick()
    local svc = ns.SessionLootService
    if not svc then
        return
    end
    local self = LootHistoryUI
    local tab = self.activeTab
    local tabName = ns.GetGatheringTabDisplayName(tab)
    local yes = LT("YES_RESET", "Yes, Reset")
    if self.activeMode == "overall" then
        --- Persisted history cannot be restored.
        AW().Confirm(string.format(LT("LOOT_RESET_OVERALL_CONFIRM",
            "Delete saved overall loot history for %s? This cannot be undone."), tabName), yes, function()
            if tab == "fishing" or tab == "crafted" then
                svc:ResetOverall(tab)
            else
                svc:ResetOverall("gathering", tab)
            end
            self:Refresh()
        end)
    else
        AW().Confirm(string.format(LT("LOOT_RESET_SESSION_CONFIRM", "Clear this session's loot for %s?"), tabName),
            yes, function()
                svc:ResetSessionForTab(tab)
                self:Refresh()
            end)
    end
end

local function ResetTooltipOnEnter(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
    if LootHistoryUI.activeMode == "overall" then
        GameTooltip:SetText(LT("LOOT_RESET_OVERALL_TT", "Permanently deletes saved history for this tab."), 1, 1, 1, 1, true)
    else
        GameTooltip:SetText(LT("LOOT_RESET_SESSION_TT", "Clears this tab's session loot. History is kept."), 1, 1, 1, 1, true)
    end
    GameTooltip:Show()
end

-- ── Build ──

--- Build the window once (hidden); Show presents it.
function LootHistoryUI:Build()
    local W = AW()
    local live = 0
    local f = W.Create({
        name = "ArtisanNexusLootHistoryFrame",
        title = LT("HUB_RAIL_SESSION_LOOT", "Session Loot"),
        posKey = "lootHistoryFrame",
        width = WIN_W,
        height = WIN_H,
        minW = MIN_W,
        minH = MIN_H,
        maxW = MAX_W,
        maxH = MAX_H,
        tileSiblings = true,
        -- Live drag: cheap reflow only; the repaint is debounced (PlansTrackerWindow.lua:2636-2676).
        onLive = function()
            LootHistoryUI:LayoutBody()
            live = live + 1
            local token = live
            if C_Timer and C_Timer.After then
                C_Timer.After(0.15, function()
                    if token == live and LootHistoryUI.main and LootHistoryUI.main:IsShown() then
                        LootHistoryUI:Refresh()
                    end
                end)
            end
        end,
        onCommit = function()
            live = live + 1
            LootHistoryUI:LayoutBody()
            if LootHistoryUI.main:IsShown() then
                LootHistoryUI:Refresh()
            end
        end,
    })
    self.main = f

    -- Header (right to left): close, settings, Artisan Hub, Recipe Matcher, loot overlay toggle,
    -- overload tracker toggle (Herbalism / Mining only).
    W.AddHeaderButton(f, {
        icon = "settings",
        tooltip = LT("SETTINGS_TAB_TITLE", SETTINGS or "Settings"),
        onClick = function()
            ns.OpenAddonSettings()
        end,
    })
    W.AddHeaderButton(f, {
        texture = "Interface\\AddOns\\ArtisanNexus\\Media\\anlogo",
        tooltip = LT("HUB_WINDOW_TITLE", "Artisan Hub"),
        desc = LT("LOOT_OPEN_HUB_DESC", "Profit, queue, orders, market and ledger."),
        onClick = function()
            W.ShowHubBeside(f)
        end,
    })
    W.AddHeaderButton(f, {
        texture = "Interface\\Icons\\INV_Misc_Book_09",
        tooltip = LT("HUB_RAIL_RECIPE_MATCHER", "Recipe Matcher"),
        desc = LT("LOOT_OPEN_RECIPES_DESC", "Recipes craftable from your bags."),
        onClick = function()
            if ns.RecipeMatcherUI then
                ns.RecipeMatcherUI:Show({ tileAfter = f })
            end
        end,
    })
    self.lootOverlayBtn = W.AddHeaderButton(f, {
        texture = "Interface\\Icons\\INV_Misc_Note_06",
        tooltip = LT("LOOT_OVERLAY_BTN", "Loot pickup overlay"),
        desc = LT("LOOT_OVERLAY_BTN_DESC", "Toggle loot toasts."),
        onClick = function()
            if ns.SessionLootOverlayUI and ns.SessionLootOverlayUI.Toggle then
                ns.SessionLootOverlayUI:Toggle()
            end
            LootHistoryUI:UpdateLootOverlayToggle()
        end,
    })
    self.overloadTrackerBtn = W.AddHeaderButton(f, {
        texture = "Interface\\Icons\\Spell_Shaman_StaticShock",
        tooltip = LT("LOOT_OVERLOAD_TRACKER_BTN", "Overload Tracker"),
        desc = LT("LOOT_OVERLOAD_TRACKER_BTN_DESC",
            "Floating overload cooldown. Needs Herbalism or Mining."),
        onClick = function()
            local p = ns.db and ns.db.profile
            if not p then
                return
            end
            p.overloadTrackerHudEnabled = not (p.overloadTrackerHudEnabled ~= false)
            if ns.GatheringOverloadIndicator and ns.GatheringOverloadIndicator.RefreshTracker then
                ns.GatheringOverloadIndicator:RefreshTracker()
            end
            LootHistoryUI:UpdateOverloadTrackerToggle()
            if ns.RefreshAddonSettings then
                ns.RefreshAddonSettings()
            end
        end,
    })

    local ca = f.contentArea

    -- Profession tabs + Session / Overall switch (WN sub-tab bars).
    local tabs = {}
    for i = 1, #TAB_ORDER do
        local key = TAB_ORDER[i]
        tabs[i] = { key = key, label = ns.GetGatheringTabDisplayName(key), hideIcon = true }
    end
    local tabBar = CreateBar(ca, tabs, self.activeTab, function(key)
        LootHistoryUI:SetTab(key)
    end)
    tabBar:SetPoint("TOPLEFT", ca, "TOPLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", ca, "TOPRIGHT", 0, 0)
    self.tabBar = tabBar

    local modeBar = CreateBar(ca, {
        { key = "session", label = LT("LOOT_MODE_SESSION", "Session"), hideIcon = true },
        { key = "overall", label = LT("LOOT_MODE_OVERALL", "Overall"), hideIcon = true },
    }, self.activeMode, function(key)
        LootHistoryUI:SetMode(key)
    end)
    modeBar:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -BLOCK_GAP)
    modeBar:SetPoint("TOPRIGHT", tabBar, "BOTTOMRIGHT", 0, -BLOCK_GAP)
    self.modeBar = modeBar

    -- Catalog heading: "Catalog" left, gross total right.
    local refRow = CreateFrame("Frame", nil, ca)
    refRow:SetHeight(SECTION_ROW_H)
    refRow:SetPoint("TOPLEFT", modeBar, "BOTTOMLEFT", 0, -BLOCK_GAP)
    refRow:SetPoint("TOPRIGHT", modeBar, "BOTTOMRIGHT", 0, -BLOCK_GAP)
    local FM = ns.FontManager
    local labTotal = FM:CreateFontString(refRow, "body", "OVERLAY")
    labTotal:SetPoint("RIGHT", refRow, "RIGHT", 0, 0)
    labTotal:SetJustifyH("RIGHT")
    ns.UI_SetTextColorRole(labTotal, "Normal")
    labTotal:SetFormattedText(LT("LOOT_SECTION_TOTAL_GROSS_FMT", "Total (gross): %s"), FormatGross(0))
    self.catalogTotalLabel = labTotal
    local labRef = FM:CreateFontString(refRow, "subtitle", "OVERLAY")
    labRef:SetPoint("LEFT", refRow, "LEFT", 0, 0)
    labRef:SetPoint("RIGHT", labTotal, "LEFT", -8, 0)
    labRef:SetJustifyH("LEFT")
    labRef:SetWordWrap(false)
    labRef:SetText(LT("LOOT_SECTION_REFERENCE", "Catalog"))
    ns.UI_SetTextColorRole(labRef, "Bright")
    self.catalogSectionLabel = labRef

    -- Footer: small reset button (left) + session rate status (right).
    local footer = CreateFrame("Frame", nil, ca)
    footer:SetPoint("BOTTOMLEFT", ca, "BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", ca, "BOTTOMRIGHT", -FOOTER_RIGHT_RESERVE, 0)
    local resetBtn = ns.UI_CreateThemedButton(footer, LT("LOOT_RESET_SESSION", "Reset session"), RESET_BTN_W)
    resetBtn:SetPoint("BOTTOMLEFT", footer, "BOTTOMLEFT", 0, 0)
    resetBtn:SetScript("OnClick", OnResetClick)
    resetBtn:HookScript("OnEnter", ResetTooltipOnEnter)
    resetBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    footer:SetHeight(resetBtn:GetHeight() or 32)
    self.resetBtn = resetBtn
    local status = FM:CreateFontString(footer, "small", "OVERLAY")
    status:SetPoint("LEFT", resetBtn, "RIGHT", BLOCK_GAP, 0)
    status:SetPoint("RIGHT", footer, "RIGHT", 0, 0)
    status:SetJustifyH("RIGHT")
    status:SetWordWrap(false)
    status:SetMaxLines(1)
    ns.UI_SetTextColorRole(status, "Dim")
    self.footerStatus = status

    -- Pickup list viewport (fixed share of the height) + its heading.
    local sesVp = W.CreateScrollViewport(f, ca)
    sesVp.shell:SetPoint("BOTTOMLEFT", footer, "TOPLEFT", 0, BLOCK_GAP)
    sesVp.shell:SetPoint("RIGHT", ca, "RIGHT", 0, 0)
    sesVp.shell:SetHeight(SESSION_MIN_H)
    self.sessionVp = sesVp
    self.sessionContent = sesVp.scrollChild

    local sessionRow = CreateFrame("Frame", nil, ca)
    sessionRow:SetHeight(SECTION_ROW_H)
    sessionRow:SetPoint("BOTTOMLEFT", sesVp.shell, "TOPLEFT", 0, 2)
    sessionRow:SetPoint("BOTTOMRIGHT", sesVp.shell, "TOPRIGHT", 0, 2)
    local labSes = FM:CreateFontString(sessionRow, "subtitle", "OVERLAY")
    labSes:SetPoint("LEFT", sessionRow, "LEFT", 0, 0)
    labSes:SetPoint("RIGHT", sessionRow, "RIGHT", 0, 0)
    labSes:SetJustifyH("LEFT")
    labSes:SetWordWrap(false)
    labSes:SetMaxLines(1)
    ns.UI_SetTextColorRole(labSes, "Bright")
    self.sessionSectionLabel = labSes

    -- Catalog viewport fills the band between its heading and the pickup heading.
    local catVp = W.CreateScrollViewport(f, ca)
    catVp.shell:SetPoint("TOPLEFT", refRow, "BOTTOMLEFT", 0, -2)
    catVp.shell:SetPoint("TOPRIGHT", refRow, "BOTTOMRIGHT", 0, -2)
    catVp.shell:SetPoint("BOTTOM", sessionRow, "TOP", 0, BLOCK_GAP)
    self.catalogVp = catVp
    self.catalogContent = catVp.scrollChild

    self:LayoutBody()
end

--- Restore the saved size / anchor (profile.lootHistoryFrame) — profile switch.
function LootHistoryUI:ApplySavedFrameSize(f)
    f = f or self.main
    if not f then
        return
    end
    if not AW().RestorePosition(f) then
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    self:LayoutBody()
end

--- Open the Session Loot window (open world only; elsewhere a chat line says why).
---@param which string|nil tab key or alias ("herb", "fishing", "crafted", ...)
---@param opts table|nil `{ tileAfter = Frame }`: the window this was opened from stays open and
---   the Session Loot window tiles beside it when the screen has room.
function LootHistoryUI:Show(which, opts)
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        if self.main and self.main:IsShown() then
            self.main:Hide()
        end
        ArtisanNexus:Print(LT("LOOT_OPEN_WORLD_ONLY", "Session Loot is available in the open world only."))
        return
    end
    local w = NormalizeShowArg(which)
    if w then
        local pick = IsValidTab(w) and w or GetVisibleTabOrder()[1]
        self.activeTab = pick
        if ns.db and ns.db.profile then
            ns.db.profile.lootHistoryActiveTab = pick
        end
    end
    if not self.main then
        self:Build()
        if not self.main then return end
    end
    AW().Present(self.main, opts)
    self:LayoutBody()
    self:Refresh()
    self:ScheduleDeferredRefresh()
end

function LootHistoryUI:Hide()
    if self.main then
        self.main:Hide()
    end
end

function LootHistoryUI:Toggle()
    if self.main and self.main:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

ns.LootHistoryUI = LootHistoryUI
