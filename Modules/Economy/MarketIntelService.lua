--[[
    Artisan Nexus — Market intelligence.
    Recomputed (coalesced, chunked) after each AH scan from db.global.ahPrices and the
    PriceHistoryService samples { t, p, q?, qs? } (p = min unit price, q = listed quantity, qs = its source):
      - movers: latest sample vs mean of the other samples in the last 7 days, with the
        Saddlebag market states (Spiking > +60%, Increasing +15..60, Stable within 15,
        Decreasing -15..-60, Crashing < -60) — Saddlebag Exchange market-state thresholds (read 2026-10-14).
      - deals: current min <= dealRatio x 7-day mean with listed quantity > 0 (fresh rows only).
      - demand: ESTIMATE of units/day = listed-quantity decreases between consecutive samples of
        one source, at most 24h apart and inside the last 7 days, over the observed time of ALL
        such pairs (a restock interval contributes no units but still counts as time). Sales
        during a restock interval are unknowable, so this is a LOWER bound on sales; listings can
        also vanish by cancel/expiry, which pushes the other way.
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
    if type(store) ~= "table" or not itemID then return nil end
    -- Tolerate either key shape, as Economy:GetMarketRow does for ahPrices.
    local row = store[itemID] or store[tonumber(itemID)] or store[tostring(itemID)]
    return (type(row) == "table" and type(row.samples) == "table") and row.samples or nil
end

--- Demand estimate from one sample array (ascending by t).
---
--- Only pairs inside WEEK_SEC count. PriceHistoryService caps its ring buffer by sample COUNT, not
--- by age, so the array can reach back months; an item that stopped moving a month ago used to
--- keep reporting its old velocity, and with "high" confidence, since that was awarded for pair
--- count, which a long stale history has no shortage of.
---
--- The denominator is every same-source pair in the window, including the ones where the listed
--- quantity ROSE. Summing only the falling intervals measured "depletion rate while depleting",
--- which overstates throughput for anything restocked often. A restock interval contributes 0 to
--- `drop` while its real sales are unknowable, so the result is now a LOWER bound on units/day
--- (it was an upper bound before).
---@param samples table[]
---@param now number|nil unix time (defaults to time())
---@return number|nil unitsPerDay, string|nil confidence, number pairs
local function EstimateDemand(samples, now)
    if not samples or #samples < MIN_SAMPLES then
        return nil, nil, 0
    end
    local cutoff = (now or time()) - WEEK_SEC
    -- The admission gate counts one source at a time: browse totals (own listings included) and
    -- commodity book totals (own excluded) are different scales and never pair with each other,
    -- so a mixed history used to pass the gate and then yield no usable pairs at all.
    local withQty = {}
    for i = 1, #samples do
        local s = samples[i]
        if tonumber(s.q) and (tonumber(s.t) or 0) >= cutoff then
            local src = s.qs or "?"
            withQty[src] = (withQty[src] or 0) + 1
        end
    end
    local bestSource = 0
    for _, n in pairs(withQty) do
        if n > bestSource then bestSource = n end
    end
    if bestSource < MIN_SAMPLES then
        return nil, nil, 0
    end
    local drop, span, pairsUsed = 0, 0, 0
    for i = 2, #samples do
        local a, b = samples[i - 1], samples[i]
        local qa, qb = tonumber(a.q), tonumber(b.q)
        local ta, tb = tonumber(a.t) or 0, tonumber(b.t) or 0
        local dt = tb - ta
        -- Samples of older builds carry no source and pair only with each other.
        if qa and qb and a.qs == b.qs and dt > 0 and dt <= DAY_SEC and ta >= cutoff then
            span = span + dt
            pairsUsed = pairsUsed + 1
            if qb <= qa then
                drop = drop + (qa - qb)
            end
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
            -- The raw key indexes `store`; it is normalised where it is written to `_demand`.
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
                local perDay, conf = EstimateDemand(samples, now)
                -- Key _demand numerically whatever the history key was, so GetDemandEstimate's
                -- numeric lookup always matches.
                local key = tonumber(itemID)
                if perDay and key then
                    demand[key] = { unitsPerDay = perDay, confidence = conf }
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
    -- Normalise the key: the recompute stores whatever pairs(ahPriceHistory) yields, so a caller
    -- passing a string used to get nil (Economy:GetMarketRow defends against the same thing).
    itemID = tonumber(itemID)
    if not itemID then
        return nil, nil
    end
    local d = self._demand[itemID]
    if d then
        return d.unitsPerDay, d.confidence
    end
    -- No row: fall through to a direct read. This used to be refused once any recompute had run,
    -- which left every item whose history appeared afterwards reporting no demand until the next
    -- AH scan completed.
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
