--[[
    Artisan Nexus — Hub tab "crafting": the craft breakdown, shown in the recipe row's tooltip.
    CraftingPage.lua owns the list (WN layout: one column strip, profession group headers, recipe
    rows); this file adds the breakdown lines a row hover shows under the short recipe summary.

    Breakdown (GameTooltip lines, same EV the list shows; CraftEVService memoizes per frame):
      Reagents       one line per required slot: icon, name x per-craft qty, total (or "no price").
                     Allocation = CraftEVService bestNoConc.alloc (cheapest mix reaching the tier),
                     slots = RecipeService:GetRequiredBasicSlots, prices = Economy:BuyCost / 7-day
                     average (same basis as the list), "Made" = make-vs-buy unit cost.
      Result         yield (Multicraft), gross sale, AH cut, deposit loss, net sale, reagent cost
                     (Resourcefulness), profit.
      Concentration  profit with concentration, gold per point, worth it (planner / your value).
      Footer         confidence, basis, proc factor source; missing prices in red.

    Adds to ns.HubCrafting (created by CraftingPage.lua):
      AddBreakdown(tooltip, row, opts)    opts = { useAverage, knownBy }
      AddStock(tooltip, row)              have / need per slot by location (bags, bank, warband
                                          bank, Warband Nexus alts) and how many crafts that covers
      OutputItem(row, opts) -> itemID|nil the evaluated output item (price history)
]]

local ADDON_NAME, ns = ...

local H = ns.HubUI_Internal
local C = ns.HubCrafting
assert(H and C, "CraftingPage.lua must load before CraftingPage_Detail.lua")

local TK = ns.UI_TableKit
local SafeL = H.SafeL
local SafeNumber = H.SafeNumber
local Hex, Dim = H.Ink, H.Dim
local ItemName = ns.GetItemDisplayName
local ItemIcon = ns.GetItemIconFileID

--- Tooltip ink: section heads, labels, values.
local HEAD_R, HEAD_G, HEAD_B = 1, 0.82, 0
local LBL_R, LBL_G, LBL_B = 0.75, 0.75, 0.75
local MAX_REAGENT_LINES = 10

local function Pct(frac)
    return math.floor((SafeNumber(frac) or 0) * 100 + 0.5)
end

-- ─────────────────────────────────────────────────────────────────
-- Reagent pricing (display mirror of CraftEVService BuyCostFor / MakeUnitCost)
-- ─────────────────────────────────────────────────────────────────

local qualityCache = {}

--- Reagent quality tier, cached per item (static data).
local function ReagentQuality(itemID)
    local q = qualityCache[itemID]
    if q == nil then
        q = false
        local fn = C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityByItemInfo
        if fn then
            local ok, rq = pcall(fn, itemID)
            q = (ok and tonumber(rq)) or false
        end
        qualityCache[itemID] = q
    end
    return q or nil
end

--- Unit cost of crafting itemID with makeSpell (cheapest non-concentration tier yielding itemID).
local function MakeUnitCost(itemID, makeSpell, opts)
    local evSvc = ns.CraftEVService
    local ev = evSvc and evSvc:Evaluate(makeSpell, opts)
    if not (ev and ev.tiers) then
        return nil
    end
    local best
    for _, row in pairs(ev.tiers) do
        if not row.conc and row.outputItem == itemID and row.reagentCost and row.yield and row.yield > 0
            and #row.missing == 0 then
            local unit = row.reagentCost / row.yield
            if not best or unit < best then
                best = unit
            end
        end
    end
    return best
end

--- Total cost of qty units and its source tag ("ah" | "vendor" | "made"), same basis as the list.
local function SlotCost(itemID, qty, makeSpell, opts)
    if makeSpell then
        local unit = MakeUnitCost(itemID, makeSpell, opts)
        if unit then
            return unit * qty, "made"
        end
    end
    local vendor = ns.VendorPriceService and ns.VendorPriceService.GetBuyPrice
        and ns.VendorPriceService:GetBuyPrice(itemID)
    if opts.useAverage and ns.PriceHistoryService and ns.PriceHistoryService.GetStats then
        local s = ns.PriceHistoryService:GetStats(itemID)
        if s and s.count and s.count >= 2 and s.avg then
            if vendor and vendor < s.avg then
                return vendor * qty, "vendor"
            end
            return s.avg * qty, "ah"
        end
    end
    local econ = ns.Economy
    if econ and econ.BuyCost then
        local c, src = econ:BuyCost(itemID, qty)
        if c then
            return c, (src == "vendor") and "vendor" or "ah"
        end
    end
    return nil, nil
end

--- Fills `out` with one entry per required Basic slot; returns count and the pre-Resourcefulness sum
--- (nil when any slot has no price).
local function BuildReagents(r, base, opts, out)
    local rs = ns.RecipeService
    local slots = rs and rs.GetRequiredBasicSlots and rs:GetRequiredBasicSlots(r.spellID) or {}
    local bags = rs and rs.GetBagCounts and rs:GetBagCounts() or {}
    local alloc = (base and base.alloc) or {}
    local make = (base and base.makeReagents) or {}
    local n, sum = 0, 0
    for i = 1, #slots do
        local slot = slots[i]
        -- The EV's own pick per slot position; allocations are keyed by ModifiedReagent dataSlotIndex
        -- only, which a plain Reagent slot can share.
        local itemID = (base and base.slotPicks and base.slotPicks[i])
            or (slot.passToOperation and slot.dataSlotIndex and alloc[slot.dataSlotIndex])
            or slot.candidates[1]
        if itemID then
            n = n + 1
            local e = out[n]
            if not e then
                e = {}
                out[n] = e
            end
            local qty = tonumber(slot.qty) or 0
            local total, src = SlotCost(itemID, qty, make[itemID], opts)
            e.itemID, e.qty, e.have = itemID, qty, tonumber(bags[itemID]) or 0
            e.total, e.src, e.makeSpell = total, src, make[itemID]
            e.unit = (total and qty > 0) and (total / qty) or nil
            e.quality = ReagentQuality(itemID)
            if total and sum then
                sum = sum + total
            else
                sum = nil
            end
        end
    end
    for i = n + 1, #out do
        out[i] = nil
    end
    return n, sum
end

--- Worth it: the planner's own allocation wins, else gold per point vs the concentration value.
local function WorthIt(r, conc, base, concValue)
    local delta = (conc.profit and base.profit) and (conc.profit - base.profit) or nil
    if not delta or delta <= 0 then
        return false, SafeL("HUB_CRAFT_WORTH_NO_GAIN", "Concentration does not raise the profit of this craft.")
    end
    local planner = ns.ConcentrationPlannerService
    if planner and planner.IsFunded and planner:IsFunded(r.profession, r.spellID) then
        return true, SafeL("HUB_CRAFT_WORTH_PLAN", "Your plan spends concentration here.")
    end
    if concValue > 0 and conc.gpc then
        if conc.gpc > concValue then
            return true, string.format(SafeL("HUB_CRAFT_WORTH_YES_FMT",
                "%s per point, above your value of %s."), H.Money(conc.gpc, nil, true), H.Money(concValue, nil, true))
        end
        return false, string.format(SafeL("HUB_CRAFT_WORTH_NO_FMT",
            "%s per point, below your value of %s."), H.Money(conc.gpc, nil, true), H.Money(concValue, nil, true))
    end
    return r.recommendConcentration == true, SafeL("HUB_CRAFT_WORTH_UNSET",
        "Set a concentration value in Settings.")
end


-- ─────────────────────────────────────────────────────────────────
-- Tooltip breakdown
-- ─────────────────────────────────────────────────────────────────

local reagents = {}

local function Head(tt, text)
    tt:AddLine(" ")
    tt:AddLine(text, HEAD_R, HEAD_G, HEAD_B)
end

local function Pair(tt, label, value)
    tt:AddDoubleLine(label, value or Dim("-"), LBL_R, LBL_G, LBL_B, 1, 1, 1)
end

local function AddReagents(tt, r, base, opts)
    local n, sum = BuildReagents(r, base, opts, reagents)
    if n == 0 then return sum end
    Head(tt, SafeL("HUB_COL_REAGENTS", "Reagents"))
    for i = 1, math.min(n, MAX_REAGENT_LINES) do
        local e = reagents[i]
        local name = C.IconMarkup(ItemIcon(e.itemID), 14) .. " " .. ItemName(e.itemID)
        if e.quality then
            name = name .. " " .. C.TierBadge(e.quality, 12)
        end
        name = name .. Dim(" x" .. tostring(e.qty))
        local value = e.total and H.Money(e.total, nil, true) or Hex(SafeL("HUB_NO_PRICE", "no price"), "danger")
        if e.src == "made" then
            value = Dim(SafeL("HUB_CRAFT_SRC_MADE", "Made") .. " ") .. value
        elseif e.src == "vendor" then
            value = Dim(SafeL("HUB_CRAFT_SRC_VENDOR", "Vendor") .. " ") .. value
        end
        Pair(tt, name, value)
    end
    if n > MAX_REAGENT_LINES then
        tt:AddLine("...", LBL_R, LBL_G, LBL_B)
    end
    return sum
end

local function AddResult(tt, r, ev, base, preSum)
    Head(tt, SafeL("HUB_CRAFT_SEC_RESULT", "Result"))
    local stats = ev.stats or {}
    local mc = ev.stackable and (SafeNumber(stats.multicraft) or 0) or 0
    local yieldLabel, yieldTxt = SafeL("HUB_TT_YIELD", "Yield"), string.format("%.2f", SafeNumber(base.yield) or 0)
    if mc > 0 then
        yieldLabel = string.format(SafeL("HUB_CRAFT_YIELD_MC_FMT", "Yield (Multicraft %d%%)"), Pct(mc))
        yieldTxt = string.format("%.2f -> %.2f", SafeNumber(ev.baseYield) or 1, SafeNumber(base.yield) or 0)
    end
    Pair(tt, yieldLabel, yieldTxt)
    Pair(tt, SafeL("HUB_TT_GROSS", "Gross sale"), H.Money(base.revenueGross, nil, true))

    local cut, cutSrc = 0, "config"
    local econ = ns.Economy
    if econ and econ.CutRate then
        cut, cutSrc = econ:CutRate()
    end
    local cutLabel = string.format(SafeL("HUB_TT_CUT_FMT", "AH cut (%.1f%%)"), (cut or 0) * 100)
    cutLabel = cutLabel .. " " .. Dim(cutSrc == "observed" and SafeL("HUB_TT_OBSERVED", "observed")
        or SafeL("HUB_TT_CONFIG", "settings"))
    Pair(tt, cutLabel, C.Minus((SafeNumber(base.revenueGross) or 0) * (cut or 0)))
    local item = base.outputItem
    local depLoss = r.depositLoss
    if depLoss == nil and item and econ and econ.ExpectedDepositLossPerUnit then
        depLoss = econ:ExpectedDepositLossPerUnit(item) * (SafeNumber(base.yield) or 1)
    end
    Pair(tt, SafeL("HUB_TT_DEPOSIT_LOSS", "Expected deposit loss"), C.Minus(depLoss))
    Pair(tt, SafeL("HUB_TT_NET", "Net sale"), H.Money(base.revenueNet, nil, true))

    local costLabel = SafeL("HUB_TT_REAGENT_COST", "Reagent cost")
    local res = SafeNumber(stats.resourcefulness) or 0
    if res > 0 then
        local saved = preSum and base.reagentCost and (preSum - base.reagentCost) or nil
        if saved and saved > 0 then
            costLabel = costLabel .. " " .. Dim(string.format(
                SafeL("HUB_CRAFT_RES_SAVED_FMT", "(Resourcefulness %d%%: %s saved)"), Pct(res), H.Money(saved, nil, true)))
        else
            costLabel = costLabel .. " " .. Dim(string.format(SafeL("HUB_TT_RES_FMT", "(Resourcefulness %d%%)"), Pct(res)))
        end
    end
    Pair(tt, costLabel, C.Minus(base.reagentCost))
    Pair(tt, SafeL("HUB_COL_PROFIT", "Profit"), H.Signed(base.profit, true))
end

local function AddConcentration(tt, r, base, conc)
    Head(tt, SafeL("HUB_CRAFT_SEC_CONC", "With concentration"))
    local profTxt = H.Signed(conc.profit, true)
    if conc.profit and base.profit then
        profTxt = profTxt .. " " .. Dim("(" .. TK.FormatSignedMoneyPlain(math.floor(conc.profit - base.profit + 0.5), 12) .. ")")
    end
    Pair(tt, SafeL("HUB_TT_PROFIT_WITH_CONC", "Profit with concentration"), profTxt)
    Pair(tt, SafeL("HUB_TT_GPC", "Gold per concentration"), conc.gpc and H.Money(conc.gpc, nil, true) or Dim("-"))
    local econ = ns.Economy
    local concValue = (econ and econ.ConcentrationValue and econ:ConcentrationValue(r.profession)) or 0
    local yes, why = WorthIt(r, conc, base, concValue)
    Pair(tt, SafeL("HUB_CRAFT_WORTH_IT", "Worth it"), yes and Hex(SafeL("HUB_CRAFT_YES", "Yes"), "success")
        or Hex(SafeL("HUB_CRAFT_NO", "No"), "danger"))
    tt:AddLine(why, LBL_R, LBL_G, LBL_B, true)
end

local function MissingText(ev)
    local m = ev.missing
    if type(m) ~= "table" or #m == 0 then
        return nil
    end
    local names = {}
    for i = 1, math.min(4, #m) do
        names[i] = ItemName(m[i])
    end
    if #m > 4 then
        names[#names + 1] = "..."
    end
    return SafeL("HUB_TT_MISSING_PRICES", "No price for:") .. " " .. table.concat(names, ", ")
end

--- "Not in the cost: 2x Spark of Radiance": soulbound reagents nobody can buy (no make cost either).
local function BoundText(ev)
    local b = ev.boundReagents
    if type(b) ~= "table" or #b == 0 then
        return nil
    end
    local parts = {}
    for i = 1, #b do
        parts[i] = string.format("%dx %s", tonumber(b[i].qty) or 1, ItemName(b[i].itemID))
    end
    return SafeL("HUB_TT_BOUND_NOT_COSTED", "Not in the cost (soulbound, not sold on the AH):") .. " "
        .. table.concat(parts, ", ")
end

local function AddFooter(tt, ev)
    local missing = MissingText(ev)
    if missing then
        tt:AddLine(" ")
        tt:AddLine(missing, 1, 0.4, 0.4, true)
    end
    local bound = BoundText(ev)
    if bound then
        tt:AddLine(" ")
        tt:AddLine(bound, 1, 0.7, 0.3, true)
    end
    tt:AddLine(" ")
    if ev.snapshotFromAlt then
        tt:AddLine(SafeL("HUB_TT_ALT_SNAPSHOT", "Skill and stats come from another character's last scan."), 1, 0.7, 0.3, true)
    end
    tt:AddLine(SafeL("HUB_CRAFT_CONFIDENCE", "Confidence") .. ": "
        .. Hex(C.ConfidenceLabel(ev.confidence), C.CONF_ROLE[ev.confidence] or "danger"), LBL_R, LBL_G, LBL_B)
    tt:AddLine(SafeL("HUB_TT_BASIS", "Basis") .. ": " .. (ev.basis == "ops"
        and SafeL("HUB_CRAFT_BASIS_SCAN", "from your last profession scan") or SafeL("HUB_TT_BASIS_FALLBACK", "estimate"))
        .. "  |  " .. SafeL("HUB_TT_PROC_FACTORS", "Proc factors") .. ": " .. (ev.factorsSource == "observed"
        and SafeL("HUB_TT_OBSERVED", "observed") or SafeL("HUB_TT_CONFIG", "settings")), LBL_R, LBL_G, LBL_B, true)
end

--- "<rank1 badge> x3  <rank2 badge> x2": reagent units per reagent rank in an allocation (quality
--- slots only; a slot uses the allocated item, else its first candidate).
local function RankMixText(slots, row)
    local picks, alloc = row.slotPicks, row.alloc
    local units = {}
    local maxRank = 0
    for i = 1, #slots do
        local slot = slots[i]
        if #slot.candidates > 1 then
            local itemID = (picks and picks[i])
                or (slot.passToOperation and alloc and slot.dataSlotIndex and alloc[slot.dataSlotIndex])
                or slot.candidates[1]
            local rank = itemID and ReagentQuality(itemID)
            if rank then
                units[rank] = (units[rank] or 0) + (tonumber(slot.qty) or 0)
                if rank > maxRank then maxRank = rank end
            end
        end
    end
    local parts = {}
    for rank = 1, maxRank do
        if (units[rank] or 0) > 0 then
            parts[#parts + 1] = C.TierBadge(rank, 12) .. Dim("x" .. units[rank])
        end
    end
    return #parts > 0 and table.concat(parts, "  ") or Dim("-")
end

--- One line per reachable output quality (and per concentration-reached quality): the cheapest
--- reagent rank mix that reaches it and the profit of crafting it that way; the most profitable
--- line in accent ink. Answers "which reagent ranks should I use for which result".
local function AddByQuality(tt, r, ev)
    local list = {}
    for tier, row in pairs(ev.tiers or {}) do
        if tier > 0 and not row.conc then list[#list + 1] = row end
    end
    for _, row in pairs(ev.concTiers or {}) do
        list[#list + 1] = row
    end
    if #list < 2 then return end
    table.sort(list, function(a, b)
        if (a.tier or 0) ~= (b.tier or 0) then return (a.tier or 0) < (b.tier or 0) end
        return not a.conc and b.conc
    end)
    local rs = ns.RecipeService
    local slots = rs and rs.GetRequiredBasicSlots and rs:GetRequiredBasicSlots(r.spellID) or {}
    Head(tt, SafeL("HUB_CRAFT_SEC_BY_QUALITY", "By result quality"))
    for i = 1, #list do
        local row = list[i]
        local left = C.TierBadge(row.tier, 14) .. "  " .. RankMixText(slots, row)
        if row.conc then
            left = left .. " " .. Dim("+" .. SafeL("HUB_CRAFT_CONC_SHORT", "conc"))
        end
        local profit = row.profit and H.Signed(row.profit, true) or Hex(SafeL("HUB_NO_PRICE", "no price"), "danger")
        if row == ev.bestNoConc then
            left = Hex(">", "accent") .. " " .. left
        end
        Pair(tt, left, profit)
    end
end

local function Evaluate(r, opts)
    local evSvc = ns.CraftEVService
    return evSvc and evSvc:Evaluate(r.spellID, { useAverage = opts.useAverage, knownBy = opts.knownBy })
end

--- Appends the craft breakdown of `r` to `tt` (caller owns SetOwner / Show).
function C.AddBreakdown(tt, r, opts)
    local ev = Evaluate(r, opts)
    local base = ev and ev.bestNoConc
    if not base then
        tt:AddLine(" ")
        tt:AddLine(SafeL("HUB_TT_MISSING_SOME", "Some reagents have no price."), 1, 0.5, 0.3)
        return
    end
    AddByQuality(tt, r, ev)
    local preSum = AddReagents(tt, r, base, opts)
    AddResult(tt, r, ev, base, preSum)
    if ev.bestConc then
        AddConcentration(tt, r, base, ev.bestConc)
    end
    AddFooter(tt, ev)
end

local MAX_ALT_NAMES = 3

--- "Name 10, Name2 5" for the alts holding the most of a slot's items.
local function AltNames(perAlt)
    local list = {}
    for name, n in pairs(perAlt) do
        list[#list + 1] = { name = name, n = n }
    end
    table.sort(list, function(a, b) return a.n > b.n end)
    local parts = {}
    for i = 1, math.min(#list, MAX_ALT_NAMES) do
        parts[#parts + 1] = list[i].name .. " " .. list[i].n
    end
    if #list > MAX_ALT_NAMES then
        parts[#parts + 1] = "..."
    end
    return table.concat(parts, ", ")
end

--- Stock section: per required slot, have / need with where it is (bags, bank, warband bank and
--- Warband Nexus alts), then how many crafts this character can do and how many the alts' stock adds.
function C.AddStock(tt, r)
    local rs = ns.RecipeService
    if not (rs and rs.GetMandatorySlots and rs.GetStockByLocation and r.spellID) then return end
    local slots = rs:GetMandatorySlots(r.spellID)
    if #slots == 0 then return end
    local status, maxCrafts = C.CraftStatus(r)
    Head(tt, SafeL("HUB_TT_STOCK", "Your stock"))
    if status == "unlearned" then
        tt:AddLine(Hex(SafeL("HUB_TT_NOT_LEARNED", "Not learned on this character"), "danger"))
    end
    local anyAlt = false
    for i = 1, math.min(#slots, MAX_REAGENT_LINES) do
        local slot = slots[i]
        local need = SafeNumber(slot.qty) or 0
        local bags, bank, warband, alts, perAlt, firstID = 0, 0, 0, 0, {}, nil
        for ci = 1, #slot.candidates do
            local id = slot.candidates[ci].itemID
            if id then
                firstID = firstID or id
                local s = rs:GetStockByLocation(id)
                bags, bank, warband = bags + s.bags, bank + s.bank, warband + s.warband
                local alt = rs.GetAltStock and rs:GetAltStock(id)
                if alt and alt.total > 0 then
                    alts = alts + alt.total
                    for d = 1, #alt.details do
                        local det = alt.details[d]
                        local nm = det.name or "?"
                        perAlt[nm] = (perAlt[nm] or 0) + (SafeNumber(det.total) or 0)
                    end
                end
            end
        end
        if firstID and need > 0 then
            local have = bags + bank + warband
            local name = C.IconMarkup(ItemIcon(firstID), 14) .. " " .. ItemName(firstID)
            Pair(tt, name, Hex(string.format("%d / %d", have, need), have >= need and "success" or "danger"))
            local where = string.format(SafeL("HUB_TT_STOCK_WHERE_FMT", "Bags %d · Bank %d · Warband %d"),
                bags, bank, warband)
            if alts > 0 then
                anyAlt = true
                where = where .. " · " .. string.format(SafeL("HUB_TT_STOCK_ALTS_FMT", "Alts %d (%s)"),
                    alts, AltNames(perAlt))
            end
            tt:AddLine("    " .. Dim(where))
        end
    end
    if #slots > MAX_REAGENT_LINES then
        tt:AddLine("...", LBL_R, LBL_G, LBL_B)
    end
    Pair(tt, SafeL("HUB_TT_CAN_CRAFT", "Can craft"),
        Hex(tostring(maxCrafts or 0), (maxCrafts or 0) >= 1 and "success" or "danger"))
    if anyAlt and rs.GetCraftStockCounts and rs.MaxCraftsFromStock then
        local withAlts = rs:MaxCraftsFromStock(r.spellID, rs:GetCraftStockCounts(r.spellID, true)) or 0
        if withAlts > (maxCrafts or 0) then
            Pair(tt, SafeL("HUB_TT_CAN_CRAFT_ALTS", "With alts' stock"), tostring(withAlts))
        end
    end
end

--- Output item of the evaluated craft (tier item when the EV picked one), else the recipe output.
function C.OutputItem(r, opts)
    local ev = Evaluate(r, opts)
    local base = ev and ev.bestNoConc
    return (base and base.outputItem) or r.outputItem
end
