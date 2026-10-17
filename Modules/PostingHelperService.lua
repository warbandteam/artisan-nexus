--[[
    Artisan Nexus — Auction Posting Helper (pricing engine).

    Suggests a post price for whatever the player is selling on the AH sell tab and explains
    the numbers around it (deposit, net after cut, profit vs cost basis, deposit risk).
    The panel (UI/PostingHelperUI.lua) is the only surface; this module never prints to chat
    and never posts — PostCommodity / PostItem stay on Blizzard's own Post button.

    Strategy (db.profile.posting.strategy):
      "undercut" (default)
          commodities: automatic match-vs-undercut by wall depth (posting.commodityMode = "auto"),
                       or forced "match" / "undercut"; undercut = one Economy:UndercutStep()
          items:       lowest other seller's buyout minus one step
      "average"  7-day average x averageMul
      "max"      higher of the undercut target and the 7-day average x averageMul
    All prices go through Economy:RoundPostPrice (whole silver unless SupportsCopperValues).
    Own listings are never undercut; nothing is suggested below
      floor = max(cost basis, vendor sell / (1 - cut), 7d avg x floorMul)
    and a market below the floor is flagged as "hold".

    Facts (verified 2026-10-14, wow-ui-source live 12.1.5.70391 + AuctionHouseDocumentation):
      - CommoditySearchResultInfo { unitPrice, quantity, numOwnerItems, containsOwnerItem }.
      - ItemSearchResultInfo { buyoutAmount, quantity, containsOwnerItem }; buyoutAmount is per
        unit (ItemSellFrame:OnSearchResultSelected writes it straight into the per-item PriceInput).
      - Item sell searches use GetItemKeyFromItem(itemLocation) with itemLevel / itemSuffix zeroed
        for equipment (AuctionHouseUtil.ConvertItemSellItemKey).
      - Sell frames: :GetItem() -> ItemLocation, :GetQuantity(), :GetDuration() (1/2/3),
        .PriceInput:SetAmount(copper) (AuctionHouseAlignedPriceInputFrameMixin; the money boxes'
        OnTextChanged runs the frame's UpdatePostState, same path as clicking a result row).
      - CalculateItemDeposit(itemLocation, duration, quantity) for non-commodities.

    Public API:
      PostingHelperService:GetConfig() / :SetConfig(cfg)
      PostingHelperService:GetSellContext() -> ctx|nil
      PostingHelperService:Analyze(ctx) -> result (see Analyze)
      PostingHelperService:ApplyPrice(price) -> ok   (call from a click handler)
]]

local ADDON_NAME, ns = ...

local PostingHelperService = {}

--- Core.lua defaults.profile.posting: strategy, averageMul, floorMul, commodityMode ("auto" wall depth |
--- "match" | "undercut"), wallShare (no demand data: cheapest level is a deep wall at this share of the
--- visible non-own book), wallDurations (with demand: deep wall when it outlasts this many post durations).
local DEFAULT_CFG = ns.DEFAULTS.profile.posting

local WEEK_SEC = 7 * 24 * 3600
local DURATION_HOURS = { 12, 24, 48 }

local T = ns.SafeLocaleString

local function Cfg()
    local p = ns.db and ns.db.profile
    if not p then return DEFAULT_CFG end
    if type(p.posting) ~= "table" then p.posting = {} end
    for k, v in pairs(DEFAULT_CFG) do
        if p.posting[k] == nil then p.posting[k] = v end
    end
    return p.posting
end

function PostingHelperService:GetConfig() return Cfg() end

function PostingHelperService:SetConfig(cfg)
    local cur = Cfg()
    if type(cfg) ~= "table" then return end
    for k, v in pairs(cfg) do cur[k] = v end
end

local function Econ() return ns.Economy end

local function Round(copper, mode)
    local econ = Econ()
    if econ and econ.RoundPostPrice then return econ:RoundPostPrice(copper, mode) end
    copper = tonumber(copper) or 0
    if copper <= 0 then return 0 end
    if mode == "up" then return math.max(100, math.ceil(copper / 100) * 100) end
    return math.max(100, math.floor(copper / 100) * 100)
end

local function Step()
    local econ = Econ()
    return (econ and econ.UndercutStep and econ:UndercutStep()) or 100
end

local function CutRate()
    local econ = Econ()
    if econ and econ.CutRate then return econ:CutRate() end
    return 0.05
end

-- ---------------------------------------------------------------------------
-- Sell frame context
-- ---------------------------------------------------------------------------

local function SafeCall(obj, method, ...)
    local fn = obj and obj[method]
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, obj, ...)
    if ok then return a end
    return nil
end

--- Copy of the sell-search item key (do not mutate the API's table).
local function SellItemKey(itemLocation)
    if not (C_AuctionHouse and C_AuctionHouse.GetItemKeyFromItem and itemLocation) then return nil end
    local ok, key = pcall(C_AuctionHouse.GetItemKeyFromItem, itemLocation)
    if not ok or type(key) ~= "table" or not key.itemID then return nil end
    local copy = {
        itemID = key.itemID,
        itemLevel = key.itemLevel or 0,
        itemSuffix = key.itemSuffix or 0,
        battlePetSpeciesID = key.battlePetSpeciesID or 0,
    }
    local okI, info = pcall(C_AuctionHouse.GetItemKeyInfo, copy)
    if okI and type(info) == "table" and info.isEquipment then
        -- Same normalization as AuctionHouseUtil.ConvertItemSellItemKey.
        copy.itemLevel, copy.itemSuffix = 0, 0
    end
    return copy
end

--- Live state of the visible Blizzard sell frame.
---@return table|nil { frame, isCommodity, itemLocation, itemID, itemKey?, quantity, duration }
function PostingHelperService:GetSellContext()
    local ah = _G.AuctionHouseFrame
    if not ah then return nil end
    local frame, isCommodity
    if ah.CommoditiesSellFrame and ah.CommoditiesSellFrame:IsShown() then
        frame, isCommodity = ah.CommoditiesSellFrame, true
    elseif ah.ItemSellFrame and ah.ItemSellFrame:IsShown() then
        frame, isCommodity = ah.ItemSellFrame, false
    else
        return nil
    end
    local loc = SafeCall(frame, "GetItem")
    if not loc then return { frame = frame, isCommodity = isCommodity } end
    local valid = SafeCall(loc, "IsValid")
    if not valid then return { frame = frame, isCommodity = isCommodity } end
    local itemID = C_Item and C_Item.GetItemID and C_Item.GetItemID(loc)
    return {
        frame = frame,
        isCommodity = isCommodity,
        itemLocation = loc,
        itemID = itemID,
        itemKey = (not isCommodity) and SellItemKey(loc) or nil,
        quantity = math.max(1, tonumber(SafeCall(frame, "GetQuantity")) or 1),
        duration = tonumber(SafeCall(frame, "GetDuration")) or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Live market reads
-- ---------------------------------------------------------------------------

--- Commodity book from the loaded search results (cheapest first).
---@return table|nil { othersLowest, wallQty, totalQty, ownLowest }
local function ReadCommodityMarket(itemID)
    if not (C_AuctionHouse and C_AuctionHouse.GetNumCommoditySearchResults) then return nil end
    local okN, n = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
    if not okN or not n or n < 1 then return nil end
    local m = { totalQty = 0, wallQty = 0 }
    for i = 1, n do
        local ok, r = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, i)
        if not ok or type(r) ~= "table" then break end
        local p, q = tonumber(r.unitPrice), tonumber(r.quantity) or 0
        local own = tonumber(r.numOwnerItems) or 0
        if p and p > 0 then
            if own > 0 and (not m.ownLowest or p < m.ownLowest) then m.ownLowest = p end
            local others = q - own
            if others > 0 then
                m.totalQty = m.totalQty + others
                if not m.othersLowest then
                    m.othersLowest = p
                    m.wallQty = others
                elseif p == m.othersLowest then
                    m.wallQty = m.wallQty + others
                end
            end
        end
    end
    if not m.othersLowest and not m.ownLowest then return nil end
    return m
end

---@return table|nil { othersLowest, totalQty, ownLowest }
local function ReadItemMarket(itemKey)
    if not (itemKey and C_AuctionHouse and C_AuctionHouse.GetNumItemSearchResults) then return nil end
    local okN, n = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
    if not okN or not n or n < 1 then return nil end
    local m = { totalQty = 0 }
    for i = 1, n do
        local ok, r = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
        if not ok or type(r) ~= "table" then break end
        local unit = tonumber(r.buyoutAmount)
        if unit and unit > 0 then
            if r.containsOwnerItem then
                if not m.ownLowest or unit < m.ownLowest then m.ownLowest = unit end
            else
                m.totalQty = m.totalQty + (tonumber(r.quantity) or 1)
                if not m.othersLowest or unit < m.othersLowest then m.othersLowest = unit end
            end
        end
    end
    if not m.othersLowest and not m.ownLowest then return nil end
    return m
end

local function DemandPerDay(itemID)
    local mi = ns.MarketIntelService
    if not (mi and mi.GetDemandEstimate) then return nil end
    local ok, v = pcall(mi.GetDemandEstimate, mi, itemID)
    if not ok then return nil end
    if type(v) == "table" then v = v.unitsPerDay or v.perDay end
    v = tonumber(v)
    return (v and v > 0) and v or nil
end

-- ---------------------------------------------------------------------------
-- Cost basis + floor
-- ---------------------------------------------------------------------------

---@return number|nil copper per unit
---@return string|nil source "ledger"|"craft"
local function CostBasis(itemID)
    local ledger = ns.SalesLedgerService
    if ledger and ledger.GetAvgBuyPrice then
        local ok, v = pcall(ledger.GetAvgBuyPrice, ledger, itemID)
        if ok then
            if type(v) == "table" then v = v.avg or v.price end
            v = tonumber(v)
            if v and v > 0 then return v, "ledger" end
        end
    end
    local ts = ns.TooltipService
    if ts and ts.GetCraftSummary then
        local s = ts:GetCraftSummary(itemID)
        if s and s.costPerUnit and s.costPerUnit > 0 then return s.costPerUnit, "craft" end
    end
    return nil, nil
end

local function ComputeFloor(itemID, avg, cfg)
    local cut = CutRate()
    local floor, source = 0, nil
    local basis, basisSource = CostBasis(itemID)
    if basis and basis > floor then floor, source = basis, basisSource end
    local econ = Econ()
    local vsp = econ and econ.VendorSellPrice and econ:VendorSellPrice(itemID)
    if vsp and cut < 1 then
        local vf = vsp / (1 - cut)
        if vf > floor then floor, source = vf, "vendor" end
    end
    local mul = tonumber(cfg.floorMul) or 0
    if avg and mul > 0 and avg * mul > floor then
        floor, source = avg * mul, "history"
    end
    if floor <= 0 then return nil, nil, basis, basisSource end
    return floor, source, basis, basisSource
end

-- ---------------------------------------------------------------------------
-- Strategy
-- ---------------------------------------------------------------------------

--- Market-following target (the "undercut" strategy body).
---@return number|nil price, string mode, string reason
local function MarketTarget(ctx, market, cfg, itemID)
    if not market then return nil, "none", T("POSTING_REASON_NO_MARKET", "no live listings loaded") end
    local others, own = market.othersLowest, market.ownLowest
    if own and (not others or own <= others) then
        return own, "own", T("POSTING_REASON_OWN_LOWEST", "you already hold the lowest price")
    end
    local step = Step()
    if others - step < step then
        -- Already at the minimum legal price: undercutting would post at zero.
        return others, "match", T("POSTING_REASON_MATCH_MIN", "lowest is at the minimum price: match")
    end
    if not ctx.isCommodity then
        return others - step, "undercut", T("POSTING_REASON_UNDERCUT_ITEM", "lowest other listing minus one step")
    end
    local mode = cfg.commodityMode or "auto"
    if mode == "match" then
        return others, "match", T("POSTING_REASON_MATCH_FORCED", "match lowest (setting)")
    elseif mode == "undercut" then
        return others - step, "undercut", T("POSTING_REASON_UNDERCUT_FORCED", "undercut by one step (setting)")
    end
    local deep
    local demand = DemandPerDay(itemID)
    if demand then
        local hours = DURATION_HOURS[ctx.duration or 2] or 24
        local sellable = demand * hours / 24 * (tonumber(cfg.wallDurations) or 1)
        deep = (market.wallQty or 0) >= sellable
    else
        local share = tonumber(cfg.wallShare) or 0.3
        deep = market.totalQty > 0 and (market.wallQty or 0) >= market.totalQty * share
    end
    if deep then
        return others, "match", T("POSTING_REASON_MATCH_WALL", "deep wall at lowest: match")
    end
    return others - step, "undercut", T("POSTING_REASON_UNDERCUT_THIN", "thin lowest level: undercut one step")
end

local function Deposit(ctx, itemID, qty, duration)
    if not ctx.isCommodity and ctx.itemLocation and C_AuctionHouse and C_AuctionHouse.CalculateItemDeposit then
        local ok, dep = pcall(C_AuctionHouse.CalculateItemDeposit, ctx.itemLocation, duration, qty)
        if ok and type(dep) == "number" then return dep, false end
    end
    local econ = Econ()
    if econ and econ.EstimateDeposit then return econ:EstimateDeposit(itemID, qty, duration) end
    return nil, true
end

--- Full posting analysis for a sell context (or a bare itemID).
---@param ctx table|number { itemID, isCommodity?, itemLocation?, itemKey?, quantity?, duration? } or itemID
---@return table result {
---   itemID, isCommodity, strategy, mode ("match"|"undercut"|"own"|"average"|"max"|"history"|"floor"|"none"),
---   price, reason, hold (market below floor), marketLowest, ownLowest, wallQty, totalQty, demandPerDay,
---   floor, floorSource ("ledger"|"craft"|"vendor"|"history"), costBasis, costSource,
---   quantity, duration, deposit, depositEstimated, cutRate, gross, net, profit, depositLoss, avg, trend }
function PostingHelperService:Analyze(ctx)
    if type(ctx) == "number" then ctx = { itemID = ctx } end
    ctx = ctx or {}
    local itemID = ctx.itemID
    local cfg = Cfg()
    local res = { itemID = itemID, strategy = cfg.strategy or "undercut", mode = "none" }
    if not itemID then
        res.reason = T("POSTING_REASON_NO_ITEM", "no item")
        return res
    end
    if ctx.isCommodity == nil then
        -- ItemKeyInfo may be nil until ITEM_KEY_ITEM_INFO_RECEIVED; unknown reads the commodity book.
        local info
        if C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo and C_AuctionHouse.MakeItemKey then
            local okK, key = pcall(C_AuctionHouse.MakeItemKey, itemID)
            if okK and key then
                local okI, i = pcall(C_AuctionHouse.GetItemKeyInfo, key)
                if okI then info = i end
            end
        end
        ctx.isCommodity = not (type(info) == "table" and info.isCommodity == false)
    end
    res.isCommodity = ctx.isCommodity

    local econ = Econ()
    local qty = math.max(1, tonumber(ctx.quantity) or 1)
    local duration = tonumber(ctx.duration) or (econ and tonumber(econ:Config().postDuration)) or 2
    res.quantity, res.duration = qty, duration

    local market
    if ctx.isCommodity then
        market = ReadCommodityMarket(itemID)
    else
        market = ReadItemMarket(ctx.itemKey)
    end
    if market then
        res.marketLowest, res.ownLowest = market.othersLowest, market.ownLowest
        res.wallQty, res.totalQty = market.wallQty, market.totalQty
    end
    res.demandPerDay = DemandPerDay(itemID)

    local ph = ns.PriceHistoryService
    local hist = ph and ph:GetStats(itemID, WEEK_SEC)
    local avg = hist and hist.count and hist.count >= 2 and hist.avg or nil
    res.avg = avg
    res.trend = (avg and ph:GetTrend(itemID, WEEK_SEC)) or 0
    local avgTarget = avg and avg * (tonumber(cfg.averageMul) or 1) or nil

    local price, mode, reason
    local strategy = res.strategy
    if strategy == "average" and avgTarget then
        price, mode = avgTarget, "average"
        reason = string.format(T("POSTING_REASON_AVERAGE_FMT", "7d avg x %.2f"), tonumber(cfg.averageMul) or 1)
    else
        price, mode, reason = MarketTarget(ctx, market, cfg, itemID)
        if strategy == "max" and avgTarget and (not price or avgTarget > price) then
            price, mode, reason = avgTarget, "max", T("POSTING_REASON_MAX_AVG", "7d avg above market")
        end
        if not price and avgTarget then
            price, mode, reason = avgTarget, "history", T("POSTING_REASON_HISTORY", "no live listings: 7d avg")
        end
    end

    local floor, floorSource, basis, basisSource = ComputeFloor(itemID, avg, cfg)
    res.floor, res.floorSource = floor, floorSource
    res.costBasis, res.costSource = basis, basisSource

    if price then
        -- Live levels are already legal; computed targets (avg x mul) round down to the AH grid.
        price = Round(price, "down")
        if floor and price < floor then
            res.hold = true
            price = Round(floor, "up")
            mode = "floor"
            reason = T("POSTING_REASON_HOLD", "market below your floor: hold")
        end
    end
    res.price, res.mode, res.reason = price, mode, reason or T("POSTING_REASON_NO_DATA", "no data")

    local cut = CutRate()
    res.cutRate = cut
    local dep, estimated = Deposit(ctx, itemID, qty, duration)
    res.deposit, res.depositEstimated = dep, estimated
    if price then
        res.gross = price * qty
        res.net = math.floor(res.gross * (1 - cut) + 0.5)
        if basis then res.profit = res.net - math.floor(basis * qty + 0.5) end
    end
    if dep and dep > 0 and econ then
        local s = tonumber(econ:Config().sellThroughRate) or 0.7
        s = math.max(0.05, math.min(1, s))
        res.depositLoss = math.floor(dep * (1 / s - 1) + 0.5)
    end
    return res
end

--- Writes `price` into the visible Blizzard sell frame's unit price input. Hardware-click only
--- by convention (the panel's Apply button); the player still presses Blizzard's Post.
---@param price number copper per unit
---@return boolean ok
function PostingHelperService:ApplyPrice(price)
    price = tonumber(price)
    if not price or price <= 0 then return false end
    local ctx = self:GetSellContext()
    local input = ctx and ctx.frame and ctx.frame.PriceInput
    if not (input and input.SetAmount) then return false end
    local ok = pcall(input.SetAmount, input, Round(price, "down"))
    return ok
end

ns.PostingHelperService = PostingHelperService
