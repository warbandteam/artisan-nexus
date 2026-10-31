--[[
    Artisan Nexus — Crafting expected-value engine.

    How the EV is computed (per recipe, per reachable output tier):
      1. Allocation: the CraftOpsService snapshot (current character, else most recent alt) says
         which reagent-quality mix reaches each tier, with and without concentration. When the
         snapshot kept its raw combos, the cheapest mix per tier is re-chosen at today's prices.
         No snapshot -> "fallback" basis: cheapest candidate per slot, tier from a live operation
         when the window is open, else the base output item.
      2. yield       = avg(baseQtyMin, baseQtyMax) * (1 + multicraft% * ProcFactors.multicraftExtra)
                       (multicraft only for stackable outputs: not single-item / enchant / ilvl-tier gear)
      3. reagentCost = sum over required Basic slots of slotCost * (1 - resourcefulness% * ProcFactors.resourcefulnessSave)
                       (resourcefulness only on tradeable reagents: bindType not OnAcquire/Quest)
                       slotCost = buy cost (Economy:BuyCost walks the commodity book; vendor when cheaper),
                       owned stock via Economy:ReagentCost when opts.useOwned, or the 7-day average when
                       opts.useAverage (same basis as the output), or the EV unit cost of making the
                       reagent (make-vs-buy, depth <= 3, cycle guarded) when that is cheaper.
      4. revenueNet  = Economy:NetSaleValue(tierOutputItem, unitPrice, yield)   (AH cut + expected deposit loss)
      5. profit      = revenueNet - reagentCost
      6. concentration rows: effConc = concCost - ingenuity% * op.ingenuityRefund (points refunded on a
         proc, from the server); ProcFactors.ingenuityRefund (share of the cost) only without it
                       gpc = (profitWithConc - bestProfitNoConc) / effConc
                       profitAfterConc = profit - effConc * Economy:ConcentrationValue(profession)
    Results are memoized per frame (GetTime); returned tables are shared — do not mutate.
]]

local ADDON_NAME, ns = ...

local GetItemInfo = C_Item.GetItemInfo

local CraftEVService = {}

local MAX_MAKE_DEPTH = 3

-- Enum.ItemBind OnAcquire = 1, Quest = 4 (verified 2026-10-14, ItemConstantsDocumentation 12.1.5.70391).
local UNTRADEABLE_BIND = { [1] = true, [4] = true }

local memo = { stamp = nil, rows = {} }

local function MemoGet(key)
    local now = GetTime()
    if memo.stamp ~= now then
        memo.stamp = now
        memo.rows = {}
        return nil
    end
    return memo.rows[key]
end

local function MemoSet(key, value)
    memo.rows[key] = value
end

local function IsTradeable(itemID)
    local bindType = select(14, GetItemInfo(itemID))
    bindType = tonumber(bindType)
    return not (bindType and UNTRADEABLE_BIND[bindType])
end

local function IsStackableItem(itemID)
    if not itemID then return nil end
    local stack = tonumber((select(8, GetItemInfo(itemID))))
    if not stack then return nil end
    return stack > 1
end

--- Output unit price on the requested basis.
---@return number|nil price, boolean fromHistory
local function OutputUnitPrice(itemID, useAverage)
    if not itemID then return nil, false end
    if useAverage and ns.PriceHistoryService and ns.PriceHistoryService.GetStats then
        local s = ns.PriceHistoryService:GetStats(itemID)
        if s and s.count and s.count >= 2 and s.avg then
            return s.avg, true
        end
    end
    local p = ns.AHPriceService and ns.AHPriceService.GetPrice and ns.AHPriceService:GetPrice(itemID)
    return p, false
end

--- Buy-side cost of qty units on the requested basis (no make-vs-buy).
---@return number|nil copper, string|nil source
local function BuyCostFor(itemID, qty, ctx)
    local econ = ns.Economy
    if ctx.useOwned and econ and econ.ReagentCost then
        -- Crafting-usable stock, not just what is carried: RecipeService:ScanBags walks bags plus
        -- the warband tabs, so reagents kept in the character bank or the reagent bank read as
        -- zero and "value owned stock" priced them as a purchase. GetStockByLocation goes through
        -- C_Item.GetItemCount (bags + bank + warband), the same count Blizzard crafts against.
        local owned = 0
        if ctx.stockFn then
            owned = tonumber(ctx.stockFn(itemID)) or 0
        elseif ctx.bagCounts then
            owned = tonumber(ctx.bagCounts[itemID]) or 0
        end
        local c = econ:ReagentCost(itemID, qty, owned)
        if c then return c, owned > 0 and "owned" or "buy" end
    end
    if ctx.useAverage then
        local avg, fromHistory = OutputUnitPrice(itemID, true)
        if avg and fromHistory then
            local vendor = ns.VendorPriceService and ns.VendorPriceService:GetBuyPrice(itemID)
            if vendor and vendor < avg then return vendor * qty, "vendor" end
            return avg * qty, "avg"
        end
    end
    if econ and econ.BuyCost then
        local c, src = econ:BuyCost(itemID, qty)
        if c then return c, src end
    end
    local p = ns.AHPriceService and ns.AHPriceService.GetPrice and ns.AHPriceService:GetPrice(itemID)
    if p then return p * qty, "price" end
    return nil, nil
end

local function KnownOK(spellID, knownBy)
    local rs = ns.RecipeService
    local sch = rs and rs:GetSchematic(spellID)
    local cd = ns.CharacterData
    if not sch or cd:IsKnownByAny(spellID) == false then return false end
    if knownBy == "me" and cd:IsKnownByMe(spellID) == false then return false end
    return true
end

--- Cheapest EV unit cost of crafting itemID (reagent cost per yielded unit, no concentration).
---@return number|nil unitCost, number|nil spellID
local function MakeUnitCost(itemID, ctx)
    local rs = ns.RecipeService
    if not rs or not rs.GetRecipesProducingItem or ctx.depth >= MAX_MAKE_DEPTH then return nil, nil end
    local best, bestSpell
    local producers = rs:GetRecipesProducingItem(itemID)
    for i = 1, #producers do
        local sid = producers[i].spellID
        if not ctx.visiting[sid] and KnownOK(sid, ctx.knownBy) then
            local ev = CraftEVService:Evaluate(sid, {
                useAverage = ctx.useAverage,
                knownBy = ctx.knownBy,
                noLiveOps = ctx.noLiveOps,
                _depth = ctx.depth + 1,
                _visiting = ctx.visiting,
            })
            if ev and ev.tiers then
                for _, row in pairs(ev.tiers) do
                    if not row.conc and row.outputItem == itemID and row.reagentCost and row.yield
                        and row.yield > 0 and #row.missing == 0 then
                        local unit = row.reagentCost / row.yield
                        if not best or unit < best then best, bestSpell = unit, sid end
                    end
                end
            end
        end
    end
    return best, bestSpell
end

--- Cost of one slot fill: min(buy, make).
---@return number|nil copper, string|nil source, number|nil makeSpellID
local function SlotCost(itemID, qty, ctx)
    local mkey = itemID .. "x" .. qty
    local m = ctx.slotMemo[mkey]
    if m then return m[1], m[2], m[3] end
    local buy, src = BuyCostFor(itemID, qty, ctx)
    if ctx.makeVsBuy then
        local unit, sid = MakeUnitCost(itemID, ctx)
        if unit and (not buy or unit * qty < buy) then
            ctx.slotMemo[mkey] = { unit * qty, "make", sid }
            return unit * qty, "make", sid
        end
    end
    ctx.slotMemo[mkey] = { buy, src, nil }
    return buy, src, nil
end

local function OutputItemForTier(sch, tier)
    if tier and type(sch.qualityItemIDs) == "table" and sch.qualityItemIDs[tier] then
        return sch.qualityItemIDs[tier]
    end
    return sch.output and sch.output.itemID or nil
end

--- Price all required slots for an allocation (alloc overrides the cheapest-candidate pick).
--- Returns total, missing itemIDs, make (itemID -> producing spell), used (alloc shape: ModifiedReagent
--- dataSlotIndex -> itemID), picks (slot position -> itemID, every priced slot) and bound
--- ({ itemID, qty } for slots whose every candidate is soulbound / quest-bound and has no make cost:
--- they can never be bought, so they are listed instead of making the whole recipe "unpriced").
local function PriceSlots(slots, alloc, resPct, resSave, ctx)
    local total, missing, make, used, picks, bound = 0, {}, {}, {}, {}, {}
    for i = 1, #slots do
        local slot = slots[i]
        -- Allocations are keyed by dataSlotIndex of the ModifiedReagent slots sent to the server; a
        -- plain Reagent slot can share that number, so only passToOperation slots read them.
        local chosen = slot.passToOperation and slot.dataSlotIndex and alloc and alloc[slot.dataSlotIndex]
        local cost, itemID, makeSpell
        if chosen then
            local c0, _src0, ms0 = SlotCost(chosen, slot.qty, ctx)
            cost, makeSpell = c0, ms0
            itemID = chosen
        else
            for ci = 1, #slot.candidates do
                local cand = slot.candidates[ci]
                local c, _src, ms = SlotCost(cand, slot.qty, ctx)
                if c and (not cost or c < cost) then cost, itemID, makeSpell = c, cand, ms end
            end
            itemID = itemID or slot.candidates[1]
        end
        if cost then
            if resPct > 0 and itemID and IsTradeable(itemID) then
                cost = cost * (1 - resPct * resSave)
            end
            total = total + cost
            if makeSpell then make[itemID] = makeSpell end
            if itemID then
                picks[i] = itemID
                if slot.passToOperation and slot.dataSlotIndex then used[slot.dataSlotIndex] = itemID end
            end
        elseif itemID then
            local allBound = #slot.candidates > 0
            for ci = 1, #slot.candidates do
                local bt = tonumber((select(14, GetItemInfo(slot.candidates[ci]))))
                if not (bt and UNTRADEABLE_BIND[bt]) then
                    allBound = false
                    break
                end
            end
            if allBound then
                bound[#bound + 1] = { itemID = itemID, qty = slot.qty }
            else
                missing[#missing + 1] = itemID
            end
        end
        -- Currency-only slots (no item candidate) carry no gold price and are not "missing".
    end
    return total, missing, make, used, picks, bound
end

--- Tiers from a stored snapshot. Non-concentration winners are re-derived from the stored combos at
--- today's prices; concentration rows stay anchored to what SampleRecipe confirmed (verified rows,
--- reached-tier re-keying, hasConc = false), and only unverified rows take today's cheaper combo.
local function SnapshotTiers(snap, sch, costFn)
    local cos = ns.CraftOpsService
    local stored = snap.concTiers or {}
    if snap.hasConc == false then stored = {} end
    if not (snap.combos and snap.qslots and cos and cos.TiersFromCombos) then
        return snap.tiers or {}, stored
    end
    local cap = cos.TierCap and cos:TierCap(sch, snap.maxQuality) or snap.maxQuality
    local tiers, derived = cos:TiersFromCombos(snap.combos, snap.qslots, cap, costFn)
    local concTiers = {}
    for tier, srow in pairs(stored) do
        local d = derived[tier]
        if d and not srow.verified then
            d.ingenuityRefund = d.ingenuityRefund or srow.ingenuityRefund
            concTiers[tier] = d
        else
            concTiers[tier] = srow
        end
    end
    return tiers, concTiers
end

local function FallbackTiers(spellID, sch, noLiveOps)
    local rs = ns.RecipeService
    local tiers, concTiers, stats = {}, {}, nil
    -- Blizzard only asks for operation info when the schematic says it has one.
    -- noLiveOps (tooltips): never call GetCraftingOperationInfo from a hover.
    local op = not noLiveOps and sch.hasCraftingOperationInfo == true and rs and rs.GetCraftingOperation
        and rs:GetCraftingOperation(spellID, false) or nil
    if op then
        local t = math.max(1, tonumber(op.craftingQuality) or 1)
        tiers[t] = { conc = false, concCost = tonumber(op.concentrationCost) or 0 }
        if ns.CraftOpsService and ns.CraftOpsService.ParseBonusStats then
            stats = ns.CraftOpsService:ParseBonusStats(op.bonusStats)
        end
        if (tonumber(op.concentrationCurrencyID) or 0) ~= 0 and (tonumber(op.concentrationCost) or 0) > 0 then
            local cop = rs:GetCraftingOperation(spellID, true)
            local ct = cop and math.max(1, tonumber(cop.craftingQuality) or 1)
            if ct and ct > t then
                concTiers[ct] = { conc = true, concCost = tonumber(op.concentrationCost),
                    ingenuityRefund = tonumber(cop.ingenuityRefund), verified = true }
            end
        end
    else
        tiers[0] = { conc = false } -- tier unknown: price the base output item
    end
    return tiers, concTiers, stats, op ~= nil
end

---@param spellID number
---@param opts table|nil { useAverage?, useOwned?, knownBy? ("me"|"any"), guid?, makeVsBuy? (override config) }
---@return table|nil ev { spellID, profession, tiers = {[tier]=row}, concTiers = {[tier]=row}, bestNoConc, bestConc,
---   stats, factors, factorsSource, missing = itemID[], confidence, basis = "ops"|"fallback", baseYield, stackable,
---   snapshotGuid, snapshotAt }
---   row = { tier, conc, outputItem, unitPrice, fromHistory, yield, revenueGross, revenueNet, reagentCost, profit,
---           concCost, effConc, gpc, profitAfterConc, alloc, makeReagents = {[itemID]=spellID}, missing, verified }
function CraftEVService:Evaluate(spellID, opts)
    spellID = tonumber(spellID)
    opts = opts or {}
    local rs = ns.RecipeService
    local econ = ns.Economy
    if not spellID or not rs or not econ then return nil end
    local sch = rs:GetSchematic(spellID)
    if not sch or type(sch.reagents) ~= "table" or #sch.reagents < 1 then return nil end

    local depth = tonumber(opts._depth) or 0
    local cfg = econ:Config()
    local makeVsBuy = opts.makeVsBuy
    if makeVsBuy == nil then makeVsBuy = cfg.makeVsBuy ~= false end
    local key = table.concat({ spellID, opts.useAverage and 1 or 0, opts.useOwned and 1 or 0,
        tostring(opts.knownBy), tostring(opts.guid), makeVsBuy and 1 or 0, depth,
        opts.noLiveOps and 1 or 0 }, ":")
    -- Nested (make-vs-buy) results depend on the caller's cycle-guard set, which the key does not
    -- capture: only top-level evaluations are memoized.
    if depth == 0 then
        local hit = MemoGet(key)
        if hit ~= nil then return hit or nil end
    end

    local visiting = opts._visiting or {}
    if visiting[spellID] then return nil end
    visiting[spellID] = true

    local profession = sch.profession or rs:GetProfession(spellID)
    local ctx = {
        useAverage = opts.useAverage == true,
        useOwned = opts.useOwned == true,
        bagCounts = (opts.useOwned and not rs.GetStockByLocation) and rs:GetBagCounts() or nil,
        stockFn = (opts.useOwned and rs.GetStockByLocation)
            and function(itemID) return rs:GetStockByLocation(itemID).total end or nil,
        knownBy = opts.knownBy,
        makeVsBuy = makeVsBuy,
        noLiveOps = opts.noLiveOps == true,
        depth = depth,
        visiting = visiting,
        slotMemo = {},
    }

    local snap, snapGuid
    if ns.CraftOpsService and ns.CraftOpsService.GetSnapshot then
        snap, snapGuid = ns.CraftOpsService:GetSnapshot(spellID, opts.guid)
    end
    local tiers, concTiers, stats, basis, liveOp
    if snap then
        -- Rank mix per tier: the cheapest stored combo priced exactly like the profit below (owned
        -- stock, price basis, make-vs-buy, Resourcefulness), not by raw AH buy cost.
        local snapStats = snap.stats or {}
        local f0 = econ:ProcFactors(spellID, profession)
        local slots0 = rs:GetRequiredBasicSlots(spellID)
        local res0, save0 = tonumber(snapStats.resourcefulness) or 0, tonumber(f0.resourcefulnessSave) or 0
        local function costFn(alloc)
            local total, missing = PriceSlots(slots0, alloc, res0, save0, ctx)
            if #missing > 0 then return math.huge end
            return total
        end
        tiers, concTiers = SnapshotTiers(snap, sch, costFn)
        stats = snap.stats
        basis = "ops"
    else
        tiers, concTiers, stats, liveOp = FallbackTiers(spellID, sch, opts.noLiveOps == true)
        basis = "fallback"
    end
    stats = stats or { multicraft = 0, resourcefulness = 0, ingenuity = 0 }

    local factors = econ:ProcFactors(spellID, profession)
    local flags = rs.GetRecipeFlags and rs:GetRecipeFlags(spellID) or {}
    local qmin = (snap and snap.baseQtyMin) or (sch.output and tonumber(sch.output.quantityMin)) or 1
    local qmax = (snap and snap.baseQtyMax) or (sch.output and tonumber(sch.output.quantityMax)) or qmin
    local baseYield = (qmin + qmax) / 2
    local stackable = not (flags.hasSingleItemOutput or flags.isEnchantingRecipe or flags.hasQualityIlvlBonuses)
    local outID = sch.output and sch.output.itemID
    local isStack = IsStackableItem(outID)
    if stackable and isStack == false then
        stackable = false
    elseif isStack == nil and outID and C_Item and C_Item.RequestLoadItemDataByID then
        -- Not cached yet: the harvest flags decide this pass; the next evaluation reads the stack size.
        C_Item.RequestLoadItemDataByID(outID)
    end
    local mcPct = stackable and (tonumber(stats.multicraft) or 0) or 0
    local yield = baseYield * (1 + mcPct * (tonumber(factors.multicraftExtra) or 0))
    local resPct = tonumber(stats.resourcefulness) or 0
    local resSave = tonumber(factors.resourcefulnessSave) or 0
    local ingPct = tonumber(stats.ingenuity) or 0
    local ingRefund = tonumber(factors.ingenuityRefund) or 0
    local concValue = econ:ConcentrationValue(profession) or 0

    local slots = rs:GetRequiredBasicSlots(spellID)
    local allMissing, missingSeen = {}, {}
    local allBound, boundSeen = {}, {}

    local function BuildRow(tier, src, conc)
        local cost, missing, make, used, picks, bound = PriceSlots(slots, src.alloc, resPct, resSave, ctx)
        for i = 1, #bound do
            if not boundSeen[bound[i].itemID] then
                boundSeen[bound[i].itemID] = true
                allBound[#allBound + 1] = bound[i]
            end
        end
        -- Each quality tier is its own item: an unpriced tier stays unpriced (pricing it with the base
        -- output's price would value a rank-2 craft at the rank-1 price, or the other way round).
        local item = OutputItemForTier(sch, tier > 0 and tier or nil)
        local unit, fromHistory = OutputUnitPrice(item, ctx.useAverage)
        local saleUnit = unit and econ:SaleUnitPrice(unit) or nil
        for i = 1, #missing do
            if not missingSeen[missing[i]] then
                missingSeen[missing[i]] = true
                allMissing[#allMissing + 1] = missing[i]
            end
        end
        local row = {
            tier = tier > 0 and tier or nil,
            conc = conc,
            outputItem = item,
            unitPrice = unit,
            fromHistory = fromHistory,
            yield = yield,
            revenueGross = saleUnit and saleUnit * yield or nil,
            revenueNet = saleUnit and econ:NetSaleValue(item, saleUnit, yield) or nil,
            reagentCost = cost,
            alloc = used,
            slotPicks = picks,
            boundReagents = bound,
            makeReagents = make,
            missing = missing,
            verified = src.verified,
        }
        -- An unpriced reagent is left out of `cost`, so a profit over it would be inflated: no data.
        if row.revenueNet and #missing == 0 then row.profit = row.revenueNet - cost end
        if conc then
            row.concCost = tonumber(src.concCost) or 0
            -- Ingenuity refunds CraftingOperationInfo.ingenuityRefund concentration points on a proc
            -- (Blizzard PROFESSIONS_OUTPUT_INGENUITY_DESC "refunded %d Concentration"; TradeSkillUITypes
            -- 12.1.5.70448, checked 2026-10-17). Without the server value, the configured factor.
            -- The operation-info field has no documented unit; a value below 1 can only be a share.
            local refundPts = tonumber(src.ingenuityRefund)
            if refundPts and refundPts >= 1 then
                row.effConc = math.max(0, row.concCost - ingPct * math.min(refundPts, row.concCost))
            elseif refundPts and refundPts > 0 then
                row.effConc = row.concCost * (1 - ingPct * refundPts)
            else
                row.effConc = row.concCost * (1 - ingPct * ingRefund)
            end
        end
        return row
    end

    local ev = {
        spellID = spellID,
        profession = profession,
        tiers = {},
        concTiers = {},
        stats = stats,
        factors = factors,
        factorsSource = factors.source,
        missing = allMissing,
        boundReagents = allBound,
        basis = basis,
        baseYield = baseYield,
        stackable = stackable,
        snapshotGuid = snapGuid,
        snapshotAt = snap and snap.at or nil,
    }

    for tier, src in pairs(tiers) do
        local row = BuildRow(tier, src, false)
        ev.tiers[row.tier or 0] = row
        if row.profit and (not ev.bestNoConc or row.profit > ev.bestNoConc.profit) then
            ev.bestNoConc = row
        elseif not ev.bestNoConc and not row.profit then
            ev._anyNoConc = ev._anyNoConc or row
        end
    end
    ev.bestNoConc = ev.bestNoConc or ev._anyNoConc
    ev._anyNoConc = nil

    local baseProfit = ev.bestNoConc and ev.bestNoConc.profit
    for tier, src in pairs(concTiers) do
        local row = BuildRow(tier, src, true)
        if row.profit and baseProfit and row.effConc and row.effConc > 0 then
            row.gpc = (row.profit - baseProfit) / row.effConc
        end
        if row.profit and row.effConc then
            row.profitAfterConc = row.profit - row.effConc * concValue
        end
        ev.concTiers[tier] = row
        if not ev.tiers[tier] then ev.tiers[tier] = row end
        local best = ev.bestConc
        if row.gpc and row.gpc > 0 and (not best or not best.gpc or row.gpc > best.gpc) then
            ev.bestConc = row
        elseif not best and row.profit then
            ev.bestConc = row
        end
    end

    local fresh, stale, singleListing = false, false, false
    local outItem = ev.bestNoConc and ev.bestNoConc.outputItem
    if outItem and ns.AHPriceService and ns.AHPriceService.GetPriceInfo then
        local _, _, isFresh, isStale, src = ns.AHPriceService:GetPriceInfo(outItem)
        fresh, stale = isFresh == true, isStale == true
        -- A non-commodity price from AN's scan is one listing (qsrc "i"), not market depth.
        local row = src == "an" and econ.GetMarketRow and econ:GetMarketRow(outItem)
        singleListing = type(row) == "table" and row.qsrc == "i"
    end
    -- A snapshot taken on another character carries that character's skill, stats, gear and
    -- specialization: usable as an estimate, never "high".
    local me = ns.Utilities and ns.Utilities.GetCharacterGUID and ns.Utilities:GetCharacterGUID() or nil
    ev.snapshotFromAlt = snapGuid ~= nil and me ~= nil and snapGuid ~= me
    if #allMissing > 0 or not (ev.bestNoConc and ev.bestNoConc.unitPrice) or stale then
        ev.confidence = "low"
    elseif basis == "ops" and fresh and not singleListing and not ev.snapshotFromAlt and #allBound == 0 then
        ev.confidence = "high"
    else
        ev.confidence = "medium"
    end
    ev.liveOperation = liveOp

    visiting[spellID] = nil
    if depth == 0 then MemoSet(key, ev) end
    return ev
end

ns.CraftEVService = CraftEVService
