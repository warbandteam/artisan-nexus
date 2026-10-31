--[[
    Artisan Nexus — Owned auctions monitor (snapshot, undercut detection, sell-through).

    While the Auction House is open, the player's auctions are queried once (and again after
    posting/cancelling), snapshotted per character and compared against the market:
      db.global.ownedAuctions = {
        chars = { [guid] = { at, auctions = { OwnedRow, ... } } },
        outcomes = { { t, guid?, itemID?, name?, qty, outcome = "sold"|"expired"|"cancelled",
                       src = "ah"|"mail", unitPrice? }, ... }          -- oldest first, capped
        seen = { [auctionID] = t }                                      -- outcome de-dupe
      }
      OwnedRow = { auctionID, itemID, itemKey, itemLink?, quantity, status, timeLeftSeconds?,
                   timeLeft?, buyoutAmount?, bidAmount?, unitPrice?, isCommodity? }

    Facts (verified 2026-10-14, AuctionHouseDocumentation.lua 12.1.5.70391):
      C_AuctionHouse.QueryOwnedAuctions(sorts: AuctionHouseSortType[]) -> OWNED_AUCTIONS_UPDATED
      C_AuctionHouse.GetOwnedAuctions() -> OwnedAuctionInfo[] { auctionID, itemKey, itemLink?, status
        (Enum.AuctionStatus Active=0/Sold=1), quantity, timeLeftSeconds?, timeLeft?, bidAmount?,
        buyoutAmount?, bidder? }
      CanCancelAuction(id) -> bool, GetCancelCost(id) -> copper; CancelAuction is HasRestrictions
        (never called here; UI does it from a hardware click).
      Events AUCTION_CANCELED(auctionID), AUCTION_HOUSE_AUCTIONS_EXPIRED(auctionID),
        AUCTION_HOUSE_AUCTION_CREATED(auctionID), COMMODITY_SEARCH_RESULTS_UPDATED(itemID),
        ITEM_SEARCH_RESULTS_UPDATED(itemKey, newAuctionID?).
      CommoditySearchResultInfo { unitPrice, quantity, numOwnerItems }, ItemSearchResultInfo
        { buyoutAmount?, containsOwnerItem }.
    Sort list mirrors Blizzard_AuctionHouseFrame.lua (AllAuctions: Name, then Price).
    ItemSearchResultInfo.buyoutAmount is per unit (verified 2026-10-15: Blizzard_AuctionHouseItemSellFrame.lua
      seeds the per-unit PriceInput from it, :325, and GetTotalPrice multiplies by quantity, :440; PostItem's
      buyout is that per-unit amount).
    UNVERIFIED: OwnedAuctionInfo.buyoutAmount semantics (the All Auctions "Buyout" column just prints it,
      Blizzard_AuctionHouseTableBuilder.lua). Per unit is assumed, matching PostItem; for stacks UnitPrice()
      still picks the reading (per unit vs per auction) closest to the market price when one is known.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS

local OwnedAuctionsService = { _enabled = false, _ahOpen = false }

local OUTCOME_CAP = 2000
local OUTCOME_TRIM_SLACK = 100
local SEEN_TTL = 3 * 86400
local FRESH_MARKET_TTL = 30 * 60
local STATUS_ACTIVE, STATUS_SOLD = 0, 1

local freshMarket = {}   -- [MarketKey] = { p = unitPrice, t = GetTime() } (session only)
local pendingCancel = {} -- [auctionID] = true until the next snapshot
local pendingExpire = {}

local function Store()
    local g = ns.db and ns.db.global
    if not g then return nil end
    local s = g.ownedAuctions
    if type(s) ~= "table" then
        s = {}
        g.ownedAuctions = s
    end
    if type(s.chars) ~= "table" then s.chars = {} end
    if type(s.outcomes) ~= "table" then s.outcomes = {} end
    if type(s.seen) ~= "table" then s.seen = {} end
    return s
end

local function Guid()
    return ns.Utilities and ns.Utilities:GetCharacterGUID() or nil
end

local function Notify(reason)
    ns.ArtisanNexus:SendMessage(E.OWNED_AUCTIONS_UPDATED, reason)
end

local function IsCommodityKey(itemKey)
    if type(itemKey) ~= "table" or not (C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo) then return nil end
    local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
    if ok and type(info) == "table" and info.isCommodity ~= nil then
        return info.isCommodity == true
    end
    return nil
end

---------------------------------------------------------------------------
-- Market reference
---------------------------------------------------------------------------

--- Live-market key: itemID alone for commodities / base items, itemID:itemLevel:suffix for gear
--- variants so a different item level never reads as an undercut.
local function MarketKey(itemID, itemKey)
    local lvl = type(itemKey) == "table" and tonumber(itemKey.itemLevel) or 0
    local suf = type(itemKey) == "table" and tonumber(itemKey.itemSuffix) or 0
    if lvl == 0 and suf == 0 then return itemID end
    return itemID .. ":" .. lvl .. ":" .. suf
end

---@param itemID number
---@param itemKey table|nil ItemKey (item level / suffix variant for live listings)
---@return number|nil unitPrice
---@return string|nil source "live"|"scan"|"price"
function OwnedAuctionsService:GetMarketPrice(itemID, itemKey)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    local f = freshMarket[MarketKey(itemID, itemKey)]
    if f and GetTime() - f.t <= FRESH_MARKET_TTL then
        return f.p, "live"
    end
    local econ = ns.Economy
    local row = econ and econ.GetMarketRow and econ:GetMarketRow(itemID)
    local p = row and tonumber(row.buyout)
    if p and p > 0 then return p, "scan" end
    local svc = ns.AHPriceService
    p = svc and svc.GetPrice and tonumber(svc:GetPrice(itemID))
    if p and p > 0 then return p, "price" end
    return nil
end

--- Per-unit price of an owned row (see header for the commodity ambiguity).
---@param a table OwnedRow
---@return number|nil
function OwnedAuctionsService:UnitPrice(a)
    if type(a) ~= "table" then return nil end
    local buyout = tonumber(a.buyoutAmount)
    if not buyout or buyout <= 0 then return nil end
    local qty = math.max(1, tonumber(a.quantity) or 1)
    if qty == 1 then return buyout end
    local market = self:GetMarketPrice(a.itemID, a.itemKey)
    if market and market > 0 then
        local asUnit = math.abs(math.log(buyout / market))
        local asTotal = math.abs(math.log((buyout / qty) / market))
        if asTotal < asUnit then return buyout / qty end
    end
    return buyout
end

local function ReadCommodityMarket(itemID)
    if not (C_AuctionHouse and C_AuctionHouse.GetNumCommoditySearchResults and C_AuctionHouse.GetCommoditySearchResultInfo) then
        return
    end
    local okN, n = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
    n = okN and tonumber(n) or 0
    for i = 1, math.min(n, 50) do
        local ok, r = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, i)
        if not ok or type(r) ~= "table" then break end
        local p, q = tonumber(r.unitPrice), tonumber(r.quantity) or 0
        local own = tonumber(r.numOwnerItems) or 0
        if p and p > 0 and q - own > 0 then
            freshMarket[itemID] = { p = p, t = GetTime() }
            return
        end
    end
end

local function ReadItemMarket(itemKey)
    if type(itemKey) ~= "table" or not (C_AuctionHouse and C_AuctionHouse.GetNumItemSearchResults
        and C_AuctionHouse.GetItemSearchResultInfo) then
        return
    end
    local itemID = tonumber(itemKey.itemID)
    if not itemID then return end
    local okN, n = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
    n = okN and tonumber(n) or 0
    local best
    for i = 1, math.min(n, 50) do
        local ok, r = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
        if not ok or type(r) ~= "table" then break end
        local unit = tonumber(r.buyoutAmount) -- per unit (see header)
        if unit and unit > 0 and not r.containsOwnerItem then
            if not best or unit < best then best = unit end
        end
    end
    if best then
        freshMarket[MarketKey(itemID, itemKey)] = { p = best, t = GetTime() }
    end
end

---------------------------------------------------------------------------
-- Outcomes
---------------------------------------------------------------------------

local function TrimOutcomes(list)
    if #list <= OUTCOME_CAP + OUTCOME_TRIM_SLACK then return end
    local drop = #list - OUTCOME_CAP
    local keep = {}
    for i = drop + 1, #list do keep[#keep + 1] = list[i] end
    wipe(list)
    for i = 1, #keep do list[i] = keep[i] end
end

local function PruneSeen(seen)
    local cutoff = time() - SEEN_TTL
    for id, t in pairs(seen) do
        if (tonumber(t) or 0) < cutoff then seen[id] = nil end
    end
end

--- The same auction is usually observed twice: by the AH (snapshot / events) and later by its mail.
--- Pair an outcome with an unpaired one of the other source (same character, item, outcome and
--- quantity, or any quantity when the mail did not say). Returns the partner row when found.
local PAIR_WINDOW = 31 * 86400
local PAIR_SCAN = 400
local function FindPartner(list, row, qtyKnown)
    if not row.itemID then return nil end
    local cutoff = row.t - PAIR_WINDOW
    for i = #list, math.max(1, #list - PAIR_SCAN), -1 do
        local o = list[i]
        if (tonumber(o.t) or 0) < cutoff then break end
        if not o.paired and o.src ~= row.src and o.outcome == row.outcome and o.itemID == row.itemID
            and (o.guid == nil or row.guid == nil or o.guid == row.guid)
            and (not qtyKnown or o.qtyUnknown or o.qty == row.qty) then
            return o
        end
    end
    return nil
end

--- Record one auction outcome. AH-observed outcomes de-dupe by auctionID; each mail is passed once
--- by SalesLedgerService; an AH and a mail observation of the same auction are counted once.
---@param info table { itemID?, name?, qty, qtyUnknown?, outcome = "sold"|"expired"|"cancelled", src?, unitPrice?, auctionID?, guid? }
---@return boolean recorded
function OwnedAuctionsService:RecordOutcome(info)
    local store = Store()
    if not store or type(info) ~= "table" then return false end
    local outcome = info.outcome
    if outcome ~= "sold" and outcome ~= "expired" and outcome ~= "cancelled" then return false end
    local id = tonumber(info.auctionID)
    if id then
        if store.seen[id] then return false end
        store.seen[id] = time()
    end
    local probe = {
        t = time(), guid = info.guid or Guid(), itemID = tonumber(info.itemID),
        qty = math.max(1, tonumber(info.qty) or 1), outcome = outcome, src = info.src or "ah",
    }
    local partner = FindPartner(store.outcomes, probe, not info.qtyUnknown)
    if partner then
        partner.paired = true
        if not partner.unitPrice and info.unitPrice then partner.unitPrice = tonumber(info.unitPrice) end
        if partner.qtyUnknown and not info.qtyUnknown then
            partner.qty, partner.qtyUnknown = probe.qty, nil
        end
        return false
    end
    store.outcomes[#store.outcomes + 1] = {
        t = time(),
        guid = info.guid or Guid(),
        itemID = tonumber(info.itemID),
        name = (not info.itemID) and info.name or nil,
        qty = math.max(1, tonumber(info.qty) or 1),
        outcome = outcome,
        src = info.src or "ah",
        unitPrice = tonumber(info.unitPrice),
        qtyUnknown = info.qtyUnknown and true or nil,
    }
    TrimOutcomes(store.outcomes)
    return true
end

local function FindInSnapshot(guid, auctionID)
    local store = Store()
    local snap = store and guid and store.chars[guid]
    if type(snap) ~= "table" or type(snap.auctions) ~= "table" then return nil end
    for i = 1, #snap.auctions do
        if snap.auctions[i].auctionID == auctionID then return snap.auctions[i] end
    end
    return nil
end

---@param qty number|nil units this outcome covers (defaults to the row's remaining quantity)
local function OutcomeFromRow(row, outcome, svc, qty)
    return {
        auctionID = row.auctionID, itemID = row.itemID, qty = qty or row.quantity,
        outcome = outcome, src = "ah", unitPrice = svc:UnitPrice(row),
    }
end

--- Diff previous vs new snapshot into sold / expired / cancelled outcomes.
local function RecordTransitions(svc, prev, new)
    if type(prev) ~= "table" then return end
    local byID = {}
    for i = 1, #new do byID[new[i].auctionID] = new[i] end
    for i = 1, #prev do
        local old = prev[i]
        local now = byID[old.auctionID]
        if old.status == STATUS_ACTIVE then
            if now and now.status == STATUS_SOLD then
                -- `now.quantity` is what is left on the auction, so booking it as the units sold
                -- lost everything an earlier partial fill already took. Book what was still
                -- outstanding when we last looked.
                svc:RecordOutcome(OutcomeFromRow(now, "sold", svc, old.quantity))
            -- A commodity auction that fills piecewise stays ACTIVE with a smaller quantity, and
            -- those partial fills are still not recorded: RecordOutcome de-dupes on auctionID, so
            -- booking one would swallow the auction's later outcomes. Needs a per-fill de-dupe key
            -- and in-game confirmation of how partial commodity fills are reported (ECONOMY_AUDIT
            -- B12); until then sell-through still reads low rather than double-counting.
            elseif not now then
                if pendingCancel[old.auctionID] then
                    svc:RecordOutcome(OutcomeFromRow(old, "cancelled", svc))
                elseif pendingExpire[old.auctionID] then
                    svc:RecordOutcome(OutcomeFromRow(old, "expired", svc))
                end
                -- Otherwise unknown: after a long absence a vanished auction may have sold (and been
                -- collected) as well as expired. No guess; the expired / sold mail books it.
            end
        end
    end
end

---------------------------------------------------------------------------
-- Snapshot
---------------------------------------------------------------------------

function OwnedAuctionsService:ReadOwned()
    if not (C_AuctionHouse and C_AuctionHouse.GetOwnedAuctions) then return end
    local guid = Guid()
    local store = Store()
    if not guid or not store then return end
    local ok, list = pcall(C_AuctionHouse.GetOwnedAuctions)
    if not ok or type(list) ~= "table" then return end
    -- HasFullOwnedAuctionResults (verified 2026-10-15, AuctionHouseDocumentation.lua; Blizzard's All
    -- Auctions list uses it, Blizzard_AuctionHouseAuctionsFrame.lua:236). A partial list is kept for
    -- undercut display, but vanished rows are not diffed into outcomes (they may just be unloaded).
    local full = true
    if C_AuctionHouse.HasFullOwnedAuctionResults then
        local okF, f = pcall(C_AuctionHouse.HasFullOwnedAuctionResults)
        full = not okF or f ~= false
    end
    local rows = {}
    for i = 1, #list do
        local a = list[i]
        local key = type(a) == "table" and a.itemKey
        local itemID = type(key) == "table" and tonumber(key.itemID)
        if itemID and a.auctionID then
            local row = {
                auctionID = a.auctionID,
                itemID = itemID,
                itemKey = {
                    itemID = itemID,
                    itemLevel = tonumber(key.itemLevel) or 0,
                    itemSuffix = tonumber(key.itemSuffix) or 0,
                    battlePetSpeciesID = tonumber(key.battlePetSpeciesID) or 0,
                },
                itemLink = a.itemLink,
                quantity = tonumber(a.quantity) or 1,
                status = tonumber(a.status) or STATUS_ACTIVE,
                timeLeftSeconds = tonumber(a.timeLeftSeconds),
                timeLeft = tonumber(a.timeLeft),
                buyoutAmount = tonumber(a.buyoutAmount),
                bidAmount = tonumber(a.bidAmount),
                isCommodity = IsCommodityKey(key),
            }
            rows[#rows + 1] = row
        end
    end
    for i = 1, #rows do
        rows[i].unitPrice = self:UnitPrice(rows[i])
    end
    local prev = store.chars[guid]
    -- A partial list must not replace the last full one as the diff baseline, or the next full
    -- read misses cancels/expiries of rows the partial list never loaded.
    local baseline = prev and (prev.baseline or (not prev.partial and prev.auctions)) or nil
    if full then
        RecordTransitions(self, baseline, rows)
        wipe(pendingCancel)
        wipe(pendingExpire)
    end
    store.chars[guid] = {
        at = time(), auctions = rows,
        partial = (not full) or nil,
        baseline = (not full) and baseline or nil,
    }
    PruneSeen(store.seen)
    Notify("snapshot")
end

local queryGen = 0

--- Ask the server for the owned list (AH must be open; waits for the throttle and scans).
function OwnedAuctionsService:RequestRefresh(delay)
    if not self._enabled then return end
    queryGen = queryGen + 1
    local myGen = queryGen
    local tries = 0
    local function Try()
        if myGen ~= queryGen or not OwnedAuctionsService._enabled or not OwnedAuctionsService._ahOpen then return end
        if not (C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions and Enum and Enum.AuctionHouseSortOrder) then return end
        local scanning = ns.AHPriceService and ns.AHPriceService.IsScanActive and ns.AHPriceService:IsScanActive()
        local ready = not C_AuctionHouse.IsThrottledMessageSystemReady or C_AuctionHouse.IsThrottledMessageSystemReady()
        if scanning or not ready then
            tries = tries + 1
            if tries <= 12 then C_Timer.After(5, Try) end
            return
        end
        local sorts = {
            { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
            { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
        }
        pcall(C_AuctionHouse.QueryOwnedAuctions, sorts)
    end
    C_Timer.After(tonumber(delay) or 0, Try)
end

---------------------------------------------------------------------------
-- Public read API
---------------------------------------------------------------------------

---@param guid string|nil default current character
---@return table|nil { at, auctions = OwnedRow[] } (stored table; read-only)
function OwnedAuctionsService:GetOwned(guid)
    local store = Store()
    guid = guid or Guid()
    return store and guid and store.chars[guid] or nil
end

--- Active auctions of the current character priced above the market.
---@param guid string|nil
---@return table[] { auctionID, itemID, quantity, myPrice, marketPrice, diff, source, timeLeftSeconds? }
function OwnedAuctionsService:GetUndercut(guid)
    local out = {}
    local snap = self:GetOwned(guid)
    if not snap or type(snap.auctions) ~= "table" then return out end
    for i = 1, #snap.auctions do
        local a = snap.auctions[i]
        if a.status == STATUS_ACTIVE then
            local mine = self:UnitPrice(a)
            local market, src = self:GetMarketPrice(a.itemID, a.itemKey)
            if mine and market and market < mine then
                out[#out + 1] = {
                    auctionID = a.auctionID, itemID = a.itemID, quantity = a.quantity,
                    myPrice = mine, marketPrice = market, diff = mine - market, source = src,
                    timeLeftSeconds = a.timeLeftSeconds,
                }
            end
        end
    end
    table.sort(out, function(x, y) return x.diff * (x.quantity or 1) > y.diff * (y.quantity or 1) end)
    return out
end

--- For a UI cancel button (the click handler must call C_AuctionHouse.CancelAuction itself).
---@param auctionID number
---@return number|nil auctionID when cancellable
---@return number|nil cancelCost copper
function OwnedAuctionsService:GetCancelInfo(auctionID)
    auctionID = tonumber(auctionID)
    if not auctionID or not self._ahOpen or not C_AuctionHouse then return nil end
    if C_AuctionHouse.CanCancelAuction then
        local ok, can = pcall(C_AuctionHouse.CanCancelAuction, auctionID)
        if not ok or not can then return nil end
    end
    local cost
    if C_AuctionHouse.GetCancelCost then
        local ok, c = pcall(C_AuctionHouse.GetCancelCost, auctionID)
        cost = ok and tonumber(c) or nil
    end
    return auctionID, cost
end

--- Item IDs seen in any character's owned snapshot (used for invoice name resolution).
---@return table set [itemID] = itemLink|true
function OwnedAuctionsService:GetKnownItems()
    local set = {}
    local store = Store()
    if not store then return set end
    for _, snap in pairs(store.chars) do
        if type(snap) == "table" and type(snap.auctions) == "table" then
            for i = 1, #snap.auctions do
                local a = snap.auctions[i]
                if a.itemID then set[a.itemID] = a.itemLink or true end
            end
        end
    end
    return set
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function OwnedAuctionsService:Enable()
    if self._enabled then return end
    self._enabled = true
    local owner = self._eventOwner or ns.NewEventOwner("OwnedAuctionsService")
    self._eventOwner = owner
    self._ahOpen = ns.Economy and ns.Economy.IsAuctionHouseOpen and ns.Economy:IsAuctionHouseOpen() or false

    local readPending = false
    local function QueueRead()
        if readPending then return end
        readPending = true
        C_Timer.After(0.2, function()
            readPending = false
            if OwnedAuctionsService._enabled then OwnedAuctionsService:ReadOwned() end
        end)
    end

    owner:RegisterEvent("AUCTION_HOUSE_SHOW", function()
        OwnedAuctionsService._ahOpen = true
        OwnedAuctionsService:RequestRefresh(1.5)
    end)
    owner:RegisterEvent("AUCTION_HOUSE_CLOSED", function()
        OwnedAuctionsService._ahOpen = false
    end)
    owner:RegisterEvent("OWNED_AUCTIONS_UPDATED", QueueRead)
    owner:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED", function()
        OwnedAuctionsService:RequestRefresh(2)
    end)
    owner:RegisterEvent("AUCTION_CANCELED", function(_, auctionID)
        auctionID = tonumber(auctionID)
        if not auctionID then return end
        pendingCancel[auctionID] = true
        local row = FindInSnapshot(Guid(), auctionID)
        if row then
            OwnedAuctionsService:RecordOutcome(OutcomeFromRow(row, "cancelled", OwnedAuctionsService))
            Notify("cancelled")
        end
        OwnedAuctionsService:RequestRefresh(2)
    end)
    owner:RegisterEvent("AUCTION_HOUSE_AUCTIONS_EXPIRED", function(_, auctionID)
        auctionID = tonumber(auctionID)
        if not auctionID then return end
        pendingExpire[auctionID] = true
        local row = FindInSnapshot(Guid(), auctionID)
        if row then
            OwnedAuctionsService:RecordOutcome(OutcomeFromRow(row, "expired", OwnedAuctionsService))
            Notify("expired")
        end
    end)
    owner:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID)
        itemID = tonumber(itemID)
        if itemID then ReadCommodityMarket(itemID) end
    end)
    owner:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED", function(_, itemKey)
        ReadItemMarket(itemKey)
    end)
    if self._ahOpen then
        self:RequestRefresh(1)
    end
end

function OwnedAuctionsService:Disable()
    if not self._enabled then return end
    self._enabled = false
    queryGen = queryGen + 1
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
    end
end

ns.OwnedAuctionsService = OwnedAuctionsService
