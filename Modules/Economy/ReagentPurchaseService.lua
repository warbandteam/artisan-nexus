--[[
    Artisan Nexus - buying a shopping-list reagent at the auction house.

    Commodities only. The API forces the shape of this: StartCommoditiesPurchase and
    PlaceBid are both #hwevent, so the player's own click has to reach Start, while
    ConfirmCommoditiesPurchase carries no such tag and is fired from the price event
    (AuctionHouseDocumentation.lua 12.1.5 live; same division of labour Blizzard's own
    buy frame uses). Nothing here is a loop: one click buys one reagent.

    PlaceBid is deliberately not wired up. Non-commodity listings confirm differently and
    a half-understood bid path risks the player's gold for a case the shopping list,
    which deals in stackable reagents, barely meets.

    Price safety, in the order it matters:
      1. the quote is read from a fresh commodity search, never from cached scan data;
      2. the quantity never exceeds the shortfall or what is actually listed;
      3. COMMODITY_PRICE_UPDATED is re-checked against the quoted total before
         confirming, and anything higher cancels the purchase instead.
]]

local ADDON_NAME, ns = ...
local ArtisanNexus = ns.ArtisanNexus
local L = ns.SafeLocaleString

local ReagentPurchaseService = {}
ns.ReagentPurchaseService = ReagentPurchaseService

--- Quote lifetime: beyond this the listing book is assumed to have moved on.
local QUOTE_TTL_SEC = 30

local SEARCH_SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

local pending = nil   -- { itemID, quantity, totalPrice } awaiting confirm
local quotes = {}     -- itemID -> { unitPrice, quantity, total, at }

local function Notify(msg)
    if ArtisanNexus and ArtisanNexus.Print then
        ArtisanNexus:Print(msg)
    end
end

local function IsCommodity(itemID)
    if not (C_AuctionHouse and C_AuctionHouse.MakeItemKey and C_AuctionHouse.GetItemKeyInfo) then
        return false
    end
    local okKey, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
    if not okKey or not key then return false end
    local okInfo, info = pcall(C_AuctionHouse.GetItemKeyInfo, key)
    if not okInfo or type(info) ~= "table" then return false end
    return info.isCommodity == true
end

--- Walk the listing book cheapest-first and price exactly `want` units.
---@return number|nil unitPrice top listing's unit price
---@return number quantity units actually available, capped at want
---@return number total copper for that quantity
local function PriceFromBook(itemID, want)
    local n = C_AuctionHouse.GetCommoditySearchResultsQuantity and C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID) or 0
    if (tonumber(n) or 0) < 1 then
        return nil, 0, 0
    end
    local left, total, taken, topUnit = want, 0, 0, nil
    for i = 1, n do
        if left <= 0 then break end
        local ok, r = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, i)
        if ok and type(r) == "table" and r.quantity and r.unitPrice then
            topUnit = topUnit or r.unitPrice
            local take = math.min(left, r.quantity)
            total = total + take * r.unitPrice
            taken = taken + take
            left = left - take
        end
    end
    return topUnit, taken, total
end

--- Ask the server for this reagent's listings. The caller is told through onQuote.
---@param itemID number
---@param want number units still needed
---@param onQuote function(quote: table|nil, reason: string|nil)
function ReagentPurchaseService:RequestQuote(itemID, want, onQuote)
    itemID, want = tonumber(itemID), tonumber(want)
    if not itemID or not want or want < 1 then
        return
    end
    if not (C_AuctionHouse and C_AuctionHouse.SendSearchQuery) then
        return
    end
    if not IsCommodity(itemID) then
        if onQuote then onQuote(nil, "notCommodity") end
        return
    end
    self._awaiting = { itemID = itemID, want = want, onQuote = onQuote }
    local key = C_AuctionHouse.MakeItemKey(itemID)
    pcall(C_AuctionHouse.SendSearchQuery, key, SEARCH_SORTS, false)
end

function ReagentPurchaseService:GetQuote(itemID)
    local q = quotes[tonumber(itemID) or 0]
    if not q then return nil end
    if (GetTime() - q.at) > QUOTE_TTL_SEC then
        return nil
    end
    return q
end

--- Must run inside the player's click: StartCommoditiesPurchase is #hwevent.
---@return boolean started
function ReagentPurchaseService:Buy(itemID)
    itemID = tonumber(itemID)
    local q = itemID and self:GetQuote(itemID)
    if not q then
        Notify(L("AH_BUY_NO_QUOTE", "Search the reagent first - the price quote has expired."))
        return false
    end
    if pending then
        return false
    end
    local money = GetMoney and GetMoney() or 0
    if q.total > money then
        Notify(L("AH_BUY_NOT_ENOUGH_GOLD", "Not enough gold for that purchase."))
        return false
    end
    pending = { itemID = itemID, quantity = q.quantity, total = q.total, at = GetTime() }
    local ok = pcall(C_AuctionHouse.StartCommoditiesPurchase, itemID, q.quantity)
    if not ok then
        pending = nil
        return false
    end
    --- If the price event never arrives the purchase is stuck open and every later buy
    --- is refused, so give up on it rather than leaving the player with a dead button.
    local started = pending
    C_Timer.After(10, function()
        if pending == started then
            pcall(C_AuctionHouse.CancelCommoditiesPurchase)
            pending = nil
            Notify(L("AH_BUY_TIMED_OUT", "The auction house did not answer - purchase cancelled."))
        end
    end)
    return true
end

local function ClearPending()
    pending = nil
end

--- The server's final word on the price. Anything above what the player was shown is
--- cancelled rather than bought: this is the window where another buyer takes the
--- cheap listings and the next one up is several times the price.
local function OnPriceUpdated(updatedUnitPrice, updatedTotalPrice)
    if not pending then
        return
    end
    local quoted = pending.total
    local total = tonumber(updatedTotalPrice) or 0
    if total > 0 and total <= quoted then
        pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, pending.itemID, pending.quantity)
        return
    end
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    local fmt = L("AH_BUY_PRICE_MOVED_FMT", "Price moved while buying - cancelled (was %s, now %s).")
    local money = ns.UI_FormatMoney
    Notify(string.format(fmt, money and money(quoted, 12, true) or quoted, money and money(total, 12, true) or total))
    ClearPending()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
frame:RegisterEvent("COMMODITY_PRICE_UPDATED")
frame:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
frame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
frame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:SetScript("OnEvent", function(_, event, a, b)
    if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        local await = ReagentPurchaseService._awaiting
        local itemID = tonumber(a)
        if not await or not itemID or await.itemID ~= itemID then
            return
        end
        ReagentPurchaseService._awaiting = nil
        local unit, qty, total = PriceFromBook(itemID, await.want)
        if not unit or qty < 1 then
            quotes[itemID] = nil
            if await.onQuote then await.onQuote(nil, "noListings") end
            return
        end
        local q = { unitPrice = unit, quantity = qty, total = total, at = GetTime() }
        quotes[itemID] = q
        if await.onQuote then await.onQuote(q, nil) end
    elseif event == "COMMODITY_PRICE_UPDATED" then
        OnPriceUpdated(a, b)
    elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
        if pending then
            pcall(C_AuctionHouse.CancelCommoditiesPurchase)
            Notify(L("AH_BUY_PRICE_UNAVAILABLE", "The auction house would not quote a price - purchase cancelled."))
            ClearPending()
        end
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        if pending then
            quotes[pending.itemID] = nil
        end
        ClearPending()
    elseif event == "COMMODITY_PURCHASE_FAILED" then
        ClearPending()
    elseif event == "AUCTION_HOUSE_CLOSED" then
        --- A quote outlives nothing: the book is gone and so is any half-finished buy.
        if pending then
            pcall(C_AuctionHouse.CancelCommoditiesPurchase)
        end
        ClearPending()
        ReagentPurchaseService._awaiting = nil
        wipe(quotes)
    end
end)
