--[[
    Artisan Nexus — Crafting operation snapshots.

    C_TradeSkillUI.GetCraftingOperationInfo only answers while the player's own profession
    window is open, so this service samples it once per open profession and persists what the
    EV engine needs to price crafts later (window closed, other characters):

      db.global.craftOps[spellID][guid] = {
        at, build, skill, difficulty, maxQuality, baseQtyMin, baseQtyMax, hasConc,
        stats  = { multicraft = 0..1, resourcefulness = 0..1, ingenuity = 0..1, raw = { [name] = pct } },
        tiers  = { [tier] = { alloc = { [dataSlotIndex] = itemID }, cost, conc = false, concCost, ingenuityRefund } },
        concTiers = { [tier] = { alloc, cost, conc = true, concCost, ingenuityRefund, verified } },
        combos = { { a = alloc, q = tier, c = concCost, s = skill }, ... } | nil (only when small),
      }
      db.global.craftOpsMeta = { builds = { "70391", ... } } (newest last)

    Reagent-quality optimizer: required Basic slots with several quality candidates are
    enumerated exhaustively (<= EXHAUSTIVE_LIMIT combos) or greedily (upgrade the slot with
    the best skill gain per copper). One quality per slot (no split stacks inside a slot).
    Concentration rows: a combo landing on tier t with concentrationCost > 0 reaches t+1 when
    concentrating; the cheapest such combo per target tier is confirmed with applyConcentration.

    Facts (verified 2026-10-14, Blizzard_APIDocumentationGenerated 12.1.5.70391 unless noted):
      - GetCraftingOperationInfo(recipeID, craftingReagents, allocationItemGUID?, applyConcentration)
        -> CraftingOperationInfo? { baseSkill, bonusSkill, baseDifficulty, bonusDifficulty, quality (float),
        craftingQuality (int), lowerSkillThreshold, upperSkillTreshold (sic), bonusStats[], concentrationCurrencyID,
        concentrationCost, ingenuityRefund }.
      - CraftingReagentInfo = { reagent = { itemID }, dataSlotIndex, quantity } (12.0 shape).
      - CraftingOperationBonusStatInfo has no type id: { bonusStatName, bonusStatValue, ratingDescription, ratingPct, bonusRatingPct }.
      - nil with applyConcentration=true -> retry with false (Blizzard_ProfessionsRecipeSchematicForm.lua:276-299).
      - Own-window guards: IsTradeSkillLinked / IsTradeSkillGuild / IsNPCCrafting (Blizzard_Professions UI call sites).
      - Stat labels: ITEM_MOD_MULTICRAFT_SHORT="Multicraft", ITEM_MOD_RESOURCEFULNESS_SHORT="Resourcefulness",
        ITEM_MOD_INGENUITY_SHORT="Ingenuity", PROFESSIONS_OUTPUT_*_TITLE (Ketho BlizzardInterfaceResources
        live Resources/GlobalStrings/enUS.lua). UNVERIFIED: that bonusStatName equals these strings in every
        locale; unmatched names are kept raw in stats.raw.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS

local CraftOpsService = { _enabled = false }

--- GetCraftingOperationInfo calls allowed per frame before yielding to the next frame.
local CALLS_PER_FRAME = 12
--- Enumerate every quality combo up to this many; beyond it the greedy path is used.
local EXHAUSTIVE_LIMIT = 64
--- Persist raw combos (lets the EV engine re-optimize at today's prices) up to this many; equal to
--- EXHAUSTIVE_LIMIT so every exhaustively sampled recipe can be re-optimized.
local STORE_COMBOS_LIMIT = 64
--- Snapshot rows from builds older than the newest N seen builds are dropped.
local KEEP_BUILDS = 2
--- Characters kept per recipe (most recent first).
local MAX_GUIDS_PER_RECIPE = 12
--- Re-sample a recipe for the same character/build only after this many seconds unless forced.
local MIN_REFRESH_SEC = 600
--- Greedy safety cap (upgrade steps per recipe).
local GREEDY_MAX_STEPS = 32
--- Delay after the trade skill events settle (RecipeService harvests first, at 0.2-0.35 s).
local SETTLE_DELAY_SEC = 1.0
--- Snapshot layout revision; rows of another revision are ignored and re-sampled.
--- 2: reagent slots keyed by schematic slot (a Reagent and a ModifiedReagent slot sharing a
---    dataSlotIndex no longer merge, so ranked slots are sent to GetCraftingOperationInfo again).
local SNAP_REV = 2

local function CurrentBuild()
    if GetBuildInfo then
        local _, build = GetBuildInfo()
        return build and tostring(build) or nil
    end
    return nil
end

local function Store()
    local g = ns.db and ns.db.global
    if not g then return nil end
    g.craftOps = g.craftOps or {}
    return g.craftOps
end

local function Meta()
    local g = ns.db and ns.db.global
    if not g then return nil end
    g.craftOpsMeta = g.craftOpsMeta or { builds = {} }
    g.craftOpsMeta.builds = g.craftOpsMeta.builds or {}
    return g.craftOpsMeta
end

local function CharGUID()
    return ns.Utilities and ns.Utilities.GetCharacterGUID and ns.Utilities:GetCharacterGUID() or nil
end

--==========================================================================
-- Bonus stat identification (by localized name)
--==========================================================================

local STAT_GLOBALS = {
    multicraft = { "ITEM_MOD_MULTICRAFT_SHORT", "PROFESSIONS_OUTPUT_MULTICRAFT_TITLE" },
    resourcefulness = { "ITEM_MOD_RESOURCEFULNESS_SHORT", "PROFESSIONS_OUTPUT_RESOURCEFULNESS_TITLE",
        "PROFESSIONS_CRAFTING_STAT_TT_RESOURCE_RETURN_HEADER" },
    ingenuity = { "ITEM_MOD_INGENUITY_SHORT", "PROFESSIONS_OUTPUT_INGENUITY_TITLE" },
}

local function NormalizeStatName(s)
    if type(s) ~= "string" then return nil end
    if issecretvalue and issecretvalue(s) then return nil end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    s = s:gsub("[:%s]+$", ""):gsub("^%s+", "")
    return s:lower()
end

local statNameMap

local function StatNameMap()
    if statNameMap then return statNameMap end
    statNameMap = {}
    for key, globals in pairs(STAT_GLOBALS) do
        for i = 1, #globals do
            local label = NormalizeStatName(_G[globals[i]])
            if label and label ~= "" then
                statNameMap[label] = key
            end
        end
    end
    return statNameMap
end

--- Parse CraftingOperationInfo.bonusStats / GatheringOperationInfo.bonusStats.
---@param bonusStats table[]|nil
---@return table { multicraft = 0..1, resourcefulness = 0..1, ingenuity = 0..1, raw = { [name] = pct } }
function CraftOpsService:ParseBonusStats(bonusStats)
    local out = { multicraft = 0, resourcefulness = 0, ingenuity = 0, raw = {} }
    if type(bonusStats) ~= "table" then return out end
    local map = StatNameMap()
    for i = 1, #bonusStats do
        local st = bonusStats[i]
        if type(st) == "table" then
            local pct = tonumber(st.ratingPct) or 0
            local norm = NormalizeStatName(st.bonusStatName)
            local key = norm and map[norm]
            if key then
                out[key] = math.max(0, math.min(1, pct / 100))
            elseif norm then
                out.raw[st.bonusStatName] = pct
            end
        end
    end
    return out
end

--==========================================================================
-- Snapshot access
--==========================================================================

--- Best snapshot for a recipe: the given character, else the current one, else the most recent alt.
---@param spellID number
---@param guid string|nil
---@return table|nil snapshot
---@return string|nil ownerGuid
function CraftOpsService:GetSnapshot(spellID, guid)
    local s = Store()
    local bucket = s and s[tonumber(spellID) or spellID]
    if type(bucket) ~= "table" then return nil, nil end
    local function valid(row)
        return type(row) == "table" and row.rev == SNAP_REV
    end
    if guid then
        local row = bucket[guid]
        return valid(row) and row or nil, valid(row) and guid or nil
    end
    local me = CharGUID()
    if me and valid(bucket[me]) then
        return bucket[me], me
    end
    local best, bestGuid
    for g, row in pairs(bucket) do
        if valid(row) and (not best or (row.at or 0) > (best.at or 0)) then
            best, bestGuid = row, g
        end
    end
    return best, bestGuid
end

--- Prune rows from builds outside the newest KEEP_BUILDS and cap characters per recipe.
function CraftOpsService:Prune()
    local s, meta = Store(), Meta()
    if not s or not meta then return end
    local build = CurrentBuild()
    local builds = meta.builds
    if build and builds[#builds] ~= build then
        for i = #builds, 1, -1 do
            if builds[i] == build then table.remove(builds, i) end
        end
        builds[#builds + 1] = build
        while #builds > KEEP_BUILDS do table.remove(builds, 1) end
    end
    local keep = {}
    for i = 1, #builds do keep[builds[i]] = true end
    for spellID, bucket in pairs(s) do
        if type(bucket) ~= "table" then
            s[spellID] = nil
        else
            local list = {}
            for g, row in pairs(bucket) do
                if type(row) ~= "table" or (row.build and next(keep) and not keep[row.build]) then
                    bucket[g] = nil
                else
                    list[#list + 1] = { g = g, at = row.at or 0 }
                end
            end
            if #list > MAX_GUIDS_PER_RECIPE then
                table.sort(list, function(a, b) return a.at > b.at end)
                for i = MAX_GUIDS_PER_RECIPE + 1, #list do bucket[list[i].g] = nil end
            end
            if next(bucket) == nil then s[spellID] = nil end
        end
    end
end

--==========================================================================
-- Sampling
--==========================================================================

local function OwnTradeSkillOpen()
    local T = C_TradeSkillUI
    if not T or not T.GetCraftingOperationInfo then return false end
    if T.IsTradeSkillReady and not T.IsTradeSkillReady() then return false end
    if T.IsTradeSkillLinked and T.IsTradeSkillLinked() then return false end
    if T.IsTradeSkillGuild and T.IsTradeSkillGuild() then return false end
    if T.IsNPCCrafting and T.IsNPCCrafting() then return false end
    return true
end

local function ChildSkillLineID()
    if not (C_TradeSkillUI and C_TradeSkillUI.GetChildProfessionInfo) then return nil end
    local ok, info = pcall(C_TradeSkillUI.GetChildProfessionInfo)
    if ok and type(info) == "table" then return tonumber(info.professionID) end
    return nil
end

--- Copper for qty units of a candidate at today's prices (nil when unpriced).
local function CandidateCost(itemID, qty)
    local econ = ns.Economy
    if econ and econ.BuyCost then
        local c = econ:BuyCost(itemID, qty)
        if c then return c end
    end
    local p = ns.AHPriceService and ns.AHPriceService.GetPrice and ns.AHPriceService:GetPrice(itemID)
    return p and p * qty or nil
end
CraftOpsService.CandidateCost = CandidateCost

--- Total cost of the quality slots of an allocation; unpriced -> math.huge (sorts last).
---@param alloc table [dataSlotIndex] = itemID
---@param qslots table[] slot descriptors (dataSlotIndex, qty)
---@return number cost
function CraftOpsService:AllocCost(alloc, qslots)
    local total = 0
    for i = 1, #qslots do
        local slot = qslots[i]
        local itemID = alloc[slot.dataSlotIndex]
        local c = itemID and CandidateCost(itemID, slot.qty)
        if not c then return math.huge end
        total = total + c
    end
    return total
end

--- Highest tier a prediction may reach: maxQuality, else #qualityItemIDs; 0 = uncapped.
---@param sch table|nil schematic row
---@param maxQuality number|nil
---@return number cap
function CraftOpsService:TierCap(sch, maxQuality)
    local cap = tonumber(maxQuality) or 0
    if cap <= 0 and sch and type(sch.qualityItemIDs) == "table" then
        cap = #sch.qualityItemIDs
    end
    return cap
end

--- Per-tier winners from raw combos at today's prices.
---@param combos table[] { a = alloc, q = tier, c = concCost, s = skill }
---@param qslots table[]
---@param maxQuality number|nil
---@param costFn function|nil alloc -> copper (math.huge when unpriced); default AllocCost (buy cost of
---  the quality slots). The EV engine passes its own reagent pricing so the mix chosen per tier is
---  the one that is cheapest on the same basis the profit uses.
---@return table tiers, table concTiers
function CraftOpsService:TiersFromCombos(combos, qslots, maxQuality, costFn)
    local tiers, concTiers = {}, {}
    maxQuality = tonumber(maxQuality) or 0
    for i = 1, #combos do
        local cb = combos[i]
        local cost = costFn and costFn(cb.a) or self:AllocCost(cb.a, qslots)
        local t = cb.q
        local cur = tiers[t]
        if not cur or cost < cur._cost then
            tiers[t] = { alloc = cb.a, _cost = cost, conc = false, concCost = cb.c, ingenuityRefund = cb.i }
        end
        if (cb.c or 0) > 0 and (maxQuality == 0 or t < maxQuality) then
            local tt = t + 1
            local cc = concTiers[tt]
            if not cc or cost < cc._cost or (cost == cc._cost and (cb.c or 0) < (cc.concCost or 0)) then
                concTiers[tt] = { alloc = cb.a, _cost = cost, conc = true, concCost = cb.c, verified = false }
            end
        end
    end
    for _, map in ipairs({ tiers, concTiers }) do
        for _, row in pairs(map) do
            row.cost = (row._cost ~= math.huge) and row._cost or nil
            row._cost = nil
        end
    end
    return tiers, concTiers
end

local function CopyAlloc(a)
    local o = {}
    for k, v in pairs(a) do o[k] = v end
    return o
end

--- Inside the job coroutine: one budgeted GetCraftingOperationInfo call.
local function OpCall(job, spellID, reagents, applyConc)
    if job.calls >= CALLS_PER_FRAME then
        coroutine.yield()
    end
    job.calls = job.calls + 1
    local ok, info = pcall(C_TradeSkillUI.GetCraftingOperationInfo, spellID, reagents, nil, applyConc == true)
    if ok and type(info) == "table" then return info end
    return nil
end

local function BuildReagents(passSlots, alloc)
    local out = {}
    for i = 1, #passSlots do
        local slot = passSlots[i]
        local itemID = alloc[slot.dataSlotIndex] or slot.candidates[1]
        if itemID then
            out[#out + 1] = {
                reagent = { itemID = itemID },
                dataSlotIndex = slot.dataSlotIndex,
                quantity = slot.qty,
            }
        end
    end
    return out
end

local function Tier(info)
    local t = tonumber(info and info.craftingQuality) or 0
    if t < 1 then t = 1 end
    return t
end

local function Skill(info)
    return (tonumber(info.baseSkill) or 0) + (tonumber(info.bonusSkill) or 0)
end

local function ComboOf(alloc, info)
    return {
        a = CopyAlloc(alloc),
        q = Tier(info),
        c = tonumber(info.concentrationCost) or 0,
        s = Skill(info),
        i = tonumber(info.ingenuityRefund) or nil,
    }
end

--- Sample one recipe (runs inside the job coroutine).
---@return table|nil snapshot
local function SampleRecipe(job, spellID)
    local rs = ns.RecipeService
    local sch = rs and rs:GetSchematic(spellID)
    if not sch or sch.hasCraftingOperationInfo ~= true then return nil end
    local slots = rs:GetRequiredBasicSlots(spellID)
    local passSlots, qslots = {}, {}
    for i = 1, #slots do
        local slot = slots[i]
        if slot.passToOperation then
            passSlots[#passSlots + 1] = slot
            if slot.isQuality then qslots[#qslots + 1] = slot end
        end
    end

    local alloc = {}
    for i = 1, #passSlots do
        alloc[passSlots[i].dataSlotIndex] = passSlots[i].candidates[1]
    end
    local base = OpCall(job, spellID, BuildReagents(passSlots, alloc), false)
    if not base then return nil end

    local maxQuality = tonumber(sch.maxQuality)
    -- Tier cap for predictions: maxQuality, else the number of quality output items (nil/0 = uncapped).
    local tierCap = CraftOpsService:TierCap(sch, maxQuality)
    local combos = { ComboOf(alloc, base) }
    local total = 1
    for i = 1, #qslots do total = total * #qslots[i].candidates end

    if #qslots > 0 and total <= EXHAUSTIVE_LIMIT then
        -- Odometer over candidate indices; combo #1 (all lowest) is already sampled.
        local idx = {}
        for i = 1, #qslots do idx[i] = 1 end
        while true do
            local k = 1
            while k <= #qslots do
                idx[k] = idx[k] + 1
                if idx[k] <= #qslots[k].candidates then break end
                idx[k] = 1
                k = k + 1
            end
            if k > #qslots then break end
            local a = CopyAlloc(alloc)
            for i = 1, #qslots do a[qslots[i].dataSlotIndex] = qslots[i].candidates[idx[i]] end
            local info = OpCall(job, spellID, BuildReagents(passSlots, a), false)
            if info then combos[#combos + 1] = ComboOf(a, info) end
        end
    elseif #qslots > 0 then
        -- Greedy: upgrade the slot with the best skill gain per copper until nothing helps.
        local cur, curSkill, curTier = CopyAlloc(alloc), Skill(base), Tier(base)
        local curIdx = {}
        for i = 1, #qslots do curIdx[i] = 1 end
        for _ = 1, GREEDY_MAX_STEPS do
            if tierCap > 0 and curTier >= tierCap then break end
            local curCost = CraftOpsService:AllocCost(cur, qslots)
            -- Priced steps rank by skill per copper; when a cost is unknown (unpriced reagent)
            -- fall back to raw skill gain so the walk does not stall on missing prices.
            local bestI, bestRatio, bestAlloc, bestSkill, bestTier
            local uBestI, uBestGain, uBestAlloc, uBestSkill, uBestTier
            for i = 1, #qslots do
                if curIdx[i] < #qslots[i].candidates then
                    local a = CopyAlloc(cur)
                    a[qslots[i].dataSlotIndex] = qslots[i].candidates[curIdx[i] + 1]
                    local info = OpCall(job, spellID, BuildReagents(passSlots, a), false)
                    if info then
                        combos[#combos + 1] = ComboOf(a, info)
                        local dSkill = Skill(info) - curSkill
                        local cost = CraftOpsService:AllocCost(a, qslots)
                        local dCost = (cost ~= math.huge and curCost ~= math.huge) and math.max(1, cost - curCost) or nil
                        if dSkill > 0 and dCost then
                            local ratio = dSkill / dCost
                            if not bestRatio or ratio > bestRatio then
                                bestI, bestRatio, bestAlloc, bestSkill, bestTier = i, ratio, a, Skill(info), Tier(info)
                            end
                        elseif dSkill > 0 then
                            if not uBestGain or dSkill > uBestGain then
                                uBestI, uBestGain, uBestAlloc, uBestSkill, uBestTier = i, dSkill, a, Skill(info), Tier(info)
                            end
                        end
                    end
                end
            end
            if not bestI and uBestI then
                bestI, bestAlloc, bestSkill, bestTier = uBestI, uBestAlloc, uBestSkill, uBestTier
            end
            if not bestI then break end
            cur, curSkill, curTier = bestAlloc, bestSkill, bestTier
            curIdx[bestI] = curIdx[bestI] + 1
        end
    end

    local tiers, concTiers = CraftOpsService:TiersFromCombos(combos, qslots, tierCap)
    local hasConc = (tonumber(base.concentrationCurrencyID) or 0) ~= 0
    if not hasConc then
        concTiers = {}
    else
        -- Confirm each concentration winner; Blizzard retries without concentration on nil
        -- (not enough concentration right now) — keep the predicted row unverified then.
        local targets = {}
        for target in pairs(concTiers) do targets[#targets + 1] = target end
        table.sort(targets)
        for ti = 1, #targets do
            local target = targets[ti]
            local row = concTiers[target]
            local info = row and OpCall(job, spellID, BuildReagents(passSlots, row.alloc), true)
            if info then
                row.verified = true
                row.ingenuityRefund = tonumber(info.ingenuityRefund) or row.ingenuityRefund
                if (tonumber(info.concentrationCost) or 0) > 0 then
                    row.concCost = tonumber(info.concentrationCost)
                end
                local reached = Tier(info)
                if reached ~= target then
                    concTiers[target] = nil
                    local other = concTiers[reached]
                    if not other or (other.cost or math.huge) > (row.cost or math.huge) then
                        concTiers[reached] = row
                    end
                end
            end
        end
    end

    local stats = CraftOpsService:ParseBonusStats(base.bonusStats)
    local snap = {
        rev = SNAP_REV,
        at = time(),
        build = CurrentBuild(),
        skill = Skill(base),
        difficulty = (tonumber(base.baseDifficulty) or 0) + (tonumber(base.bonusDifficulty) or 0),
        lowerSkillThreshold = tonumber(base.lowerSkillThreshold),
        upperSkillThreshold = tonumber(base.upperSkillTreshold), -- API field is misspelled
        maxQuality = maxQuality,
        baseQtyMin = sch.output and tonumber(sch.output.quantityMin) or 1,
        baseQtyMax = sch.output and tonumber(sch.output.quantityMax) or 1,
        hasConc = hasConc,
        stats = stats,
        tiers = tiers,
        concTiers = concTiers,
        qslots = {},
    }
    for i = 1, #qslots do
        snap.qslots[i] = { dataSlotIndex = qslots[i].dataSlotIndex, qty = qslots[i].qty }
    end
    if #combos <= STORE_COMBOS_LIMIT then
        snap.combos = combos
    end
    return snap
end

--- Recipes of the open profession worth sampling now.
local function CollectTargets(force)
    local rs = ns.RecipeService
    if not rs or not C_TradeSkillUI.GetAllRecipeIDs then return {} end
    local childSL = ChildSkillLineID()
    local profession = childSL and rs:GetProfessionForSkillLine(childSL)
    local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" then return {} end
    local guid, build, now = CharGUID(), CurrentBuild(), time()
    local out = {}
    for i = 1, #ids do
        local spellID = tonumber(ids[i])
        if spellID and rs:IsMidnightRecipe(spellID)
            and (not profession or rs:GetProfession(spellID) == profession) then
            local sch = rs:GetSchematic(spellID)
            if sch and sch.hasCraftingOperationInfo == true and type(sch.reagents) == "table" and #sch.reagents > 0 then
                -- Freshness first: a recent snapshot skips the GetRecipeInfo call entirely.
                local prev = guid and CraftOpsService:GetSnapshot(spellID, guid)
                if force or not prev or prev.build ~= build or (now - (prev.at or 0)) >= MIN_REFRESH_SEC then
                    local okI, info = pcall(C_TradeSkillUI.GetRecipeInfo, spellID)
                    if okI and type(info) == "table" and info.learned and not info.isGatheringRecipe
                        and not info.isSalvageRecipe and not info.isRecraft and not info.isDummyRecipe then
                        out[#out + 1] = spellID
                    end
                end
            end
        end
    end
    return out, childSL
end

local function Emit(payload)
    ns.ArtisanNexus:SendMessage(E.CRAFT_OPS_UPDATED, payload)
end

local function Pump(job)
    local self = CraftOpsService
    if self._job ~= job then return end
    if not self._enabled or not OwnTradeSkillOpen() or ChildSkillLineID() ~= job.skillLine then
        self._job = nil
        if job.done > 0 then Emit(nil) end
        return
    end
    job.calls = 0
    local ok, err = coroutine.resume(job.co)
    if not ok then
        self._job = nil
        if geterrorhandler then geterrorhandler()(err) end
        return
    end
    if coroutine.status(job.co) == "dead" then
        self._job = nil
        if job.done > 0 then Emit(job.single) end
        return
    end
    C_Timer.After(0, function() Pump(job) end)
end

--- Sample learned Midnight recipes of the open profession (chunked across frames).
---@param force boolean|nil ignore the MIN_REFRESH_SEC throttle
---@param onlySpellID number|nil restrict to one recipe
---@return boolean started
function CraftOpsService:RefreshOpenProfession(force, onlySpellID)
    if not self._enabled or not OwnTradeSkillOpen() then return false end
    if self._job and not force then return false end
    local guid = CharGUID()
    local store = Store()
    if not guid or not store then return false end
    local targets, skillLine = CollectTargets(force)
    if onlySpellID then
        local filtered = {}
        for i = 1, #targets do
            if targets[i] == onlySpellID then filtered[1] = onlySpellID end
        end
        targets = filtered
    end
    if #targets < 1 then return false end
    self:Prune()
    local job = { calls = 0, done = 0, skillLine = skillLine, single = onlySpellID }
    job.co = coroutine.create(function()
        for i = 1, #targets do
            local spellID = targets[i]
            local snap = SampleRecipe(job, spellID)
            if snap then
                store[spellID] = store[spellID] or {}
                store[spellID][guid] = snap
                job.done = job.done + 1
            end
        end
    end)
    self._job = job
    Pump(job)
    return true
end

function CraftOpsService:Enable()
    if self._enabled then return end
    self._enabled = true
    local owner = self._eventOwner or ns.NewEventOwner("CraftOpsService")
    self._eventOwner = owner
    self:Prune()

    local pending, pendingForce = false, false
    local function Schedule(force)
        pendingForce = pendingForce or force == true
        if pending then return end
        pending = true
        C_Timer.After(SETTLE_DELAY_SEC, function()
            pending = false
            -- A gear swap or spec change with the profession window closed must still force the
            -- next sample (otherwise MIN_REFRESH_SEC keeps the pre-change stats for 10 minutes).
            local f = pendingForce or CraftOpsService._forceOnNextOpen == true
            pendingForce = false
            if CraftOpsService._enabled then
                local started = CraftOpsService:RefreshOpenProfession(f)
                if f then
                    CraftOpsService._forceOnNextOpen = not started or nil
                end
            end
        end)
    end
    owner:RegisterEvent("TRADE_SKILL_SHOW", function() Schedule(false) end)
    owner:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function() Schedule(false) end)
    owner:RegisterEvent("CRAFTING_DETAILS_UPDATE", function() Schedule(false) end)
    -- Stat changes: profession gear swap or spec points (both V-DOC 12.1.5.70391).
    owner:RegisterEvent("PROFESSION_EQUIPMENT_CHANGED", function() Schedule(true) end)
    owner:RegisterEvent("SKILL_LINE_SPECS_RANKS_CHANGED", function() Schedule(true) end)
    owner:RegisterEvent("TRADE_SKILL_CLOSE", function()
        local job = CraftOpsService._job
        CraftOpsService._job = nil
        if job and job.done > 0 then Emit(nil) end
    end)
end

function CraftOpsService:Disable()
    if not self._enabled then return end
    self._enabled = false
    self._job = nil
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
        self._eventOwner:UnregisterAllMessages()
    end
end

ns.CraftOpsService = CraftOpsService
