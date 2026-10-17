--[[
    Artisan Nexus — Profitability Service.

    Per-recipe craft profit rows for the Hub / briefing. Values come from CraftEVService
    (expected value net of AH cut, deposit loss and crafting-stat procs); this file only
    filters recipes and maps the EV result onto the row shape the UI consumes.
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

local function IsFresh(itemID, ttl)
    if ns.AHPriceService and ns.AHPriceService.GetPriceInfo then
        -- Honour the caller's ttl; GetPriceInfo's own isFresh uses profile.ahFreshTTL.
        local _, updatedAt = ns.AHPriceService:GetPriceInfo(itemID)
        return updatedAt ~= nil and (time() - updatedAt) < ttl
    end
    local db = ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.global and ns.ArtisanNexus.db.global.ahPrices
    if type(db) ~= "table" then return false end
    local row = db[itemID]
    if not row or not row.updatedAt then return false end
    return (time() - row.updatedAt) < ttl
end

local function Round(c)
    if not c then return nil end
    return math.floor(c + 0.5)
end

local function CountKeys(t)
    local n = 0
    if type(t) == "table" then
        for _ in pairs(t) do n = n + 1 end
    end
    return n
end

--- Learned filter (ns.CharacterData: Warband Nexus crafters or AN-native learnedBy). knownBy "me" =
--- current character, "any" = any tracked character; nil keeps the legacy rule (skip only rows
--- explicitly marked unlearned).
local function PassesKnownBy(sch, spellID, knownBy)
    if not sch then return knownBy == nil end
    local cd = ns.CharacterData
    if cd:IsKnownByAny(spellID) == false then return false end
    if knownBy == "me" then
        -- nil = no per-character data yet (row harvested before learnedBy existed): keep it.
        return cd:IsKnownByMe(spellID) ~= false
    end
    return true
end

--- Should concentration be spent on this recipe? Uses the concentration opportunity value when
--- known (gpc must beat it), else the legacy heuristic (delta >= max(5s, 5% of base margin)).
local function RecommendConcentration(concRow, baseRow, concValue, profession, spellID)
    if not concRow or not baseRow or not concRow.profit or not baseRow.profit then return false end
    local delta = concRow.profit - baseRow.profit
    if delta <= 0 then return false end
    -- The planner's own allocation is the recommendation; the shadow price is the gpc of its
    -- marginal funded recipe, so comparing a funded recipe to it would always reject it.
    local planner = ns.ConcentrationPlannerService
    if planner and planner.IsFunded and planner:IsFunded(profession, spellID) then
        return true
    end
    if concValue and concValue > 0 and concRow.gpc then
        return concRow.gpc > concValue
    end
    if (concRow.concCost or 0) > 0 then
        return delta >= math.max(500, baseRow.profit * 0.05)
    end
    return concRow.outputItem ~= baseRow.outputItem
end

---@param opts table|nil { profession?, ownedProfessionsOnly?, harvestedOnly? (default true), knownBy? ("me"|"any"),
---   useAverage?, useOwned?, compareConcentration? (default true), freshOnly?, minMargin?, sortBy? }
---@return table[] rows (Hub / briefing shape; money in copper, net of AH cut and expected deposit loss)
function ProfitabilityService:ListRecipes(opts)
    opts = opts or {}
    local rs = ns.RecipeService
    if not rs then return {} end
    local ev = ns.CraftEVService
    local econ = ns.Economy
    local ttl = (ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.profile and ns.ArtisanNexus.db.profile.ahFreshTTL) or DEFAULT_FRESH_TTL_SEC

    local ownedSet
    if opts.ownedProfessionsOnly and rs.GetOwnedCraftProfessions then
        ownedSet = {}
        local owned = rs:GetOwnedCraftProfessions()
        for i = 1, #owned do
            ownedSet[owned[i]] = true
        end
    end

    local cutRate = econ and econ:CutRate() or nil
    local rows = {}
    local harvestedOnly = opts.harvestedOnly ~= false
    local compareConc = opts.compareConcentration ~= false
    for _, spellID in ipairs(CatalogSpellIDs()) do
        local profession = rs:GetProfession(spellID)
        local sch = rs:GetSchematic(spellID)
        local hasReagents = sch and type(sch.reagents) == "table" and #sch.reagents > 0
        local skip = false
        if opts.profession and profession ~= opts.profession then
            skip = true
        elseif ownedSet and profession and not ownedSet[profession] then
            skip = true
        elseif harvestedOnly and not hasReagents then
            skip = true
        elseif (harvestedOnly or opts.knownBy) and not PassesKnownBy(sch, spellID, opts.knownBy) then
            skip = true
        end
        if not skip then
            local result = ev and hasReagents and ev:Evaluate(spellID, {
                useAverage = opts.useAverage,
                useOwned = opts.useOwned,
                knownBy = opts.knownBy,
            }) or nil
            local base = result and result.bestNoConc
            local concRow = compareConc and result and result.bestConc or nil
            local outputItem = (base and base.outputItem) or rs:GetOutputItem(spellID)
            local cost = base and Round(base.reagentCost)
            local value = base and Round(base.revenueNet)
            local margin = base and Round(base.profit)
            local marginPct = (margin and cost and cost > 0) and (margin / cost * 100) or nil
            local concValue = econ and econ:ConcentrationValue(profession) or 0
            local marginWithConc, concProfitDelta, goldPerConcentration
            if concRow and concRow.profit then
                marginWithConc = Round(concRow.profit)
                if base and base.profit then
                    concProfitDelta = Round(concRow.profit - base.profit)
                end
                if concRow.gpc and concRow.gpc > 0 then
                    goldPerConcentration = math.floor(concRow.gpc)
                end
            end
            local fresh = (outputItem and IsFresh(outputItem, ttl)) or false
            local missingCount = result and #result.missing or 0
            local depositLoss
            if base and base.outputItem and econ then
                depositLoss = Round(econ:ExpectedDepositLossPerUnit(base.outputItem) * (base.yield or 1))
            end

            local include = true
            if opts.freshOnly and not fresh then include = false end
            if opts.minMargin and (not margin or margin < opts.minMargin) then include = false end

            if include then
                rows[#rows + 1] = {
                    spellID = spellID,
                    name = rs:GetRecipeName(spellID) or (sch and sch.name) or ("Recipe " .. tostring(spellID)),
                    profession = profession,
                    outputItem = outputItem,
                    cost = cost,
                    unitValue = base and base.unitPrice or nil,
                    value = value,
                    margin = margin,
                    marginPct = marginPct,
                    missingReagentPrices = missingCount,
                    -- Soulbound reagents with no buy or make cost: not in `cost`, listed for the UI.
                    boundReagents = result and result.boundReagents or nil,
                    missing = result and result.missing or {},
                    hasHistory = base and base.fromHistory or false,
                    fresh = fresh,
                    qualityTier = base and base.tier or nil,
                    concentrationCost = concRow and concRow.concCost or nil,
                    effectiveConcentration = concRow and concRow.effConc or nil,
                    marginWithConc = marginWithConc,
                    concProfitDelta = concProfitDelta,
                    goldPerConcentration = goldPerConcentration,
                    concQualityTier = concRow and concRow.tier or nil,
                    concOutputItem = concRow and concRow.outputItem or nil,
                    recommendConcentration = compareConc and RecommendConcentration(concRow, base, concValue, profession, spellID) or false,
                    confidence = result and result.confidence or "low",
                    -- EV engine extras
                    evYield = base and base.yield or nil,
                    cutRate = cutRate,
                    depositLoss = depositLoss,
                    factorsSource = result and result.factorsSource or nil,
                    basis = result and result.basis or nil,
                    makeReagents = base and base.makeReagents or nil,
                    makeReagentCount = base and CountKeys(base.makeReagents) or 0,
                    knownByMe = ns.CharacterData:IsKnownByMe(spellID),
                    knownByCount = ns.CharacterData:GetKnownByCount(spellID),
                }
            end
        end
    end

    table.sort(rows, function(a, b)
        if opts.sortBy == "concentration" or opts.sortBy == "gpc" then
            local ag = a.goldPerConcentration
            local bg = b.goldPerConcentration
            if ag and not bg then return true end
            if bg and not ag then return false end
            if ag and bg and ag ~= bg then return ag > bg end
        elseif opts.sortBy == "marginPct" then
            local ap = a.marginPct
            local bp = b.marginPct
            if ap and not bp then return true end
            if bp and not ap then return false end
            if ap and bp and ap ~= bp then return ap > bp end
        end
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
