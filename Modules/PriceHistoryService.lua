--[[
    Artisan Nexus — Price History Service.

    Extends AHPriceService.SavePrice with a rolling per-item timeseries so
    other modules (Profitability, Posting Helper, charts) can read recent
    average / min / max instead of just the latest snapshot.

    Storage shape (ArtisanNexusDB.global.ahPriceHistory):
      [itemID] = {
        samples = { { t = unix, p = copperPerUnit }, ... },  -- ordered ascending
      }

    Cap per item: HISTORY_MAX_SAMPLES (default 96 ≈ 4 days at 1h cadence).
]]

local ADDON_NAME, ns = ...

local HISTORY_MAX_SAMPLES = 96
local DEDUP_WINDOW_SEC    = 5 * 60   -- merge samples within 5min into the latest

local PriceHistoryService = {}

local function Store()
    local db = ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.global
    if not db then return nil end
    if type(db.ahPriceHistory) ~= "table" then db.ahPriceHistory = {} end
    return db.ahPriceHistory
end

--- Append a sample. Called from AHPriceService.SavePrice automatically when
--- this service is loaded; safe to call manually.
---@param itemID number
---@param unitPrice number copper-per-unit
function PriceHistoryService:Push(itemID, unitPrice)
    if not itemID or type(unitPrice) ~= "number" or unitPrice <= 0 then return end
    local store = Store()
    if not store then return end
    local row = store[itemID]
    if not row then
        row = { samples = {} }
        store[itemID] = row
    end
    local samples = row.samples
    local now = time()
    local last = samples[#samples]
    if last and (now - (last.t or 0)) < DEDUP_WINDOW_SEC then
        -- Same window: keep the latest price (overwrite).
        last.t = now
        last.p = unitPrice
    else
        samples[#samples + 1] = { t = now, p = unitPrice }
    end
    while #samples > HISTORY_MAX_SAMPLES do
        table.remove(samples, 1)
    end
end

--- Return the raw sample array for an item (read-only).
---@param itemID number
---@return table[] samples (may be empty)
function PriceHistoryService:GetSamples(itemID)
    local store = Store()
    if not store then return {} end
    local row = store[itemID]
    return (row and row.samples) or {}
end

--- Aggregate stats over a recent window. windowSec defaults to 7 days.
---@param itemID number
---@param windowSec number|nil
---@return table { count, min, max, avg, latest, oldest }
function PriceHistoryService:GetStats(itemID, windowSec)
    windowSec = windowSec or (7 * 24 * 3600)
    local samples = self:GetSamples(itemID)
    local cutoff = time() - windowSec
    local n, sum, mn, mx = 0, 0, nil, nil
    local latest, oldest
    for i = 1, #samples do
        local s = samples[i]
        if s.t and s.t >= cutoff and type(s.p) == "number" and s.p > 0 then
            n = n + 1
            sum = sum + s.p
            if not mn or s.p < mn then mn = s.p end
            if not mx or s.p > mx then mx = s.p end
            if not oldest or s.t < oldest.t then oldest = s end
            if not latest or s.t > latest.t then latest = s end
        end
    end
    if n == 0 then
        return { count = 0 }
    end
    return {
        count  = n,
        min    = mn,
        max    = mx,
        avg    = math.floor(sum / n + 0.5),
        latest = latest and latest.p or nil,
        oldest = oldest and oldest.p or nil,
        firstAt = oldest and oldest.t or nil,
        lastAt  = latest and latest.t or nil,
    }
end

--- Trend direction over the window: -1 falling, 0 flat, +1 rising. Uses simple
--- first-vs-last comparison with a small dead band so noise doesn't flip it.
---@param itemID number
---@param windowSec number|nil
---@return integer direction, number percentChange
function PriceHistoryService:GetTrend(itemID, windowSec)
    local s = self:GetStats(itemID, windowSec)
    if s.count < 2 or not s.oldest or not s.latest or s.oldest <= 0 then
        return 0, 0
    end
    local pct = ((s.latest - s.oldest) / s.oldest) * 100
    if pct > 3 then return 1, pct
    elseif pct < -3 then return -1, pct
    else return 0, pct end
end

ns.PriceHistoryService = PriceHistoryService
