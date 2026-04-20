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

--- Seconds between individual commodity queries (Blizzard throttle headroom).
--- Keep low for responsiveness; server-side throttling still applies.
local SCAN_STEP_SEC = 0.15

--- If neither commodity nor item result events fire, still advance.
local SEARCH_RESULT_TIMEOUT_SEC = 2.5

local QUICK_SCAN_MAX_ITEMS = 28

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

--- Alt sağ: sayfalama / satın alma çubuğu ile çakışır. Arama şeridinin altı (sol) veya cüzdan üstü.
local function ApplyAHSyncButtonAnchor(btn, parent)
    if not btn or not parent then
        return
    end
    btn:ClearAllPoints()
    local searchBar = parent.SearchBar
    if searchBar then
        btn:SetPoint("TOPLEFT", searchBar, "BOTTOMLEFT", 0, -10)
        return
    end
    btn:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 20, 72)
end

---@class AHPriceService
local AHPriceService = {
    _queue = {},
    _scanning = false,
    _currentItemID = nil,
    _expectQueryId = nil,
    _ahButtonCreated = false,
    _ahButton = nil,
    _totalItems = 0,
    _scannedItems = 0,
}

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

--- Build the ordered list of all catalog itemIDs to scan.
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
        local filtered = {}
        for i = 1, #ids do
            local itemID = ids[i]
            local row = db[itemID]
            if not row or not row.updatedAt or (now - row.updatedAt) >= (20 * 60) then
                filtered[#filtered + 1] = itemID
            end
        end
        ids = filtered
    end
    return ids
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

local function UpdateAHButtonText()
    local btn = AHPriceService._ahButton
    if not btn then return end
    if AHPriceService._scanning then
        local done = AHPriceService._scannedItems
        local total = AHPriceService._totalItems
        btn:SetText(string.format("Scanning %d/%d...", done, total))
    else
        btn:SetText(L("AH_SYNC_PRICES", "Sync AH Prices"))
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

function AHPriceService:ScanNext()
    if not self._scanning then return end
    if not AHIsOpen() then
        self._scanning = false
        self._expectQueryId = nil
        self._currentItemID = nil
        UpdateAHButtonText()
        return
    end
    if #self._queue == 0 then
        self._scanning = false
        self._currentItemID = nil
        self._expectQueryId = nil
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
        After(SCAN_STEP_SEC, function() AHPriceService:ScanNext() end)
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
        After(SCAN_STEP_SEC, function() AHPriceService:ScanNext() end)
        return
    end

    After(SEARCH_RESULT_TIMEOUT_SEC, function()
        if not AHPriceService._scanning then
            return
        end
        if AHPriceService._expectQueryId ~= qid then
            return
        end
        AHPriceService._expectQueryId = nil
        After(SCAN_STEP_SEC, function() AHPriceService:ScanNext() end)
    end)
end

---@param force boolean|nil If true, clears an in-progress or stuck scan and starts over.
---@param fullScan boolean|nil If true, scan whole catalog instead of quick queue.
function AHPriceService:StartScan(force, fullScan)
    if force then
        self._scanning = false
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
        self._queue = BuildItemQueue(true)
    else
        self._queue = BuildQuickItemQueue()
    end
    local n = #self._queue
    if n == 0 then
        Notify(L("AH_SCAN_NO_ITEMS", "No catalog items to scan."))
        return
    end
    self._scanning = true
    self._totalItems = n
    self._scannedItems = 0
    UpdateAHButtonText()
    Notify(string.format(
        useFull and L("AH_SCAN_STARTED", "Starting AH price scan (%d items).")
            or L("AH_SCAN_STARTED", "Starting AH price scan (%d items)."),
        n
    ))
    self:ScanNext()
end

local function SavePrice(itemID, unitPrice)
    if not ArtisanNexus or not ArtisanNexus.db then return end
    local g = ArtisanNexus.db.global
    if type(g.ahPrices) ~= "table" then
        g.ahPrices = {}
    end
    g.ahPrices[itemID] = { buyout = unitPrice, updatedAt = time() }
end

local function ScheduleScanStep()
    After(SCAN_STEP_SEC, function() AHPriceService:ScanNext() end)
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
    local okComm, numComm = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemKey.itemID)
    if okComm and numComm and numComm > 0 then
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
    ScheduleScanStep()
end

local function TryCreateAHButton()
    if AHPriceService._ahButtonCreated then return end
    local parent = _G.AuctionHouseFrame
    if not parent then return end
    local btn = CreateFrame("Button", "ArtisanNexusAHSyncBtn", parent, "UIPanelButtonTemplate")
    if not btn then return end
    btn:SetSize(140, 26)
    ApplyAHSyncButtonAnchor(btn, parent)
    btn:SetText(L("AH_SYNC_PRICES", "Sync AH Prices"))
    btn:SetFrameStrata("HIGH")
    btn:SetFrameLevel(parent:GetFrameLevel() + 50)
    btn:EnableMouse(true)
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetScript("OnClick", function()
        AHPriceService:StartScan(true, true)
    end)
    AHPriceService._ahButtonCreated = true
    AHPriceService._ahButton = btn
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
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
        end
        -- Manual trigger only: user starts scans via "Sync AH Prices" button.
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
