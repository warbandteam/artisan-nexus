--[[
    Artisan Nexus — Market intelligence.
    Recomputed (coalesced, chunked) after each AH scan from db.global.ahPrices and the
    PriceHistoryService samples { t, p, q?, qs? } (p = min unit price, q = listed quantity, qs = its source):
      - movers: latest sample vs mean of the other samples in the last 7 days, with the
        Saddlebag market states (Spiking > +60%, Increasing +15..60, Stable within 15,
        Decreasing -15..-60, Crashing < -60) — Saddlebag Exchange market-state thresholds (read 2026-10-14).
      - deals: current min <= dealRatio x 7-day mean with listed quantity > 0 (fresh rows only).
      - demand: ESTIMATE of units/day = listed-quantity decreases between consecutive samples
        at most 24h apart (pairs where quantity rose are ignored), normalized to a day.
        Listings can also vanish by cancel/expiry, so this is an upper bound on sales.
      - weekday profile: mean price per weekday over all samples.
    Only items with >= 3 samples are considered.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS

local MarketIntelService = {
    _movers = {},
    _deals = {},
    _demand = {},
    _computedAt = nil,
    _pending = false,
    _token = 0,
}

local WEEK_SEC = 7 * 24 * 3600
local DAY_SEC = 24 * 3600
local MIN_SAMPLES = 3
local ITEMS_PER_FRAME = 150
local COALESCE_SEC = 1.5
--- Rows older than this are not offered as deals (a stale min is not buyable).
local DEAL_FRESH_SEC = 24 * 3600
local DEFAULT_DEAL_RATIO = 0.7
local MAX_MOVERS = 200
local MAX_DEALS = 200

local STATE_LABELS = {
    spiking = { "MARKET_STATE_SPIKING", "Spiking" },
    increasing = { "MARKET_STATE_INCREASING", "Increasing" },
    stable = { "MARKET_STATE_STABLE", "Stable" },
    decreasing = { "MARKET_STATE_DECREASING", "Decreasing" },
    crashing = { "MARKET_STATE_CRASHING", "Crashing" },
}

--- Saddlebag market state for a % change (bounds: +60 / +15 / -15 / -60).
local function StateFor(pct)
    if pct > 60 then
        return "spiking"
    elseif pct > 15 then
        return "increasing"
    elseif pct >= -15 then
        return "stable"
    elseif pct >= -60 then
        return "decreasing"
    end
    return "crashing"
end

local function HistoryStore()
    local g = ns.db and ns.db.global
    return g and g.ahPriceHistory
end

local function Samples(itemID)
    local store = HistoryStore()
    local row = store and store[itemID]
    return (type(row) == "table" and type(row.samples) == "table") and row.samples or nil
end

--- Demand estimate from one sample array (ascending by t).
---@return number|nil unitsPerDay, string|nil confidence, number pairs
local function EstimateDemand(samples)
    if not samples or #samples < MIN_SAMPLES then
        return nil, nil, 0
    end
    local drop, span, pairsUsed, withQty = 0, 0, 0, 0
    for i = 1, #samples do
        if tonumber(samples[i].q) then
            withQty = withQty + 1
        end
    end
    if withQty < MIN_SAMPLES then
        return nil, nil, 0
    end
    for i = 2, #samples do
        local a, b = samples[i - 1], samples[i]
        local qa, qb = tonumber(a.q), tonumber(b.q)
        local dt = (tonumber(b.t) or 0) - (tonumber(a.t) or 0)
        -- Only diff quantities of one source (browse total vs commodity book are different scales);
        -- samples of older builds carry no source and pair only with each other.
        if qa and qb and a.qs == b.qs and dt > 0 and dt <= DAY_SEC and qb <= qa then
            drop = drop + (qa - qb)
            span = span + dt
            pairsUsed = pairsUsed + 1
        end
    end
    if pairsUsed < 2 or span <= 0 then
        return nil, nil, pairsUsed
    end
    local perDay = drop / span * DAY_SEC
    local confidence = "low"
    if pairsUsed >= 10 and span >= DAY_SEC then
        confidence = "high"
    elseif pairsUsed >= 4 then
        confidence = "medium"
    end
    return perDay, confidence, pairsUsed
end

--- Mover / deal analysis for one item; nil when not enough recent data.
local function AnalyzeItem(itemID, samples, now, dealRatio)
    local cutoff = now - WEEK_SEC
    local n, sum = 0, 0
    local latest
    for i = 1, #samples do
        local s = samples[i]
        local p = tonumber(s.p)
        if p and p > 0 and (tonumber(s.t) or 0) >= cutoff then
            n = n + 1
            sum = sum + p
            if not latest or (s.t or 0) >= (latest.t or 0) then
                latest = s
            end
        end
    end
    if n < MIN_SAMPLES or not latest then
        return nil, nil
    end
    --- Baseline excludes the latest sample so a spike does not dampen itself.
    local mean = (sum - latest.p) / (n - 1)
    if mean <= 0 then
        return nil, nil
    end
    local pct = (latest.p - mean) / mean * 100
    local mover = {
        itemID = itemID,
        latest = latest.p,
        mean7d = math.floor(mean + 0.5),
        pct = pct,
        state = StateFor(pct),
        samples = n,
        at = latest.t,
    }
    local deal
    local row = ns.Economy and ns.Economy.GetMarketRow and ns.Economy:GetMarketRow(itemID)
    if type(row) == "table" then
        local cur = tonumber(row.buyout)
        local qty = tonumber(row.qty) or tonumber(latest.q)
        local fresh = (tonumber(row.updatedAt) or 0) >= now - DEAL_FRESH_SEC
        if cur and cur > 0 and qty and qty > 0 and fresh and cur <= mean * dealRatio then
            deal = {
                itemID = itemID,
                price = cur,
                mean7d = math.floor(mean + 0.5),
                ratio = cur / mean,
                qty = qty,
                discount = math.floor(mean - cur + 0.5),
                at = row.updatedAt,
            }
        end
    end
    return mover, deal
end

--- Chunked recompute over every item with history.
function MarketIntelService:Recompute()
    local store = HistoryStore()
    if type(store) ~= "table" then
        return
    end
    self._token = self._token + 1
    local token = self._token
    local ids = {}
    for itemID, row in pairs(store) do
        if type(row) == "table" and type(row.samples) == "table" and #row.samples >= MIN_SAMPLES then
            ids[#ids + 1] = itemID
        end
    end
    local cfg = ns.Economy and ns.Economy.Config and ns.Economy:Config()
    local dealRatio = tonumber(cfg and cfg.dealRatio) or DEFAULT_DEAL_RATIO
    dealRatio = math.max(0.05, math.min(0.99, dealRatio))
    local movers, deals, demand = {}, {}, {}
    local idx = 1
    local function step()
        if token ~= MarketIntelService._token or not MarketIntelService._enabled then
            return
        end
        local now = time()
        local stop = math.min(#ids, idx + ITEMS_PER_FRAME - 1)
        for i = idx, stop do
            local itemID = ids[i]
            local samples = store[itemID] and store[itemID].samples
            if samples then
                local mover, deal = AnalyzeItem(itemID, samples, now, dealRatio)
                -- "Movers" means outside the stable band (Saddlebag-style +/-15%).
                if mover and mover.state ~= "stable" then
                    movers[#movers + 1] = mover
                end
                if deal then
                    deals[#deals + 1] = deal
                end
                local perDay, conf = EstimateDemand(samples)
                if perDay then
                    demand[itemID] = { unitsPerDay = perDay, confidence = conf }
                end
            end
        end
        idx = stop + 1
        if idx <= #ids then
            C_Timer.After(0, step)
            return
        end
        table.sort(movers, function(a, b) return math.abs(a.pct) > math.abs(b.pct) end)
        for i = #movers, MAX_MOVERS + 1, -1 do
            movers[i] = nil
        end
        table.sort(deals, function(a, b) return a.ratio < b.ratio end)
        for i = #deals, MAX_DEALS + 1, -1 do
            deals[i] = nil
        end
        MarketIntelService._movers = movers
        MarketIntelService._deals = deals
        MarketIntelService._demand = demand
        MarketIntelService._computedAt = now
        ns.ArtisanNexus:SendMessage(E.MARKET_INTEL_UPDATED, { movers = #movers, deals = #deals })
    end
    step()
end

function MarketIntelService:ScheduleRecompute()
    if self._pending or not self._enabled then
        return
    end
    self._pending = true
    C_Timer.After(COALESCE_SEC, function()
        MarketIntelService._pending = false
        if MarketIntelService._enabled then
            MarketIntelService:Recompute()
        end
    end)
end

local function Slice(list, limit)
    limit = tonumber(limit)
    if not limit or limit >= #list then
        return list
    end
    local out = {}
    for i = 1, math.max(0, limit) do
        out[i] = list[i]
    end
    return out
end

--- Biggest price moves (by |pct|).
---@param limit number|nil
---@return table[] { itemID, latest, mean7d, pct, state, samples, at }
function MarketIntelService:GetMovers(limit)
    if not self._computedAt then
        self:ScheduleRecompute()
    end
    return Slice(self._movers, limit)
end

--- Current listings far below their 7-day mean (cheapest ratio first).
---@param limit number|nil
---@return table[] { itemID, price, mean7d, ratio, qty, discount, at }
function MarketIntelService:GetDeals(limit)
    if not self._computedAt then
        self:ScheduleRecompute()
    end
    return Slice(self._deals, limit)
end

--- ESTIMATED units/day leaving the market (see header). Falls back to a direct read when the
--- last recompute has not seen the item.
---@param itemID number
---@return number|nil unitsPerDay, string|nil confidence "low"|"medium"|"high"
function MarketIntelService:GetDemandEstimate(itemID)
    if not itemID then
        return nil, nil
    end
    local d = self._demand[itemID]
    if d then
        return d.unitsPerDay, d.confidence
    end
    if self._computedAt then
        return nil, nil
    end
    local perDay, conf = EstimateDemand(Samples(itemID))
    return perDay, conf
end

--- Localized label for a mover state key.
---@param state string
---@return string
function MarketIntelService:GetStateLabel(state)
    local def = STATE_LABELS[state]
    if not def then
        return tostring(state)
    end
    local loc = ns.L
    local v = loc and loc[def[1]]
    if type(v) == "string" and v ~= "" then
        return v
    end
    return def[2]
end

---@return number|nil unix time of the last finished recompute
function MarketIntelService:GetComputedAt()
    return self._computedAt
end

function MarketIntelService:Enable()
    if self._enabled then
        return
    end
    self._enabled = true
    local owner = self._eventOwner or ns.NewEventOwner("MarketIntelService")
    self._eventOwner = owner
    if E and E.AH_SCAN_COMPLETE then
        owner:RegisterMessage(E.AH_SCAN_COMPLETE, function()
            MarketIntelService:ScheduleRecompute()
        end)
    end
    if E and E.ECONOMY_CONFIG_CHANGED then
        owner:RegisterMessage(E.ECONOMY_CONFIG_CHANGED, function(_, key)
            if key == nil or key == "dealRatio" then
                MarketIntelService:ScheduleRecompute()
            end
        end)
    end
    --- Login: serve stored history without waiting for the next scan.
    C_Timer.After(6, function()
        if MarketIntelService._enabled and not MarketIntelService._computedAt then
            MarketIntelService:Recompute()
        end
    end)
end

function MarketIntelService:Disable()
    if not self._enabled then
        return
    end
    self._enabled = false
    self._token = self._token + 1
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
        self._eventOwner:UnregisterAllMessages()
    end
end

ns.MarketIntelService = MarketIntelService
