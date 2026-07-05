--[[
    Session loot: per-tab catalog (Session vs Overall totals) + Last N pickups (always in-memory session feed).
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local L = ns.L
local E = ns.Constants.EVENTS

local COLORS = ns.UI_COLORS
local LAYOUT = ns.UI_LAYOUT
local ApplyPanelBackdrop = ns.UI_ApplyPanelBackdrop
local ApplyVisuals = ns.UI_ApplyVisuals

local PAD = LAYOUT.BASE_INDENT or 12
local LOOT_TAB_H = LAYOUT.SHELL_TAB_HEIGHT or 30
local LOOT_TAB_GAP = 5
local LOOT_TAB_BAR_H = LOOT_TAB_H + 4
local LOOT_MIN_W = LAYOUT.LOOT_FRAME_MIN_WIDTH or 340
local LOOT_MIN_H = LAYOUT.LOOT_FRAME_MIN_HEIGHT or 420
local LOOT_MAX_W = LAYOUT.LOOT_FRAME_MAX_WIDTH or 900
local LOOT_MAX_H = LAYOUT.LOOT_FRAME_MAX_HEIGHT or 900
local LOOT_SCROLL_PAD = 6

local function LootScrollReserve()
    return (LAYOUT.SCROLLBAR_COLUMN_WIDTH or 26) + (LAYOUT.SCROLL_GAP or 2)
end

local function LootScrollAttachOpts(host)
    local pad = 4
    return ns.UI_BuildExternalScrollOpts(host, {
        padL = pad,
        padT = -pad,
        padR = pad,
        padB = pad,
        topInset = 0,
        bottomInset = 0,
    })
end

local function ApplyLootInsetToHost(panel, host)
    if not panel or not host then
        return
    end
    local reserve = LootScrollReserve()
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    panel:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)
    panel:SetPoint("TOPRIGHT", host, "TOPRIGHT", -reserve, 0)
    panel:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -reserve, 0)
    panel:SetClipsChildren(true)
    host:SetClipsChildren(true)
end

local function GetLastLootListCap()
    local s = ns.SessionLootService
    if s and s.GetMaxRecentLoot then
        return s:GetMaxRecentLoot()
    end
    return 15
end

local function OpenAddonSettings()
    if ns.OpenAddonSettings then
        ns.OpenAddonSettings()
        return
    end
    ArtisanNexus:Print((L and L["SETTINGS_UI_UNAVAILABLE"]) or "Settings UI is not available.")
end

--- Shared money / unit-price helpers (Modules/Utilities.lua; loads before this file per TOC).
local FormatCopper = ns.FormatCopper
local LootUnitCopper = ns.GetLootUnitCopperWithFallback

--- Overall grid “Total” and per-row value = Σ(qty × **current** AH unit from `ahPrices`). Counts stay historical; gold revalues when AH sync updates prices (mark-to-market).
local function ComputeTotalsCopper(totals)
    local sum = 0
    if type(totals) ~= "table" then
        return 0
    end
    for rawId, qty in pairs(totals) do
        local q = tonumber(qty) or 0
        --- SavedVariables / DB pairs may use string keys — normalize before price lookup.
        local itemID = tonumber(rawId) or rawId
        local nid = tonumber(itemID)
        local unit = nid and LootUnitCopper(nid) or nil
        if q > 0 and unit and unit > 0 then
            sum = sum + (q * unit)
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
    for i = 1, #events do
        local e = events[i]
        if e then
            qty = qty + math.max(0, tonumber(e.qty) or 0)
            local et = tonumber(e.t)
            if et and et < oldestT then
                oldestT = et
            end
        end
    end
    if qty <= 0 then
        return nil
    end
    --- A span under a minute (single pickup: span 0) produces absurd
    --- extrapolations like "3600 items/hr" — show no rate until there is one.
    local spanSec = newestT - oldestT
    if spanSec < 60 then
        return nil
    end
    local iph = qty / (spanSec / 3600)
    return string.format("Rate: %.1f items/hr", iph)
end

--- Top-level tab template; rendered set is filtered by owned professions (same `GetProfessions` scan as Utilities).
local TAB_ORDER = { "fishing", "herb", "mine", "leather", "disenchant", "others", "crafted" }

local function GetOwnedTabMap()
    local U = ns
    local herb = U.PlayerOwnsHerbalism and U.PlayerOwnsHerbalism() or false
    local mine = U.PlayerOwnsMining and U.PlayerOwnsMining() or false
    local fishing = U.PlayerOwnsFishing and U.PlayerOwnsFishing() or false
    --- Fishing tab should remain accessible when profession APIs fail to report secondary lines on some clients.
    --- If module is enabled and we have any fishing history/events, force the tab visible.
    if not fishing then
        --- Fishing API can fail to report on some clients; show the tab whenever the module is enabled
        --- so reset actions don't make the tab vanish (overall/session counts can drop to zero).
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
    --- "Others": shared motes / non-primary-tab mats; same gate as before (no fishing-only requirement).
    if herb or mine or leather or disenchant then
        owned.others = true
    end
    --- Craft outputs: always available when Session loot is enabled (not a gathering catalog tab).
    owned.crafted = true
    return owned
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
            entries[#entries + 1] = { itemID = id }
        end
    end
    table.sort(entries, function(a, b)
        return (totals[a.itemID] or 0) > (totals[b.itemID] or 0)
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
    --- Never show every tab when detection fails — that hides the intended profession filter.
    --- Minimal placeholder until SKILL_LINES_CHANGED / PLAYER_ENTERING_WORLD refreshes (`LayoutTabs`).
    if #out == 0 then
        out[1] = "fishing"
    end
    return out
end

--- Forward declaration: Lua block scope begins here so closures above the table literal still close over this upvalue (not `_G.LootHistoryUI`).
local LootHistoryUI

local IsValidTab

---@class LootHistoryUI
LootHistoryUI = {
    main = nil,
    activeTab = "fishing",
    --- "session" = in-memory (resets on login/manual); "overall" = persisted db.global
    activeMode = "session",
    catalogContent = nil,
    sessionContent = nil,
    catalogScroll = nil,
    sessionScroll = nil,
    sessionPanel = nil,
    sessionEfficiencyLabel = nil,
    headerBar = nil,
    headerLogo = nil,
    tabBar = nil,
    tabButtons = {},
    modeBar = nil,
    modeButtons = {},
    resetRow = nil,
    resetSessionBtn = nil,
    resetText = nil,
    settingsBtn = nil,
    resizeGrip = nil,
    overloadTrackerBtn = nil,
    _sizeSaveTimer = nil,
    --- Grip `StartSizing` aktifken ağır `Refresh` atlanır (takılma önlemi); bırakınca bir kez tam yenileme.
    _isLootFrameSizing = false,
    --- Başlıktan taşırken katalog shimmer / tick işlerini hafiflet (FPS).
    _pauseLootFx = false,
    --- Canlı resize sırasında LayoutTabs sıklığını sınırla (son kare Finish’te tamamlanır).
    _nextLootTabLayoutTime = nil,
}

--- `hooksecurefunc("StopMovingOrSizing")` bazı istemcilerde yok / hata verir. LMB bırakılınca anket + grip MouseUp.
local function FinishLootFrameSizing()
    if LootHistoryUI.main then
        LootHistoryUI.main:SetScript("OnUpdate", nil)
    end
    if not LootHistoryUI._isLootFrameSizing then
        return
    end
    LootHistoryUI._isLootFrameSizing = false
    LootHistoryUI._pauseLootFx = false
    LootHistoryUI._nextLootTabLayoutTime = nil
    LootHistoryUI:LayoutTabs()
    LootHistoryUI:LayoutModeBtns()
    LootHistoryUI:SaveFrameSize()
    LootHistoryUI:Refresh()
end

local function LootFrameSizingPoll()
    if not LootHistoryUI._isLootFrameSizing then
        if LootHistoryUI.main then
            LootHistoryUI.main:SetScript("OnUpdate", nil)
        end
        return
    end
    if not IsMouseButtonDown("LeftButton") then
        FinishLootFrameSizing()
    end
end

local function ClearSubtreeScripts(frame)
    if not frame then
        return
    end
    frame:SetScript("OnUpdate", nil)
    local ch = { frame:GetChildren() }
    for i = 1, #ch do
        ClearSubtreeScripts(ch[i])
    end
end

local function ClearScrollContent(scroll, content)
    if not content then return end
    --- Pooled path: Draw releases its cells/rows/lines back into the pools
    --- kept on the content frame (frames are reused, never discarded — WoW
    --- never garbage-collects frames).
    local DrawMod = ns.LootHistoryUIDraw
    if DrawMod and DrawMod.ReleaseContent then
        DrawMod.ReleaseContent(content)
        return
    end
    --- Legacy fallback (Draw chunk missing): detach and discard.
    local regions = { content:GetRegions() }
    for i = 1, #regions do
        regions[i]:Hide()
        regions[i]:SetParent(nil)
    end
    local ch = { content:GetChildren() }
    for i = 1, #ch do
        ClearSubtreeScripts(ch[i])
        if ns.UI_UnregisterVisuals then
            ns.UI_UnregisterVisuals(ch[i])
        end
        ch[i]:Hide()
        ch[i]:SetParent(nil)
    end
end

local function GetLootFrameBounds()
    local Chrome = ns.LootHistoryUI_Chrome
    if Chrome and Chrome.GetFrameBounds then
        return Chrome.GetFrameBounds(LOOT_MIN_W, LOOT_MAX_W, LOOT_MIN_H, LOOT_MAX_H)
    end
    local p = UIParent
    local maxW, maxH = LOOT_MAX_W, LOOT_MAX_H
    if p and p.GetWidth and p.GetHeight then
        local pw = p:GetWidth() or 1200
        local ph = p:GetHeight() or 800
        maxW = math.min(LOOT_MAX_W, math.max(LOOT_MIN_W + 80, pw - 24))
        maxH = math.min(LOOT_MAX_H, math.max(LOOT_MIN_H + 80, ph - 24))
    end
    return maxW, maxH
end

function LootHistoryUI:ApplySavedFramePosition(f)
    if not f then
        return
    end
    local db = ns.db and ns.db.profile and ns.db.profile.lootHistoryFrame
    local point = db and db.point
    f:ClearAllPoints()
    if point and db.x ~= nil and db.y ~= nil then
        local relTo = UIParent
        local rn = db.relativeTo
        if rn and rn ~= "" and rn ~= "UIParent" then
            local rf = _G[rn]
            if rf and rf.IsShown then
                relTo = rf
            end
        end
        local rp = db.relativePoint or point
        f:SetPoint(point, relTo, rp, tonumber(db.x) or 0, tonumber(db.y) or 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

function LootHistoryUI:ApplySavedFrameSize(f)
    if not f then
        return
    end
    local db = ns.db and ns.db.profile and ns.db.profile.lootHistoryFrame
    local w = (db and db.width) or LAYOUT.WINDOW_WIDTH
    local h = (db and db.height) or LAYOUT.WINDOW_HEIGHT
    local maxW, maxH = GetLootFrameBounds()
    w = math.max(LOOT_MIN_W, math.min(maxW, w))
    h = math.max(LOOT_MIN_H, math.min(maxH, h))
    f:SetWidth(w)
    f:SetHeight(h)
    self:ApplySavedFramePosition(f)
end

function LootHistoryUI:SaveFrameSize()
    if not self.main or not ns.db or not ns.db.profile then
        return
    end
    ns.db.profile.lootHistoryFrame = ns.db.profile.lootHistoryFrame or {}
    local t = ns.db.profile.lootHistoryFrame
    t.width = self.main:GetWidth()
    t.height = self.main:GetHeight()
    local point, rel, relTo, x, y = self.main:GetPoint(1)
    if point then
        t.point = point
        t.relativePoint = rel or point
        t.x = math.floor((tonumber(x) or 0) + 0.5)
        t.y = math.floor((tonumber(y) or 0) + 0.5)
        if relTo and relTo.GetName then
            local nm = relTo:GetName()
            t.relativeTo = (nm and nm ~= "") and nm or "UIParent"
        else
            t.relativeTo = "UIParent"
        end
    end
end

local SESSION_FRAC = 0.34
--- Köşeden sürüklerken sekme yerleşimini en fazla bu sıklıkta yap (her pikselde ClearAllPoints olmaz).
local LOOT_LAYOUT_THROTTLE_SEC = 1 / 20

function LootHistoryUI:LayoutClassicShellBodyChrome()
    if not self.main or not self.tabBar then
        return
    end
    local classic = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    self.tabBar:ClearAllPoints()
    if classic and ns.UI_GetClassicShellContentTop then
        local top = ns.UI_GetClassicShellContentTop()
        self.tabBar:SetPoint("TOPLEFT", self.main, "TOPLEFT", PAD, -top)
        self.tabBar:SetPoint("TOPRIGHT", self.main, "TOPRIGHT", -PAD, -top)
    elseif self.headerBar then
        self.tabBar:SetPoint("TOPLEFT", self.headerBar, "BOTTOMLEFT", PAD, -6)
        self.tabBar:SetPoint("TOPRIGHT", self.headerBar, "BOTTOMRIGHT", -PAD, -6)
    end
end

function LootHistoryUI:LayoutLootScrollChrome()
    ApplyLootInsetToHost(self.catalogPanel, self.catalogHost)
    ApplyLootInsetToHost(self.sessionPanel, self.sessionHost)
    if self.catalogScroll and ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(self.catalogScroll)
    end
    if self.sessionScroll and ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(self.sessionScroll)
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() and ns.UI_ApplyClassicScrollBarLayout then
        if self.catalogScroll then
            ns.UI_ApplyClassicScrollBarLayout(self.catalogScroll)
        end
        if self.sessionScroll then
            ns.UI_ApplyClassicScrollBarLayout(self.sessionScroll)
        end
    end
    if ns.UI_RegisterViewportDebug then
        ns.UI_RegisterViewportDebug(self.catalogHost, "loot_catalog_host")
        ns.UI_RegisterViewportDebug(self.catalogPanel, "loot_catalog_vp")
        ns.UI_RegisterViewportDebug(self.sessionHost, "loot_session_host")
        ns.UI_RegisterViewportDebug(self.sessionPanel, "loot_session_vp")
        if self.catalogScroll then
            ns.UI_RegisterViewportDebug(self.catalogScroll, "loot_catalog_scroll")
            ns.UI_RegisterViewportDebug(self.catalogScroll._anScrollBarColumn, "loot_catalog_bar")
        end
        if self.sessionScroll then
            ns.UI_RegisterViewportDebug(self.sessionScroll, "loot_session_scroll")
            ns.UI_RegisterViewportDebug(self.sessionScroll._anScrollBarColumn, "loot_session_bar")
        end
    end
end

function LootHistoryUI:LayoutTabs()
    if not self.main or not self.tabBar or not self.tabButtons then
        return
    end
    local order = GetVisibleTabOrder()
    for key, btn in pairs(self.tabButtons) do
        if btn then
            btn:Hide()
        end
    end
    local w = self.tabBar:GetWidth()
    if not w or w < 80 then
        return
    end
    local n = #order
    if n < 1 then
        return
    end
    local row = {}
    for i = 1, n do
        row[i] = self.tabButtons[order[i]]
    end
    if ns.UI_LayoutStretchRow then
        ns.UI_LayoutStretchRow(self.tabBar, row, LOOT_TAB_GAP)
    end
end

function LootHistoryUI:LayoutModeBtns()
    if not self.modeBar or not self.modeButtons then
        return
    end
    local w = self.modeBar:GetWidth()
    if not w or w < 80 then
        return
    end
    local row = { self.modeButtons.session, self.modeButtons.overall }
    if ns.UI_LayoutStretchRow then
        ns.UI_LayoutStretchRow(self.modeBar, row, LOOT_TAB_GAP)
    end
end

function LootHistoryUI:SetMode(mode)
    if mode ~= "session" and mode ~= "overall" then return end
    self.activeMode = mode
    self:Refresh()
end

function LootHistoryUI:RefreshModeButtonVisuals()
    if not self.modeButtons then return end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        for _, key in ipairs({ "session", "overall" }) do
            local btn = self.modeButtons[key]
            if btn and ns.UI_StyleClassicTabButton then
                ns.UI_StyleClassicTabButton(btn, key == self.activeMode)
            end
        end
        if self.resetText then
            if self.activeMode == "overall" then
                self.resetText:SetText((L and L["LOOT_RESET_OVERALL"]) or "Reset overall")
            else
                self.resetText:SetText((L and L["LOOT_RESET_SESSION"]) or "Reset session")
            end
        end
        return
    end
    if not ApplyVisuals then return end
    for _, key in ipairs({ "session", "overall" }) do
        local btn = self.modeButtons[key]
        if btn then
            local sel = key == self.activeMode
            local bg = sel and COLORS.tabActive or COLORS.tabInactive
            local br = sel
                and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.86 }
                or { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.44 }
            ApplyVisuals(btn, bg, br)
            local fs = btn:GetFontString()
            if fs then
                if sel then
                    fs:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])
                else
                    fs:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3])
                end
            end
        end
    end
    if self.resetText then
        if self.activeMode == "overall" then
            self.resetText:SetText((L and L["LOOT_RESET_OVERALL"]) or "Reset overall")
        else
            self.resetText:SetText((L and L["LOOT_RESET_SESSION"]) or "Reset session")
        end
    end
end

function LootHistoryUI:OnLootFrameSizeChanged()
    if self.main and self.sessionHost then
        local fh = self.main:GetHeight() or 668
        self.sessionHost:SetHeight(math.max(140, math.floor(fh * SESSION_FRAC)))
    end
    --- Grip ile resize: sekme yerleşimini throttle et; tam düzen FinishLootFrameSizing’de.
    if self._isLootFrameSizing then
        local now = GetTime()
        if not self._nextLootTabLayoutTime or now >= self._nextLootTabLayoutTime then
            self._nextLootTabLayoutTime = now + LOOT_LAYOUT_THROTTLE_SEC
            self:LayoutTabs()
            self:LayoutModeBtns()
            self:ApplyHeaderTitleClip()
        end
        return
    end
    self._nextLootTabLayoutTime = nil
    self:LayoutTabs()
    self:LayoutModeBtns()
    self:ApplyHeaderTitleClip()
    self:Refresh()
    if self._sizeSaveTimer and self._sizeSaveTimer.Cancel then
        self._sizeSaveTimer:Cancel()
    end
    if C_Timer and C_Timer.NewTimer then
        self._sizeSaveTimer = C_Timer.NewTimer(0.2, function()
            self._sizeSaveTimer = nil
            if LootHistoryUI.main then
                LootHistoryUI:SaveFrameSize()
            end
        end)
    else
        self:SaveFrameSize()
    end
end

local Draw = ns.LootHistoryUIDraw

local function SortFishingCatalogEntries(entries, totals)
    if Draw and Draw.SortFishingCatalogEntries then
        return Draw.SortFishingCatalogEntries(entries, totals)
    end
    return entries
end

local function PopulateCatalog(content, entries, totals, tabKey)
    if Draw and Draw.PopulateCatalog then
        Draw.PopulateCatalog(content, entries, totals, tabKey)
    end
end

local function PopulateSessionList(content, events, catalogEntries, listCap, emptyMsg, tabKey, startY)
    if Draw and Draw.PopulateSessionList then
        Draw.PopulateSessionList(content, events, catalogEntries, listCap, emptyMsg, tabKey, startY)
    end
end

--- Catalog reference glow fade only — no list rebuild (hot path during gathering).
function LootHistoryUI:RefreshCatalogGlowsOnly()
    if not self.main or not self.main:IsShown() then
        return
    end
    if self._isLootFrameSizing or self._pauseLootFx then
        return
    end
    local Draw = ns.LootHistoryUIDraw
    if Draw and Draw.RefreshCatalogGlowStrengths and self.catalogContent then
        Draw.RefreshCatalogGlowStrengths(self.catalogContent, self.activeTab)
    end
end

function LootHistoryUI:Refresh()
    if not self.main or not self.catalogContent or not self.sessionContent then return end
    if self._isLootFrameSizing or self._pauseLootFx then
        return
    end
    if not IsValidTab(self.activeTab) then
        local order = GetVisibleTabOrder()
        self.activeTab = order[1] or "fishing"
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

    --- Catalog: Session vs Overall persisted totals. Last pickups: always session event list (not Overall DB slice).
    local totals = {}
    local eventsLastPickups = {}
    if svc then
        if self.activeTab == "fishing" then
            totals = svc:GetItemTotals("fishing", nil, isOverall) or {}
            --- Last pickups: ALWAYS the session event list (crafted/gathering
            --- already do this) — overall mode fed multi-day, multi-character
            --- rows into the "Last N pickups" panel and the Rate text.
            eventsLastPickups = svc:GetRecentEvents("fishing", nil, false) or {}
        elseif self.activeTab == "crafted" then
            totals = svc:GetItemTotals("crafted", nil, isOverall) or {}
            eventsLastPickups = svc:GetRecentEvents("crafted", nil, false) or {}
            entries = BuildCraftedCatalogEntries(totals)
        else
            local cat = self.activeTab
            totals = svc:GetItemTotals("gathering", cat, isOverall) or {}
            eventsLastPickups = svc:GetRecentEvents("gathering", cat, false) or {}
        end
    end
    if self.activeTab == "fishing" and type(entries) == "table" then
        entries = SortFishingCatalogEntries(entries, totals)
    end
    if self.catalogTotalLabel then
        local totalCopper = ComputeTotalsCopper(totals)
        local totalFmt = (L and L["LOOT_SECTION_TOTAL_FMT"]) or "Total: %s"
        local worthStr = (totalCopper > 0) and (FormatCopper(totalCopper) or "") or ((L and L["LOOT_CATALOG_AH_EMPTY"]) or "—")
        self.catalogTotalLabel:SetFormattedText(totalFmt, worthStr)
    end

    ClearScrollContent(self.catalogScroll, self.catalogContent)
    ClearScrollContent(self.sessionScroll, self.sessionContent)

    if ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(self.catalogScroll)
        ns.UI_FinishScrollLayout(self.sessionScroll)
    end

    local cw = math.max((self.catalogScroll and self.catalogScroll:GetWidth()) or 360, 280)
    self.catalogContent:SetWidth(cw)
    PopulateCatalog(self.catalogContent, entries, totals, self.activeTab)

    local sw = math.max((self.sessionScroll and self.sessionScroll:GetWidth()) or 360, 280)
    self.sessionContent:SetWidth(sw)
    local cap = GetLastLootListCap()
    if self.sessionSectionLabel then
        local fmt = (L and L["LOOT_SECTION_SESSION_FMT"]) or "Last %d pickups"
        if isOverall then
            self.sessionSectionLabel:SetText((L and L["LOOT_CHAR_EARNINGS_HEADER"]) or "Earnings by character")
        else
            self.sessionSectionLabel:SetFormattedText(fmt, cap)
        end
    end
    local emptyLastPickups = (L and L["LOOT_LAST_PICKUPS_EMPTY"]) or (L and L["LOOT_SESSION_EMPTY"]) or "No recent pickups yet."
    if self.activeTab == "crafted" then
        emptyLastPickups = (L and L["LOOT_CRAFTED_EMPTY"]) or emptyLastPickups
    end
    --- Overall mode: per-character earnings breakdown (GUID-keyed) above the pickup list.
    local sessionStartY = 0
    if isOverall and svc and svc.GetPerCharacterEarnings and Draw and Draw.PopulateCharEarnings then
        sessionStartY = Draw.PopulateCharEarnings(self.sessionContent, svc:GetPerCharacterEarnings()) or 0
    end
    PopulateSessionList(self.sessionContent, eventsLastPickups, entries, cap, emptyLastPickups, self.activeTab, sessionStartY)
    if ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(self.catalogScroll)
        ns.UI_FinishScrollLayout(self.sessionScroll)
    end
    if self.sessionEfficiencyLabel then
        local eff = ComputeSessionEfficiencyText(eventsLastPickups)
        self.sessionEfficiencyLabel:SetText(eff or "")
    end

    LootHistoryUI:RefreshTabButtonVisuals()
    LootHistoryUI:RefreshModeButtonVisuals()
    LootHistoryUI:UpdateOverloadTrackerToggle()
end

--- Title string clipped to never run under the window control cluster (overload optional).
function LootHistoryUI:ApplyHeaderTitleClip()
    local ht = self.headerTitle
    local logo = self.headerLogo
    local clip = self.shellRightClip
    if not ht or not logo or not clip then
        return
    end
    ht:ClearAllPoints()
    ht:SetPoint("LEFT", logo, "RIGHT", 8, 0)
    ht:SetPoint("RIGHT", clip, "LEFT", -8, 0)
end

--- Hide overload HUD toggle unless Herbalism or Mining; dim when HUD is off.
function LootHistoryUI:UpdateOverloadTrackerToggle()
    local b = self.overloadTrackerBtn
    if not b then
        return
    end
    local U = ns.Utilities
    if not U or not U.PlayerOwnsAnyOverloadTrackerProfession or not U.PlayerOwnsAnyOverloadTrackerProfession() then
        b:Hide()
        LootHistoryUI:ApplyHeaderTitleClip()
        return
    end
    b:Show()
    local on = ns.db and ns.db.profile and ns.db.profile.overloadTrackerHudEnabled ~= false
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if b.SetAlpha then
            b:SetAlpha(1)
        end
    elseif b.SetAlpha then
        b:SetAlpha(on and 1 or 0.45)
    end
    LootHistoryUI:ApplyHeaderTitleClip()
end

---@param btn Frame|Button
---@param selected boolean
---@param otherTabLootPulse boolean|nil non-selected tab that just received catalog loot for its profession
local function StyleTabButton(btn, selected, otherTabLootPulse)
    if not btn then
        return
    end
    --- UI_StyleShellTabButton branches on classic itself and forwards opts,
    --- so the loot pulse survives the classic skin (gold text emphasis).
    ns.UI_StyleShellTabButton(btn, selected, { pulse = otherTabLootPulse and not selected })
end

function LootHistoryUI:RefreshTabButtonVisuals()
    if not self.tabButtons then
        return
    end
    local order = GetVisibleTabOrder()
    local svc = ns.SessionLootService
    for i = 1, #TAB_ORDER do
        local key = TAB_ORDER[i]
        local btn = self.tabButtons[key]
        if btn then
            local visible = false
            for j = 1, #order do
                if order[j] == key then
                    visible = true
                    break
                end
            end
            if visible then
                local sel = key == self.activeTab
                local pulse = (not sel) and svc and svc.IsTabAttentionActive and svc:IsTabAttentionActive(key)
                StyleTabButton(btn, sel, pulse)
                btn:Show()
            else
                btn:Hide()
            end
        end
    end
end

IsValidTab = function(tab)
    local order = GetVisibleTabOrder()
    for i = 1, #order do
        if order[i] == tab then
            return true
        end
    end
    return false
end

function LootHistoryUI:IsValidTab(tab)
    return IsValidTab(tab)
end

function LootHistoryUI:GetVisibleTabOrder()
    return GetVisibleTabOrder()
end

function LootHistoryUI:ResetForUiMode()
    if self.main then
        self.main:Hide()
        self.main = nil
    end
    self.shell = nil
    self.headerBar = nil
    self.tabButtons = nil
    self.modeButtons = nil
    self.catalogScroll = nil
    self.sessionScroll = nil
end

function LootHistoryUI:RefreshClassicChrome()
    if not self.main or not (ns.UI_IsClassicUi and ns.UI_IsClassicUi()) then
        return
    end
    if self.catalogPanel and ns.UI_ApplyClassicInsetPanel then
        ns.UI_ApplyClassicInsetPanel(self.catalogPanel)
    end
    if self.sessionPanel and ns.UI_ApplyClassicInsetPanel then
        ns.UI_ApplyClassicInsetPanel(self.sessionPanel)
    end
    if self.resetSessionBtn and ns.UI_StyleClassicPanelButton then
        ns.UI_StyleClassicPanelButton(self.resetSessionBtn)
    end
    if self.tabButtons and ns.UI_StyleClassicTabButton then
        for _, key in ipairs(TAB_ORDER) do
            local btn = self.tabButtons[key]
            if btn and btn:IsShown() then
                ns.UI_StyleClassicTabButton(btn, key == self.activeTab)
            end
        end
    end
    if self.modeButtons and ns.UI_StyleClassicTabButton then
        for _, key in ipairs({ "session", "overall" }) do
            local btn = self.modeButtons[key]
            if btn then
                ns.UI_StyleClassicTabButton(btn, key == self.activeMode)
            end
        end
    end
    if self.sessionSectionLabel then
        self.sessionSectionLabel:SetTextColor(1, 0.82, 0)
    end
    if self.catalogTotalLabel then
        self.catalogTotalLabel:SetTextColor(1, 0.82, 0)
    end
    if self.headerBar and ns.UI_RefreshClassicWindowHeader then
        ns.UI_RefreshClassicWindowHeader(self.headerBar)
    end
    self:LayoutClassicShellBodyChrome()
    if self.settingsBtn and ns.UI_StyleClassicToolButton then
        ns.UI_StyleClassicToolButton(self.settingsBtn)
    end
    if self.recipesBtn and ns.UI_StyleClassicToolButton then
        ns.UI_StyleClassicToolButton(self.recipesBtn)
    end
    if self.hubBtn and ns.UI_StyleClassicToolButton then
        ns.UI_StyleClassicToolButton(self.hubBtn)
    end
    if self.overloadTrackerBtn and ns.UI_StyleClassicToolButton then
        ns.UI_StyleClassicToolButton(self.overloadTrackerBtn)
    end
    self:LayoutLootScrollChrome()
end

function LootHistoryUI:RefreshTheme()
    if not self.main then
        return
    end
    if ns.UI_ApplyMainWindowChrome then
        ns.UI_ApplyMainWindowChrome(self.main)
    elseif ns.UI_ApplyPanelBackdrop then
        ns.UI_ApplyPanelBackdrop(self.main)
    end
    if ns.UI_RefreshWindowHeader then
        ns.UI_RefreshWindowHeader(self.headerBar)
    end
    self:LayoutClassicShellBodyChrome()
    self:RefreshClassicChrome()
    self:LayoutLootScrollChrome()
    if self.main:IsShown() then
        self:RefreshModeButtonVisuals()
        self:RefreshTabButtonVisuals()
        self:Refresh()
    end
    if self.catalogScroll and ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(self.catalogScroll)
    end
    if self.sessionScroll and ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(self.sessionScroll)
    end
end

---@param tab "fishing"|"herb"|"mine"|"leather"|"disenchant"
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

function LootHistoryUI:Show(which)
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        if self.main and self.main:IsShown() then
            self.main:Hide()
        end
        return
    end
    local w = NormalizeShowArg(which)
    if w then
        if IsValidTab(w) then
            self.activeTab = w
            if ns.db and ns.db.profile then
                ns.db.profile.lootHistoryActiveTab = w
            end
        else
            local order = GetVisibleTabOrder()
            local pick = order[1] or w
            self.activeTab = pick
            if ns.db and ns.db.profile then
                ns.db.profile.lootHistoryActiveTab = pick
            end
        end
    end
    if self.main then
        local minW = LAYOUT.WINDOW_WIDTH or 600
        local minH = LAYOUT.WINDOW_HEIGHT or 720
        if (self.main:GetWidth() or 0) < minW - 16 then
            self.main:SetSize(minW, minH)
        end
        if ns.UI_PresentCraftWindow then
            ns.UI_PresentCraftWindow(self.main, "loot")
        else
            if ns.UI_CloseSiblingCraftWindows then
                ns.UI_CloseSiblingCraftWindows("loot")
            end
            self.main:Show()
        end
        if self.sessionHost then
            local fh = self.main:GetHeight() or LAYOUT.WINDOW_HEIGHT or 640
            self.sessionHost:SetHeight(math.max(140, math.floor(fh * SESSION_FRAC)))
        end
        self:LayoutTabs()
        self:Refresh()
        return
    end

    local f = CreateFrame("Frame", "ArtisanNexusLootHistoryFrame", UIParent, "BackdropTemplate")
    f:SetSize(LAYOUT.WINDOW_WIDTH, LAYOUT.WINDOW_HEIGHT)
    LootHistoryUI:ApplySavedFrameSize(f)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:SetResizable(true)
    f:EnableMouse(true)
    local rbW, rbH = GetLootFrameBounds()
    local Chrome = ns.LootHistoryUI_Chrome
    if Chrome and Chrome.ApplyResizeBounds then
        Chrome.ApplyResizeBounds(f, LOOT_MIN_W, LOOT_MIN_H, LOOT_MAX_W, LOOT_MAX_H)
    elseif f.SetResizeBounds then
        pcall(function()
            f:SetResizeBounds(LOOT_MIN_W, LOOT_MIN_H, rbW, rbH)
        end)
    elseif f.SetMinResize then
        f:SetMinResize(LOOT_MIN_W, LOOT_MIN_H)
        f:SetMaxResize(rbW, rbH)
    end
    f:SetScript("OnSizeChanged", function()
        LootHistoryUI:OnLootFrameSizeChanged()
    end)
    if ns.UI_ApplyMainWindowChrome then
        ns.UI_ApplyMainWindowChrome(f)
    else
        ApplyPanelBackdrop(f)
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() and f.SetClipsChildren then
        f:SetClipsChildren(false)
    end

    local shell = ns.UI_CreateWindowHeader(f, {
        title = (L and L["ADDON_NAME"]) or "Artisan Nexus",
        dragFrame = f,
        onDragStart = function()
            LootHistoryUI._pauseLootFx = true
            f:StartMoving()
        end,
        onDragStop = function()
            f:StopMovingOrSizing()
            LootHistoryUI._pauseLootFx = false
            LootHistoryUI:SaveFrameSize()
        end,
        onClose = function()
            f:Hide()
        end,
        showSettings = true,
        onSettings = OpenAddonSettings,
        settingsTooltip = {
            title = (L and L["LOOT_SETTINGS_TOOLTIP"]) or "Artisan Nexus settings",
        },
        utilities = {
            {
                texture = "Interface\\Icons\\INV_Misc_Book_09",
                onClick = function()
                    if ns.RecipeMatcherUI and ns.RecipeMatcherUI.Show then
                        ns.RecipeMatcherUI:Show()
                    end
                end,
                title = (L and L["LOOT_OPEN_RECIPES"]) or "Recipes",
                desc = (L and L["LOOT_OPEN_RECIPES_DESC"]) or "",
            },
            {
                texture = "Interface\\Icons\\INV_Misc_Coin_01",
                onClick = function()
                    if ns.ArtisanHubUI and ns.ArtisanHubUI.Show then
                        ns.ArtisanHubUI:Show()
                    end
                end,
                title = (L and L["LOOT_OPEN_HUB"]) or "Hub",
                desc = (L and L["LOOT_OPEN_HUB_DESC"]) or "",
            },
        },
    })
    self.shell = shell
    self.headerBar = shell.bar
    self.headerLogo = shell.logo
    self.headerTitle = shell.title
    self.settingsBtn = shell.settings
    self.recipesBtn = shell.utilities[1]
    self.hubBtn = shell.utilities[2]

    local overloadTrackerBtn = CreateFrame("Button", nil, shell.bar)
    overloadTrackerBtn:SetSize(26, 26)
    local overloadAnchor = shell.utilities[2] or shell.settings or shell.close
    overloadTrackerBtn:SetPoint("RIGHT", overloadAnchor, "LEFT", -2, 0)
    overloadTrackerBtn:SetNormalTexture("Interface\\Icons\\Spell_Shaman_StaticShock")
    overloadTrackerBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    overloadTrackerBtn:SetScript("OnClick", function()
        if not ns.db or not ns.db.profile then
            return
        end
        ns.db.profile.overloadTrackerHudEnabled = not (ns.db.profile.overloadTrackerHudEnabled ~= false)
        if ns.GatheringOverloadIndicator and ns.GatheringOverloadIndicator.RefreshTracker then
            ns.GatheringOverloadIndicator:RefreshTracker()
        end
        LootHistoryUI:UpdateOverloadTrackerToggle()
    end)
    overloadTrackerBtn:SetScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
        if GameTooltip.ClearLines then
            GameTooltip:ClearLines()
        end
        local title = (L and L["LOOT_OVERLOAD_TRACKER_BTN"]) or "Overload tracker"
        local desc = (L and L["LOOT_OVERLOAD_TRACKER_BTN_DESC"]) or "Show or hide the floating overload cooldown tracker (Herbalism / Mining)."
        GameTooltip:AddLine(title, 1, 1, 1)
        GameTooltip:AddLine(desc, 0.85, 0.85, 0.85, true)
        GameTooltip:Show()
    end)
    overloadTrackerBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    self.overloadTrackerBtn = overloadTrackerBtn
    self.shellRightClip = overloadTrackerBtn
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() and ns.UI_StyleClassicToolButton then
        ns.UI_StyleClassicToolButton(overloadTrackerBtn)
    end
    if shell.title and shell.logo then
        shell.title:ClearAllPoints()
        shell.title:SetPoint("LEFT", shell.logo, "RIGHT", 8, 0)
        shell.title:SetPoint("RIGHT", overloadTrackerBtn, "LEFT", -8, 0)
    end
    LootHistoryUI:ApplyHeaderTitleClip()

    local function LootTabLabel(key)
        if ns.GetGatheringTabDisplayName then
            return ns.GetGatheringTabDisplayName(key)
        end
        local map = {
            fishing = "LOOT_TAB_FISHING",
            herb = "LOOT_GATHER_HERB",
            mine = "LOOT_GATHER_MINE",
            leather = "LOOT_GATHER_LEATHER",
            disenchant = "LOOT_GATHER_DE",
            others = "LOOT_GATHER_OTHERS",
            crafted = "LOOT_TAB_CRAFTED",
        }
        local fallbacks = {
            fishing = "Fishing",
            herb = "Herbalism",
            mine = "Mining",
            leather = "Leatherworking",
            disenchant = "Enchanting",
            others = "Others",
            crafted = "Crafted",
        }
        local lk = map[key]
        if lk and ns.SafeLocaleString then
            local s = ns.SafeLocaleString(lk, nil)
            if s then
                return s
            end
        end
        return fallbacks[key] or ns.CoerceUiString(key, "?")
    end

    local labels = {
        fishing = LootTabLabel("fishing"),
        herb = LootTabLabel("herb"),
        mine = LootTabLabel("mine"),
        leather = LootTabLabel("leather"),
        disenchant = LootTabLabel("disenchant"),
        others = LootTabLabel("others"),
        crafted = LootTabLabel("crafted"),
    }

    local classicLoot = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    local btnTemplate = (ns.UI_ClassicButtonTemplate and ns.UI_ClassicButtonTemplate()) or "BackdropTemplate"

    local function AssignLootButtonLabel(btn, text)
        if classicLoot then
            btn._anClassicNativePanel = true
            if ns.UI_SetNativePanelButtonText then
                ns.UI_SetNativePanelButtonText(btn, text)
            elseif btn.SetText then
                btn:SetText(text)
            end
        else
            local t = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            t:SetAllPoints()
            t:SetText(text)
            btn:SetFontString(t)
        end
    end

    local tabBar = CreateFrame("Frame", nil, f)
    self.tabBar = tabBar
    LootHistoryUI:LayoutClassicShellBodyChrome()
    tabBar:SetHeight(LOOT_TAB_BAR_H)

    self.tabButtons = {}
    for i = 1, #TAB_ORDER do
        local key = TAB_ORDER[i]
        local b = CreateFrame("Button", nil, tabBar, btnTemplate)
        b:SetParent(tabBar)
        b:SetHeight(LOOT_TAB_H)
        AssignLootButtonLabel(b, labels[key] or key)
        b:SetScript("OnClick", function()
            LootHistoryUI:SetTab(key)
        end)
        self.tabButtons[key] = b
    end

    local modeBar = CreateFrame("Frame", nil, f)
    modeBar:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -8)
    modeBar:SetPoint("TOPRIGHT", tabBar, "BOTTOMRIGHT", 0, -8)
    modeBar:SetHeight(LOOT_TAB_H)
    self.modeBar = modeBar

    local modeLabels = {
        session = (L and L["LOOT_MODE_SESSION"]) or "Session",
        overall = (L and L["LOOT_MODE_OVERALL"]) or "Overall",
    }
    self.modeButtons = {}
    for _, key in ipairs({ "session", "overall" }) do
        local mb = CreateFrame("Button", nil, modeBar, btnTemplate)
        mb:SetParent(modeBar)
        mb:SetHeight(LOOT_TAB_H)
        AssignLootButtonLabel(mb, modeLabels[key] or key)
        mb:SetScript("OnClick", function()
            LootHistoryUI:SetMode(key)
        end)
        self.modeButtons[key] = mb
    end

    local resetRow = CreateFrame("Frame", nil, f)
    resetRow:SetPoint("TOPLEFT", modeBar, "BOTTOMLEFT", 0, -4)
    resetRow:SetPoint("TOPRIGHT", modeBar, "BOTTOMRIGHT", 0, -4)
    resetRow:SetHeight(LOOT_TAB_H)
    self.resetRow = resetRow

    local resetSessionBtn = CreateFrame("Button", nil, resetRow, btnTemplate)
    resetSessionBtn:SetHeight(LOOT_TAB_H)
    resetSessionBtn:SetPoint("TOPLEFT", resetRow, "TOPLEFT", 0, 0)
    resetSessionBtn:SetPoint("TOPRIGHT", resetRow, "TOPRIGHT", 0, 0)
    AssignLootButtonLabel(resetSessionBtn, (L and L["LOOT_RESET_SESSION"]) or "Reset session")
    if resetSessionBtn.GetFontString then
        self.resetText = resetSessionBtn:GetFontString()
    end
    self.resetSessionBtn = resetSessionBtn
    resetSessionBtn:SetScript("OnClick", function()
        local svc = ns.SessionLootService
        if not svc then
            return
        end
        if LootHistoryUI.activeMode == "overall" then
            if LootHistoryUI.activeTab == "fishing" then
                svc:ResetOverall("fishing")
            elseif LootHistoryUI.activeTab == "crafted" then
                svc:ResetOverall("crafted")
            else
                svc:ResetOverall("gathering", LootHistoryUI.activeTab)
            end
        else
            svc:ResetSessionForTab(LootHistoryUI.activeTab)
        end
        LootHistoryUI:Refresh()
    end)
    if not classicLoot and ns.UI_StylePanelButton then
        ns.UI_StylePanelButton(resetSessionBtn)
    end

    --- Bottom panel: larger share of height (SESSION_FRAC); explicit height so scroll works.
    local sessionHost = CreateFrame("Frame", nil, f)
    sessionHost:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 18)
    sessionHost:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 18)
    do
        local fh = f:GetHeight() or LAYOUT.WINDOW_HEIGHT or 640
        sessionHost:SetHeight(math.max(140, math.floor(fh * SESSION_FRAC)))
    end
    self.sessionHost = sessionHost

    local sessionPanel = CreateFrame("Frame", nil, sessionHost, "BackdropTemplate")
    self.sessionPanel = sessionPanel
    ApplyLootInsetToHost(sessionPanel, sessionHost)
    if ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(sessionPanel)
    end

    local labSes = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    --- Split row: left / right halves so efficiency text never overlaps the session heading at narrow widths.
    labSes:SetPoint("BOTTOMLEFT", sessionHost, "TOPLEFT", 4, 5)
    labSes:SetPoint("BOTTOMRIGHT", sessionHost, "TOP", -4, 5)
    labSes:SetJustifyH("LEFT")
    labSes:SetWordWrap(false)
    labSes:SetMaxLines(1)
    labSes:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])
    self.sessionSectionLabel = labSes
    do
        local fmt = (L and L["LOOT_SECTION_SESSION_FMT"]) or "Last %d pickups"
        labSes:SetFormattedText(fmt, GetLastLootListCap())
    end
    local labEff = f:CreateFontString(nil, "OVERLAY", (ns.UI_FONTS and ns.UI_FONTS.WINDOW_META) or "GameFontHighlightSmall")
    labEff:SetPoint("BOTTOMLEFT", sessionHost, "TOP", 4, 5)
    labEff:SetPoint("BOTTOMRIGHT", sessionHost, "TOPRIGHT", -4, 5)
    labEff:SetJustifyH("RIGHT")
    labEff:SetWordWrap(false)
    labEff:SetMaxLines(1)
    labEff:SetText("")
    labEff:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3], 1)
    self.sessionEfficiencyLabel = labEff

    local refRow = CreateFrame("Frame", nil, f)
    refRow:SetPoint("TOPLEFT", resetRow, "BOTTOMLEFT", 0, -4)
    refRow:SetPoint("TOPRIGHT", resetRow, "BOTTOMRIGHT", 0, -4)
    refRow:SetHeight(22)

    local labRef = refRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    labRef:SetPoint("LEFT", refRow, "LEFT", 0, 0)
    labRef:SetJustifyH("LEFT")
    labRef:SetText((L and L["LOOT_SECTION_REFERENCE"]) or "Catalog")
    labRef:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])

    local labTotal = refRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    labTotal:SetPoint("RIGHT", refRow, "RIGHT", 0, 0)
    labTotal:SetJustifyH("RIGHT")
    labTotal:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])
    local totalFmt = (L and L["LOOT_SECTION_TOTAL_FMT"]) or "Total: %s"
    labTotal:SetFormattedText(totalFmt, "0c")
    labRef:SetPoint("RIGHT", labTotal, "LEFT", -8, 0)
    self.catalogTotalLabel = labTotal

    local catalogHost = CreateFrame("Frame", nil, f)
    catalogHost:SetPoint("TOPLEFT", refRow, "BOTTOMLEFT", 0, -4)
    catalogHost:SetPoint("TOPRIGHT", refRow, "BOTTOMRIGHT", 0, -4)
    catalogHost:SetPoint("BOTTOM", labSes, "TOP", 0, 6)
    self.catalogHost = catalogHost

    local catalogPanel = CreateFrame("Frame", nil, catalogHost, "BackdropTemplate")
    self.catalogPanel = catalogPanel
    ApplyLootInsetToHost(catalogPanel, catalogHost)
    if ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(catalogPanel)
    end

    local catScroll, catContent = ns.UI_AttachThemedScroll(catalogPanel, LootScrollAttachOpts(catalogHost))
    self.catalogScroll = catScroll
    self.catalogContent = catContent

    local sesScroll, sesContent = ns.UI_AttachThemedScroll(sessionPanel, LootScrollAttachOpts(sessionHost))
    self.sessionScroll = sesScroll
    self.sessionContent = sesContent
    self.sessionPanel = sessionPanel

    local grip = CreateFrame("Button", nil, f)
    grip:SetFrameLevel(f:GetFrameLevel() + 20)
    grip:SetSize(18, 18)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 5)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        LootHistoryUI._isLootFrameSizing = true
        LootHistoryUI._pauseLootFx = true
        f:StartSizing("BOTTOMRIGHT")
        f:SetScript("OnUpdate", LootFrameSizingPoll)
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        FinishLootFrameSizing()
    end)
    self.resizeGrip = grip

    self.main = f
    f:SetScript("OnShow", function()
        local rbW, rbH = GetLootFrameBounds()
        if f.SetResizeBounds then
            pcall(function()
                f:SetResizeBounds(LOOT_MIN_W, LOOT_MIN_H, rbW, rbH)
            end)
        elseif f.SetMaxResize then
            f:SetMaxResize(rbW, rbH)
        end
        LootHistoryUI:LayoutTabs()
        LootHistoryUI:LayoutModeBtns()
        LootHistoryUI:RefreshTabButtonVisuals()
        LootHistoryUI:RefreshModeButtonVisuals()
        if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
            LootHistoryUI:RefreshClassicChrome()
        end
    end)
    LootHistoryUI:LayoutTabs()
    LootHistoryUI:LayoutModeBtns()
    self:RefreshClassicChrome()
    self:LayoutLootScrollChrome()
    self:Refresh()
    if ns.UI_PresentCraftWindow then
        ns.UI_PresentCraftWindow(f, "loot")
    else
        f:Show()
    end
end

function LootHistoryUI:Hide()
    self._isLootFrameSizing = false
    self._pauseLootFx = false
    self._nextLootTabLayoutTime = nil
    if self.main then
        self.main:SetScript("OnUpdate", nil)
    end
    if self._sizeSaveTimer and self._sizeSaveTimer.Cancel then
        pcall(function()
            self._sizeSaveTimer:Cancel()
        end)
        self._sizeSaveTimer = nil
    end
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
