--[[
    AH commodity price scanner for gathering catalog items.

    On AUCTION_HOUSE_SHOW, queues all catalog itemIDs and queries them one by one
    via C_AuctionHouse.SendSearchQuery.  Item keys must use C_AuctionHouse.MakeItemKey
    (raw tables with wrong field names fail silently on some clients).  Commodity vs
    non-commodity: COMMODITY_SEARCH_RESULTS_UPDATED vs ITEM_SEARCH_RESULTS_UPDATED.
    A timeout advances the queue if neither fires.

    Callers:
        ns.AHPriceService:GetPrice(itemID)  → copper unit price or nil
        ns.AHPriceService:StartScan(force)  → force=true clears a stuck scan and restarts
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS
local ApplyVisuals = ns.UI_ApplyVisuals
local COLORS = ns.UI_COLORS
local AHPriceService

--- Seconds between individual commodity queries (Blizzard throttle headroom).
--- Keep low for responsiveness; server-side throttling still applies.
local SCAN_STEP_SEC = 0.15

--- If neither commodity nor item result events fire, still advance.
local SEARCH_RESULT_TIMEOUT_SEC = 2.5

local QUICK_SCAN_MAX_ITEMS = 28

--- Per-item cache freshness. Items younger than this are skipped on incremental
--- scans (force=true / right-click "Full scan" overrides). Tunable via DB.
local DEFAULT_FRESH_TTL_SEC = 60 * 60 * 6   -- 6 hours
local STALE_TTL_SEC         = 60 * 60 * 24  -- 24 hours

--- Adaptive backoff cap. After repeated timeouts we slow the queue so we don't
--- hammer the AH and trip Blizzard's rate limit.
local SCAN_STEP_MAX_SEC = 0.6

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

--- Stable anchor: dock the button to the AH frame's title bar, just left of
--- the close button. Independent of which AH tab is active, never shifts
--- when the user switches Browse/Buy/Sell/Auctions, never collides with
--- tab content because it lives in the chrome above it.
local function ApplyAHSyncButtonAnchor(btn, parent)
    if not btn or not parent then return end
    btn:ClearAllPoints()
    local closeBtn = parent.CloseButton or _G.AuctionHouseFrameCloseButton
    if closeBtn and closeBtn.GetRight then
        btn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -2, -2)
    else
        btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -28, -4)
    end
end

local function ApplyAHButtonStyle(btn, isHover)
    if not btn then
        return
    end
    local scanning = AHPriceService and AHPriceService._scanning
    local colors = COLORS or {}
    local bg = colors.tabInactive or { 0.12, 0.11, 0.13, 1 }
    local border = colors.border or { 0.42, 0.38, 0.50, 0.9 }
    if scanning then
        bg = colors.tabActive or { 0.22, 0.18, 0.30, 1 }
        border = colors.accent or { 0.52, 0.40, 0.66, 0.95 }
    elseif isHover then
        bg = colors.tabHover or { 0.24, 0.20, 0.32, 1 }
        border = colors.borderLight or colors.accent or { 0.58, 0.50, 0.72, 0.95 }
    end
    if ApplyVisuals then
        ApplyVisuals(btn, bg, { border[1], border[2], border[3], border[4] or 0.95 })
    else
        if btn.SetBackdrop then
            btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
            btn:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
        end
    end
    if btn._label then
        local tc = colors.textBright or { 0.98, 0.97, 0.99, 1 }
        btn._label:SetTextColor(tc[1], tc[2], tc[3], tc[4] or 1)
    end
    if btn._icon then
        local ic = scanning and (colors.accent or { 0.52, 0.40, 0.66, 1 }) or (colors.textNormal or { 0.88, 0.84, 0.92, 1 })
        btn._icon:SetVertexColor(ic[1], ic[2], ic[3], 1)
    end
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
    _scanStartedAt = 0,
    _consecutiveTimeouts = 0,
    _currentStepSec = SCAN_STEP_SEC,
    _lastFullScanAt = 0,
}

local function ScheduleAHSyncAnchorRefresh()
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

--- Unit price in copper for itemID, or nil if never scanned / not on AH.
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

--- Build the ordered list of every catalog itemID to scan (gathering tabs: herb, mine, leather, disenchant, others + `GetFishingCatalogEntries`).
--- Keep category lists in sync when adding new `BY_CAT` rows or fishing entries.
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

    local full = BuildItemQueue(false)
    for i = 1, #full do
        if #ids >= QUICK_SCAN_MAX_ITEMS then
            break
        end
        push(full[i])
    end

    return ids
end

local function FormatRemaining(seconds)
    if seconds < 60 then return string.format("%ds", math.max(1, math.floor(seconds))) end
    if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
    return string.format("%dh", math.floor(seconds / 3600))
end

--- Update the visual state of the icon-only button: progress fill bar
--- when scanning, "II" overlay when paused, otherwise plain coin.
local function UpdateAHButtonText()
    local btn = AHPriceService._ahButton
    if not btn then return end

    if AHPriceService._scanning then
        -- Show the progress bar across the bottom of the icon
        if btn._progressBg then btn._progressBg:Show() end
        if btn._progressFill then
            btn._progressFill:Show()
            local total = AHPriceService._totalItems
            local done = AHPriceService._scannedItems
            local pct = (total > 0) and math.min(1, done / total) or 0
            local fullW = btn:GetWidth() - 2
            btn._progressFill:SetWidth(math.max(1, fullW * pct))
        end
        if btn._pauseGlyph then btn._pauseGlyph:Hide() end
        if btn._icon then btn._icon:SetDesaturated(false) end
    elseif AHPriceService._paused then
        -- Pause overlay; keep progress bar visible (shows where we stopped)
        if btn._progressBg then btn._progressBg:Show() end
        if btn._progressFill then
            btn._progressFill:Show()
            local total = AHPriceService._totalItems
            local done = AHPriceService._scannedItems
            local pct = (total > 0) and math.min(1, done / total) or 0
            local fullW = btn:GetWidth() - 2
            btn._progressFill:SetWidth(math.max(1, fullW * pct))
        end
        if btn._pauseGlyph then btn._pauseGlyph:Show() end
        if btn._icon then btn._icon:SetDesaturated(true) end
    else
        if btn._progressBg then btn._progressBg:Hide() end
        if btn._progressFill then btn._progressFill:Hide() end
        if btn._pauseGlyph then btn._pauseGlyph:Hide() end
        if btn._icon then btn._icon:SetDesaturated(false) end
    end
    ApplyAHButtonStyle(btn, btn._isHover == true)
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
        self._scanning = false
        self._paused = false
        self._currentItemID = nil
        self._expectQueryId = nil
        self._consecutiveTimeouts = 0
        self._currentStepSec = SCAN_STEP_SEC
        UpdateAHButtonText()
        Notify(L("AH_SCAN_DONE", "AH price scan finished."))
        if ArtisanNexus and ArtisanNexus.SendMessage then
            ArtisanNexus:SendMessage(E.AH_PRICES_UPDATED)
        end
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
        C_AuctionHouse.SendSearchQuery(
            itemKey,
            { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
            false
        )
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
    if not self._scanning then return end
    self._paused = true
    self._scanning = false
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
    self._scanStartedAt = GetTime and GetTime() or 0
    UpdateAHButtonText()
    self:ScanNext()
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
    self._queue = {}
    self._currentItemID = nil
    self._expectQueryId = nil
    self._totalItems = 0
    self._scannedItems = 0
    self._consecutiveTimeouts = 0
    self._currentStepSec = SCAN_STEP_SEC
    UpdateAHButtonText()
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
    self._scanning = true
    self._paused = false
    self._totalItems = n
    self._scannedItems = 0
    self._consecutiveTimeouts = 0
    self._currentStepSec = SCAN_STEP_SEC
    self._scanStartedAt = GetTime and GetTime() or 0
    if useFull then self._lastFullScanAt = time() end
    UpdateAHButtonText()
    Notify(string.format(L("AH_SCAN_STARTED", "Starting AH price scan (%d items)."), n))
    self:ScanNext()
end

local function SavePrice(itemID, unitPrice)
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
    --- Loot History totals/session lines multiply stack sizes by **latest** unit price; notify UI after each commodity/item result.
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
            SavePrice(itemID, result.unitPrice)
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
        local best
        for i = 1, num do
            local ok2, result = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
            if ok2 and result and result.buyoutAmount and result.quantity and result.quantity > 0 then
                local unit = math.floor(result.buyoutAmount / result.quantity)
                if unit > 0 and (not best or unit < best) then
                    best = unit
                end
            end
        end
        if best then
            SavePrice(itemKey.itemID, best)
        end
    end
    -- Successful round → cool the adaptive backoff back down.
    AHPriceService._consecutiveTimeouts = 0
    if AHPriceService._currentStepSec > SCAN_STEP_SEC then
        AHPriceService._currentStepSec = math.max(SCAN_STEP_SEC, AHPriceService._currentStepSec * 0.85)
    end
    ScheduleScanStep()
end

--- Compact, single-purpose icon button. Sits flush with the AH portrait;
--- no text label, no progress text bleed into the chrome. Visual state:
---   * idle      → coin icon, soft border
---   * scanning  → spinning highlight + progress fill bar across the bottom
---   * paused    → amber border + "II" overlay
local function TryCreateAHButton()
    if AHPriceService._ahButtonCreated then return end
    local parent = _G.AuctionHouseFrame
    if not parent then return end
    local btn = CreateFrame("Button", "ArtisanNexusAHSyncBtn", parent, "BackdropTemplate")
    if not btn then return end
    btn:SetSize(22, 22)
    ApplyAHSyncButtonAnchor(btn, parent)
    btn:SetFrameStrata("HIGH")
    btn:SetFrameLevel(parent:GetFrameLevel() + 50)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetHitRectInsets(0, 0, 0, 0)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn._icon = icon

    -- Pause overlay glyph (only shown when paused)
    local pauseGlyph = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    pauseGlyph:SetPoint("CENTER")
    pauseGlyph:SetText("|cffffd700II|r")
    pauseGlyph:Hide()
    btn._pauseGlyph = pauseGlyph

    -- Progress fill bar (bottom edge), 0..100% width
    local progressBg = btn:CreateTexture(nil, "OVERLAY")
    progressBg:SetPoint("BOTTOMLEFT", 1, 1)
    progressBg:SetPoint("BOTTOMRIGHT", -1, 1)
    progressBg:SetHeight(2)
    progressBg:SetColorTexture(0, 0, 0, 0.6)
    progressBg:Hide()
    btn._progressBg = progressBg

    local progressFill = btn:CreateTexture(nil, "OVERLAY")
    progressFill:SetPoint("BOTTOMLEFT", 1, 1)
    progressFill:SetHeight(2)
    progressFill:SetColorTexture(0.85, 0.65, 1.0, 1)
    progressFill:Hide()
    btn._progressFill = progressFill

    btn._label = nil  -- legacy field; no in-chrome label any more

    btn:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            AHPriceService:ShowContextMenu(self)
            return
        end
        -- Single coherent left-click action:
        --   idle      → start incremental scan (TTL-aware; "up to date" toast if nothing stale)
        --   scanning  → pause
        --   paused    → resume
        if AHPriceService._paused then
            AHPriceService:Resume()
        elseif AHPriceService._scanning then
            AHPriceService:Pause()
        else
            AHPriceService:StartScan(false, true)
        end
    end)
    btn:SetScript("OnEnter", function(self)
        self._isHover = true
        ApplyAHButtonStyle(self, true)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
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
                0.7,0.7,0.7, 1,1,1)
        elseif AHPriceService._paused then
            GameTooltip:AddDoubleLine("Paused",
                string.format("%d/%d", AHPriceService._scannedItems, AHPriceService._totalItems),
                1,0.84,0, 1,1,1)
        end
        GameTooltip:AddDoubleLine("Cached", string.format("%d items", stats.total), 0.7,0.7,0.7, 1,1,1)
        GameTooltip:AddDoubleLine("Fresh / stale",
            string.format("|cff44ff44%d|r / |cffd4af37%d|r", stats.fresh, stats.stale),
            0.7,0.7,0.7, 1,1,1)
        if lastAge then
            GameTooltip:AddDoubleLine("Last update", FormatRemaining(lastAge) .. " ago",
                0.7,0.7,0.7, 1,1,1)
        end
        GameTooltip:AddLine(" ")
        if AHPriceService._scanning then
            GameTooltip:AddLine("|cffaaaaaaLeft-click: pause   ·   Right-click: menu|r")
        elseif AHPriceService._paused then
            GameTooltip:AddLine("|cffaaaaaaLeft-click: resume   ·   Right-click: menu|r")
        else
            GameTooltip:AddLine("|cffaaaaaaLeft-click: refresh stale   ·   Right-click: full / quick / clear|r")
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        self._isHover = false
        ApplyAHButtonStyle(self, false)
        GameTooltip:Hide()
    end)
    ApplyAHButtonStyle(btn, false)
    UpdateAHButtonText()
    AHPriceService._ahButtonCreated = true
    AHPriceService._ahButton = btn
    ScheduleAHSyncAnchorRefresh()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
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
        -- Don't drop the queue; ScanNext will detect AHIsOpen()==false and pause.
        if AHPriceService._scanning then
            AHPriceService._paused = (#AHPriceService._queue > 0)
            AHPriceService._scanning = false
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
    end
end)

ns.AHPriceService = AHPriceService
