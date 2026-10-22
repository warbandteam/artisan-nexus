--[[
    Artisan Nexus — Craft ledger (realized craft outcomes + proc calibration).

    Every craft operation is recorded once, after its result events settle:
      db.global.craftLedger = {
        rows = { { t, guid, spellID?, profession?, outputs = { {itemID, qty, quality?}, ... },
                   baseQty, multicraft?, qtyMin?, qtyMax?, resourcesReturned? = { {itemID?, currencyID?, qty} },
                   concentrationSpent?, hasIngenuityProc?, ingenuityRefund?, firstCraftReward?,
                   rewards? = { {itemID?|currencyID?, qty} }, isEnchant?,
                   cost?, costMissing?, returnedValue?, value?, net?,
                   evCost?, evRevenue?, evProfit?, order? (crafting-order craft: not valued) }, ... } -- oldest first, capped
        cost = gross reagent cost (RecipeService:EstimateReagentCost); ev* = CraftEVService:Evaluate
        expectations at craft time (proc-adjusted), kept for predicted-vs-realized.
        cal  = { spell = { [spellID] = Stats }, prof = { [profession] = Stats } }
      }
      Stats = { n, mcProcs, mcSum, resProcs, resSum, ingN, ingProcs, ingSum }

    Facts (verified 2026-10-14, TradeSkillUITypesDocumentation.lua 12.1.5.70391):
      CraftingItemResultData { itemID, quantity, multicraft, bonusCraft, operationID, firstCraftReward,
        resourcesReturned? (CraftingResourceReturnInfo { reagent {itemID?, currencyID?}, quantity }),
        concentrationSpent, hasIngenuityProc, ingenuityRefund, craftingQuality?, isEnchant }
      There is no resourcefulness flag; a proc shows up as a non-nil resourcesReturned.
      CraftingCurrencyResultData { currencyID, quantity, operationID, firstCraftReward, showCurrencyText }
    Pattern (verified 2026-10-14, Blizzard_ProfessionsCraftingOutputLog.lua): results sharing an
    operationID belong to one craft; Blizzard waits 0.35 s for the server to finish sending them.
    UNVERIFIED: whether concentrationSpent is gross or net of the ingenuity refund (we use
    refund / spent, capped at 1).
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS

local CraftLedgerService = { _enabled = false }

local LEDGER_CAP = 3000
--- Trim in batches so the ring buffer is not shifted on every insert.
local LEDGER_TRIM_SLACK = 100
local SETTLE_SECONDS = 0.35
--- A long multi-cast keeps resetting the settle timer; force a flush after this long.
local SETTLE_MAX_SECONDS = 3
local MIN_SPELL_SAMPLES = 20
local MIN_PROFESSION_SAMPLES = 50
--- Halve accumulated calibration once a bucket exceeds this many crafts (keeps it adaptive).
local CALIBRATION_DECAY_AT = 2000

local function Store()
    local g = ns.db and ns.db.global
    if not g then return nil end
    local s = g.craftLedger
    if type(s) ~= "table" then
        s = {}
        g.craftLedger = s
    end
    if type(s.rows) ~= "table" then s.rows = {} end
    if type(s.cal) ~= "table" then s.cal = {} end
    if type(s.cal.spell) ~= "table" then s.cal.spell = {} end
    if type(s.cal.prof) ~= "table" then s.cal.prof = {} end
    return s
end

local function Price(itemID)
    local svc = ns.AHPriceService
    if not itemID or not svc or not svc.GetPrice then return nil end
    local p = svc:GetPrice(itemID)
    p = tonumber(p)
    if p and p > 0 then return p end
    return nil
end

---------------------------------------------------------------------------
-- Pending operations (settle window)
---------------------------------------------------------------------------

local pending = {}        -- [opKey] = { first, results = {}, currencies = {}, pendingSpellID }
local pendingOrder = {}   -- opKeys in arrival order
local syntheticSeq = 0
local settleGen = 0
local settleStartedAt = nil

local function OpKey(opID)
    opID = tonumber(opID) or 0
    if opID == 0 then
        -- Blizzard treats a missing operationID as its own parent; do the same.
        syntheticSeq = syntheticSeq + 1
        return "x" .. syntheticSeq
    end
    return opID
end

local function GetOp(key, pendingSpellID)
    local op = pending[key]
    if not op then
        op = { first = time(), results = {}, currencies = {}, pendingSpellID = pendingSpellID }
        pending[key] = op
        pendingOrder[#pendingOrder + 1] = key
    elseif not op.pendingSpellID then
        op.pendingSpellID = pendingSpellID
    end
    return op
end

local ScheduleSettle -- forward

---------------------------------------------------------------------------
-- Calibration
---------------------------------------------------------------------------

local function NewStats()
    return { n = 0, mcProcs = 0, mcSum = 0, resProcs = 0, resSum = 0, ingN = 0, ingProcs = 0, ingSum = 0 }
end

local function DecayStats(st)
    if (st.n or 0) <= CALIBRATION_DECAY_AT then return end
    for k, v in pairs(st) do
        if type(v) == "number" then st[k] = v / 2 end
    end
end

local function ApplyStats(st, sample)
    st.n = (st.n or 0) + 1
    if sample.mcFrac then
        st.mcProcs = (st.mcProcs or 0) + 1
        st.mcSum = (st.mcSum or 0) + sample.mcFrac
    end
    if sample.resFrac then
        st.resProcs = (st.resProcs or 0) + 1
        st.resSum = (st.resSum or 0) + sample.resFrac
    end
    if sample.usedConcentration then
        st.ingN = (st.ingN or 0) + 1
        if sample.ingFrac then
            st.ingProcs = (st.ingProcs or 0) + 1
            st.ingSum = (st.ingSum or 0) + sample.ingFrac
        end
    end
    DecayStats(st)
end

--- Quantity of the mandatory reagent slot that holds itemID (any quality-tier candidate).
local function ConsumedSlotQty(spellID, itemID)
    local rs = ns.RecipeService
    if not spellID or not itemID or not rs or not rs.GetMandatorySlots then return nil end
    local slots = rs:GetMandatorySlots(spellID, true)
    for si = 1, #slots do
        local slot = slots[si]
        for ci = 1, #slot.candidates do
            if tonumber(slot.candidates[ci].itemID) == itemID then
                local q = tonumber(slot.qty)
                if q and q > 0 then return q end
            end
        end
    end
    return nil
end

local function BuildSample(row)
    local sample = {}
    local base = tonumber(row.baseQty) or 0
    local mc = tonumber(row.multicraft) or 0
    if mc > 0 and base > 0 then
        sample.mcFrac = mc / base
    end
    if type(row.resourcesReturned) == "table" and #row.resourcesReturned > 0 then
        local sum, k = 0, 0
        for i = 1, #row.resourcesReturned do
            local r = row.resourcesReturned[i]
            local slotQty = r.itemID and ConsumedSlotQty(row.spellID, r.itemID)
            if slotQty then
                sum = sum + math.min(1, (tonumber(r.qty) or 0) / slotQty)
                k = k + 1
            end
        end
        if k > 0 then
            sample.resFrac = sum / k
        end
    end
    local spent = tonumber(row.concentrationSpent) or 0
    if spent > 0 then
        sample.usedConcentration = true
        local refund = tonumber(row.ingenuityRefund) or 0
        if row.hasIngenuityProc and refund > 0 then
            sample.ingFrac = math.min(1, refund / spent)
        end
    end
    return sample
end

local function UpdateCalibration(store, row)
    if not row.spellID then return end
    local sample = BuildSample(row)
    local spell = store.cal.spell[row.spellID]
    if type(spell) ~= "table" then
        spell = NewStats()
        store.cal.spell[row.spellID] = spell
    end
    ApplyStats(spell, sample)
    if row.profession then
        local prof = store.cal.prof[row.profession]
        if type(prof) ~= "table" then
            prof = NewStats()
            store.cal.prof[row.profession] = prof
        end
        ApplyStats(prof, sample)
    end
end

---------------------------------------------------------------------------
-- Finalize
---------------------------------------------------------------------------

local outputDeduper = nil

--- Gross reagent cost of one craft at current prices (the realized side; returned reagents are
--- booked separately as returnedValue).
local function EstimateCost(spellID)
    if not spellID then return nil, nil end
    local rs = ns.RecipeService
    if rs and rs.EstimateReagentCost then
        local cost, missing = rs:EstimateReagentCost(spellID)
        return tonumber(cost), tonumber(missing) or 0
    end
    return nil, nil
end

--- Predicted economics from CraftEVService:Evaluate (expected values: proc-adjusted cost and
--- net revenue) so realized vs predicted can be compared. Memoized per spell for 10 s so a
--- multi-cast does not re-evaluate every operation.
local evMemo = {}
local function PredictedEV(spellID, usedConcentration)
    local ev = ns.CraftEVService
    if not spellID or not ev or not ev.Evaluate then return nil end
    local key = spellID .. (usedConcentration and ":c" or ":n")
    local m = evMemo[key]
    if m and GetTime() - m.at < 10 then return m.row end
    local ok, res = pcall(ev.Evaluate, ev, spellID)
    local row = nil
    if ok and type(res) == "table" then
        -- verified 2026-10-14, Modules/Economy/CraftEVService.lua: bestNoConc / bestConc rows
        -- { reagentCost, revenueNet, profit, ... }.
        local r = (usedConcentration and res.bestConc) or res.bestNoConc or res.bestConc
        if type(r) == "table" then
            row = { cost = tonumber(r.reagentCost), revenueNet = tonumber(r.revenueNet), profit = tonumber(r.profit) }
        end
    end
    evMemo[key] = { at = GetTime(), row = row }
    return row
end

local function BuildRow(op)
    local ces = ns.CraftEventService
    local spellID
    -- Primary results first; first-craft reward items say nothing about the recipe.
    for pass = 1, 2 do
        for i = 1, #op.results do
            local d = op.results[i]
            if (pass == 1) ~= (d.firstCraftReward == true) then
                spellID = ces and ces:ResolveSpellForResult(d, op.pendingSpellID)
                if spellID then break end
            end
        end
        if spellID then break end
    end
    local rs = ns.RecipeService
    local row = {
        t = op.first,
        guid = ns.Utilities and ns.Utilities:GetCharacterGUID() or nil,
        spellID = spellID,
        profession = (spellID and rs and rs.GetProfession) and rs:GetProfession(spellID) or nil,
        outputs = {},
        baseQty = 0,
    }
    local sch = spellID and rs and rs.GetSchematic and rs:GetSchematic(spellID)
    if sch and sch.output then
        row.qtyMin = tonumber(sch.output.quantityMin)
        row.qtyMax = tonumber(sch.output.quantityMax)
    end

    if not outputDeduper and ces then
        outputDeduper = ces:CreateOutputDeduper()
    end
    local outByKey, returned, rewards = {}, {}, {}
    local mcTotal, spent, refund = 0, 0, 0
    for i = 1, #op.results do
        local d = op.results[i]
        local itemID = ces and ces:GetResultItemID(d)
        if d.firstCraftReward then
            if itemID then
                rewards[#rewards + 1] = { itemID = itemID, qty = tonumber(d.quantity) or 1 }
            end
            row.firstCraftReward = true
        elseif itemID and outputDeduper then
            local credit, extra = outputDeduper:Credit(d, spellID)
            if credit and credit > 0 then
                local q = tonumber(d.craftingQuality)
                local key = itemID .. ":" .. (q or 0)
                local o = outByKey[key]
                if not o then
                    o = { itemID = itemID, qty = 0, quality = q }
                    outByKey[key] = o
                    row.outputs[#row.outputs + 1] = o
                end
                o.qty = o.qty + credit
                mcTotal = mcTotal + (extra or 0)
                row.baseQty = row.baseQty + (credit - (extra or 0))
            end
        end
        if d.isEnchant then row.isEnchant = true end
        if type(d.resourcesReturned) == "table" then
            for j = 1, #d.resourcesReturned do
                local r = d.resourcesReturned[j]
                local reagent = type(r) == "table" and r.reagent
                if type(reagent) == "table" then
                    returned[#returned + 1] = {
                        itemID = tonumber(reagent.itemID),
                        currencyID = tonumber(reagent.currencyID),
                        qty = tonumber(r.quantity) or 0,
                    }
                end
            end
        end
        -- Fields repeat on every result of the operation; take the max, never the sum.
        spent = math.max(spent, tonumber(d.concentrationSpent) or 0)
        refund = math.max(refund, tonumber(d.ingenuityRefund) or 0)
        if d.hasIngenuityProc then row.hasIngenuityProc = true end
    end
    for i = 1, #op.currencies do
        local c = op.currencies[i]
        rewards[#rewards + 1] = { currencyID = tonumber(c.currencyID), qty = tonumber(c.quantity) or 0 }
        if c.firstCraftReward then row.firstCraftReward = true end
    end
    if mcTotal > 0 then row.multicraft = mcTotal end
    if #returned > 0 then row.resourcesReturned = returned end
    if #rewards > 0 then row.rewards = rewards end
    if spent > 0 then row.concentrationSpent = spent end
    if refund > 0 then row.ingenuityRefund = refund end

    -- Crafting-order craft: the customer supplied (part of) the reagents and receives the item, so it
    -- is neither our cost nor our output value; the tip is booked by SalesLedgerService.
    if op.orderSpellID and spellID and spellID == op.orderSpellID then
        row.order = true
        return row
    end

    -- Valuation at craft time.
    local cost, missing = EstimateCost(spellID)
    if cost then
        row.cost = cost
        if missing and missing > 0 then row.costMissing = missing end
    end
    local rv = 0
    for i = 1, #returned do
        local p = returned[i].itemID and Price(returned[i].itemID)
        if p then rv = rv + p * returned[i].qty end
    end
    if rv > 0 then row.returnedValue = rv end
    local pred = PredictedEV(spellID, spent > 0)
    if pred then
        row.evCost, row.evRevenue, row.evProfit = pred.cost, pred.revenueNet, pred.profit
    end
    local value, net, priced = 0, 0, false
    local econ = ns.Economy
    for i = 1, #row.outputs do
        local o = row.outputs[i]
        local p = Price(o.itemID)
        if p then
            priced = true
            value = value + p * o.qty
            if econ and econ.NetSaleValue then
                net = net + econ:NetSaleValue(o.itemID, p, o.qty)
            else
                net = net + p * o.qty
            end
        end
    end
    if priced then
        row.value = value
        row.net = math.floor(net + 0.5)
    end
    return row
end

local function TrimRows(rows)
    if #rows <= LEDGER_CAP + LEDGER_TRIM_SLACK then return end
    local drop = #rows - LEDGER_CAP
    local keep = {}
    for i = drop + 1, #rows do
        keep[#keep + 1] = rows[i]
    end
    wipe(rows)
    for i = 1, #keep do rows[i] = keep[i] end
end

local function FinalizePending()
    settleStartedAt = nil
    local store = Store()
    local order = pendingOrder
    local ops = pending
    pending, pendingOrder = {}, {}
    if not store then return end
    local added = 0
    for i = 1, #order do
        local op = ops[order[i]]
        if op and (#op.results > 0 or #op.currencies > 0) then
            -- One malformed result must not drop the rest of the batch.
            local ok, row = pcall(BuildRow, op)
            if ok and row and (#row.outputs > 0 or row.rewards) then
                store.rows[#store.rows + 1] = row
                if #row.outputs > 0 and not row.order then
                    pcall(UpdateCalibration, store, row)
                end
                added = added + 1
            end
        end
    end
    TrimRows(store.rows)
    if added > 0 and ns.ArtisanNexus and ns.ArtisanNexus.SendMessage and E and E.CRAFT_LEDGER_UPDATED then
        ns.ArtisanNexus:SendMessage(E.CRAFT_LEDGER_UPDATED, added)
    end
end

ScheduleSettle = function()
    settleGen = settleGen + 1
    local myGen = settleGen
    local now = GetTime()
    settleStartedAt = settleStartedAt or now
    local wait = SETTLE_SECONDS
    if now - settleStartedAt >= SETTLE_MAX_SECONDS then
        wait = 0
    end
    C_Timer.After(wait, function()
        if myGen == settleGen then
            FinalizePending()
        end
    end)
end

--- Spell of the crafting order the player has claimed (nil when none).
--- C_CraftingOrders.GetClaimedOrder() -> CraftingOrderInfo? { spellID, ... } (verified 2026-10-15,
--- CraftingOrderUIDocumentation.lua / CraftingOrderUISharedDocumentation.lua 12.1.5).
local function ClaimedOrderSpell()
    if not (C_CraftingOrders and C_CraftingOrders.GetClaimedOrder) then return nil end
    local ok, order = pcall(C_CraftingOrders.GetClaimedOrder)
    if ok and type(order) == "table" then return tonumber(order.spellID) end
    return nil
end

local function OnCraftResult(data, pendingSpellID)
    if not CraftLedgerService._enabled or type(data) ~= "table" then return end
    local op = GetOp(OpKey(data.operationID), pendingSpellID)
    op.orderSpellID = op.orderSpellID or ClaimedOrderSpell()
    op.results[#op.results + 1] = data
    ScheduleSettle()
end

local function OnCurrencyResult(data, pendingSpellID)
    if not CraftLedgerService._enabled or type(data) ~= "table" then return end
    local opID = tonumber(data.operationID) or 0
    -- A currency reward without operationID cannot be paired with a craft; ignore it.
    if opID == 0 then return end
    local op = GetOp(opID, pendingSpellID)
    op.currencies[#op.currencies + 1] = data
    ScheduleSettle()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

local function StatMean(st, procsKey, sumKey, minSamples)
    local procs = st and tonumber(st[procsKey]) or 0
    if procs >= minSamples and procs > 0 then
        return (tonumber(st[sumKey]) or 0) / procs, procs
    end
    return nil, procs
end

--- Observed proc factors. Only stats backed by enough procs are returned:
--- >= 20 for the recipe, else >= 50 for the profession.
---   multicraftExtra      mean extra units per multicraft proc / base units
---   resourcefulnessSave  mean share of a returned slot's quantity per resourcefulness proc
---   ingenuityRefund      mean ingenuityRefund / concentrationSpent per ingenuity proc
---@param spellID number|nil
---@param profession string|nil (derived from spellID when nil)
---@return table { multicraftExtra?, resourcefulnessSave?, ingenuityRefund?,
---   samples = { mc, res, ing }, rates = { mc?, res?, ing? }, crafts, scope = { mc?, res?, ing? } }
function CraftLedgerService:GetCalibration(spellID, profession)
    local store = Store()
    local out = { samples = { mc = 0, res = 0, ing = 0 }, rates = {}, scope = {}, crafts = 0 }
    if not store then return out end
    spellID = tonumber(spellID)
    if not profession and spellID and ns.RecipeService and ns.RecipeService.GetProfession then
        profession = ns.RecipeService:GetProfession(spellID)
    end
    local s = spellID and store.cal.spell[spellID]
    local p = profession and store.cal.prof[profession]

    local function Pick(field, procsKey, sumKey, nKey, sampleKey)
        local v, n = StatMean(s, procsKey, sumKey, MIN_SPELL_SAMPLES)
        local src, st = "spell", s
        if not v then
            local pv, pn = StatMean(p, procsKey, sumKey, MIN_PROFESSION_SAMPLES)
            if pv then
                v, n, src, st = pv, pn, "profession", p
            end
        end
        out.samples[sampleKey] = n or 0
        if v then
            out[field] = v
            out.scope[sampleKey] = src
            local denom = tonumber(st[nKey]) or 0
            if denom > 0 then
                out.rates[sampleKey] = (tonumber(st[procsKey]) or 0) / denom
            end
        end
    end
    Pick("multicraftExtra", "mcProcs", "mcSum", "n", "mc")
    Pick("resourcefulnessSave", "resProcs", "resSum", "n", "res")
    Pick("ingenuityRefund", "ingProcs", "ingSum", "ingN", "ing")
    out.crafts = (s and tonumber(s.n)) or 0
    return out
end

--- Totals over the last `days` (all characters).
---@param days number|nil default 7
---@return table { crafts, orderCrafts (crafting-order crafts, not valued), value, net, cost, returnedValue, profit, unpriced, concentrationSpent,
---   predictedRevenue, predictedProfit, predictedCrafts (rows with a CraftEV prediction),
---   ingenuityRefund, procs = { mc, res, ing }, byProfession = { [prof] = { crafts, value, net, cost } } }
--- Craft rows newest first (stored tables; read-only), crafting-order crafts excluded (not valued).
--- Realized profit of a row = net - cost + returnedValue (nil parts when unpriced).
---@param days number|nil default 7
---@return table[]
function CraftLedgerService:GetCrafts(days)
    local since = time() - (tonumber(days) or 7) * 86400
    local out = {}
    local store = Store()
    if not store then return out end
    local rows = store.rows
    for i = #rows, 1, -1 do
        local r = rows[i]
        if (tonumber(r.t) or 0) < since then break end
        if not r.order then out[#out + 1] = r end
    end
    return out
end

function CraftLedgerService:GetSummary(days)
    days = tonumber(days) or 7
    local since = time() - days * 86400
    local sum = {
        crafts = 0, orderCrafts = 0, value = 0, net = 0, cost = 0, returnedValue = 0, profit = 0, unpriced = 0,
        predictedRevenue = 0, predictedProfit = 0, predictedCrafts = 0,
        concentrationSpent = 0, ingenuityRefund = 0,
        procs = { mc = 0, res = 0, ing = 0 },
        byProfession = {},
    }
    local store = Store()
    if not store then return sum end
    local rows = store.rows
    for i = #rows, 1, -1 do
        local r = rows[i]
        if (tonumber(r.t) or 0) < since then break end
        if r.order then
            sum.orderCrafts = sum.orderCrafts + 1
        elseif #(r.outputs or {}) > 0 then
            sum.crafts = sum.crafts + 1
            sum.value = sum.value + (r.value or 0)
            sum.net = sum.net + (r.net or 0)
            sum.cost = sum.cost + (r.cost or 0)
            sum.returnedValue = sum.returnedValue + (r.returnedValue or 0)
            if not r.value or not r.cost then sum.unpriced = sum.unpriced + 1 end
            if r.evProfit then
                sum.predictedCrafts = sum.predictedCrafts + 1
                sum.predictedRevenue = sum.predictedRevenue + (r.evRevenue or 0)
                sum.predictedProfit = sum.predictedProfit + r.evProfit
            end
            sum.concentrationSpent = sum.concentrationSpent + (r.concentrationSpent or 0)
            sum.ingenuityRefund = sum.ingenuityRefund + (r.ingenuityRefund or 0)
            if r.multicraft then sum.procs.mc = sum.procs.mc + 1 end
            if r.resourcesReturned then sum.procs.res = sum.procs.res + 1 end
            if r.hasIngenuityProc then sum.procs.ing = sum.procs.ing + 1 end
            local key = r.profession or "?"
            local bp = sum.byProfession[key]
            if not bp then
                bp = { crafts = 0, value = 0, net = 0, cost = 0 }
                sum.byProfession[key] = bp
            end
            bp.crafts = bp.crafts + 1
            bp.value = bp.value + (r.value or 0)
            bp.net = bp.net + (r.net or 0)
            bp.cost = bp.cost + (r.cost or 0)
        end
    end
    -- Realized-at-market profit: net sale value - reagent cost + value of returned reagents.
    sum.profit = sum.net - sum.cost + sum.returnedValue
    return sum
end

function CraftLedgerService:Enable()
    if self._enabled then return end
    local ces = ns.CraftEventService
    if not ces then return end
    self._enabled = true
    -- CraftEventService has no unregister; register once and gate on _enabled.
    if not self._registered then
        self._registered = true
        ces:RegisterCraftResult(OnCraftResult)
        if ces.RegisterCurrencyResult then
            ces:RegisterCurrencyResult(OnCurrencyResult)
        end
    end
end

function CraftLedgerService:Disable()
    if not self._enabled then return end
    -- Book whatever already arrived before going quiet.
    FinalizePending()
    self._enabled = false
end

ns.CraftLedgerService = CraftLedgerService
