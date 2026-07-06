--[[
    AH price scanner for gathering catalog + craft briefing item IDs.

    Primary path (Retail 8.3+): C_AuctionHouse.SearchForItemKeys (up to 100 keys per
    call) then C_AuctionHouse.GetBrowseResults on AUCTION_HOUSE_BROWSE_RESULTS_UPDATED.
    One batch replaces dozens of SendSearchQuery round-trips (100/min throttle).

    Fallback: per-item C_AuctionHouse.SendSearchQuery + COMMODITY/ITEM_SEARCH_RESULTS_UPDATED.

    Callers:
        ns.AHPriceService:GetPrice(itemID)  → copper unit price or nil
        ns.AHPriceService:StartScan(force, fullScan)
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
local AHPriceService
local SavePrice

--- Legacy per-item path: gap between queries after a successful result.
local SCAN_STEP_SEC = 0.55

--- If neither commodity nor item result events fire, still advance (legacy path).
local SEARCH_RESULT_TIMEOUT_SEC = 2.5

--- SearchForItemKeys batch: max keys per call (wiki: >100 risks disconnect).
local BATCH_MAX_KEYS = 100

--- Whole-batch timeout before falling back to per-item SendSearchQuery.
local BATCH_RESULT_TIMEOUT_SEC = 12

local QUICK_SCAN_MAX_ITEMS = 28

--- Wiki-recommended sort stack for AH search/browse queries.
local SEARCH_SORTS = {
    { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
    { sortOrder = Enum.AuctionHouseSortOrder.Level, reverseSort = true },
}

--- Per-item cache freshness. Items younger than this are skipped on incremental
--- scans (force=true / right-click "Full scan" overrides). Tunable via DB.
local DEFAULT_FRESH_TTL_SEC = 60 * 60 * 6   -- 6 hours
local STALE_TTL_SEC         = 60 * 60 * 24  -- 24 hours

--- Adaptive backoff cap. After repeated timeouts we slow the queue so we don't
--- hammer the AH and trip Blizzard's rate limit.
local SCAN_STEP_MAX_SEC = 0.6

--- AceGUI sync button — CategoriesList footer (below category scroll / WoW Token).
local AH_SYNC_BTN_H = 22
local AH_SYNC_CAT_PAD_X = 8
local AH_SYNC_CAT_PAD_BOTTOM = 10
local AH_SYNC_CAT_SCROLLBAR_W = 28

local function FormatRemaining(seconds)
    if seconds < 60 then return string.format("%ds", math.max(1, math.floor(seconds))) end
    if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
    return string.format("%dh", math.floor(seconds / 3600))
end

local function L(key, fallback)
    local loc = ns.L
    if loc and loc[key] then
        return loc[key]
    end
    return fallback
end

local function Notify(msg)
    if ArtisanNexus and ArtisanNexus.Print then
        ArtisanNexus:Print(msg)
    else
        local name = L("ADDON_NAME", "Artisan Nexus")
        DEFAULT_CHAT_FRAME:AddMessage("|cff6a0dad" .. name .. "|r: " .. tostring(msg))
    end
end

--- Valid ItemKey for SendSearchQuery (suffixItemID is not a valid ItemKey field).
local function MakeQueryItemKey(itemID)
    if not itemID then
        return nil
    end
    if C_AuctionHouse and C_AuctionHouse.MakeItemKey then
        local ok, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
        if ok and type(key) == "table" then
            return key
        end
    end
    return {
        itemID = itemID,
        itemLevel = 0,
        itemSuffix = 0,
        battlePetSpeciesID = 0,
    }
end

local function After(delaySec, fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(delaySec, fn)
    elseif ArtisanNexus and ArtisanNexus.ScheduleTimer then
        ArtisanNexus:ScheduleTimer(fn, delaySec)
    else
        fn()
    end
end

-- (GetFirstShownButton removed — sibling-button hunt was unreliable across
-- AH tabs; the new chrome-relative anchor is independent of tab content.)

local ScheduleAHSyncAnchorRefresh

local function GetAHSyncWidgetFrame(widget)
    return widget and (widget.frame or widget)
end

--- CategoriesList bottom gutter (below WoW Token scroll row); full column width.
local function ApplyAHSyncButtonAnchor(widget, parent)
    local frame = GetAHSyncWidgetFrame(widget)
    if not frame or not widget or not parent then
        return
    end
    local cat = parent.CategoriesList
    if not cat then
        frame:Hide()
        return
    end
    if frame:GetParent() ~= cat then
        frame:SetParent(cat)
        frame:SetFrameStrata(cat:GetFrameStrata())
        frame:SetFrameLevel(cat:GetFrameLevel() + 5)
    end
    frame:ClearAllPoints()
    local catW = (cat.GetWidth and cat:GetWidth()) or 168
    local btnW = math.max(100, catW - AH_SYNC_CAT_PAD_X - AH_SYNC_CAT_SCROLLBAR_W)
    widget:SetAutoWidth(false)
    widget:SetWidth(btnW)
    widget:SetHeight(AH_SYNC_BTN_H)
    frame:SetPoint("BOTTOMLEFT", cat, "BOTTOMLEFT", AH_SYNC_CAT_PAD_X, AH_SYNC_CAT_PAD_BOTTOM)
    frame:SetPoint("BOTTOMRIGHT", cat, "BOTTOMRIGHT", -AH_SYNC_CAT_SCROLLBAR_W, AH_SYNC_CAT_PAD_BOTTOM)
    if cat.IsShown and cat:IsShown() then
        frame:Show()
    else
        frame:Hide()
    end
end

local function ShowAHSyncTooltip(owner)
    if not owner then
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(L("AH_SYNC_PRICES", "AH price sync"), 1, 1, 1)
    local stats = AHPriceService:GetCacheStats()
    local lastAge = (stats.newest > 0) and (time() - stats.newest) or nil
    GameTooltip:AddLine(" ")
    if AHPriceService._scanning then
        local pct = AHPriceService._totalItems > 0
            and math.floor(AHPriceService._scannedItems / AHPriceService._totalItems * 100 + 0.5) or 0
        GameTooltip:AddDoubleLine("Scanning",
            string.format("%d/%d  (%d%%)", AHPriceService._scannedItems, AHPriceService._totalItems, pct),
            0.7, 0.7, 0.7, 1, 1, 1)
    elseif AHPriceService._paused then
        GameTooltip:AddDoubleLine("Paused",
            string.format("%d/%d", AHPriceService._scannedItems, AHPriceService._totalItems),
            1, 0.84, 0, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Cached", string.format("%d items", stats.total), 0.7, 0.7, 0.7, 1, 1, 1)
    local plan = AHPriceService:GetScanPlan(false)
    GameTooltip:AddDoubleLine("Tracked catalog",
        string.format("%d items", plan.tracked), 0.7, 0.7, 0.7, 1, 1, 1)
    if plan.freshSkipped > 0 then
        GameTooltip:AddDoubleLine("Fresh (skipped)",
            string.format("%d", plan.freshSkipped), 0.7, 0.7, 0.7, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Stale queue",
        string.format("%d", plan.queued), 0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddDoubleLine("Fresh / stale",
        string.format("|cff44ff44%d|r / |cffd4af37%d|r", stats.fresh, stats.stale),
        0.7, 0.7, 0.7, 1, 1, 1)
    if lastAge then
        GameTooltip:AddDoubleLine("Last update", FormatRemaining(lastAge) .. " ago",
            0.7, 0.7, 0.7, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    if AHPriceService._scanning then
        GameTooltip:AddLine("|cffaaaaaaLeft-click: pause   ·   Right-click: menu|r")
    elseif AHPriceService._paused then
        GameTooltip:AddLine("|cffaaaaaaLeft-click: resume   ·   Right-click: menu|r")
    else
        GameTooltip:AddLine("|cffaaaaaaLeft-click: refresh stale   ·   Right-click: quick / full|r")
    end
    GameTooltip:AddLine("|cffaaaaaaBrowse list restores when sync finishes.|r")
    GameTooltip:Show()
end

local function ItemIsCommodity(itemID)
    if not itemID or not C_AuctionHouse or not C_AuctionHouse.GetItemCommodityStatus then
        return false
    end
    local ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, itemID)
    if not ok or status == nil then
        return false
    end
    if Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.NotCommodity ~= nil then
        return status ~= Enum.ItemCommodityStatus.NotCommodity
    end
    return status ~= 0
end

--- Batch browse misses prices; legacy per-item path handles unpriced keys after each chunk.
local function QueueLegacyFollowup(itemID)
    if not itemID then
        return
    end
    local tail = AHPriceService._legacyTail
    if not tail then
        tail = {}
        AHPriceService._legacyTail = tail
    end
    tail[#tail + 1] = itemID
    AHPriceService._legacyQueuedThisScan = (AHPriceService._legacyQueuedThisScan or 0) + 1
end

local function DrainLegacyTailIfNeeded()
    local tail = AHPriceService._legacyTail
    if not tail or #tail < 1 then
        return false
    end
    AHPriceService._legacyTail = {}
    if ns.DebugPrint then
        ns.DebugPrint(string.format("|cff9370DB[AN AH]|r legacy follow-up tail: %d items", #tail))
    end
    for i = 1, #tail do
        AHPriceService._queue[#AHPriceService._queue + 1] = tail[i]
    end
    AHPriceService:ScanNext()
    return true
end

---@class AHPriceService
AHPriceService = {
    _queue = {},
    _scanning = false,
    _paused = false,
    _currentItemID = nil,
    _expectQueryId = nil,
    _ahButtonCreated = false,
    _ahButton = nil,
    _totalItems = 0,
    _scannedItems = 0,
    _pricedThisScan = 0,
    _legacyQueuedThisScan = 0,
    _browseSnapshot = nil,
    _scanStartedAt = 0,
    _consecutiveTimeouts = 0,
    _currentStepSec = SCAN_STEP_SEC,
    _lastFullScanAt = 0,
    _suppressPriceMessages = false,
    _batchMode = false,
    _batchExpectId = nil,
    _batchChunkSize = 0,
    _batchPendingSet = nil,
    _legacyTail = nil,
}

function ScheduleAHSyncAnchorRefresh()
    local btn = AHPriceService._ahButton
    local af = _G.AuctionHouseFrame
    if not btn or not af or not af.IsShown or not af:IsShown() then
        return
    end
    After(0, function()
        if AHPriceService._ahButton and _G.AuctionHouseFrame then
            ApplyAHSyncButtonAnchor(AHPriceService._ahButton, _G.AuctionHouseFrame)
        end
    end)
    After(0.12, function()
        if AHPriceService._ahButton and _G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown() then
            ApplyAHSyncButtonAnchor(AHPriceService._ahButton, _G.AuctionHouseFrame)
        end
    end)
end

--- Returns whether an AH scan is in progress.
---@return boolean
function AHPriceService:IsScanActive()
    return self._scanning == true
end

---@param itemID number
---@return number|nil
function AHPriceService:GetPrice(itemID)
    if not itemID then return nil end
    local db = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.global.ahPrices
    if type(db) ~= "table" then return nil end
    local row = db[itemID]
    if not row then
        local n = tonumber(itemID)
        if n then
            row = db[n]
        end
    end
    if not row and type(itemID) == "number" then
        row = db[tostring(itemID)]
    end
    return row and row.buyout or nil
end

--- Price with age metadata. `isFresh` uses profile.ahFreshTTL (scan-skip window);
--- `isStale` uses STALE_TTL_SEC — consumers can badge or discard very old prices
--- (GetPrice itself stays age-blind for backward compatibility).
---@param itemID number
---@return number|nil buyout copper per unit
---@return number|nil updatedAt unix time
---@return boolean isFresh
---@return boolean isStale
function AHPriceService:GetPriceInfo(itemID)
    if not itemID then return nil, nil, false, true end
    local db = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.global.ahPrices
    local row = type(db) == "table" and db[itemID] or nil
    if not row then return nil, nil, false, true end
    local updatedAt = tonumber(row.updatedAt)
    local age = updatedAt and (time() - updatedAt) or math.huge
    local freshTTL = (ArtisanNexus.db.profile and tonumber(ArtisanNexus.db.profile.ahFreshTTL)) or DEFAULT_FRESH_TTL_SEC
    return row.buyout, updatedAt, age <= freshTTL, age > STALE_TTL_SEC
end

--- Build the ordered list of every catalog itemID to scan (gathering + fishing +
--- all harvested recipe reagents/outputs + shopping list shorts).
local function BuildItemQueue(includeFresh)
    local ids = {}
    local seen = {}
    local cats = { "herb", "mine", "leather", "disenchant", "others" }
    for _, cat in ipairs(cats) do
        local entries = ns.GetGatheringCatalogByCategory and ns.GetGatheringCatalogByCategory(cat) or {}
        for _, entry in ipairs(entries) do
            local ranks = ns.ResolveCatalogEntryRanks and ns.ResolveCatalogEntryRanks(entry) or {}
            for _, itemID in ipairs(ranks) do
                if not seen[itemID] then
                    seen[itemID] = true
                    ids[#ids + 1] = itemID
                end
            end
        end
    end
    local fish = ns.GetFishingCatalogEntries and ns.GetFishingCatalogEntries() or {}
    for _, entry in ipairs(fish) do
        local ranks = ns.ResolveCatalogEntryRanks and ns.ResolveCatalogEntryRanks(entry) or {}
        for _, itemID in ipairs(ranks) do
            if not seen[itemID] then
                seen[itemID] = true
                ids[#ids + 1] = itemID
            end
        end
    end
    local rs = ns.RecipeService
    if rs and rs.CollectSchematicPriceItemIDs then
        local econIds = rs:CollectSchematicPriceItemIDs()
        for bi = 1, #econIds do
            local itemID = econIds[bi]
            if not seen[itemID] then
                seen[itemID] = true
                ids[#ids + 1] = itemID
            end
        end
    end
    local shop = ns.ShoppingListService
    if shop and shop.GetPurchaseShorts then
        local shorts = shop:GetPurchaseShorts({}) or {}
        for si = 1, #shorts do
            local row = shorts[si]
            if row and row.itemID and not seen[row.itemID] then
                seen[row.itemID] = true
                ids[#ids + 1] = row.itemID
            end
        end
    end
    local db = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.global and ArtisanNexus.db.global.ahPrices
    if not includeFresh and type(db) == "table" then
        local now = time()
        local ttl = (ArtisanNexus.db.profile and ArtisanNexus.db.profile.ahFreshTTL) or DEFAULT_FRESH_TTL_SEC
        local filtered = {}
        for i = 1, #ids do
            local itemID = ids[i]
            local row = db[itemID]
            if not row or not row.updatedAt or (now - row.updatedAt) >= ttl then
                filtered[#filtered + 1] = itemID
            end
        end
        ids = filtered
    end
    return ids
end

--- Catalog size vs stale queue (tooltips / scan start message).
---@param includeFresh boolean|nil When true, counts all tracked items (force full).
---@return table tracked number, queued number, freshSkipped number
function AHPriceService:GetScanPlan(includeFresh)
    local tracked = BuildItemQueue(true)
    local queued = includeFresh and tracked or BuildItemQueue(false)
    return {
        tracked = #tracked,
        queued = #queued,
        freshSkipped = #tracked - #queued,
    }
end

--- Stats for the AH button hover tooltip / future UI.
function AHPriceService:GetCacheStats()
    local db = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.global and ArtisanNexus.db.global.ahPrices
    if type(db) ~= "table" then return { total = 0, fresh = 0, stale = 0, missing = 0, oldest = 0, newest = 0 } end
    local total, fresh, stale = 0, 0, 0
    local oldest, newest = 0, 0
    local now = time()
    local ttl = (ArtisanNexus.db.profile and ArtisanNexus.db.profile.ahFreshTTL) or DEFAULT_FRESH_TTL_SEC
    for _, row in pairs(db) do
        if type(row) == "table" and row.updatedAt then
            total = total + 1
            local age = now - row.updatedAt
            if age < ttl then fresh = fresh + 1
            else stale = stale + 1 end
            if oldest == 0 or row.updatedAt < oldest then oldest = row.updatedAt end
            if row.updatedAt > newest then newest = row.updatedAt end
        end
    end
    return { total = total, fresh = fresh, stale = stale, oldest = oldest, newest = newest }
end

--- Quick queue for responsiveness: currently relevant items first.
--- Priority:
--- 1) Recent session pickups (fishing + each gathering tab)
--- 2) Active tab catalog
--- 3) Fill with full queue if still too small
local function BuildQuickItemQueue()
    local ids = {}
    local seen = {}
    local function push(itemID)
        if not itemID or seen[itemID] then
            return
        end
        seen[itemID] = true
        ids[#ids + 1] = itemID
    end

    local s = ns.SessionLootService
    if s and s.GetRecentEvents then
        local fish = s:GetRecentEvents("fishing", nil, false) or {}
        for i = 1, #fish do
            local e = fish[i]
            if e and e.itemID then
                push(e.itemID)
            end
        end
        local cats = { "herb", "mine", "leather", "disenchant", "others" }
        for ci = 1, #cats do
            local evs = s:GetRecentEvents("gathering", cats[ci], false) or {}
            for i = 1, #evs do
                local e = evs[i]
                if e and e.itemID then
                    push(e.itemID)
                end
            end
        end
    end

    local activeTab = ns.db and ns.db.profile and ns.db.profile.lootHistoryActiveTab
    if activeTab == "fishing" and ns.GetFishingCatalogEntries then
        local entries = ns.GetFishingCatalogEntries() or {}
        for i = 1, #entries do
            local ranks = ns.ResolveCatalogEntryRanks and ns.ResolveCatalogEntryRanks(entries[i]) or {}
            for r = 1, #ranks do
                push(ranks[r])
            end
        end
    elseif activeTab and ns.GetGatheringCatalogByCategory then
        local entries = ns.GetGatheringCatalogByCategory(activeTab) or {}
        for i = 1, #entries do
            local ranks = ns.ResolveCatalogEntryRanks and ns.ResolveCatalogEntryRanks(entries[i]) or {}
            for r = 1, #ranks do
                push(ranks[r])
            end
        end
    end

    -- Economy: every harvested schematic reagent tier + output (no cap — quick scan was
    -- stopping at QUICK_SCAN_MAX_ITEMS and leaving most recipe prices missing).
    local rs = ns.RecipeService
    if rs and rs.CollectSchematicPriceItemIDs then
        local econIds = rs:CollectSchematicPriceItemIDs()
        for bi = 1, #econIds do
            push(econIds[bi])
        end
    end
    local shop = ns.ShoppingListService
    if shop and shop.GetPurchaseShorts then
        local shorts = shop:GetPurchaseShorts({}) or {}
        for si = 1, #shorts do
            local row = shorts[si]
            if row and row.itemID then
                push(row.itemID)
            end
        end
    end

    local full = BuildItemQueue(false)
    for i = 1, #full do
        if #ids >= QUICK_SCAN_MAX_ITEMS then
            break
        end
        push(full[i])
    end

    return ids
end

--- AceGUI label: idle title or scan progress text.
local function UpdateAHButtonText()
    local widget = AHPriceService._ahButton
    if not widget or not widget.SetText then
        return
    end

    local total = AHPriceService._totalItems or 0
    local done = AHPriceService._scannedItems or 0
    local pctInt = (total > 0) and math.floor(math.min(1, done / total) * 100 + 0.5) or 0
    local text
    if AHPriceService._paused then
        text = string.format(
            L("AH_SYNC_PAUSED_FMT", "Paused %d / %d  (%d%%)"),
            done, total, pctInt)
    elseif AHPriceService._scanning then
        text = string.format(
            L("AH_SYNC_PROGRESS_FMT", "Syncing %d / %d  (%d%%)"),
            done, total, pctInt)
    else
        text = L("AH_SYNC_PRICES", "Sync AH Prices")
    end
    widget:SetText(text)
    local af = _G.AuctionHouseFrame
    if af then
        ApplyAHSyncButtonAnchor(widget, af)
    end
end

local function AHIsOpen()
    if not C_AuctionHouse then
        return false
    end
    local af = _G.AuctionHouseFrame
    if not af then
        return false
    end
    if af.IsShown and af:IsShown() then
        return true
    end
    if af.IsVisible and af:IsVisible() then
        return true
    end
    return false
end

local function CanUseBatchScan()
    return C_AuctionHouse
        and C_AuctionHouse.SearchForItemKeys
        and C_AuctionHouse.GetBrowseResults
end

--- SearchForItemKeys repaints the Buy tab browse list; snapshot Blizzard's active query to restore after scan.
local function SnapshotBrowseForRestore()
    local af = _G.AuctionHouseFrame
    if not af or type(af.activeSearches) ~= "table" or not af.GetBrowseSearchContext then
        return nil
    end
    local displayMode = _G.AuctionHouseFrameDisplayMode
    if displayMode and af.displayMode ~= displayMode.Buy then
        return nil
    end
    local ctx = af:GetBrowseSearchContext()
    local active = ctx and af.activeSearches[ctx]
    if type(active) ~= "table" or #active < 1 then
        return nil
    end
    local params = {}
    for i = 1, #active do
        local v = active[i]
        if type(v) == "table" then
            local copy = {}
            for j = 1, #v do
                copy[j] = v[j]
            end
            for k, val in pairs(v) do
                if type(k) ~= "number" then
                    copy[k] = val
                end
            end
            params[i] = copy
        else
            params[i] = v
        end
    end
    return { context = ctx, params = params }
end

local function RestoreBrowseAfterScan(snapshot)
    if not snapshot or type(snapshot.params) ~= "table" then
        return
    end
    local af = _G.AuctionHouseFrame
    if not af or not AHIsOpen() then
        return
    end
    local favCtx = _G.AuctionHouseSearchContext and _G.AuctionHouseSearchContext.AllFavorites
    if favCtx and snapshot.context == favCtx and af.QueryAll then
        af:QueryAll(snapshot.context)
        return
    end
    if af.SendBrowseQueryInternal then
        af:SendBrowseQueryInternal(unpack(snapshot.params))
    end
end

local function ScheduleBrowseRestore(snapshot)
    if not snapshot then
        return
    end
    After(0.05, function()
        if AHPriceService._scanning or AHPriceService._paused then
            return
        end
        RestoreBrowseAfterScan(snapshot)
    end)
end

local function FinishScan()
    local self = AHPriceService
    self._scanning = false
    self._paused = false
    self._batchMode = false
    self._batchExpectId = nil
    self._batchChunkSize = 0
    self._batchPendingSet = nil
    self._legacyTail = nil
    self._currentItemID = nil
    self._expectQueryId = nil
    self._suppressPriceMessages = false
    self._consecutiveTimeouts = 0
    self._currentStepSec = SCAN_STEP_SEC
    UpdateAHButtonText()
    local scanned = self._scannedItems or 0
    local priced = self._pricedThisScan or 0
    local legacy = self._legacyQueuedThisScan or 0
    local elapsed = 0
    if GetTime and self._scanStartedAt then
        elapsed = math.max(0, GetTime() - self._scanStartedAt)
    end
    if legacy > 0 then
        Notify(string.format(
            L("AH_SCAN_DONE_DETAIL", "AH scan done in %.1fs — %d prices updated, %d checked (%d commodity lookups)."),
            elapsed, priced, scanned, legacy))
    else
        Notify(string.format(
            L("AH_SCAN_DONE_FAST", "AH scan done in %.1fs — %d prices updated, %d checked (batch only, no commodity lookups)."),
            elapsed, priced, scanned))
    end
    self._pricedThisScan = 0
    self._legacyQueuedThisScan = 0
    local browseSnap = self._browseSnapshot
    self._browseSnapshot = nil
    ScheduleBrowseRestore(browseSnap)
    if ArtisanNexus and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.AH_PRICES_UPDATED)
        if E.AH_SCAN_COMPLETE then
            ArtisanNexus:SendMessage(E.AH_SCAN_COMPLETE, {
                kind = "scan",
                scanned = self._scannedItems or 0,
                total = self._totalItems or 0,
            })
        end
    end
end

function AHPriceService:BeginScanPipeline()
    if not self._scanning then
        return
    end
    if CanUseBatchScan() then
        self:StartNextBatch()
    else
        self:ScanNext()
    end
end

function AHPriceService:StartNextBatch()
    if not self._scanning or self._paused then
        return
    end
    if not AHIsOpen() then
        self._scanning = false
        self._batchMode = false
        self._batchExpectId = nil
        self._paused = (#self._queue > 0)
        UpdateAHButtonText()
        return
    end
    if #self._queue < 1 then
        if DrainLegacyTailIfNeeded() then
            return
        end
        FinishScan()
        return
    end

    local chunkSize = math.min(BATCH_MAX_KEYS, #self._queue)
    local keys = {}
    local pending = {}
    for i = 1, chunkSize do
        local itemID = table.remove(self._queue, 1)
        if itemID then
            pending[itemID] = true
            local key = MakeQueryItemKey(itemID)
            if key then
                keys[#keys + 1] = key
            end
        end
    end
    if #keys < 1 then
        self._scannedItems = self._scannedItems + chunkSize
        UpdateAHButtonText()
        self:StartNextBatch()
        return
    end

    self._batchMode = true
    self._batchChunkSize = chunkSize
    self._batchPendingSet = pending
    --- Monotonic, never-reset sequence: CompleteBatch nils _batchExpectId, so a
    --- resettable counter would reuse id 1 and let a stale timeout demote the
    --- NEXT healthy batch to the slow legacy path.
    self._batchSeq = (self._batchSeq or 0) + 1
    self._batchExpectId = self._batchSeq
    local bid = self._batchExpectId

    local function sendBatch()
        if not AHPriceService._scanning or AHPriceService._batchExpectId ~= bid then
            return
        end
        local ok = pcall(C_AuctionHouse.SearchForItemKeys, keys, SEARCH_SORTS)
        if not ok then
            AHPriceService:FallbackBatchToLegacy(bid)
        end
    end

    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        local throttleFrame = CreateFrame("Frame")
        local sent = false
        local function trySend()
            if sent or AHPriceService._batchExpectId ~= bid then
                return
            end
            if C_AuctionHouse.IsThrottledMessageSystemReady() then
                sent = true
                throttleFrame:UnregisterAllEvents()
                sendBatch()
            end
        end
        throttleFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        throttleFrame:SetScript("OnEvent", trySend)
        After(2, trySend)
    else
        sendBatch()
    end

    After(BATCH_RESULT_TIMEOUT_SEC, function()
        if AHPriceService._scanning and AHPriceService._batchExpectId == bid then
            AHPriceService:FallbackBatchToLegacy(bid)
        end
    end)
end

function AHPriceService:CompleteBatch(bid)
    if not self._scanning or self._batchExpectId ~= bid then
        return
    end
    self._batchExpectId = nil
    self._batchMode = false
    self._batchPendingSet = nil
    self._scannedItems = self._scannedItems + (self._batchChunkSize or 0)
    self._batchChunkSize = 0
    UpdateAHButtonText()
    if #self._queue > 0 then
        After(0.02, function()
            AHPriceService:StartNextBatch()
        end)
    elseif DrainLegacyTailIfNeeded() then
        return
    else
        FinishScan()
    end
end

function AHPriceService:FallbackBatchToLegacy(bid)
    if self._batchExpectId ~= bid then
        return
    end
    local pending = self._batchPendingSet
    self._batchExpectId = nil
    self._batchMode = false
    self._batchPendingSet = nil
    if pending then
        local restore = {}
        for itemID, _ in pairs(pending) do
            restore[#restore + 1] = itemID
        end
        table.sort(restore)
        for i = #restore, 1, -1 do
            table.insert(self._queue, 1, restore[i])
        end
    end
    self._batchChunkSize = 0
    if ns.DebugPrint then
        ns.DebugPrint("|cff9370DB[AN AH]|r batch fallback to per-item scan")
    end
    self:ScanNext()
end

local function ProcessBrowseBatchResults(bid)
    if not AHPriceService._scanning or AHPriceService._batchExpectId ~= bid then
        return
    end
    local pending = AHPriceService._batchPendingSet
    if not pending then
        return
    end
    local priced = {}
    local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
    if ok and type(results) == "table" then
        for ri = 1, #results do
            local row = results[ri]
            if row and row.itemKey and row.itemKey.itemID and pending[row.itemKey.itemID] then
                local minPrice = tonumber(row.minPrice)
                if minPrice and minPrice > 0 then
                    SavePrice(row.itemKey.itemID, minPrice, true)
                    priced[row.itemKey.itemID] = true
                end
            end
        end
    end
    -- Commodities need legacy follow-up; unique items with no browse row count as resolved.
    local pricedCount = 0
    for _ in pairs(priced) do
        pricedCount = pricedCount + 1
    end
    local resolvedCount = pricedCount
    local legacyQueued = 0
    for itemID in pairs(pending) do
        if not priced[itemID] then
            if ItemIsCommodity(itemID) then
                QueueLegacyFollowup(itemID)
                legacyQueued = legacyQueued + 1
            else
                resolvedCount = resolvedCount + 1
            end
        end
    end
    AHPriceService._batchChunkSize = resolvedCount
    if legacyQueued > 0 and ns.DebugPrint then
        ns.DebugPrint(string.format("|cff9370DB[AN AH]|r batch priced %d, legacy queued %d", pricedCount, legacyQueued))
    end
    AHPriceService:CompleteBatch(bid)
end

function AHPriceService:ScanNext()
    if not self._scanning then return end
    if self._paused then return end
    if not AHIsOpen() then
        -- AH closed mid-scan: keep the queue intact and surface a "resume"
        -- prompt the next time the AH is opened.
        self._scanning = false
        self._expectQueryId = nil
        self._currentItemID = nil
        self._paused = (#self._queue > 0)
        UpdateAHButtonText()
        return
    end
    if #self._queue == 0 then
        if DrainLegacyTailIfNeeded() then
            return
        end
        FinishScan()
        return
    end

    local itemID = table.remove(self._queue, 1)
    self._currentItemID = itemID
    self._scannedItems = self._scannedItems + 1
    UpdateAHButtonText()

    self._expectQueryId = (self._expectQueryId or 0) + 1
    local qid = self._expectQueryId

    local itemKey = MakeQueryItemKey(itemID)
    if not itemKey then
        self._expectQueryId = nil
        After(self._currentStepSec, function() AHPriceService:ScanNext() end)
        return
    end

    local ok = pcall(function()
        C_AuctionHouse.SendSearchQuery(itemKey, SEARCH_SORTS, false)
    end)
    if not ok then
        self._expectQueryId = nil
        Notify(L("AH_SCAN_QUERY_FAIL", "Auction search failed for one item; skipping."))
        After(self._currentStepSec, function() AHPriceService:ScanNext() end)
        return
    end

    After(SEARCH_RESULT_TIMEOUT_SEC, function()
        if not AHPriceService._scanning then return end
        if AHPriceService._expectQueryId ~= qid then return end
        AHPriceService._expectQueryId = nil
        -- Adaptive backoff: each consecutive timeout slows the next step by
        -- 25% (capped) so we don't pile queries during AH rate-limit spikes.
        AHPriceService._consecutiveTimeouts = (AHPriceService._consecutiveTimeouts or 0) + 1
        if AHPriceService._consecutiveTimeouts >= 2 then
            AHPriceService._currentStepSec = math.min(SCAN_STEP_MAX_SEC, AHPriceService._currentStepSec * 1.25)
        end
        After(AHPriceService._currentStepSec, function() AHPriceService:ScanNext() end)
    end)
end

--- Pause/resume controls for the right-click menu and scan-on-AH-close logic.
function AHPriceService:Pause()
    if not self._scanning then
        return
    end
    if self._batchExpectId and self._batchPendingSet then
        local restore = {}
        for itemID, _ in pairs(self._batchPendingSet) do
            restore[#restore + 1] = itemID
        end
        table.sort(restore)
        for i = #restore, 1, -1 do
            table.insert(self._queue, 1, restore[i])
        end
        -- No _scannedItems rollback: the batch path only credits progress in
        -- CompleteBatch, so an in-flight chunk was never counted — subtracting
        -- here double-penalized every mid-batch pause and capped scans below 100%.
    end
    self._batchMode = false
    self._batchExpectId = nil
    self._batchPendingSet = nil
    self._batchChunkSize = 0
    self._paused = true
    self._scanning = false
    self._expectQueryId = nil
    self._currentItemID = nil
    UpdateAHButtonText()
end

function AHPriceService:Resume()
    if self._scanning then return end
    if not AHIsOpen() then
        Notify(L("AH_SCAN_NEED_OPEN", "Open the Auction House window first."))
        return
    end
    if #self._queue == 0 then
        self._paused = false
        UpdateAHButtonText()
        return
    end
    self._paused = false
    self._scanning = true
    self._suppressPriceMessages = true
    self._scanStartedAt = GetTime and GetTime() or 0
    UpdateAHButtonText()
    self:BeginScanPipeline()
end

function AHPriceService:ShowContextMenu(anchor)
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(anchor or UIParent, function(_, root)
            root:CreateTitle(L("AH_SYNC_PRICES", "Sync AH Prices"))
            if self._scanning then
                root:CreateButton("Pause scan", function() self:Pause() end)
                root:CreateButton("Cancel scan", function() self:Cancel() end)
            elseif self._paused then
                root:CreateButton("Resume scan", function() self:Resume() end)
                root:CreateButton("Cancel scan", function() self:Cancel() end)
            else
                root:CreateButton("Quick scan (recent items)", function() self:StartScan(false, false) end)
                root:CreateButton("Refresh stale items", function() self:StartScan(false, true) end)
                root:CreateButton("Force full rescan", function() self:StartScan(true, true) end)
            end
            root:CreateDivider()
            local stats = self:GetCacheStats()
            root:CreateTitle(string.format("Cache: %d items (%d fresh)", stats.total, stats.fresh))
        end)
    else
        Notify("Context menu API unavailable on this client; use left-click.")
    end
end

function AHPriceService:Cancel()
    self._scanning = false
    self._paused = false
    self._batchMode = false
    self._batchExpectId = nil
    self._batchPendingSet = nil
    self._batchChunkSize = 0
    self._suppressPriceMessages = false
    self._queue = {}
    self._legacyTail = nil
    self._currentItemID = nil
    self._expectQueryId = nil
    self._totalItems = 0
    self._scannedItems = 0
    self._pricedThisScan = 0
    self._legacyQueuedThisScan = 0
    self._consecutiveTimeouts = 0
    self._currentStepSec = SCAN_STEP_SEC
    local browseSnap = self._browseSnapshot
    self._browseSnapshot = nil
    UpdateAHButtonText()
    ScheduleBrowseRestore(browseSnap)
end

---@param force boolean|nil If true, clears an in-progress or stuck scan and starts over.
---@param fullScan boolean|nil If true, scan whole catalog instead of quick queue.
function AHPriceService:StartScan(force, fullScan)
    if force then
        self._scanning = false
        self._paused = false
        self._expectQueryId = nil
        self._currentItemID = nil
        self._queue = {}
        self._legacyTail = nil
    end
    if self._scanning then
        Notify(L("AH_SCAN_BUSY", "AH price scan is already running."))
        return
    end
    if not AHIsOpen() then
        Notify(L("AH_SCAN_NEED_OPEN", "Open the Auction House window first."))
        return
    end
    local useFull = (fullScan ~= false)
    if useFull then
        -- Force=true means "rescan everything"; force=false honors TTL (skip fresh items).
        self._queue = BuildItemQueue(force == true)
    else
        self._queue = BuildQuickItemQueue()
    end
    local n = #self._queue
    if n == 0 then
        Notify(L("AH_SCAN_UP_TO_DATE", "AH cache is up to date — no items need a refresh."))
        return
    end
    local plan = self:GetScanPlan(force == true)
    self._scanning = true
    self._paused = false
    self._totalItems = n
    self._scannedItems = 0
    self._pricedThisScan = 0
    self._legacyQueuedThisScan = 0
    self._consecutiveTimeouts = 0
    self._currentStepSec = SCAN_STEP_SEC
    self._scanStartedAt = GetTime and GetTime() or 0
    if useFull then self._lastFullScanAt = time() end
    self._suppressPriceMessages = true
    self._batchMode = false
    self._batchExpectId = nil
    self._legacyTail = {}
    self._browseSnapshot = SnapshotBrowseForRestore()
    UpdateAHButtonText()
    if plan.freshSkipped > 0 then
        Notify(string.format(
            L("AH_SCAN_STARTED_PLAN", "Starting AH scan: %d to refresh (%d tracked, %d fresh skipped)."),
            n, plan.tracked, plan.freshSkipped))
    else
        Notify(string.format(L("AH_SCAN_STARTED", "Starting AH price scan (%d items)."), n))
    end
    self:BeginScanPipeline()
end

function SavePrice(itemID, unitPrice, suppressMessage)
    if not ArtisanNexus or not ArtisanNexus.db then return end
    local g = ArtisanNexus.db.global
    if type(g.ahPrices) ~= "table" then
        g.ahPrices = {}
    end
    g.ahPrices[itemID] = { buyout = unitPrice, updatedAt = time() }
    -- Append to rolling history (cheap; PriceHistoryService dedups within 5min).
    if ns.PriceHistoryService and ns.PriceHistoryService.Push then
        ns.PriceHistoryService:Push(itemID, unitPrice)
    end
    if AHPriceService._suppressPriceMessages then
        AHPriceService._pricedThisScan = (AHPriceService._pricedThisScan or 0) + 1
    end
    if suppressMessage or AHPriceService._suppressPriceMessages then
        return
    end
    if ArtisanNexus and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.AH_PRICES_UPDATED)
    end
end

local function ScheduleScanStep()
    After(AHPriceService._currentStepSec or SCAN_STEP_SEC, function() AHPriceService:ScanNext() end)
end

--- Consume this query id once; duplicate events or late timeouts are ignored.
---@param qid number
---@return boolean
local function TryConsumeQuery(qid)
    if AHPriceService._expectQueryId ~= qid then
        return false
    end
    AHPriceService._expectQueryId = nil
    return true
end

local function OnCommodityResults(itemID, qid)
    if AHPriceService._batchMode then
        return
    end
    if not AHPriceService._scanning then
        return
    end
    if itemID ~= AHPriceService._currentItemID then
        return
    end
    if not TryConsumeQuery(qid) then
        return
    end
    local ok, numResults = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
    if ok and numResults and numResults > 0 then
        local ok2, result = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, 1)
        if ok2 and result and result.unitPrice and result.unitPrice > 0 then
            SavePrice(itemID, result.unitPrice, true)
        end
    end
    -- Successful round → cool the adaptive backoff back down.
    AHPriceService._consecutiveTimeouts = 0
    if AHPriceService._currentStepSec > SCAN_STEP_SEC then
        AHPriceService._currentStepSec = math.max(SCAN_STEP_SEC, AHPriceService._currentStepSec * 0.85)
    end
    ScheduleScanStep()
end

--- Non-commodity items use item search results instead.
local function OnItemSearchResults(itemKey, qid)
    if AHPriceService._batchMode then
        return
    end
    if not AHPriceService._scanning then
        return
    end
    if not itemKey or type(itemKey) ~= "table" or not itemKey.itemID then
        return
    end
    if itemKey.itemID ~= AHPriceService._currentItemID then
        return
    end
    --- Commodity items sometimes deliver `ITEM_SEARCH_RESULTS_UPDATED` before or without a separate commodity callback; process here or the queue stalls.
    local okComm, numComm = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemKey.itemID)
    if okComm and numComm and numComm > 0 then
        OnCommodityResults(itemKey.itemID, qid)
        return
    end
    if not TryConsumeQuery(qid) then
        return
    end
    local ok, num = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
    if ok and num and num > 0 then
        local ok2, result = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, 1)
        if ok2 and result and result.buyoutAmount and result.quantity and result.quantity > 0 then
            local unit = math.floor(result.buyoutAmount / result.quantity)
            if unit > 0 then
                SavePrice(itemKey.itemID, unit, true)
            end
        end
    end
    -- Successful round → cool the adaptive backoff back down.
    AHPriceService._consecutiveTimeouts = 0
    if AHPriceService._currentStepSec > SCAN_STEP_SEC then
        AHPriceService._currentStepSec = math.max(SCAN_STEP_SEC, AHPriceService._currentStepSec * 0.85)
    end
    ScheduleScanStep()
end

--- AceGUI Button in CategoriesList footer (Browse tab).
local function TryCreateAHButton()
    if AHPriceService._ahButtonCreated then
        return
    end
    if not AceGUI then
        return
    end
    local parent = _G.AuctionHouseFrame
    if not parent or not parent.CategoriesList then
        return
    end

    local widget = AceGUI:Create("Button")
    local frame = widget.frame
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    widget:SetAutoWidth(false)
    widget:SetText(L("AH_SYNC_PRICES", "Sync AH Prices"))

    widget:SetCallback("OnClick", function(_, _, mouseButton)
        if mouseButton == "RightButton" then
            AHPriceService:ShowContextMenu(frame)
            return
        end
        if AHPriceService._paused then
            AHPriceService:Resume()
        elseif AHPriceService._scanning then
            AHPriceService:Pause()
        else
            AHPriceService:StartScan(false, true)
        end
    end)
    widget:SetCallback("OnEnter", function()
        ShowAHSyncTooltip(frame)
    end)
    widget:SetCallback("OnLeave", function()
        GameTooltip:Hide()
    end)

    ApplyAHSyncButtonAnchor(widget, parent)

    local cat = parent.CategoriesList
    if cat and not cat.ArtisanNexusAHSyncAnchorHook then
        cat.ArtisanNexusAHSyncAnchorHook = true
        cat:HookScript("OnShow", ScheduleAHSyncAnchorRefresh)
        cat:HookScript("OnHide", ScheduleAHSyncAnchorRefresh)
    end

    AHPriceService._ahButtonCreated = true
    AHPriceService._ahButton = widget
    UpdateAHButtonText()
    ScheduleAHSyncAnchorRefresh()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
eventFrame:SetScript("OnEvent", function(_, event, arg1, ...)
    if event == "ADDON_LOADED" then
        if arg1 == "Blizzard_AuctionHouseUI" or arg1 == ADDON_NAME then
            TryCreateAHButton()
            local af = _G.AuctionHouseFrame
            if af and not af.ArtisanNexusAHHook then
                af.ArtisanNexusAHHook = true
                af:HookScript("OnShow", function()
                    TryCreateAHButton()
                    if AHPriceService._ahButton then
                        ApplyAHSyncButtonAnchor(AHPriceService._ahButton, af)
                        ScheduleAHSyncAnchorRefresh()
                    end
                end)
            end
        end
        return
    end
    if event == "AUCTION_HOUSE_SHOW" then
        TryCreateAHButton()
        local af = _G.AuctionHouseFrame
        if AHPriceService._ahButton and af then
            ApplyAHSyncButtonAnchor(AHPriceService._ahButton, af)
            ScheduleAHSyncAnchorRefresh()
        end
        -- Auto-resume any paused scan from a previous AH session so the user
        -- doesn't have to click again. Skip if AH was reopened on a different toon.
        if AHPriceService._paused and #AHPriceService._queue > 0 then
            After(0.5, function()
                if AHIsOpen() and AHPriceService._paused then
                    Notify(string.format(L("AH_SCAN_AUTO_RESUME", "Resuming AH scan (%d items left)."),
                        #AHPriceService._queue))
                    AHPriceService:Resume()
                end
            end)
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        -- Pause() restores an in-flight batch's pending items into the queue so a
        -- mid-batch close doesn't silently skip up to a full chunk on resume.
        if AHPriceService._scanning then
            AHPriceService:Pause()
            AHPriceService._paused = (#AHPriceService._queue > 0)
            UpdateAHButtonText()
        end
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        local itemID = arg1
        local qid = AHPriceService._expectQueryId
        if qid then
            OnCommodityResults(itemID, qid)
        end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        local itemKey = arg1
        local qid = AHPriceService._expectQueryId
        if qid then
            OnItemSearchResults(itemKey, qid)
        end
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        local bid = AHPriceService._batchExpectId
        if bid and AHPriceService._scanning then
            AHPriceService._batchBrowseToken = (AHPriceService._batchBrowseToken or 0) + 1
            local token = AHPriceService._batchBrowseToken
            After(0.4, function()
                if AHPriceService._batchBrowseToken ~= token then
                    return
                end
                if AHPriceService._batchExpectId == bid and AHPriceService._scanning then
                    ProcessBrowseBatchResults(bid)
                end
            end)
        end
    elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
        local bid = AHPriceService._batchExpectId
        if bid and AHPriceService._scanning then
            AHPriceService:FallbackBatchToLegacy(bid)
        end
    end
end)

ns.AHPriceService = AHPriceService
