--[[
    Artisan Nexus — Concentration planner.
    AN-native view of every tracked character x profession concentration pool (Warband Nexus
    optional), a greedy demand-capped spend plan per profession, and the marginal gold per
    concentration point of that plan (shadow price, read by ns.Economy:ConcentrationValue).

    Sources:
      - ns.CharacterData:GetConcentrationPools() (Modules/Data/CharacterDataProvider.lua): live current
        character + Warband Nexus or AN-native alt snapshots.
      - ns.CraftEVService:Evaluate(spellID, opts) (other engineer; guarded) for gold/concentration.
      - ns.MarketIntelService:GetDemandEstimate(itemID) for the demand cap.

    GetShadowPrice never computes synchronously: CraftEVService may call ConcentrationValue while
    evaluating, so plans are built off-frame and the last finished value is served.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS

local ConcentrationPlannerService = {
    _plans = {},
    _shadow = {},
    _buildPending = false,
    _building = false,
}

local SECONDS_PER_HOUR = 3600
--- "Caps soon" window for the login alert.
local ALERT_WINDOW_HOURS = 12
--- Defaults for profile.economy keys this service reads (reported; not in Core defaults).
local DEFAULT_HORIZON_DAYS = 2
--- Recipes evaluated per frame while building plans.
local EVAL_CHUNK = 12
local REBUILD_DEBOUNCE_SEC = 2

local L = ns.SafeLocaleString

local function Cfg(key, fallback)
    local cfg = ns.Economy and ns.Economy.Config and ns.Economy:Config()
    local v = cfg and cfg[key]
    if v == nil then
        return fallback
    end
    return v
end

local function ProfileFlag(key, fallback)
    local p = ns.db and ns.db.profile
    local v = p and p[key]
    if v == nil then
        return fallback
    end
    return v
end

--- All tracked pools, projected to now. Served by ns.CharacterData (current character live; alts
--- from Warband Nexus when it covers concentration, else AN's persisted snapshots).
---@return table[] { guid, charKey?, charName, classFile, profession, professionName, skillLineID, currencyID,
---   current, max, ratePerHour, secondsToCap, capped, source = "an"|"wn", live?, at }
function ConcentrationPlannerService:GetPools()
    return ns.CharacterData:GetConcentrationPools()
end

--- Concentration available to a profession over the planning horizon (sum over characters,
--- each capped at its max): the planner treats alts' pools as one budget.
local function PoolForProfession(pools, profession, horizonHours)
    local total = 0
    for i = 1, #pools do
        local p = pools[i]
        if p.profession == profession then
            total = total + math.min(p.max, p.current + (p.ratePerHour or 0) * horizonHours)
        end
    end
    return math.floor(total)
end

--- Pick the concentration tier from a CraftEVService result (bestConc may be a tier index or a tier table).
local function ConcTier(ev)
    if type(ev) ~= "table" then
        return nil
    end
    local best = ev.bestConc
    if type(best) == "number" and type(ev.tiers) == "table" then
        best = ev.tiers[best]
    end
    if type(best) ~= "table" then
        return nil
    end
    return best
end

local function EvaluateRecipe(spellID, profession, horizonDays)
    local ev = ns.CraftEVService
    if not ev or not ev.Evaluate then
        return nil
    end
    local ok, res = pcall(ev.Evaluate, ev, spellID, { profession = profession })
    if not ok then
        return nil
    end
    local tier = ConcTier(res)
    if not tier then
        return nil
    end
    local gpc = tonumber(tier.gpc)
    local perCraft = tonumber(tier.effConc) or tonumber(tier.concCost)
    if not gpc or gpc <= 0 or not perCraft or perCraft <= 0 then
        return nil
    end
    --- Demand cap: estimated units/day x horizon, divided by expected units per craft.
    local RS = ns.RecipeService
    local itemID = tonumber(tier.outputItem)
    if not itemID and RS and RS.GetOutputItemID then
        local tierIdx = type(res.bestConc) == "number" and res.bestConc or tier.tier
        itemID = RS:GetOutputItemID(spellID, tierIdx)
    end
    local maxCrafts, demandPerDay, demandConfidence
    local intel = ns.MarketIntelService
    if itemID and intel and intel.GetDemandEstimate then
        demandPerDay, demandConfidence = intel:GetDemandEstimate(itemID)
        if demandPerDay and demandPerDay > 0 then
            local yield = tonumber(tier.yield)
                or (RS and RS.GetOutputQuantity and tonumber(RS:GetOutputQuantity(spellID))) or 1
            yield = math.max(1, yield)
            maxCrafts = math.floor(demandPerDay * horizonDays / yield)
        end
    end
    return {
        spellID = spellID,
        itemID = itemID,
        gpc = gpc,
        concPerCraft = perCraft,
        profitPerCraft = tonumber(tier.profit) or 0,
        maxCrafts = maxCrafts,
        demandPerDay = demandPerDay,
        demandConfidence = demandConfidence,
    }
end

--- Greedy allocation in descending gpc. Returns plan rows + marginal gpc (shadow price).
local function Allocate(candidates, pool)
    table.sort(candidates, function(a, b) return a.gpc > b.gpc end)
    local rows, remaining, marginal = {}, pool, 0
    for i = 1, #candidates do
        if remaining < 1 then
            break
        end
        local c = candidates[i]
        local byConc = math.floor(remaining / c.concPerCraft)
        local crafts = c.maxCrafts and math.min(byConc, c.maxCrafts) or byConc
        if crafts > 0 then
            local used = crafts * c.concPerCraft
            remaining = remaining - used
            marginal = c.gpc
            rows[#rows + 1] = {
                spellID = c.spellID,
                itemID = c.itemID,
                crafts = crafts,
                concUsed = math.floor(used + 0.5),
                gpc = c.gpc,
                expectedProfit = math.floor(crafts * c.profitPerCraft + 0.5),
                demandCapped = c.maxCrafts ~= nil and crafts == c.maxCrafts,
                demandPerDay = c.demandPerDay,
                demandConfidence = c.demandConfidence,
            }
        end
    end
    return rows, marginal, remaining
end

--- Plan for one profession (catalog key, e.g. "Alchemy"). Cached; rebuilt off-frame.
---@param profession string
---@return table|nil { profession, pool, horizonDays, rows = { {spellID, itemID, crafts, concUsed, gpc,
---   expectedProfit, demandCapped, demandPerDay, demandConfidence} }, unallocated, shadowPrice, builtAt }
function ConcentrationPlannerService:GetPlan(profession)
    -- Only the first read builds: a finished build that has no plan for `profession` (no pool, not in
    -- the catalog) would otherwise rebuild on every read, and every build ends in
    -- CONCENTRATION_PLAN_UPDATED -> Hub / sidecar repaint -> read (repaint loop). Data messages
    -- (Enable) rebuild after that.
    if not self._plans[profession] and not self._builtAt then
        self:ScheduleRebuild()
    end
    return self._plans[profession]
end

--- True when the cached plan for `profession` spends concentration on `spellID`. The shadow price
--- equals the marginal funded recipe's gpc, so funded recipes must not be compared against it
--- (that made the best recipe reject concentration against its own value).
---@param profession string|nil
---@param spellID number|nil
---@return boolean
function ConcentrationPlannerService:IsFunded(profession, spellID)
    local plan = profession and self._plans[profession]
    if not plan or not spellID or type(plan.rows) ~= "table" then
        return false
    end
    for i = 1, #plan.rows do
        if plan.rows[i].spellID == spellID then
            return true
        end
    end
    return false
end

--- Marginal copper per concentration point for a profession (0/nil when unknown). Never builds synchronously.
---@param profession string|nil
---@return number|nil copper
function ConcentrationPlannerService:GetShadowPrice(profession)
    if profession then
        return self._shadow[profession]
    end
    --- No profession: the best known shadow price across professions.
    local best
    for _, v in pairs(self._shadow) do
        if not best or v > best then
            best = v
        end
    end
    return best
end

function ConcentrationPlannerService:ScheduleRebuild()
    if self._building then
        self._dirty = true
        return
    end
    if self._buildPending or not self._enabled then
        return
    end
    self._buildPending = true
    C_Timer.After(REBUILD_DEBOUNCE_SEC, function()
        ConcentrationPlannerService._buildPending = false
        if ConcentrationPlannerService._enabled then
            ConcentrationPlannerService:Rebuild()
        end
    end)
end

--- Chunked rebuild of every profession that has a pool.
function ConcentrationPlannerService:Rebuild()
    if self._building then
        return
    end
    local ev = ns.CraftEVService
    if not ev or not ev.Evaluate then
        return
    end
    local cat = ns.MidnightRecipeCatalog
    if type(cat) ~= "table" then
        return
    end
    local pools = self:GetPools()
    local horizonDays = tonumber(Cfg("plannerHorizonDays", DEFAULT_HORIZON_DAYS)) or DEFAULT_HORIZON_DAYS
    horizonDays = math.max(0.25, math.min(14, horizonDays))
    local horizonHours = horizonDays * 24

    local jobs = {}
    local seen = {}
    for i = 1, #pools do
        local prof = pools[i].profession
        if prof and not seen[prof] and type(cat[prof]) == "table" and type(cat[prof].recipes) == "table" then
            seen[prof] = true
            local ids = {}
            local RS = ns.RecipeService
            for spellID in pairs(cat[prof].recipes) do
                -- Only recipes some tracked character can actually craft (learned anywhere).
                local sch = RS and RS.GetSchematic and RS:GetSchematic(spellID)
                if sch and sch.learned ~= false then
                    ids[#ids + 1] = spellID
                end
            end
            jobs[#jobs + 1] = { profession = prof, ids = ids, pool = PoolForProfession(pools, prof, horizonHours) }
        end
    end
    if #jobs == 0 then
        self._builtAt = time()
        return
    end

    self._building = true
    local jobIdx, recipeIdx, candidates = 1, 1, {}
    local function step()
        if not ConcentrationPlannerService._enabled then
            ConcentrationPlannerService._building = false
            return
        end
        local job = jobs[jobIdx]
        local n = 0
        while job and n < EVAL_CHUNK do
            local spellID = job.ids[recipeIdx]
            if spellID then
                local c = EvaluateRecipe(spellID, job.profession, horizonDays)
                if c then
                    candidates[#candidates + 1] = c
                end
                recipeIdx = recipeIdx + 1
                n = n + 1
            else
                local rows, marginal, remaining = Allocate(candidates, job.pool)
                ConcentrationPlannerService._plans[job.profession] = {
                    profession = job.profession,
                    pool = job.pool,
                    horizonDays = horizonDays,
                    rows = rows,
                    unallocated = math.floor(remaining),
                    shadowPrice = marginal,
                    builtAt = time(),
                }
                ConcentrationPlannerService._shadow[job.profession] = marginal > 0 and marginal or nil
                jobIdx = jobIdx + 1
                recipeIdx = 1
                candidates = {}
                job = jobs[jobIdx]
            end
        end
        if job then
            C_Timer.After(0, step)
        else
            ConcentrationPlannerService._building = false
            ConcentrationPlannerService._builtAt = time()
            local EV = ns.Constants.EVENTS
            if ns.ArtisanNexus and ns.ArtisanNexus.SendMessage and EV and EV.CONCENTRATION_PLAN_UPDATED then
                ns.ArtisanNexus:SendMessage(EV.CONCENTRATION_PLAN_UPDATED)
            end
            if ConcentrationPlannerService._dirty then
                ConcentrationPlannerService._dirty = false
                ConcentrationPlannerService:ScheduleRebuild()
            end
        end
    end
    step()
end

local function FormatHours(seconds)
    local hoursLeft = math.max(0, (seconds or 0) / SECONDS_PER_HOUR)
    local h = math.floor(hoursLeft)
    local m = math.floor((hoursLeft - h) * 60)
    return string.format(L("HUB_CONC_HOURS_FMT", "%dh %dm"), h, m)
end

--- One chat line per day when a pool is capped or caps within ALERT_WINDOW_HOURS.
function ConcentrationPlannerService:CheckOverflowAlert()
    if ProfileFlag("concentrationOverflowAlert", true) == false then
        return
    end
    local g = ns.db and ns.db.global
    if not g then
        return
    end
    local today = date("%Y-%m-%d")
    g.concentrationPlanner = g.concentrationPlanner or {}
    if g.concentrationPlanner.lastAlertDay == today then
        return
    end
    local pools = self:GetPools()
    local parts = {}
    for i = 1, #pools do
        local p = pools[i]
        local label = string.format("%s (%s)", p.charName or "?", tostring(p.professionName or p.profession or "?"))
        if p.capped then
            parts[#parts + 1] = string.format(L("CONC_ALERT_CAPPED_ITEM", "%s: capped"), label)
        elseif p.secondsToCap and p.secondsToCap <= ALERT_WINDOW_HOURS * SECONDS_PER_HOUR then
            parts[#parts + 1] = string.format(L("CONC_ALERT_SOON_ITEM", "%s: full in %s"), label, FormatHours(p.secondsToCap))
        end
    end
    if #parts == 0 then
        return
    end
    g.concentrationPlanner.lastAlertDay = today
    local AN = ns.ArtisanNexus
    if AN and AN.Print then
        AN:Print(string.format(L("CONC_ALERT_LINE", "Concentration overflow: %s"), table.concat(parts, ", ")))
    end
end

function ConcentrationPlannerService:Enable()
    if self._enabled then
        return
    end
    self._enabled = true
    local owner = self._eventOwner or ns.NewEventOwner("ConcentrationPlannerService")
    self._eventOwner = owner
    local function rebuild()
        ConcentrationPlannerService:ScheduleRebuild()
    end
    if E then
        local msgs = {
            E.AH_PRICES_UPDATED, E.PROFESSION_SNAPSHOT_UPDATED, E.WN_DATA_UPDATED, E.CHARACTER_DATA_SOURCE_CHANGED,
            E.ECONOMY_CONFIG_CHANGED, E.CRAFT_OPS_UPDATED, E.MARKET_INTEL_UPDATED,
            E.RECIPE_SCHEMATICS_UPDATED,
        }
        for i = 1, #msgs do
            if msgs[i] then
                owner:RegisterMessage(msgs[i], rebuild)
            end
        end
    end
    --- Login: let snapshots / WN settle, then alert and build.
    C_Timer.After(8, function()
        if ConcentrationPlannerService._enabled then
            ConcentrationPlannerService:CheckOverflowAlert()
            ConcentrationPlannerService:ScheduleRebuild()
        end
    end)
end

function ConcentrationPlannerService:Disable()
    if not self._enabled then
        return
    end
    self._enabled = false
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
        self._eventOwner:UnregisterAllMessages()
    end
end

ns.ConcentrationPlannerService = ConcentrationPlannerService
