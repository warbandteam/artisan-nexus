--[[
    Artisan Nexus — Profitability Service.

    Computes per-recipe craft profit using RecipeService (reagent cost) and
    AHPriceService / PriceHistoryService (output value).
]]

local ADDON_NAME, ns = ...

local DEFAULT_FRESH_TTL_SEC = 6 * 60 * 60

local ProfitabilityService = {}

local function CatalogSpellIDs()
    local cat = ns.MidnightRecipeCatalog
    if type(cat) ~= "table" then return {} end
    local out = {}
    for _, data in pairs(cat) do
        if type(data) == "table" and type(data.recipes) == "table" then
            for spellID in pairs(data.recipes) do
                local n = tonumber(spellID)
                if n then
                    out[#out + 1] = n
                end
            end
        end
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

local function ConfidenceLevel(missingReagents, freshOutput, hasOperationInfo)
    if missingReagents and missingReagents > 0 then
        return "low"
    end
    if not freshOutput then
        return "medium"
    end
    if hasOperationInfo then
        return "high"
    end
    return "medium"
end

--- Resolve output unit price and quality tier via RecipeService + operation info when available.
---@param spellID number
---@param outputItem number|nil
---@param useAverage boolean|nil
---@param applyConcentration boolean|nil
---@return number|nil unitValue, number|nil qualityTier, number|nil pricedItemID, boolean fromHistory, number|nil concentrationCost
local function ResolveOutputPricing(spellID, outputItem, useAverage, applyConcentration)
    local rs = ns.RecipeService
    local tier
    local pricedItemID = outputItem
    local concentrationCost

    if rs and rs.GetCraftingOperation then
        local op = rs:GetCraftingOperation(spellID, applyConcentration == true)
        if op then
            tier = tonumber(op.craftingQuality) or tonumber(op.quality)
            concentrationCost = tonumber(op.concentrationCost)
            if rs.GetOutputItemID then
                pricedItemID = rs:GetOutputItemID(spellID, tier) or pricedItemID
            end
        end
    end

    if rs and rs.GetOutputItemID and not pricedItemID then
        pricedItemID = rs:GetOutputItemID(spellID, tier)
    end

    local unitValue, fromHistory = PriceForOutput(pricedItemID, useAverage)
    if not unitValue and pricedItemID ~= outputItem then
        unitValue, fromHistory = PriceForOutput(outputItem, useAverage)
        if unitValue then
            pricedItemID = outputItem
        end
    end

    return unitValue, tier, pricedItemID, fromHistory, concentrationCost
end

--- Compare base vs concentration crafting operation when profession window is open.
---@return number|nil marginWithConc, number|nil concDelta, boolean recommendConc
local function ResolveConcentrationMargin(spellID, outputItem, cost, outputCount, useAverage)
    local rs = ns.RecipeService
    if not rs or not rs.GetCraftingOperation or not cost then
        return nil, nil, false
    end
    local baseUnit, _, baseItemID = ResolveOutputPricing(spellID, outputItem, useAverage, false)
    local concUnit, concTier, concItemID, _, concCost = ResolveOutputPricing(spellID, outputItem, useAverage, true)
    if not concUnit or not baseUnit then
        return nil, nil, false
    end
    local baseValue = baseUnit * outputCount
    local concValue = concUnit * outputCount
    local marginWithConc = concValue - cost
    local marginBase = baseValue - cost
    local concDelta = marginWithConc - marginBase
    local recommend = false
    if concDelta and concDelta > 0 and (concCost or 0) > 0 then
        recommend = concDelta >= math.max(500, marginBase * 0.05)
    elseif concTier and baseItemID and concItemID and concItemID ~= baseItemID and concDelta and concDelta > 0 then
        recommend = true
    end
    return marginWithConc, concDelta, recommend
end

---@param opts table|nil
function ProfitabilityService:ListRecipes(opts)
    opts = opts or {}
    local rs = ns.RecipeService
    if not rs then return {} end
    local ttl = (ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.profile and ns.ArtisanNexus.db.profile.ahFreshTTL) or DEFAULT_FRESH_TTL_SEC

    local ownedSet
    if opts.ownedProfessionsOnly and rs.GetOwnedCraftProfessions then
        ownedSet = {}
        local owned = rs:GetOwnedCraftProfessions()
        for i = 1, #owned do
            ownedSet[owned[i]] = true
        end
    end

    local rows = {}
    local harvestedOnly = opts.harvestedOnly ~= false
    for _, spellID in ipairs(CatalogSpellIDs()) do
        local profession = rs:GetProfession(spellID)
        if opts.profession and profession ~= opts.profession then
            -- profession filter
        elseif ownedSet and profession and not ownedSet[profession] then
            -- owned craft professions only
        else
            local skip = false
            if harvestedOnly then
                local sch = rs:GetSchematic(spellID)
                if not sch or not sch.reagents or #sch.reagents < 1 then
                    skip = true
                elseif sch.learned == false then
                    skip = true
                end
            end
            if not skip then
                local outputItem = rs:GetOutputItem(spellID)
                local cost, missingReagents = rs:EstimateReagentCost(spellID)
                local unitValue, qualityTier, pricedItemID, fromHistory, concentrationCost =
                    ResolveOutputPricing(spellID, outputItem, opts.useAverage, false)
                local outputCount = (rs.GetOutputQuantity and rs:GetOutputQuantity(spellID)) or 1
                local value = unitValue and (unitValue * outputCount) or nil
                local margin = (value and cost) and (value - cost) or nil
                local marginPct = (margin and cost and cost > 0) and (margin / cost * 100) or nil
                local marginWithConc, concProfitDelta, recommendConcentration
                if opts.compareConcentration ~= false then
                    marginWithConc, concProfitDelta, recommendConcentration =
                        ResolveConcentrationMargin(spellID, outputItem, cost, outputCount, opts.useAverage)
                end
                local fresh = pricedItemID and IsFresh(pricedItemID, ttl)
                    or (outputItem and IsFresh(outputItem, ttl))
                    or false
                local sch = rs:GetSchematic(spellID)
                local hasOperationInfo = sch and sch.hasCraftingOperationInfo == true

                local include = true
                if opts.freshOnly and not fresh then include = false end
                if opts.minMargin and (not margin or margin < opts.minMargin) then include = false end

                if include then
                    rows[#rows + 1] = {
                        spellID = spellID,
                        name = rs:GetRecipeName(spellID) or (sch and sch.name) or ("Recipe " .. tostring(spellID)),
                        profession = profession,
                        outputItem = pricedItemID or outputItem,
                        cost = cost,
                        unitValue = unitValue,
                        value = value,
                        margin = margin,
                        marginPct = marginPct,
                        missingReagentPrices = missingReagents or 0,
                        hasHistory = fromHistory,
                        fresh = fresh,
                        qualityTier = qualityTier,
                        concentrationCost = concentrationCost,
                        marginWithConc = marginWithConc,
                        concProfitDelta = concProfitDelta,
                        recommendConcentration = recommendConcentration,
                        confidence = ConfidenceLevel(missingReagents, fresh, hasOperationInfo),
                    }
                end
            end
        end
    end

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
