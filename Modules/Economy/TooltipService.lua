--[[
    Artisan Nexus — Item tooltip integration.

    Appends market / stock / craft economics to every item tooltip:
      compact (default)  one line: AH min, 7d trend, craft profit
      Shift held         detailed block (each line toggleable in profile.tooltip)

    Facts relied on (verified 2026-10-14, wow-ui-source live 12.1.5.70391):
      - TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, fn); fn receives
        (tooltip, tooltipData); tooltipData.type / .id (itemID) / .hyperlink / .guid
        (Blizzard_SharedXMLGame/Tooltip/TooltipDataHandler.lua InternalProcessInfo).
      - tooltip:GetItem() -> name, hyperlink, itemID (GameTooltip.lua GameTooltipDataMixin:GetItem).
      - Owners with UpdateTooltip (bag buttons) rebuild the tooltip every TOOLTIP_UPDATE_TIME
        (GameTooltip_OnUpdate), so a Shift press shows the detailed block without us forcing a
        refresh (we never write to Blizzard tooltip fields — taint safety).
      - Post-calls cannot be unregistered: the hook is installed once and gated by _enabled.
      - C_Item.GetItemCount(item, includeBank, includeUses, includeReagentBank, includeAccountBank)
        (ItemDocumentation 12.1.5).
    Performance contract: no C_TradeSkillUI.GetCraftingOperationInfo here; per-item line memo
    (1 s, generation-invalidated); craft summaries cached per spellID; output->recipe index
    built once per schematic generation.

    Public API:
      TooltipService:FindRecipeForOutput(itemID) -> spellID|nil, qualityTier|nil
      TooltipService:GetCraftSummary(itemID) -> table|nil (see below)
      TooltipService:Invalidate()
]]

local ADDON_NAME, ns = ...

-- 12.1.5 removed the global item/coin fallbacks; bind the namespaced APIs.
local GetItemCount = C_Item and C_Item.GetItemCount

local E = ns.Constants.EVENTS

local TooltipService = { _enabled = false, _hooked = false }

--- profile.tooltip keys (read-only here); Core.lua defaults when the key is absent.
--- compactMode: true = compact line unless Shift is held; false = always the detailed block.
local TOOLTIP_DEFAULTS = ns.DEFAULTS.profile.tooltip

local LINE_MEMO_TTL = 1.0
local LINE_MEMO_CAP = 64
local CRAFT_CACHE_TTL = 60
local ALT_CACHE_TTL = 10
local WEEK_SEC = 7 * 24 * 3600
local SIDE_CACHE_CAP = 256

--- Constants.EVENTS names whose payloads change any tooltip number.
local INVALIDATING_MESSAGES = {
    "AH_PRICES_UPDATED", "AH_SCAN_COMPLETE", "CRAFT_OPS_UPDATED", "CRAFT_LEDGER_UPDATED",
    "SALES_LEDGER_UPDATED", "VENDOR_PRICES_UPDATED", "ECONOMY_CONFIG_CHANGED",
    "MARKET_INTEL_UPDATED", "WN_DATA_UPDATED", "CHARACTER_DATA_SOURCE_CHANGED", "CRAFT_BRIEFING_UPDATED",
}

--- Tooltip backgrounds are always dark (Blizzard art), so fixed label/value colors read in
--- both AN themes; semantic accents come from the Hub ink helper (HubData.lua H.Ink).
local LABEL_R, LABEL_G, LABEL_B = 0.74, 0.72, 0.80
local VALUE_R, VALUE_G, VALUE_B = 1, 1, 1

local T = ns.SafeLocaleString

local function Cfg(key)
    local p = ns.db and ns.db.profile
    local t = p and p.tooltip
    local v
    if type(t) == "table" then v = t[key] end
    if v == nil then v = TOOLTIP_DEFAULTS[key] end
    return v
end

local function Money(c)
    return (ns.FormatCopper and ns.FormatCopper(c)) or "—"
end

local function Role(text, kind)
    local H = ns.HubUI_Internal
    if H and H.Ink then return H.Ink(text, kind) end
    return text
end

local function IsSecret(v)
    return v ~= nil and issecretvalue ~= nil and issecretvalue(v) == true
end

local function FormatAge(sec)
    if not sec or sec < 0 then return nil end
    if sec < 3600 then return string.format("%dm", math.max(1, math.floor(sec / 60))) end
    if sec < 86400 then return string.format("%dh", math.floor(sec / 3600)) end
    return string.format("%dd", math.floor(sec / 86400))
end

local SOURCE_TAGS = { an = "AN", auctionator = "Auctionator", tsm = "TSM" }

local function SourceTag(src)
    if src == "vendor" then return T("TOOLTIP_SRC_VENDOR", "vendor") end
    return SOURCE_TAGS[src] or src
end

-- ---------------------------------------------------------------------------
-- Generation + caches
-- ---------------------------------------------------------------------------

local generation = 1
--- Craft summaries do not depend on bag contents: bag updates bump `generation` only, so a re-hover
--- after looting does not re-run CraftEVService:Evaluate.
local craftGeneration = 1
local lineMemo, lineMemoCount = {}, 0
local craftCache, craftCacheCount = {}, 0
local altCache, altCacheCount = {}, 0
local outputIndex, outputTier, outputIndexGen = nil, nil, -1
local schematicGen = 0

function TooltipService:Invalidate()
    generation = generation + 1
    craftGeneration = craftGeneration + 1
end

local function InvalidateStock()
    generation = generation + 1
end

local function ResetLineMemo()
    wipe(lineMemo)
    lineMemoCount = 0
end

--- Output itemID (base + every quality tier) -> producing spellID. Built once per
--- schematic generation. Prefers recipes with harvested reagents that are not flagged unlearned.
local function EnsureOutputIndex()
    if outputIndex and outputIndexGen == schematicGen then return end
    outputIndex, outputTier = {}, {}
    outputIndexGen = schematicGen
    local rs = ns.RecipeService
    local store = rs and rs.GetSchematicStore and rs:GetSchematicStore()
    if type(store) ~= "table" then return end
    local rank = {}
    for spellID, sch in pairs(store) do
        if type(sch) == "table" and type(sch.reagents) == "table" and #sch.reagents > 0 then
            local r = (sch.learned == false) and 1 or 2
            local base = sch.output and tonumber(sch.output.itemID)
            if base and (rank[base] or 0) < r then
                outputIndex[base], outputTier[base], rank[base] = spellID, nil, r
            end
            local q = sch.qualityItemIDs
            if type(q) == "table" then
                for tier = 1, #q do
                    local id = tonumber(q[tier])
                    if id and (rank[id] or 0) < r then
                        outputIndex[id], outputTier[id], rank[id] = spellID, tier, r
                    end
                end
            end
        end
    end
end

---@param itemID number
---@return number|nil spellID
---@return number|nil qualityTier 1-based tier when itemID is a quality variant
function TooltipService:FindRecipeForOutput(itemID)
    if not itemID then return nil, nil end
    local rs = ns.RecipeService
    if rs and rs.GetRecipesProducingItem then
        -- RecipeService's own output index (built once, reset on harvest).
        local producers = rs:GetRecipesProducingItem(itemID)
        local pick
        for i = 1, #producers do
            local p = producers[i]
            local sch = rs.GetSchematic and rs:GetSchematic(p.spellID)
            if not pick or (sch and sch.learned ~= false) then
                pick = p
                if sch and sch.learned ~= false then break end
            end
        end
        if pick then return pick.spellID, pick.tier end
        return nil, nil
    end
    EnsureOutputIndex()
    return outputIndex[itemID], outputTier[itemID]
end

local function BriefingGoldPerConc(spellID)
    local g = ns.db and ns.db.global
    local top = g and g.craftBriefing and g.craftBriefing.top
    if type(top) ~= "table" then return nil end
    for i = 1, #top do
        local row = top[i]
        if type(row) == "table" and row.spellID == spellID then
            return tonumber(row.goldPerConcentration)
        end
    end
    return nil
end

--- Tooltips use the EV engine with noLiveOps = true (no GetCraftingOperationInfo from a hover),
--- so the craft cost matches the Hub whether or not a profession window is open.
local function CanEvaluateEV()
    local ev = ns.CraftEVService
    return ev ~= nil and ev.Evaluate ~= nil
end

--- CraftEVService:Evaluate -> summary for the hovered output (contract: CraftEVService.lua
--- Evaluate doc — tiers[tier] = row { outputItem, yield, reagentCost, profit }, bestConc.gpc).
local function SummaryFromEV(spellID, itemID)
    if not CanEvaluateEV() then return nil end
    local svc = ns.CraftEVService
    local ok, ev = pcall(svc.Evaluate, svc, spellID, { noLiveOps = true })
    if not ok or type(ev) ~= "table" then return nil end
    local row
    if type(ev.tiers) == "table" then
        for _, r in pairs(ev.tiers) do
            if type(r) == "table" and not r.conc and r.outputItem == itemID then
                if not row or (r.profit or -math.huge) > (row.profit or -math.huge) then row = r end
            end
        end
    end
    row = row or ev.bestNoConc
    if type(row) ~= "table" then return nil end
    local missing = type(row.missing) == "table" and #row.missing or 0
    local gpc = type(ev.bestConc) == "table" and tonumber(ev.bestConc.gpc) or nil
    return {
        cost = tonumber(row.reagentCost),
        yield = tonumber(row.yield),
        profit = tonumber(row.profit),
        goldPerConc = gpc,
        missing = missing,
        -- The recipe's reachable tier may differ from the hovered tier (e.g. it always crafts Q2).
        craftsAs = (row.outputItem ~= itemID) and row.outputItem or nil,
        source = "ev",
    }
end

--- Fallback without operation info: cheapest-candidate reagent cost vs. net sale value of the
--- hovered output at the harvested yield midpoint.
local function SummaryFromEstimate(spellID, itemID)
    local rs = ns.RecipeService
    if not (rs and rs.EstimateReagentCost) then return nil end
    local cost, missing = rs:EstimateReagentCost(spellID)
    if not cost or (missing or 0) > 0 then
        return { cost = nil, missing = missing, source = "estimate" }
    end
    local yield = (rs.GetOutputQuantity and rs:GetOutputQuantity(spellID)) or 1
    local unit = ns.AHPriceService and ns.AHPriceService:GetPrice(itemID)
    local profit
    local econ = ns.Economy
    if unit and econ then
        -- Same contract and same basis as CraftEVService, so this fallback cannot read higher
        -- than the Hub row for the same recipe.
        local net = econ.ValueOutput and econ:ValueOutput(itemID, unit, yield, { undercut = true })
        if net then profit = net - cost end
    end
    return { cost = cost, yield = yield, profit = profit, goldPerConc = BriefingGoldPerConc(spellID), source = "estimate" }
end

--- Craft economics for an output item (cached per spellID+item; never calls operation info).
---@param itemID number
---@return table|nil { spellID, tier, cost (per craft), yield, costPerUnit, profit (per craft), goldPerConc, source "ev"|"estimate", missing? }
function TooltipService:GetCraftSummary(itemID)
    local spellID, tier = self:FindRecipeForOutput(itemID)
    if not spellID then return nil end
    local now = GetTime()
    local hit = craftCache[itemID]
    if hit and hit.gen == craftGeneration and (now - hit.t) < CRAFT_CACHE_TTL then
        return hit.summary or nil
    end
    local s = SummaryFromEV(spellID, itemID) or SummaryFromEstimate(spellID, itemID)
    if s then
        s.spellID, s.tier = spellID, tier
        local y = tonumber(s.yield) or 1
        if s.cost and y > 0 then s.costPerUnit = s.cost / y end
        -- Money strings expect whole copper.
        if s.cost then s.cost = math.floor(s.cost + 0.5) end
        if s.profit then s.profit = math.floor(s.profit + 0.5) end
    end
    if not hit then
        if craftCacheCount >= SIDE_CACHE_CAP then wipe(craftCache); craftCacheCount = 0 end
        craftCacheCount = craftCacheCount + 1
    end
    craftCache[itemID] = { gen = craftGeneration, t = now, summary = s or false }
    return s
end

--- Other characters' stock (ns.CharacterData: Warband Nexus or AN-native snapshot), memoized.
local function GetAltCounts(itemID)
    local cd = ns.CharacterData
    local now = GetTime()
    local hit = altCache[itemID]
    if hit and hit.gen == generation and (now - hit.t) < ALT_CACHE_TTL then
        return hit.data or nil
    end
    local ok, data = pcall(cd.GetItemCountsAcrossCharacters, cd, itemID)
    if not ok or type(data) ~= "table" then data = nil end
    if not hit then
        if altCacheCount >= SIDE_CACHE_CAP then wipe(altCache); altCacheCount = 0 end
        altCacheCount = altCacheCount + 1
    end
    altCache[itemID] = { gen = generation, t = now, data = data or false }
    return data
end

local function AvgBuyCost(itemID)
    local ledger = ns.SalesLedgerService
    if not (ledger and ledger.GetAvgBuyPrice) then return nil end
    local ok, v = pcall(ledger.GetAvgBuyPrice, ledger, itemID)
    if not ok then return nil end
    if type(v) == "table" then v = v.avg or v.price end
    v = tonumber(v)
    return (v and v > 0) and v or nil
end

-- ---------------------------------------------------------------------------
-- Line building
-- ---------------------------------------------------------------------------

--- Appends a (left, right) pair to the memo entry array.
local function Push(entry, left, right)
    local n = entry.n + 1
    entry[n * 2 - 1] = left
    entry[n * 2] = right
    entry.n = n
end

local function TrendArrow(itemID)
    local ph = ns.PriceHistoryService
    if not ph then return "" end
    local dir = ph:GetTrend(itemID, WEEK_SEC)
    if dir > 0 then return Role("▲", "success") end
    if dir < 0 then return Role("▼", "danger") end
    return Role("•", "dim")
end

local function BuildCompact(entry, itemID)
    local parts = {}
    local ahp = ns.AHPriceService
    if Cfg("showAhMin") and ahp then
        local price = ahp:GetPriceInfo(itemID)
        if price then parts[#parts + 1] = Money(price) end
    end
    if Cfg("showAvg7d") and ns.PriceHistoryService then
        local st = ns.PriceHistoryService:GetStats(itemID, WEEK_SEC)
        if st.count and st.count >= 2 then
            parts[#parts + 1] = string.format("%s %s %s", T("TOOLTIP_7D_SHORT", "7d"), Money(st.avg), TrendArrow(itemID))
        end
    end
    if Cfg("showCraft") then
        local cs = TooltipService:GetCraftSummary(itemID)
        if cs and cs.profit then
            local kind = cs.profit >= 0 and "success" or "danger"
            parts[#parts + 1] = string.format("%s %s", T("TOOLTIP_CRAFT_SHORT", "craft"), Role(Money(cs.profit), kind))
        end
    end
    if #parts == 0 then return end
    Push(entry, "Artisan Nexus", table.concat(parts, "  ·  "))
end

local function BuildDetailed(entry, itemID)
    local econ = ns.Economy
    local ahp = ns.AHPriceService
    local price, updatedAt, _, isStale, source
    if ahp then
        price, updatedAt, _, isStale, source = ahp:GetPriceInfo(itemID)
    end

    if Cfg("showAhMin") and price then
        local meta = SourceTag(source) or ""
        local age = updatedAt and FormatAge(time() - updatedAt)
        if age then meta = meta .. ", " .. age end
        local right = Money(price)
        if meta ~= "" then
            right = right .. " " .. Role("(" .. meta .. ")", isStale and "warning" or "dim")
        end
        Push(entry, T("TOOLTIP_AH_MIN", "AH min"), right)
    end

    if Cfg("showAvg7d") and ns.PriceHistoryService then
        local st = ns.PriceHistoryService:GetStats(itemID, WEEK_SEC)
        if st.count and st.count >= 2 then
            Push(entry, T("TOOLTIP_AVG_7D", "7-day avg"), Money(st.avg) .. " " .. TrendArrow(itemID))
        end
    end

    if Cfg("showListedQty") and econ then
        local row = econ:GetMarketRow(itemID)
        local qty = row and tonumber(row.qty)
        if qty and qty > 0 then
            Push(entry, T("TOOLTIP_LISTED", "Listed"), BreakUpLargeNumbers and BreakUpLargeNumbers(qty) or tostring(qty))
        end
    end

    if Cfg("showNetAfterCut") and econ and price and source ~= "vendor" then
        -- Display line: "if I sold at the price shown above", so the reference itself, not an
        -- undercut of it. Stated explicitly rather than left to the default.
        local net = econ:ValueOutput(itemID, price, 1, { undercut = false })
        net = net and math.floor(net + 0.5)
        if net and net > 0 then
            -- NetSaleValue subtracts the expected deposit loss as well as the cut, so the label
            -- says "fees", not just the cut percentage, which it used to misreport as the whole
            -- deduction. The percentage stays, since it is the part the player can name.
            local cut = econ:CutRate()
            Push(entry, string.format(T("TOOLTIP_NET_AFTER_FEES_FMT", "Net after fees (%d%% cut)"),
                math.floor(cut * 100 + 0.5)), Money(net))
        end
    end

    if Cfg("showVendorSell") and econ then
        local vs = econ:VendorSellPrice(itemID)
        if vs then Push(entry, T("TOOLTIP_VENDOR_SELL", "Vendor sell"), Money(vs)) end
    end

    if Cfg("showVendorBuy") and ns.VendorPriceService then
        local vb = ns.VendorPriceService:GetBuyPrice(itemID)
        if vb then Push(entry, T("TOOLTIP_VENDOR_BUY", "Vendor buy"), Money(vb)) end
    end

    if Cfg("showAvgBuyCost") then
        local abc = AvgBuyCost(itemID)
        if abc then Push(entry, T("TOOLTIP_AVG_BUY", "Avg buy cost"), Money(abc)) end
    end

    if Cfg("showStock") and GetItemCount then
        local okB, bags = pcall(GetItemCount, itemID, false, false, false, false)
        local okA, all = pcall(GetItemCount, itemID, true, false, true, true)
        bags = okB and tonumber(bags) or 0
        all = okA and tonumber(all) or bags
        if all > 0 then
            Push(entry, T("TOOLTIP_STOCK", "Stock"),
                string.format(T("TOOLTIP_STOCK_FMT", "%d bags / %d total"), bags, all))
        end
    end

    if Cfg("showAltStock") then
        local counts = GetAltCounts(itemID)
        local alts = counts and tonumber(counts.total) or 0
        if alts > 0 then
            Push(entry, T("TOOLTIP_ALT_STOCK", "Alts"), tostring(alts))
        end
    end

    if Cfg("showCraft") then
        local cs = TooltipService:GetCraftSummary(itemID)
        if cs then
            if cs.cost then
                local right = Money(cs.cost)
                if cs.yield and cs.yield > 1 and cs.costPerUnit then
                    right = right .. " " .. Role(string.format(T("TOOLTIP_PER_UNIT_FMT", "(%s/u)"), Money(math.floor(cs.costPerUnit + 0.5))), "dim")
                end
                Push(entry, T("TOOLTIP_CRAFT_COST", "Craft cost"), right)
            elseif (cs.missing or 0) > 0 then
                Push(entry, T("TOOLTIP_CRAFT_COST", "Craft cost"), Role(T("TOOLTIP_MISSING_PRICES", "reagent prices missing"), "warning"))
            end
            if cs.profit then
                Push(entry, T("TOOLTIP_CRAFT_PROFIT", "Craft profit"), Role(Money(cs.profit), cs.profit >= 0 and "success" or "danger"))
            end
            if cs.craftsAs then
                local q = C_TradeSkillUI and C_TradeSkillUI.GetItemCraftedQualityByItemInfo
                    and C_TradeSkillUI.GetItemCraftedQualityByItemInfo(cs.craftsAs)
                q = q or (C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityByItemInfo
                    and C_TradeSkillUI.GetItemReagentQualityByItemInfo(cs.craftsAs))
                if q then
                    Push(entry, " ", Role(string.format(T("TOOLTIP_CRAFTS_AS_FMT", "(your crafts come out as tier %d)"), q), "dim"))
                end
            end
            if cs.goldPerConc and cs.goldPerConc > 0 then
                Push(entry, T("TOOLTIP_GOLD_PER_CONC", "Gold / concentration"), Money(math.floor(cs.goldPerConc + 0.5)))
            end
        end
    end

end

local function GetLines(itemID, detailed)
    local now = GetTime()
    local key = detailed and -itemID or itemID
    local entry = lineMemo[key]
    if entry and entry.gen == generation and (now - entry.t) < LINE_MEMO_TTL then
        return entry
    end
    if not entry then
        if lineMemoCount >= LINE_MEMO_CAP then ResetLineMemo() end
        entry = { n = 0 }
        lineMemo[key] = entry
        lineMemoCount = lineMemoCount + 1
    else
        -- Reuse the table: clear previous pairs.
        for i = 1, entry.n * 2 do entry[i] = nil end
        entry.n = 0
    end
    entry.gen, entry.t = generation, now
    if detailed then
        BuildDetailed(entry, itemID)
    else
        BuildCompact(entry, itemID)
    end
    return entry
end

--- Tooltips we decorate: the main one and chat-link refs. Comparison (shopping) tooltips would
--- duplicate the block next to the main tooltip.
local function IsTargetTooltip(tooltip)
    if not tooltip or not tooltip.AddDoubleLine then return false end
    if tooltip == _G.ShoppingTooltip1 or tooltip == _G.ShoppingTooltip2 then return false end
    return true
end

local function ResolveItemID(tooltip, data)
    local itemID
    if type(data) == "table" then
        if IsSecret(data.id) or IsSecret(data.hyperlink) then return nil end
        itemID = data.id
    end
    if type(itemID) ~= "number" and tooltip.GetItem then
        local ok, _, link, id = pcall(tooltip.GetItem, tooltip)
        if ok and not IsSecret(id) and not IsSecret(link) then itemID = id end
    end
    if type(itemID) ~= "number" or itemID <= 0 then return nil end
    return itemID
end

local function OnTooltipItem(tooltip, data)
    if not TooltipService._enabled or not Cfg("enabled") then return end
    if Cfg("hideInCombat") and InCombatLockdown() then return end
    if not IsTargetTooltip(tooltip) then return end
    local itemID = ResolveItemID(tooltip, data)
    if not itemID then return end

    local detailed = (not Cfg("compactMode")) or IsShiftKeyDown()
    local entry = GetLines(itemID, detailed)
    if entry.n == 0 then return end
    if detailed then
        -- Compact mode labels its single line itself; the expanded block gets a header.
        tooltip:AddLine(Role("Artisan Nexus", "accent"))
    end
    for i = 1, entry.n do
        tooltip:AddDoubleLine(entry[i * 2 - 1], entry[i * 2], LABEL_R, LABEL_G, LABEL_B, VALUE_R, VALUE_G, VALUE_B)
    end
end

local function InstallHook()
    if TooltipService._hooked then return end
    if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType) then
        return
    end
    TooltipService._hooked = true
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        -- Never let an economics error break the Blizzard tooltip.
        local ok = pcall(OnTooltipItem, tooltip, data)
        if not ok and ns.DebugPrint then ns.DebugPrint("TooltipService: post-call failed") end
    end)
end

function TooltipService:Enable()
    if self._enabled then return end
    self._enabled = true
    InstallHook()
    local owner = self._eventOwner or ns.NewEventOwner("TooltipService")
    self._eventOwner = owner
    local function Bump() TooltipService:Invalidate() end
    if E then
        for i = 1, #INVALIDATING_MESSAGES do
            local msg = E[INVALIDATING_MESSAGES[i]]
            if msg then owner:RegisterMessage(msg, Bump) end
        end
        if E.RECIPE_SCHEMATICS_UPDATED then
            owner:RegisterMessage(E.RECIPE_SCHEMATICS_UPDATED, function()
                schematicGen = schematicGen + 1
                Bump()
            end)
        end
    end
    owner:RegisterEvent("BAG_UPDATE_DELAYED", InvalidateStock)
end

function TooltipService:Disable()
    if not self._enabled then return end
    self._enabled = false
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
        if self._eventOwner.UnregisterAllMessages then
            self._eventOwner:UnregisterAllMessages()
        end
    end
    ResetLineMemo()
    wipe(craftCache); craftCacheCount = 0
    wipe(altCache); altCacheCount = 0
end

ns.TooltipService = TooltipService
