--[[
    AH price scanner for gathering catalog + craft briefing item IDs.

    Primary path (Retail 8.3+): C_AuctionHouse.SearchForItemKeys (up to 100 keys per
    call) then C_AuctionHouse.GetBrowseResults on AUCTION_HOUSE_BROWSE_RESULTS_UPDATED.
    One batch replaces dozens of SendSearchQuery round-trips (100/min throttle).

    Fallback: per-item C_AuctionHouse.SendSearchQuery + COMMODITY/ITEM_SEARCH_RESULTS_UPDATED.

    Callers:
        ns.AHPriceService:GetPrice(itemID)  → copper unit price or nil
        ns.AHPriceService:StartScan(force, fullScan)
        ns.AHPriceService:GetScanProgress()  → done, total (scan progress counters)
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS
local AHPriceService
local SavePrice

--- Legacy per-item path: minimum gap after a result. Real pacing comes from the query budget
--- below (the old fixed 0.55s step was ~109 queries/min, over Blizzard's 100/min limit).
local SCAN_STEP_SEC = 0.05

--- "Search queries are restricted to 100 calls per minute" (C_AuctionHouse.SendSearchQuery doc,
--- AuctionHouseDocumentation 12.1.5.70391, verified 2026-10-14). Every AH request we send
--- (SearchForItemKeys, RequestMoreBrowseResults, SendSearchQuery) draws from one budget kept
--- a little under the limit.
local QUERY_BUDGET_PER_WINDOW = 95
local QUERY_WINDOW_SEC = 60

--- Browse pages read per batch (HasFullBrowseResults / RequestMoreBrowseResults).
local MAX_BROWSE_PAGES = 8

--- Shopping-list commodities that also get a per-item order-book search (real buy cost).
local DEPTH_TARGETS_MAX = 40

--- If neither commodity nor item result events fire, still advance (legacy path).
local SEARCH_RESULT_TIMEOUT_SEC = 2.5

--- SearchForItemKeys batch: max keys per call (wiki: >100 risks disconnect).
local BATCH_MAX_KEYS = 100

--- Whole-batch timeout before falling back to per-item SendSearchQuery.
local BATCH_RESULT_TIMEOUT_SEC = 12

local QUICK_SCAN_MAX_ITEMS = 28

--- Current-expansion equipment is priced from ONE paged browse (SendBrowseQuery, weapon / armor /
--- profession-tool classes, CurrentExpansionOnly) instead of one SendSellSearchQuery per item: browse
--- rows carry the real item level and BrowseResultInfo.minPrice, the field Auctionator's price DB is
--- built from (Auctionator v341 Source_ModernAH/IncrementalScan, DBKeyFromBrowseResult). Query shape
--- as Blizzard_AuctionHouseFrame.lua SendBrowseQueryInternal; enums AuctionHouseEnumsDocumentation /
--- ItemConstantsDocumentation (12.1.5.70448, checked 2026-10-17). Page size is not documented
--- (Auctionator assumes 500), so the page count is capped.
local GEAR_MAX_PAGES = 40

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
local SCAN_STEP_MAX_SEC = 1.5

--- The client queues a throttled message itself (AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED,
--- AuctionHouseDocumentation 12.1.5.70448): waiting longer than this on
--- IsThrottledMessageSystemReady only stalls the scan, so the query is sent anyway.
local THROTTLE_WAIT_MAX_SEC = 5

--- Watchdog: no send / AH event for this long while scanning = stuck in a state no timeout covers.
--- The scan is paused (in-flight items requeued) and resumed; after STALL_MAX_RECOVERIES it stays paused.
local STALL_CHECK_SEC = 5
local STALL_RECOVER_SEC = 30
local STALL_MAX_RECOVERIES = 3

--- Pause after a failed SearchForItemKeys batch before the next one (the server just refused us).
local BATCH_RETRY_DELAY_SEC = 1

--- After a scan finishes (or finds nothing to refresh) the button reads "Completed" this long.
--- Atlas markup, not an emoji: WoW fonts have no emoji glyphs (atlas also used by UI.lua / WN lists).
local COMPLETED_SHOW_SEC = 60
local COMPLETED_ICON = "|A:common-icon-checkmark:14:14|a "

--- Per-item path: requeue an item whose itemKey info is not cached yet up to this many times
--- (GetItemKeyInfo requests it) before searching anyway.
local ITEM_KEY_INFO_MAX_WAITS = 3
local ITEM_KEY_INFO_WAIT_SEC = 0.1

--- Native sync button (UIPanelButtonTemplate) — CategoriesList footer (below category scroll / WoW Token).
local AH_SYNC_BTN_H = 22
local AH_SYNC_CAT_PAD_X = 8
local AH_SYNC_CAT_PAD_BOTTOM = 10
local AH_SYNC_CAT_SCROLLBAR_W = 28

local function FormatRemaining(seconds)
    if seconds < 60 then return string.format("%ds", math.max(1, math.floor(seconds))) end
    if seconds < 3600 then return string.format("%dm", math.floor(seconds / 60)) end
    return string.format("%dh", math.floor(seconds / 3600))
end

local L = ns.SafeLocaleString

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

local querySentAt = {}
local throttleWaitSince = nil

--- Watchdog heartbeat: a query went out, is waiting for its slot, or an AH event arrived.
local function MarkScanActivity()
    if AHPriceService then
        AHPriceService._activityAt = GetTime()
    end
end

--- Seconds until another AH query may be sent (0 = now).
local function QuerySlotDelay()
    local now = GetTime()
    while querySentAt[1] and querySentAt[1] <= now - QUERY_WINDOW_SEC do
        table.remove(querySentAt, 1)
    end
    if #querySentAt >= QUERY_BUDGET_PER_WINDOW then
        throttleWaitSince = nil
        return (querySentAt[1] + QUERY_WINDOW_SEC) - now + 0.05
    end
    if C_AuctionHouse and C_AuctionHouse.IsThrottledMessageSystemReady
        and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        throttleWaitSince = throttleWaitSince or now
        if now - throttleWaitSince < THROTTLE_WAIT_MAX_SEC then
            return 0.25
        end
    end
    throttleWaitSince = nil
    return 0
end

--- Run `fn` as soon as the query budget and the client throttle allow; counts one query.
local function WhenQuerySlot(fn)
    MarkScanActivity()
    local delay = QuerySlotDelay()
    if delay <= 0 then
        querySentAt[#querySentAt + 1] = GetTime()
        fn()
    else
        After(delay, function() WhenQuerySlot(fn) end)
    end
end

--- CategoriesList bottom gutter (below WoW Token scroll row); full column width.
local function ApplyAHSyncButtonAnchor(frame, parent)
    if not frame or not parent then
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
    frame:SetWidth(btnW)
    frame:SetHeight(AH_SYNC_BTN_H)
    frame:SetPoint("BOTTOMLEFT", cat, "BOTTOMLEFT", AH_SYNC_CAT_PAD_X, AH_SYNC_CAT_PAD_BOTTOM)
    frame:SetPoint("BOTTOMRIGHT", cat, "BOTTOMRIGHT", -AH_SYNC_CAT_SCROLLBAR_W, AH_SYNC_CAT_PAD_BOTTOM)
    if cat.IsShown and cat:IsShown() then
        frame:Show()
    else
        frame:Hide()
    end
end

--- Scan progress (0..1) and an ETA from the observed rate this scan.
local function ScanProgress()
    local total = AHPriceService._totalItems or 0
    local done = AHPriceService._scannedItems or 0
    local frac = (total > 0) and math.min(1, done / total) or 0
    local eta
    local started = AHPriceService._scanStartedAt or 0
    local elapsed = (GetTime and GetTime() or 0) - started
    if AHPriceService._scanning and done > 0 and elapsed > 1 and total > done then
        eta = elapsed / done * (total - done)
    end
    return frac, done, total, eta, elapsed
end

local function ShowAHSyncTooltip(owner)
    if not owner then
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(L("AH_SYNC_PRICES", "Sync AH Prices"), 1, 1, 1)
    local stats = AHPriceService:GetCacheStats()
    local lastAge = (stats.newest > 0) and (time() - stats.newest) or nil
    GameTooltip:AddLine(" ")
    local W = 1
    local function Row(key, fb, right, r, g, b)
        GameTooltip:AddDoubleLine(L(key, fb), right, r or 0.7, g or 0.7, b or 0.7, W, W, W)
    end
    local frac, done, total, eta, elapsed = ScanProgress()
    if AHPriceService._scanning or AHPriceService._paused then
        local label = AHPriceService._paused and L("AH_TT_PAUSED", "Paused") or L("AH_TT_SCANNING", "Scanning")
        GameTooltip:AddDoubleLine(label, string.format("%d / %d  (%d%%)", done, total, math.floor(frac * 100 + 0.5)),
            AHPriceService._paused and 1 or 0.7, AHPriceService._paused and 0.84 or 0.7, AHPriceService._paused and 0 or 0.7, W, W, W)
        -- Current-expansion gear is priced by one paged browse at the end and credited when it
        -- finishes, so progress holds still meanwhile (then jumps by the gear share).
        local gs = AHPriceService._gearScan
        if AHPriceService._scanning and gs and gs.pending then
            local n = 0
            for _ in pairs(gs.pending) do n = n + 1 end
            Row("AH_TT_GEAR_PHASE", "Gear browse", string.format(L("AH_TT_GEAR_PHASE_FMT", "%d items, page %d"), n, (gs.pages or 0) + 1))
        end
        if AHPriceService._scanning and eta then
            Row("AH_TT_ETA", "Time left (est.)", "~" .. FormatRemaining(eta))
        end
        if AHPriceService._scanning and elapsed and elapsed > 5 and done > 0 then
            Row("AH_TT_RATE", "Speed", string.format(L("AH_TT_RATE_FMT", "%.0f items/min"), done / elapsed * 60))
        end
    end
    Row("AH_TT_CACHED", "Cached", string.format(L("AH_TT_ITEMS_FMT", "%d items"), stats.total))
    local plan = AHPriceService:GetScanPlan(false)
    Row("AH_TT_TRACKED", "Tracked catalog", string.format(L("AH_TT_ITEMS_FMT", "%d items"), plan.tracked))
    Row("AH_TT_PRICED_FRESH", "Priced (fresh)", string.format("%d", plan.pricedFresh))
    if plan.unlisted > 0 then
        Row("AH_TT_NO_LISTINGS", "No listings on the AH", string.format("%d", plan.unlisted))
    end
    if (plan.unsellable or 0) > 0 then
        Row("AH_TT_NOT_ON_AH", "Soulbound (not on the AH)", string.format("%d", plan.unsellable))
    end
    Row("AH_TT_STALE_QUEUE", "Stale queue", string.format("%d", plan.queued))
    local H = ns.HubUI_Internal
    local hexS = (H and H.InkHex) and H.InkHex("success") or "44ff44"
    local hexW = (H and H.InkHex) and H.InkHex("gold") or "d4af37"
    Row("AH_TT_FRESH_STALE", "Fresh / stale", string.format("|cff%s%d|r / |cff%s%d|r", hexS, stats.fresh, hexW, stats.stale))
    if lastAge then
        Row("AH_TT_LAST_UPDATE", "Last update", string.format(L("AH_TT_AGO_FMT", "%s ago"), FormatRemaining(lastAge)))
    end
    GameTooltip:AddLine(" ")
    if AHPriceService._scanning then
        GameTooltip:AddLine(L("AH_TT_HINT_SCANNING", "Left-click: pause  -  Right-click: menu"), 0.67, 0.67, 0.67)
    elseif AHPriceService._paused then
        GameTooltip:AddLine(L("AH_TT_HINT_PAUSED", "Left-click: resume  -  Right-click: menu"), 0.67, 0.67, 0.67)
    else
        GameTooltip:AddLine(L("AH_TT_HINT_IDLE", "Left-click: refresh stale  -  Right-click: quick / full"), 0.67, 0.67, 0.67)
    end
    GameTooltip:AddLine(L("AH_TT_HINT_RESTORE", "Your browse list is restored when the sync finishes."), 0.67, 0.67, 0.67)
    GameTooltip:Show()
end

--- "No listings" cache: db.global.ahEmpty[itemID] = unix time a search confirmed zero listings.
--- Unlisted items (old-expansion mats, rare reagents) are not re-queried one by one until the
--- freshness window passes — they were what made the end of a sync crawl.
local function EmptyStore()
    local g = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.global
    if not g then return nil end
    g.ahEmpty = g.ahEmpty or {}
    return g.ahEmpty
end

local function MarkNoListings(itemID)
    local store = EmptyStore()
    if store and itemID then store[itemID] = time() end
end

--- Commodity check by itemID. GetItemCommodityStatus takes an ItemLocation (bag item), not an
--- itemID (AuctionHouseDocumentation 12.1.5.70391, verified 2026-10-14) — passing an ID failed
--- under pcall every time, so unpriced commodities never got their per-item follow-up.
--- GetItemKeyInfo(itemKey).isCommodity is nil until item data is cached; then fall back to
--- "stackable" (C_Item.GetItemInfo return 8, itemStackCount), which matches commodities.
local function ItemIsCommodity(itemID)
    if not itemID or not C_AuctionHouse then
        return false
    end
    if C_AuctionHouse.MakeItemKey and C_AuctionHouse.GetItemKeyInfo then
        local okK, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
        if okK and key then
            local okI, info = pcall(C_AuctionHouse.GetItemKeyInfo, key)
            if okI and type(info) == "table" and info.isCommodity ~= nil then
                return info.isCommodity == true
            end
        end
    end
    local stack = tonumber((select(8, C_Item.GetItemInfo(itemID))))
    return stack ~= nil and stack > 1
end

--- Items that can never be listed: not an item at all (GetItemInfoInstant returns nothing), or bound
--- on pickup / quest items (C_Item.GetItemInfo return 14 bindType 1 / 4; ItemDocumentation 12.1.5,
--- checked 2026-10-17). Uncached items count as sellable until their info loads.
local function IsUnsellable(itemID)
    if not C_Item.GetItemInfoInstant(itemID) then
        return true
    end
    local bindType = tonumber((select(14, C_Item.GetItemInfo(itemID))))
    return bindType == 1 or bindType == 4
end

--- Equipment needs the "by item ID" search: SearchForItemKeys / SendSearchQuery keys of equipment
--- carry a real item level, so our level-less key finds nothing. Blizzard queries equipment by item ID
--- with C_AuctionHouse.SendSellSearchQuery, whose doc says "ItemKey should have its iLVL and suffix
--- cleared before calling" (AuctionHouseDocumentation + Blizzard_AuctionHouseUtil.lua
--- ConvertItemSellItemKey / Blizzard_AuctionHouseFrame.lua QueryItem, 12.1.5.70448, checked 2026-10-17).
--- GetItemKeyInfo(...).isEquipment is nil until item data is cached; then weapon / armor / profession
--- tool class IDs (2 / 4 / 19, GetItemInfoInstant return 6) decide.
local EQUIPMENT_CLASS = { [2] = true, [4] = true, [19] = true }
local function IsEquipment(itemID)
    if C_AuctionHouse.MakeItemKey and C_AuctionHouse.GetItemKeyInfo then
        local okK, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
        if okK and key then
            local okI, info = pcall(C_AuctionHouse.GetItemKeyInfo, key)
            if okI and type(info) == "table" and info.isEquipment ~= nil then
                return info.isEquipment == true
            end
        end
    end
    local classID = select(6, C_Item.GetItemInfoInstant(itemID))
    return classID ~= nil and EQUIPMENT_CLASS[classID] == true
end

--- Equipment of the server's current expansion (C_Item.GetItemInfo return 15 expansionID vs
--- GetServerExpansionLevel, ExpansionDocumentation 12.1.5.70448): the only equipment the
--- CurrentExpansionOnly gear browse can see. Uncached items are not counted as current.
local function IsCurrentExpansionItem(itemID)
    local exp = tonumber((select(15, C_Item.GetItemInfo(itemID))))
    local cur = GetServerExpansionLevel and GetServerExpansionLevel()
    return exp ~= nil and cur ~= nil and exp == cur
end

local function GearBrowseQuery()
    local F, C = Enum.AuctionHouseFilter, Enum.ItemClass
    return {
        searchString = "",
        sorts = {
            { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
            { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
        },
        filters = {
            F.CurrentExpansionOnly,
            F.PoorQuality, F.CommonQuality, F.UncommonQuality, F.RareQuality,
            F.EpicQuality, F.LegendaryQuality, F.ArtifactQuality,
        },
        itemClassFilters = { { classID = C.Weapon }, { classID = C.Armor }, { classID = C.Profession } },
    }
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

--- Query Auctionator API v1 for market price.
---@param itemID number|any
---@return number|nil copper
local function GetAuctionatorPrice(itemID)
    if not itemID then return nil end
    local numID = tonumber(itemID)
    if not numID or numID <= 0 then return nil end
    if _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1 and _G.Auctionator.API.v1.GetAuctionPriceByItemID then
        local ok, price = pcall(_G.Auctionator.API.v1.GetAuctionPriceByItemID, "ArtisanNexus", numID)
        if ok and type(price) == "number" and price > 0 then
            return price
        end
    end
    return nil
end

--- Query TradeSkillMaster (TSM) API for dbmarket price.
---@param itemID number|any
---@return number|nil copper
local function GetTSMPrice(itemID)
    if not itemID then return nil end
    local numID = tonumber(itemID)
    if not numID or numID <= 0 then return nil end
    if _G.TSM_API and _G.TSM_API.GetCustomPriceValue then
        -- profile.tsmPriceSource: a TSM price source name (DBMarket, DBRegionSaleAvg, ...); TSM
        -- price strings are case-insensitive. Default dbmarket (previous behaviour).
        local p = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.profile
        local src = (p and type(p.tsmPriceSource) == "string" and p.tsmPriceSource ~= "") and p.tsmPriceSource or "dbmarket"
        local ok, price = pcall(_G.TSM_API.GetCustomPriceValue, src, "i:" .. numID)
        if ok and type(price) == "number" and price > 0 then
            return price
        end
    end
    return nil
end

--- Query internal Artisan Nexus scan cache table.
---@param itemID number|any
---@return table|nil row { buyout = number, updatedAt = number }
local function GetInternalPriceRow(itemID)
    if not itemID then return nil end
    local db = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.global and ArtisanNexus.db.global.ahPrices
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
    if row and type(row.buyout) == "number" and row.buyout > 0 then
        return row
    end
    return nil
end

--- Resolve active price source provider from profile settings.
---@return string "auto"|"an"|"tsm"|"auctionator"
local function GetSelectedPriceProvider()
    local p = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.profile
    local prov = p and p.priceSourceProvider
    if prov == "an" or prov == "tsm" or prov == "auctionator" or prov == "auto" then
        return prov
    end
    return "auto"
end

--- Auctionator scan age in days -> unix time. nil when Auctionator has no age for the item.
--- Auctionator.API.v1.GetAuctionAgeByItemID(callerID, itemID) returns whole days since last seen.
---@param itemID number
---@return number|nil updatedAt
local function GetAuctionatorUpdatedAt(itemID)
    local api = _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1
    if not (api and api.GetAuctionAgeByItemID) then return nil end
    local ok, days = pcall(api.GetAuctionAgeByItemID, "ArtisanNexus", tonumber(itemID))
    if ok and type(days) == "number" and days >= 0 then
        return time() - days * 86400
    end
    return nil
end

--- Provider resolution order per priceSourceProvider. "an_fresh" = internal row that is not stale;
--- "an" = internal row of any age (last resort so an old own scan never beats fresh addon data in auto).
local PROVIDER_ORDER = {
    auto        = { "an_fresh", "auctionator", "tsm", "an" },
    an          = { "an" },
    tsm         = { "tsm", "an", "auctionator" },
    auctionator = { "auctionator", "an", "tsm" },
}

--- Single resolver behind GetPrice / GetPriceInfo so every consumer sees the same source.
---@return number|nil price
---@return number|nil updatedAt
---@return boolean isFresh
---@return boolean isStale
---@return string|nil source "an" | "tsm" | "auctionator"
local priceMemo = { stamp = nil, provider = nil, rows = {} }

local function ResolvePriceUncached(itemID)
    local freshTTL = (ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.profile and tonumber(ArtisanNexus.db.profile.ahFreshTTL)) or DEFAULT_FRESH_TTL_SEC
    local order = PROVIDER_ORDER[GetSelectedPriceProvider()] or PROVIDER_ORDER.auto
    local row, rowAge
    for i = 1, #order do
        local src = order[i]
        if src == "an" or src == "an_fresh" then
            if row == nil then
                row = GetInternalPriceRow(itemID) or false
                local updatedAt = row and tonumber(row.updatedAt)
                rowAge = updatedAt and (time() - updatedAt) or math.huge
                -- A later search found no listings: the stored price is history, not the market.
                local store = EmptyStore()
                local emptyAt = store and store[itemID]
                if updatedAt and emptyAt and emptyAt > updatedAt then
                    rowAge = math.max(rowAge, STALE_TTL_SEC + 1)
                end
            end
            if row and (src == "an" or rowAge <= STALE_TTL_SEC) then
                return row.buyout, tonumber(row.updatedAt), rowAge <= freshTTL, rowAge > STALE_TTL_SEC, "an"
            end
        elseif src == "auctionator" then
            local price = GetAuctionatorPrice(itemID)
            if price then
                local updatedAt = GetAuctionatorUpdatedAt(itemID)
                local age = updatedAt and (time() - updatedAt) or math.huge
                return price, updatedAt, age <= freshTTL, age > STALE_TTL_SEC, "auctionator"
            end
        elseif src == "tsm" then
            local price = GetTSMPrice(itemID)
            if price then
                -- dbmarket is a multi-day market average with no per-item timestamp: usable, never "fresh".
                return price, nil, false, false, "tsm"
            end
        end
    end
    return nil, nil, false, true, nil
end

--- Per-frame memo: one Hub/Shopping render asks for the same item many times and each
--- third-party lookup is a pcall into another addon. Keyed by provider so a settings
--- change re-resolves in the same frame.
local function ResolvePrice(itemID)
    local now = GetTime()
    local provider = GetSelectedPriceProvider()
    if priceMemo.stamp ~= now or priceMemo.provider ~= provider then
        priceMemo.stamp = now
        priceMemo.provider = provider
        priceMemo.rows = {}
    end
    local hit = priceMemo.rows[itemID]
    if not hit then
        local price, updatedAt, isFresh, isStale, source = ResolvePriceUncached(itemID)
        -- A vendor-sold item is never worth buying above its vendor price; vendor-only
        -- reagents (no AH listing) get a price instead of "no data".
        local vendor = ns.VendorPriceService and ns.VendorPriceService.GetBuyPrice
            and ns.VendorPriceService:GetBuyPrice(itemID)
        if vendor and (not price or vendor < price) then
            price, updatedAt, isFresh, isStale, source = vendor, nil, true, false, "vendor"
        end
        hit = { price, updatedAt, isFresh, isStale, source }
        priceMemo.rows[itemID] = hit
    end
    return hit[1], hit[2], hit[3], hit[4], hit[5]
end

---@param itemID number
---@return number|nil
function AHPriceService:GetPrice(itemID)
    if not itemID then return nil end
    local price = ResolvePrice(itemID)
    return price
end

--- Price with age metadata. `isFresh` uses profile.ahFreshTTL (scan-skip window);
--- `isStale` uses STALE_TTL_SEC — consumers can badge or discard very old prices.
--- Respects user-configured priceSourceProvider ("auto", "an", "tsm", "auctionator").
---@param itemID number
---@return number|nil buyout copper per unit
---@return number|nil updatedAt unix time
---@return boolean isFresh
---@return boolean isStale
---@return string|nil source "an" | "tsm" | "auctionator"
function AHPriceService:GetPriceInfo(itemID)
    if not itemID then return nil, nil, false, true, nil end
    return ResolvePrice(itemID)
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
    -- Every Midnight recipe's reagents and outputs from the static DB2-generated catalog, so
    -- materials of recipes never opened in the profession window are priced too.
    if rs and rs.GetCatalogReagentItemIDs then
        local catIds = rs:GetCatalogReagentItemIDs()
        for ci = 1, #catIds do
            local itemID = catIds[ci]
            if not seen[itemID] then
                seen[itemID] = true
                ids[#ids + 1] = itemID
            end
        end
    end
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
            local stale = not row or not row.updatedAt or (now - row.updatedAt) >= ttl
            -- Recently confirmed unlisted items wait for the freshness window like priced ones.
            if stale and not AHPriceService:IsKnownUnlisted(itemID) then
                filtered[#filtered + 1] = itemID
            end
        end
        ids = filtered
    end
    -- Soulbound / quest outputs and non-items never reach the AH: no query, no "no listings" count.
    local sellable, unsellable = {}, 0
    for i = 1, #ids do
        if IsUnsellable(ids[i]) then
            unsellable = unsellable + 1
        else
            sellable[#sellable + 1] = ids[i]
        end
    end
    return sellable, unsellable
end

--- Catalog size vs stale queue (tooltips / scan start message). freshSkipped splits into
--- pricedFresh (a price younger than the freshness window) and unlisted (no price that fresh, but a
--- search inside the window found no listings).
---@param includeFresh boolean|nil When true, counts all tracked items (force full).
---@return table tracked, queued, freshSkipped, pricedFresh, unlisted (numbers)
function AHPriceService:GetScanPlan(includeFresh)
    local tracked, unsellable = BuildItemQueue(true)
    local queued = includeFresh and tracked or BuildItemQueue(false)
    local pricedFresh, unlisted = 0, 0
    if not includeFresh then
        local db = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.global and ArtisanNexus.db.global.ahPrices
        local ttl = (ArtisanNexus.db.profile and ArtisanNexus.db.profile.ahFreshTTL) or DEFAULT_FRESH_TTL_SEC
        local now = time()
        for i = 1, #tracked do
            local row = type(db) == "table" and db[tracked[i]]
            if row and row.updatedAt and (now - row.updatedAt) < ttl then
                pricedFresh = pricedFresh + 1
            elseif self:IsKnownUnlisted(tracked[i]) then
                unlisted = unlisted + 1
            end
        end
    end
    return {
        tracked = #tracked,
        queued = #queued,
        freshSkipped = #tracked - #queued,
        pricedFresh = pricedFresh,
        unlisted = unlisted,
        unsellable = unsellable,
    }
end

--- Progress of the running (or last) scan: items done, items queued. Both 0 before any scan.
---@return number done, number total
function AHPriceService:GetScanProgress()
    return tonumber(self._scannedItems) or 0, tonumber(self._totalItems) or 0
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
        if not IsUnsellable(itemID) then
            ids[#ids + 1] = itemID
        end
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

--- Thin fill behind the label; the label stays short so it never clips in the narrow column.
local function UpdateAHButtonProgress(frame, frac, active)
    if not frame then return end
    local bar = frame._anProgressBar
    if not bar then
        bar = frame:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("TOPLEFT", frame, "TOPLEFT", 3, -3)
        bar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 3, 3)
        frame._anProgressBar = bar
    end
    if not active then
        bar:Hide()
        return
    end
    local ac = (ns.UI_COLORS and ns.UI_COLORS.accent) or { 0.52, 0.40, 0.66, 1 }
    bar:SetColorTexture(ac[1], ac[2], ac[3], 0.45)
    local w = math.max(0, ((frame:GetWidth() or 0) - 6) * frac)
    if w < 1 then
        bar:Hide()
    else
        bar:SetWidth(w)
        bar:Show()
    end
end

local function UpdateAHButtonText()
    local button = AHPriceService._ahButton
    if not button then
        return
    end

    local frac = ScanProgress()
    local pctInt = math.floor(frac * 100 + 0.5)
    local text
    if AHPriceService._paused then
        text = string.format(L("AH_SYNC_PAUSED_SHORT_FMT", "Paused %d%%"), pctInt)
    elseif AHPriceService._scanning then
        text = string.format(L("AH_SYNC_PROGRESS_SHORT_FMT", "Syncing %d%%"), pctInt)
    elseif AHPriceService._completedAt and GetTime() - AHPriceService._completedAt < COMPLETED_SHOW_SEC then
        text = COMPLETED_ICON .. L("AH_SYNC_COMPLETED", "Completed")
    else
        text = L("AH_SYNC_PRICES", "Sync AH Prices")
    end
    button:SetText(text)
    local fs = button:GetFontString()
    if fs then
        fs:SetWordWrap(false)
    end
    UpdateAHButtonProgress(button, frac, AHPriceService._scanning or AHPriceService._paused)
    local af = _G.AuctionHouseFrame
    if af then
        ApplyAHSyncButtonAnchor(button, af)
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

--- Show "Completed" on the sync button, then fall back to the normal label.
local function MarkScanCompleted()
    local at = GetTime()
    AHPriceService._completedAt = at
    UpdateAHButtonText()
    After(COMPLETED_SHOW_SEC + 0.1, function()
        if AHPriceService._completedAt == at then
            UpdateAHButtonText()
        end
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
    self._gearPending, self._gearScan = nil, nil
    self._currentItemID = nil
    self._expectQueryId = nil
    self._suppressPriceMessages = false
    self._consecutiveTimeouts = 0
    self._currentStepSec = SCAN_STEP_SEC
    MarkScanCompleted()
    local scanned = self._scannedItems or 0
    local priced = self._pricedThisScan or 0
    local legacy = self._legacyQueuedThisScan or 0
    local elapsed = 0
    if GetTime and self._scanStartedAt then
        elapsed = math.max(0, GetTime() - self._scanStartedAt)
    end
    if legacy > 0 then
        Notify(string.format(
            L("AH_SCAN_DONE_DETAIL", "AH scan done (%.1fs): %d updated, %d checked, %d lookups."),
            elapsed, priced, scanned, legacy))
    else
        Notify(string.format(
            L("AH_SCAN_DONE_FAST", "AH scan done (%.1fs): %d updated, %d checked."),
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
        self:FinishBatchPhase()
        return
    end

    local chunkSize = math.min(BATCH_MAX_KEYS, #self._queue)
    local keys = {}
    local pending = {}
    local noKey = 0
    for i = 1, chunkSize do
        local itemID = table.remove(self._queue, 1)
        if itemID then
            if IsEquipment(itemID) then
                if IsCurrentExpansionItem(itemID) then
                    -- One gear browse after the batches (StartGearBrowse); counted there.
                    self._gearPending = self._gearPending or {}
                    self._gearPending[itemID] = true
                else
                    -- Older equipment: per-item "by item ID" search (SendSellSearchQuery); counted there.
                    QueueLegacyFollowup(itemID)
                end
            else
                local key = MakeQueryItemKey(itemID)
                if key then
                    pending[itemID] = true
                    keys[#keys + 1] = key
                else
                    noKey = noKey + 1
                end
            end
        end
    end
    -- Items without a query key are done once dequeued (CompleteBatch only credits pending keys).
    self._scannedItems = self._scannedItems + noKey
    if #keys < 1 then
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

    self._batchPages = 0
    local function batchTimeout()
        if not AHPriceService._scanning or AHPriceService._batchExpectId ~= bid then
            return
        end
        -- Re-arm while pages keep arriving; only a silent batch falls back to per-item.
        local idle = GetTime() - (AHPriceService._batchActivityAt or 0)
        if idle < BATCH_RESULT_TIMEOUT_SEC then
            After(BATCH_RESULT_TIMEOUT_SEC - idle + 0.05, batchTimeout)
            return
        end
        AHPriceService:FallbackBatchToLegacy(bid)
    end
    WhenQuerySlot(function()
        if not AHPriceService._scanning or AHPriceService._batchExpectId ~= bid then
            return
        end
        AHPriceService._batchActivityAt = GetTime()
        -- Only browse events after our own send belong to this batch (the send may wait on
        -- the query budget while the player or Blizzard's UI browses).
        AHPriceService._batchSentId = bid
        local ok = pcall(C_AuctionHouse.SearchForItemKeys, keys, SEARCH_SORTS)
        if not ok then
            AHPriceService:FallbackBatchToLegacy(bid)
            return
        end
        After(BATCH_RESULT_TIMEOUT_SEC, batchTimeout)
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
        local run = self._runSeq
        After(0.02, function()
            if AHPriceService._runSeq == run then
                AHPriceService:StartNextBatch()
            end
        end)
    else
        self:FinishBatchPhase()
    end
end

--- After the last batch: gear browse, then the per-item tail, then done.
function AHPriceService:FinishBatchPhase()
    if self:StartGearBrowse() then
        return
    end
    if DrainLegacyTailIfNeeded() then
        return
    end
    FinishScan()
end

--- Gear browse: one SendBrowseQuery, paged with RequestMoreBrowseResults until HasFullBrowseResults
--- (or GEAR_MAX_PAGES), then each pending item takes the minimum minPrice over its item levels.
function AHPriceService:StartGearBrowse()
    local pending = self._gearPending
    if not pending or next(pending) == nil then
        return false
    end
    self._gearPending = nil
    self._gearSeq = (self._gearSeq or 0) + 1
    local gs = { id = self._gearSeq, pending = pending, pages = 0, sent = false, activityAt = GetTime() }
    self._gearScan = gs
    self._batchMode = true -- per-item result events are not ours while the browse runs
    UpdateAHButtonText()
    local function gearTimeout()
        if not AHPriceService._scanning or AHPriceService._gearScan ~= gs then
            return
        end
        local idle = GetTime() - (gs.activityAt or 0)
        if idle < BATCH_RESULT_TIMEOUT_SEC then
            After(BATCH_RESULT_TIMEOUT_SEC - idle + 0.05, gearTimeout)
            return
        end
        AHPriceService:FallbackGearToLegacy(gs.id)
    end
    WhenQuerySlot(function()
        if not AHPriceService._scanning or AHPriceService._gearScan ~= gs then
            return
        end
        gs.sent, gs.activityAt = true, GetTime()
        local ok = pcall(C_AuctionHouse.SendBrowseQuery, GearBrowseQuery())
        if not ok then
            AHPriceService:FallbackGearToLegacy(gs.id)
            return
        end
        After(BATCH_RESULT_TIMEOUT_SEC, gearTimeout)
    end)
    return true
end

--- Gear browse failed or went silent: price its items through the per-item path instead.
function AHPriceService:FallbackGearToLegacy(gid)
    local gs = self._gearScan
    if not gs or gs.id ~= gid then
        return
    end
    self._gearScan = nil
    self._batchMode = false
    for itemID in pairs(gs.pending) do
        QueueLegacyFollowup(itemID)
    end
    if ns.DebugPrint then
        ns.DebugPrint("|cff9370DB[AN AH]|r gear browse fallback to per-item scan")
    end
    if not DrainLegacyTailIfNeeded() then
        FinishScan()
    end
end

function AHPriceService:ProcessGearBrowse(gid)
    local gs = self._gearScan
    if not self._scanning or not gs or gs.id ~= gid then
        return
    end
    gs.activityAt = GetTime()
    local okFull, full = pcall(C_AuctionHouse.HasFullBrowseResults)
    if okFull and full == false and gs.pages < GEAR_MAX_PAGES then
        gs.pages = gs.pages + 1
        WhenQuerySlot(function()
            if AHPriceService._scanning and AHPriceService._gearScan == gs then
                gs.activityAt = GetTime()
                pcall(C_AuctionHouse.RequestMoreBrowseResults)
            end
        end)
        return
    end
    local complete = okFull and full ~= false
    local pending = gs.pending
    local best, qty, byIlvl = {}, {}, {}
    local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
    if ok and type(results) == "table" then
        for i = 1, #results do
            local row = results[i]
            local key = row and row.itemKey
            local id = key and key.itemID
            local price = row and tonumber(row.minPrice)
            local n = row and tonumber(row.totalQuantity) or 0
            if id and pending[id] and price and price > 0 and n > 0 then
                if not best[id] or price < best[id] then best[id] = price end
                qty[id] = (qty[id] or 0) + n
                local lvl = tonumber(key.itemLevel) or 0
                byIlvl[id] = byIlvl[id] or {}
                if not byIlvl[id][lvl] or price < byIlvl[id][lvl] then byIlvl[id][lvl] = price end
            end
        end
    end
    local resolved = 0
    for itemID in pairs(pending) do
        if best[itemID] then
            SavePrice(itemID, best[itemID], true, { qty = qty[itemID], qsrc = "b", byIlvl = byIlvl[itemID] })
            resolved = resolved + 1
        elseif complete then
            -- Current-expansion equipment absent from a complete browse of its classes: no listings.
            MarkNoListings(itemID)
            resolved = resolved + 1
        else
            QueueLegacyFollowup(itemID)
        end
    end
    self._gearScan = nil
    self._batchMode = false
    self._scannedItems = (self._scannedItems or 0) + resolved
    UpdateAHButtonText()
    if not DrainLegacyTailIfNeeded() then
        FinishScan()
    end
end

--- A batch failed (browse failure, dropped query, or silence past BATCH_RESULT_TIMEOUT_SEC). Its items
--- are retried once in a new batch; items failing twice go to the per-item tail at the end of the
--- scan. The rest of the queue keeps batching: switching the whole remaining queue to the 100/min
--- per-item path here is what made a scan crawl from the first failed batch on.
function AHPriceService:FallbackBatchToLegacy(bid)
    if self._batchExpectId ~= bid then
        return
    end
    local pending = self._batchPendingSet
    self._batchExpectId = nil
    self._batchSentId = nil
    self._batchMode = false
    self._batchPendingSet = nil
    self._batchChunkSize = 0
    local retried = self._batchRetried or {}
    self._batchRetried = retried
    local retry, tail = {}, 0
    if pending then
        for itemID in pairs(pending) do
            if retried[itemID] then
                QueueLegacyFollowup(itemID)
                tail = tail + 1
            else
                retried[itemID] = true
                retry[#retry + 1] = itemID
            end
        end
    end
    table.sort(retry)
    for i = #retry, 1, -1 do
        table.insert(self._queue, 1, retry[i])
    end
    if ns.DebugPrint then
        ns.DebugPrint(string.format("|cff9370DB[AN AH]|r batch failed: %d retried, %d to per-item tail", #retry, tail))
    end
    local run = self._runSeq
    After(BATCH_RETRY_DELAY_SEC, function()
        if AHPriceService._runSeq == run then
            AHPriceService:StartNextBatch()
        end
    end)
end

local function ProcessBrowseBatchResults(bid)
    if not AHPriceService._scanning or AHPriceService._batchExpectId ~= bid then
        return
    end
    local pending = AHPriceService._batchPendingSet
    if not pending then
        return
    end
    AHPriceService._batchActivityAt = GetTime()
    -- Browse results are paged; items beyond the first page used to be treated as unlisted.
    if C_AuctionHouse.HasFullBrowseResults and C_AuctionHouse.RequestMoreBrowseResults then
        local okFull, full = pcall(C_AuctionHouse.HasFullBrowseResults)
        if okFull and full == false and (AHPriceService._batchPages or 0) < MAX_BROWSE_PAGES then
            AHPriceService._batchPages = (AHPriceService._batchPages or 0) + 1
            WhenQuerySlot(function()
                if AHPriceService._scanning and AHPriceService._batchExpectId == bid then
                    AHPriceService._batchActivityAt = GetTime()
                    pcall(C_AuctionHouse.RequestMoreBrowseResults)
                end
            end)
            return
        end
    end
    local priced = {}
    local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
    if ok and type(results) == "table" then
        for ri = 1, #results do
            local row = results[ri]
            if row and row.itemKey and row.itemKey.itemID and pending[row.itemKey.itemID] then
                local minPrice = tonumber(row.minPrice)
                if minPrice and minPrice > 0 then
                    -- BrowseResultInfo.totalQuantity (12.1.5 AuctionHouseDocumentation): listed units.
                    local id = row.itemKey.itemID
                    -- Keep an existing order book when this browse row carries no depth.
                    SavePrice(id, minPrice, true, { qty = tonumber(row.totalQuantity), qsrc = "b" })
                    priced[id] = true
                    local depth = AHPriceService._depthTargets
                    if depth and depth[id] and ItemIsCommodity(id) then
                        depth[id] = nil
                        QueueLegacyFollowup(id)
                        AHPriceService._totalItems = (AHPriceService._totalItems or 0) + 1
                    end
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
    local browseFull = true
    if C_AuctionHouse.HasFullBrowseResults then
        local okFull, full = pcall(C_AuctionHouse.HasFullBrowseResults)
        browseFull = okFull and full ~= false
    end
    for itemID in pairs(pending) do
        if not priced[itemID] then
            if browseFull then
                -- A complete browse lists every searched key that has listings, commodities included
                -- (commodity browse rows are priced above): absent = no listings. Re-querying each one
                -- through the 100/min per-item path is what made the end of a scan crawl.
                MarkNoListings(itemID)
                resolvedCount = resolvedCount + 1
            elseif ItemIsCommodity(itemID) and not AHPriceService:IsKnownUnlisted(itemID) then
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
    -- A search for an itemKey the client has not cached is ignored without any result event
    -- (Auctionator AH/Mixins/SearchScan.lua note; GetItemKeyInfo requests the info and fires
    -- ITEM_KEY_ITEM_INFO_RECEIVED). Send it back behind the queue a few times before searching.
    local waitKey = MakeQueryItemKey(itemID)
    local okInfo, keyInfo = pcall(C_AuctionHouse.GetItemKeyInfo, waitKey)
    if waitKey and not (okInfo and keyInfo) then
        self._keyInfoWaits = self._keyInfoWaits or {}
        local waits = self._keyInfoWaits[itemID] or 0
        if waits < ITEM_KEY_INFO_MAX_WAITS and #self._queue > 0 then
            self._keyInfoWaits[itemID] = waits + 1
            self._queue[#self._queue + 1] = itemID
            MarkScanActivity()
            After(ITEM_KEY_INFO_WAIT_SEC, function() AHPriceService:ScanNext() end)
            return
        end
    end
    self._currentItemID = itemID
    self._scannedItems = self._scannedItems + 1
    UpdateAHButtonText()

    -- Monotonic id: _expectQueryId is reset to nil after every result, so deriving the next id
    -- from it made every query id 1 and let a finished item's armed timeout kill the next query.
    self._querySeq = (self._querySeq or 0) + 1
    self._expectQueryId = self._querySeq
    local qid = self._expectQueryId

    local itemKey = MakeQueryItemKey(itemID)
    if not itemKey then
        self._expectQueryId = nil
        After(self._currentStepSec, function() AHPriceService:ScanNext() end)
        return
    end

    WhenQuerySlot(function()
        if not AHPriceService._scanning or AHPriceService._expectQueryId ~= qid then
            return
        end
        local ok
        if IsEquipment(itemID) and C_AuctionHouse.SendSellSearchQuery then
            ok = pcall(C_AuctionHouse.SendSellSearchQuery, itemKey, SEARCH_SORTS, false)
        else
            ok = pcall(C_AuctionHouse.SendSearchQuery, itemKey, SEARCH_SORTS, false)
        end
        if not ok then
            AHPriceService._expectQueryId = nil
            Notify(L("AH_SCAN_QUERY_FAIL", "Auction search failed for one item; skipping."))
            After(AHPriceService._currentStepSec, function() AHPriceService:ScanNext() end)
            return
        end
        AHPriceService:_ArmItemTimeout(qid)
    end)
end

--- Per-item result timeout, armed only once the query actually went out (the budget may delay it).
function AHPriceService:_ArmItemTimeout(qid)
    After(SEARCH_RESULT_TIMEOUT_SEC, function()
        if not AHPriceService._scanning then return end
        if AHPriceService._expectQueryId ~= qid then return end
        AHPriceService._expectQueryId = nil
        -- Adaptive backoff only while the client reports AH throttling; a silent empty search is
        -- not a rate-limit signal (the query budget in WhenQuerySlot already paces sends).
        local throttled = C_AuctionHouse.IsThrottledMessageSystemReady
            and not C_AuctionHouse.IsThrottledMessageSystemReady()
        if not throttled then
            -- No result event for an item without listings: record it as unlisted, or every later
            -- scan queues it again and waits out this timeout once more.
            local itemID = AHPriceService._currentItemID
            local okN, n = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
            if itemID and not (okN and n and n > 0) then
                MarkNoListings(itemID)
            end
        end
        if throttled then
            AHPriceService._consecutiveTimeouts = (AHPriceService._consecutiveTimeouts or 0) + 1
            if AHPriceService._consecutiveTimeouts >= 2 then
                AHPriceService._currentStepSec = math.min(SCAN_STEP_MAX_SEC, math.max(0.5, AHPriceService._currentStepSec * 2))
            end
        else
            AHPriceService._consecutiveTimeouts = 0
            AHPriceService._currentStepSec = SCAN_STEP_SEC
        end
        After(AHPriceService._currentStepSec, function() AHPriceService:ScanNext() end)
    end)
end

--- AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED (no payload, AuctionHouseDocumentation 12.1.5.70448): the
--- server discarded a throttled request, so its results never arrive. The event does not say whose
--- request it was; retrying ours costs one query, waiting costs a timeout and a wrong "no listings".
function AHPriceService:OnQueryDropped()
    if not self._scanning or self._paused then
        return
    end
    if self._batchExpectId and self._batchSentId == self._batchExpectId then
        self:FallbackBatchToLegacy(self._batchExpectId)
        return
    end
    local itemID = self._currentItemID
    if self._expectQueryId and itemID then
        local retried = self._batchRetried or {}
        self._batchRetried = retried
        if retried[itemID] == "item" then
            return -- dropped twice: the per-item timeout moves on
        end
        retried[itemID] = "item"
        self._expectQueryId = nil
        self._currentItemID = nil
        table.insert(self._queue, 1, itemID)
        self._scannedItems = math.max(0, (self._scannedItems or 0) - 1)
        self._currentStepSec = math.min(SCAN_STEP_MAX_SEC, math.max(0.5, (self._currentStepSec or SCAN_STEP_SEC) * 2))
        After(self._currentStepSec, function() AHPriceService:ScanNext() end)
    end
end

--- Safety net for a scan stuck in a state none of the batch / gear / per-item timeouts cover.
function AHPriceService:ArmWatchdog()
    MarkScanActivity()
    self._watchdogSeq = (self._watchdogSeq or 0) + 1
    local seq = self._watchdogSeq
    local function tick()
        if AHPriceService._watchdogSeq ~= seq or not AHPriceService._scanning then
            return
        end
        if GetTime() - (AHPriceService._activityAt or 0) < STALL_RECOVER_SEC then
            After(STALL_CHECK_SEC, tick)
            return
        end
        AHPriceService._stallRecoveries = (AHPriceService._stallRecoveries or 0) + 1
        if ns.DebugPrint then
            ns.DebugPrint(string.format("|cff9370DB[AN AH]|r scan stalled; recovery %d", AHPriceService._stallRecoveries))
        end
        AHPriceService:Pause()
        if #AHPriceService._queue == 0 then
            FinishScan()
            return
        end
        if AHPriceService._stallRecoveries > STALL_MAX_RECOVERIES then
            Notify(string.format(L("AH_SCAN_STALLED_FMT",
                "AH scan stopped responding; paused with %d items left. Click Sync AH Prices to resume."),
                #AHPriceService._queue))
            return
        end
        AHPriceService:Resume() -- re-arms the watchdog
    end
    After(STALL_CHECK_SEC, tick)
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
    -- Per-item path: the in-flight item was already dequeued and counted; put it back so a
    -- pause / AH close does not silently skip it.
    if not self._batchExpectId and self._expectQueryId and self._currentItemID then
        table.insert(self._queue, 1, self._currentItemID)
        self._scannedItems = math.max(0, (self._scannedItems or 0) - 1)
    end
    -- Gear collected for (or in) the gear browse goes back into the queue.
    for _, set in ipairs({ self._gearPending or {}, (self._gearScan and self._gearScan.pending) or {} }) do
        for itemID in pairs(set) do
            table.insert(self._queue, 1, itemID)
        end
    end
    self._gearPending, self._gearScan = nil, nil
    -- The per-item tail would otherwise be lost when the queue is empty on resume.
    local tail = self._legacyTail
    if tail then
        for i = 1, #tail do
            self._queue[#self._queue + 1] = tail[i]
        end
        self._legacyTail = {}
    end
    self._batchMode = false
    self._batchExpectId = nil
    self._batchSentId = nil
    self._batchPendingSet = nil
    self._batchChunkSize = 0
    self._paused = true
    self._scanning = false
    self._expectQueryId = nil
    self._currentItemID = nil
    -- Delayed steps of the paused run (batch retry / next batch timers) must not start a second pipeline.
    self._runSeq = (self._runSeq or 0) + 1
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
    self._completedAt = nil
    self._suppressPriceMessages = true
    self._scanStartedAt = GetTime and GetTime() or 0
    UpdateAHButtonText()
    self:ArmWatchdog()
    self:BeginScanPipeline()
end

function AHPriceService:ShowContextMenu(anchor)
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(anchor or UIParent, function(_, root)
            root:CreateTitle(L("AH_SYNC_PRICES", "Sync AH Prices"))
            if self._scanning then
                root:CreateButton(L("AH_MENU_PAUSE", "Pause scan"), function() self:Pause() end)
                root:CreateButton(L("AH_MENU_CANCEL", "Cancel scan"), function() self:Cancel() end)
            elseif self._paused then
                root:CreateButton(L("AH_MENU_RESUME", "Resume scan"), function() self:Resume() end)
                root:CreateButton(L("AH_MENU_CANCEL", "Cancel scan"), function() self:Cancel() end)
            else
                root:CreateButton(L("AH_MENU_QUICK", "Quick scan (recent items)"), function() self:StartScan(false, false) end)
                root:CreateButton(L("AH_MENU_REFRESH_STALE", "Refresh stale items"), function() self:StartScan(false, true) end)
                root:CreateButton(L("AH_MENU_FULL", "Force full rescan"), function() self:StartScan(true, true) end)
            end
            root:CreateDivider()
            local stats = self:GetCacheStats()
            root:CreateTitle(string.format(L("AH_MENU_CACHE_FMT", "Cache: %d items (%d fresh)"), stats.total, stats.fresh))
        end)
    else
        Notify(L("AH_MENU_UNAVAILABLE", "Menu unavailable; use left-click."))
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
    self._completedAt = nil
    if n == 0 then
        MarkScanCompleted()
        local plan = self:GetScanPlan(false)
        Notify(string.format(L("AH_SCAN_UP_TO_DATE_FMT", "AH prices are up to date: %d priced, %d with no listings."),
            plan.pricedFresh, plan.unlisted))
        -- Not a Blizzard limit: items younger than the freshness window (profile.ahFreshTTL) are skipped.
        local ttl = (ArtisanNexus.db.profile and tonumber(ArtisanNexus.db.profile.ahFreshTTL)) or DEFAULT_FRESH_TTL_SEC
        Notify(string.format(L("AH_SCAN_UP_TO_DATE_HINT_FMT",
            "Prices younger than %d h are kept. Right-click Sync AH Prices > \"%s\" to scan everything now."),
            math.max(1, math.floor(ttl / 3600 + 0.5)), L("AH_MENU_FULL", "Force full rescan")))
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
    self._batchRetried = {}
    self._keyInfoWaits = {}
    self._stallRecoveries = 0
    self._depthTargets = nil
    -- Commodities the shopping list still has to buy get a per-item order-book search
    -- after their batch row, so Shopping / profit costs walk real price levels.
    local shop = ns.ShoppingListService
    if shop and shop.Aggregate then
        local okA, agg = pcall(shop.Aggregate, shop, { subtractBags = true })
        if okA and type(agg) == "table" then
            local targets, n = {}, 0
            for id, row in pairs(agg) do
                if n >= DEPTH_TARGETS_MAX then break end
                if (row.short or 0) > 0 then
                    targets[id] = true
                    n = n + 1
                end
            end
            self._depthTargets = targets
        end
    end
    self._browseSnapshot = SnapshotBrowseForRestore()
    UpdateAHButtonText()
    if plan.freshSkipped > 0 then
        Notify(string.format(
            L("AH_SCAN_STARTED_PLAN", "AH scan: %d to refresh (%d tracked, %d fresh)."),
            n, plan.tracked, plan.freshSkipped))
    else
        Notify(string.format(L("AH_SCAN_STARTED", "Starting AH price scan (%d items)."), n))
    end
    self:ArmWatchdog()
    self:BeginScanPipeline()
end

--- `market` (optional): { qty = listed units seen, book = { {p, q}, ... } cheapest-first price levels,
---   qsrc = "b" (browse totalQuantity) | "c" (commodity book, own excluded) | "i" (one item listing) }.
--- Row schema (additive): { buyout, updatedAt, qty?, book?, qsrc?, byIlvl? = { [itemLevel] = copper } }.
function SavePrice(itemID, unitPrice, suppressMessage, market)
    if not ArtisanNexus or not ArtisanNexus.db then return end
    local g = ArtisanNexus.db.global
    if type(g.ahPrices) ~= "table" then
        g.ahPrices = {}
    end
    local row = { buyout = unitPrice, updatedAt = time() }
    local prev = g.ahPrices[itemID]
    if type(market) == "table" then
        row.qty = tonumber(market.qty)
        row.book = market.book
        row.qsrc = market.qsrc
        -- Equipment: cheapest listing per item level (gear browse); buyout is the minimum over them.
        row.byIlvl = market.byIlvl
    end
    -- Browse rows carry no order book: keep the previous book while its cheapest level still
    -- matches the new minimum (otherwise it describes a market that no longer exists).
    if not row.book and type(prev) == "table" and type(prev.book) == "table" and prev.book[1]
        and tonumber(prev.book[1].p) == tonumber(unitPrice) then
        row.book = prev.book
    end
    g.ahPrices[itemID] = row
    if g.ahEmpty then g.ahEmpty[itemID] = nil end
    priceMemo.stamp = nil
    -- Append to rolling history (cheap; PriceHistoryService dedups within 5min).
    if ns.PriceHistoryService and ns.PriceHistoryService.Push then
        local qsrc = type(market) == "table" and market.qsrc or nil
        ns.PriceHistoryService:Push(itemID, unitPrice, qsrc ~= "i" and row.qty or nil, qsrc)
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

local COMMODITY_BOOK_LEVELS = 8
-- Thin-undercut filter: the anchor is the price at which COMMODITY_ANCHOR_SHARE of the listed units
-- (at least COMMODITY_ANCHOR_MIN_UNITS) can be bought; cheaper levels holding fewer units than that
-- and priced below COMMODITY_OUTLIER_RATIO x anchor are a single seller's bait, not the market.
local COMMODITY_ANCHOR_SHARE = 0.01
local COMMODITY_ANCHOR_MIN_UNITS = 5
local COMMODITY_OUTLIER_RATIO = 0.7

--- Reference price over cheapest-first levels: the first level that is not a thin outlier.
---@param levels table { { p, q }, ... } cheapest first, others' units only
---@param totalQty number
---@return number|nil
local function CommodityReferencePrice(levels, totalQty)
    local n = #levels
    if n == 0 then return nil end
    local need = math.max(COMMODITY_ANCHOR_MIN_UNITS, math.ceil(totalQty * COMMODITY_ANCHOR_SHARE))
    -- A market thinner than the anchor depth has no "market" to compare against: keep the true min.
    if totalQty < need then return levels[1].p end
    local anchor, cum = levels[n].p, 0
    for i = 1, n do
        cum = cum + levels[i].q
        if cum >= need then
            anchor = levels[i].p
            break
        end
    end
    local floorPrice = anchor * COMMODITY_OUTLIER_RATIO
    cum = 0
    for i = 1, n do
        local lvl = levels[i]
        cum = cum + lvl.q
        -- A level is kept once it is priced near the anchor or the units up to it reach real depth.
        if lvl.p >= floorPrice or cum >= need then
            return lvl.p
        end
    end
    return anchor
end

--- Read the loaded commodity order book (cheapest first). Levels that are entirely the player's
--- own listing are skipped (CommoditySearchResultInfo numOwnerItems / quantity, 12.1.5
--- AuctionHouseDocumentation), so we never price off ourselves; thin undercuts far below the
--- market are skipped for the reference price (CommodityReferencePrice) but kept in the book,
--- since BuyCost can really buy them.
---@return number|nil unitPrice
---@return table|nil market { qty, book }
local function ReadCommodityBook(itemID, numResults)
    local totalQty, book, levels = 0, {}, {}
    for i = 1, numResults do
        local okR, r = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, i)
        if not okR or type(r) ~= "table" then break end
        local p, q = tonumber(r.unitPrice), tonumber(r.quantity) or 0
        if p and p > 0 and q > 0 then
            local own = tonumber(r.numOwnerItems) or 0
            local othersQty = q - own
            if othersQty > 0 then
                totalQty = totalQty + othersQty
                levels[#levels + 1] = { p = p, q = othersQty }
                if #book < COMMODITY_BOOK_LEVELS then
                    book[#book + 1] = { p = p, q = othersQty }
                end
            end
        end
    end
    local refPrice = CommodityReferencePrice(levels, totalQty)
    if not refPrice then
        return nil, nil
    end
    return refPrice, { qty = totalQty, book = book, qsrc = "c" }
end

---@return boolean true when a recent search found no listings for itemID
function AHPriceService:IsKnownUnlisted(itemID)
    local store = EmptyStore()
    local t = store and itemID and store[itemID]
    if not t then return false end
    local ttl = (ArtisanNexus.db.profile and tonumber(ArtisanNexus.db.profile.ahFreshTTL)) or DEFAULT_FRESH_TTL_SEC
    return (time() - t) < ttl
end

--- Resolve the in-flight commodity query. `final` = COMMODITY_SEARCH_RESULTS_RECEIVED (Blizzard's
--- "results loaded" signal, Blizzard_AuctionHouseCommoditiesBuyFrame.lua): only then is an empty
--- result trusted as "no listings"; an empty UPDATED may be a partial refresh.
local function OnCommodityResults(itemID, qid, final)
    if AHPriceService._batchMode then
        return
    end
    if not AHPriceService._scanning then
        return
    end
    if itemID ~= AHPriceService._currentItemID then
        return
    end
    local ok, numResults = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
    local hasRows = ok and numResults and numResults > 0
    if not hasRows and not final then
        return -- wait for COMMODITY_SEARCH_RESULTS_RECEIVED (or the timeout)
    end
    if not TryConsumeQuery(qid) then
        return
    end
    if hasRows then
        local price, market = ReadCommodityBook(itemID, numResults)
        if price then
            SavePrice(itemID, price, true, market)
        else
            MarkNoListings(itemID) -- only our own listings
        end
    else
        MarkNoListings(itemID)
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
    local ok, num = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
    local hasRows = ok and num and num > 0
    if not hasRows then
        -- An empty update may be partial: trust "no listings" only once the results are complete.
        local okF, full = pcall(C_AuctionHouse.HasFullItemSearchResults, itemKey)
        if not (okF and full) then
            return -- wait for the next update (or the per-item timeout)
        end
    end
    if not TryConsumeQuery(qid) then
        return
    end
    if not hasRows then
        MarkNoListings(itemKey.itemID)
    else
        -- Rows arrive price-ascending (SEARCH_SORTS). Skip the player's own and their warband's
        -- listings (ItemSearchResultInfo containsOwnerItem / containsAccountItem,
        -- AuctionHouseDocumentation 12.1.5.70448, checked 2026-10-22) so we never price off ourselves.
        for i = 1, num do
            local ok2, result = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
            if not ok2 or type(result) ~= "table" then break end
            -- ItemSearchResultInfo.buyoutAmount is already per unit: Blizzard's ItemSellFrame writes it
            -- straight into the per-item price input (Blizzard_AuctionHouseItemSellFrame.lua:325,
            -- 12.1.5.70391, verified 2026-10-14). Dividing by quantity under-priced multi-unit listings.
            local unit = math.floor(tonumber(result.buyoutAmount) or 0)
            if unit > 0 and not result.containsOwnerItem and not result.containsAccountItem then
                -- One listing's quantity is not market depth: keep it on the row, not in history.
                SavePrice(itemKey.itemID, unit, true, { qty = tonumber(result.quantity), qsrc = "i" })
                break
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

--- Native Button in the CategoriesList footer (Browse tab). UIPanelButtonTemplate is the same
--- template the former AceGUI Button wrapped (libs AceGUIWidget-Button.lua).
local function TryCreateAHButton()
    if AHPriceService._ahButtonCreated then
        return
    end
    local parent = _G.AuctionHouseFrame
    if not parent or not parent.CategoriesList then
        return
    end

    local frame = CreateFrame("Button", "ArtisanNexusAHSyncButton", parent.CategoriesList, "UIPanelButtonTemplate")
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    frame:SetText(L("AH_SYNC_PRICES", "Sync AH Prices"))

    frame:SetScript("OnClick", function(_, mouseButton)
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
    frame:SetScript("OnEnter", function()
        ShowAHSyncTooltip(frame)
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    ApplyAHSyncButtonAnchor(frame, parent)

    local cat = parent.CategoriesList
    if cat and not cat.ArtisanNexusAHSyncAnchorHook then
        cat.ArtisanNexusAHSyncAnchorHook = true
        cat:HookScript("OnShow", ScheduleAHSyncAnchorRefresh)
        cat:HookScript("OnHide", ScheduleAHSyncAnchorRefresh)
    end

    AHPriceService._ahButtonCreated = true
    AHPriceService._ahButton = frame
    UpdateAHButtonText()
    ScheduleAHSyncAnchorRefresh()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_RECEIVED")
eventFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
eventFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
eventFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
eventFrame:SetScript("OnEvent", function(_, event, arg1, ...)
    if AHPriceService._scanning and event ~= "ADDON_LOADED" then
        MarkScanActivity()
    end
    if event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
        AHPriceService:OnQueryDropped()
        return
    end
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
            OnCommodityResults(itemID, qid, false)
        end
    elseif event == "COMMODITY_SEARCH_RESULTS_RECEIVED" then
        -- No payload (AuctionHouseDocumentation 12.1.5): applies to the query in flight.
        local qid = AHPriceService._expectQueryId
        if qid and AHPriceService._currentItemID then
            OnCommodityResults(AHPriceService._currentItemID, qid, true)
        end
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        local itemKey = arg1
        local qid = AHPriceService._expectQueryId
        if qid then
            OnItemSearchResults(itemKey, qid)
        end
    elseif (event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
        and AHPriceService._gearScan and AHPriceService._gearScan.sent then
        local gs = AHPriceService._gearScan
        gs.token = (gs.token or 0) + 1
        local token, gid = gs.token, gs.id
        After(0.4, function()
            if AHPriceService._gearScan == gs and gs.token == token then
                AHPriceService:ProcessGearBrowse(gid)
            end
        end)
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        local bid = AHPriceService._batchExpectId
        if bid and AHPriceService._scanning and AHPriceService._batchSentId == bid then
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
    elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" and AHPriceService._gearScan then
        AHPriceService:FallbackGearToLegacy(AHPriceService._gearScan.id)
    elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
        local bid = AHPriceService._batchExpectId
        if bid and AHPriceService._scanning then
            AHPriceService:FallbackBatchToLegacy(bid)
        end
    end
end)

ns.AHPriceService = AHPriceService
