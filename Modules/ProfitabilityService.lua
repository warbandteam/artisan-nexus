--[[
    Artisan Nexus — Profitability Service.

    Computes per-recipe craft profit using the existing RecipeService
    (reagent cost) and AHPriceService / PriceHistoryService (output value).

    Two output sources:
      * latest AH unit price (AHPriceService:GetPrice)
      * 7-day rolling average (PriceHistoryService:GetStats) — preferred
        when the user wants to ignore one-off undercuts; falls back to
        latest when no history exists.

    A single function is the public surface:
      ProfitabilityService:ListRecipes(opts)
        opts = { profession?, useAverage?, minMargin?, freshOnly? }
        returns array of { spellID, name, profession, output, cost,
                            unitValue, value, margin, marginPct,
                            missingReagentPrices, hasHistory, fresh }
        sorted descending by margin, with unprofitable / incomplete
        rows last so the user can scan to "what should I be crafting".
]]

local ADDON_NAME, ns = ...

local DEFAULT_FRESH_TTL_SEC = 6 * 60 * 60

local ProfitabilityService = {}

local function CatalogSpellIDs()
    local cat = ns.MidnightRecipeCatalog
    if type(cat) ~= "table" then return {} end
    local out = {}
    for spellID in pairs(cat) do
        out[#out + 1] = spellID
    end
    return out
end

local function PriceForOutput(itemID, useAverage)
    if not itemID then return nil, false end
    if useAverage and ns.PriceHistoryService and ns.PriceHistoryService.GetStats then
        local s = ns.PriceHistoryService:GetStats(itemID)
        if s and s.count and s.count >= 2 and s.avg then
            return s.avg, true
        end
    end
    if ns.AHPriceService and ns.AHPriceService.GetPrice then
        return ns.AHPriceService:GetPrice(itemID), false
    end
    return nil, false
end

local function IsFresh(itemID, ttl)
    local db = ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.global and ns.ArtisanNexus.db.global.ahPrices
    if type(db) ~= "table" then return false end
    local row = db[itemID]
    if not row or not row.updatedAt then return false end
    return (time() - row.updatedAt) < ttl
end

---@param opts table|nil
function ProfitabilityService:ListRecipes(opts)
    opts = opts or {}
    local rs = ns.RecipeService
    if not rs then return {} end
    local ttl = (ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.profile and ns.ArtisanNexus.db.profile.ahFreshTTL) or DEFAULT_FRESH_TTL_SEC

    local rows = {}
    for _, spellID in ipairs(CatalogSpellIDs()) do
        local profession = rs:GetProfession(spellID)
        if not opts.profession or profession == opts.profession then
            local outputItem = rs:GetOutputItem(spellID)
            local cost, missingReagents = rs:EstimateReagentCost(spellID)
            local unitValue, fromHistory = PriceForOutput(outputItem, opts.useAverage)
            local outputCount = 1  -- recipe schematic doesn't track multi-output reliably; assume 1
            local value = unitValue and (unitValue * outputCount) or nil
            local margin = (value and cost) and (value - cost) or nil
            local marginPct = (margin and cost and cost > 0) and (margin / cost * 100) or nil
            local fresh = outputItem and IsFresh(outputItem, ttl) or false

            local include = true
            if opts.freshOnly and not fresh then include = false end
            if opts.minMargin and (not margin or margin < opts.minMargin) then include = false end

            if include then
                rows[#rows + 1] = {
                    spellID = spellID,
                    name = rs:GetRecipeName(spellID),
                    profession = profession,
                    outputItem = outputItem,
                    cost = cost,
                    unitValue = unitValue,
                    value = value,
                    margin = margin,
                    marginPct = marginPct,
                    missingReagentPrices = missingReagents or 0,
                    hasHistory = fromHistory,
                    fresh = fresh,
                }
            end
        end
    end

    -- Sort: profitable (margin>0) first by margin desc; then break-even; then losses;
    -- recipes with no price data go last.
    table.sort(rows, function(a, b)
        local am = a.margin
        local bm = b.margin
        if am and not bm then return true end
        if bm and not am then return false end
        if am and bm and am ~= bm then return am > bm end
        return (a.name or "") < (b.name or "")
    end)
    return rows
end

--- Convenience: top-N most profitable recipes for a profession.
function ProfitabilityService:Top(profession, n)
    local list = self:ListRecipes({ profession = profession, useAverage = true })
    n = n or 10
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

ns.ProfitabilityService = ProfitabilityService
