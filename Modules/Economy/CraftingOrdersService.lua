--[[
    Artisan Nexus — Crafting orders evaluator (crafter side).
    When the crafter order page is available (CRAFTINGORDERS_SHOW_CRAFTER) it requests the Patron
    (Npc), Personal and Public lists once per open, then values every order:

      net = (tipAmount - consortiumCut)                      -- Blizzard shows this as the final tip
          + Σ npcOrderRewards (items at net AH sale value; currency rewards at moxieValue;
                               unpriced "Knowledge" items at knowledgePointValue — HEURISTICS)
          - cost of the required Basic slots the customer did not supply (cheapest tier, book walk)
          - concentration needed to reach order.minQuality x Economy:ConcentrationValue(profession)

    Verified 2026-10-14 (Blizzard_APIDocumentationGenerated 12.1.5.70391 + Blizzard UI source):
      - C_CraftingOrders.RequestCrafterOrders(CraftingOrderRequestInfo { orderType, selectedSkillLineAbility?,
        searchFavorites, initialNonPublicSearch, primarySort, secondarySort, forCrafter, offset, callback,
        profession? }) — CraftingOrderUIDocumentation.lua; request shape from
        Blizzard_ProfessionsCrafterOrderPage.lua RequestOrders/SendOrderRequest.
      - callback = C_FunctionContainers.CreateCallback(fn) [V-UI, CrafterOrderPage.lua:668], args
        (result, orderType, displayBuckets, expectMoreRows, offset, isSorted); GetCrafterOrders() is
        cumulative across pages (ShowGeneric iterates offset+1..#orders).
      - CraftingOrderInfo / CraftingOrderReagentInfo { reagentInfo = { reagent = { itemID }, dataSlotIndex,
        quantity }, slotIndex, source, isBasicReagent } / CraftingOrderRewardInfo { itemLink?, currencyType?,
        count } — CraftingOrderUISharedDocumentation.lua.
      - Every order.reagents entry marks its slot as customer-provided (CrafterOrderView.lua:584-597).
      - minQuality is a 1-based tier compared with the projected tier (CrafterOrderView.lua:837-839).
      - C_TradeSkillUI.GetCraftingOperationInfoForOrder(recipeID, reagents, orderID, applyConcentration) for
        recraft orders; GetCraftingOperationInfo(recipeID, reagents, nil, applyConcentration) otherwise.
      - Enum.CraftingOrderType Public=0 Guild=1 Personal=2 Npc=3; CraftingOrderSortType Tip=5 TimeRemaining=6.
    Throttling: one request in flight, one request chain per type per open, never while Blizzard's own
    page request is in flight. The type Blizzard's page shows is never requested (shared client cache);
    the OrderRequestCallback hook captures it. While that page is open other types get one page each.
]]

local ADDON_NAME, ns = ...

local GetItemInfo = C_Item.GetItemInfo
local GetItemInfoInstant = C_Item.GetItemInfoInstant

local E = ns.Constants.EVENTS

local CraftingOrdersService = {
    _rows = {},
    _rawOrders = {},
    _buckets = {},
    _requestedThisOpen = {},
    _queue = nil,
    _inFlight = nil,
}

local MAX_PAGES = 5
local REQUEST_TIMEOUT_SEC = 10
local START_DELAY_SEC = 1.5
local BUSY_RETRY_SEC = 0.75
local MAX_BUSY_RETRIES = 8

local FLAGS = {
    needsConcentration = { "ORDER_FLAG_NEEDS_CONC", "Needs concentration" },
    notEnoughConcentration = { "ORDER_FLAG_LOW_CONC", "Not enough concentration" },
    cantReachMinQuality = { "ORDER_FLAG_CANT_REACH", "Can't reach min quality" },
    notLearned = { "ORDER_FLAG_NOT_LEARNED", "Not learned" },
    missingPrices = { "ORDER_FLAG_MISSING_PRICES", "Missing prices" },
    rewardHeuristic = { "ORDER_FLAG_HEURISTIC", "Estimated reward value" },
    noQualityData = { "ORDER_FLAG_NO_QUALITY", "Quality unknown" },
    bucket = { "ORDER_FLAG_BUCKET", "Summary only" },
}

local function OrderTypes()
    local T = Enum and Enum.CraftingOrderType
    if not T then
        return nil
    end
    return { T.Npc, T.Personal, T.Public }
end

local function Notify(orderType)
    ns.ArtisanNexus:SendMessage(E.CRAFTING_ORDERS_UPDATED, { orderType = orderType })
end

local function SafeString(v)
    if type(v) ~= "string" then
        return nil
    end
    if issecretvalue and issecretvalue(v) then
        return nil
    end
    return v
end

local function Economy()
    return ns.Economy
end

local function OrderNow()
    --- expirationTime is server time_t; Blizzard derives remaining = expirationTime - GetCraftingOrderTime().
    if C_CraftingOrders and C_CraftingOrders.GetCraftingOrderTime then
        local ok, t = pcall(C_CraftingOrders.GetCraftingOrderTime)
        t = ok and tonumber(t) or nil
        if t then
            return t
        end
    end
    return nil
end

--- Value one reward entry. Returns copper, heuristic flag.
local function RewardValue(reward)
    local econ = Economy()
    local cfg = econ and econ.Config and econ:Config()
    local count = tonumber(reward.count) or 1
    if reward.itemLink then
        local itemID = GetItemInfoInstant and GetItemInfoInstant(reward.itemLink)
        if not itemID then
            return 0, true
        end
        local price = ns.AHPriceService and ns.AHPriceService.GetPrice and ns.AHPriceService:GetPrice(itemID)
        if price and price > 0 then
            if econ and econ.NetSaleValue then
                return econ:NetSaleValue(itemID, price, count), false
            end
            return price * count, false
        end
        --- HEURISTIC (UNVERIFIED): patron knowledge rewards are unpriced items whose name contains
        --- "Knowledge" (enUS); 1 KP per unit is assumed. Other clients fall through to vendor value.
        local name = GetItemInfo and GetItemInfo(itemID)
        if type(name) == "string" and name:find("Knowledge", 1, true) then
            return (tonumber(cfg and cfg.knowledgePointValue) or 0) * count, true
        end
        local vsp = econ and econ.VendorSellPrice and econ:VendorSellPrice(itemID)
        return (vsp or 0) * count, true
    elseif reward.currencyType then
        --- HEURISTIC: patron currency rewards are treated as profession Moxie (icy-veins Midnight professions summary: Moxie mostly from patron orders, read 2026-10-14).
        return (tonumber(cfg and cfg.moxieValue) or 0) * count, true
    end
    return 0, false
end

--- Cost of the required Basic slots the customer left to the crafter (stored schematic, cheapest tier).
---@return number cost, boolean missing, table providedSlots
local function CrafterReagentCost(order)
    -- provided: ModifiedReagent dataSlotIndex -> true (OrderReagents dedupe); providedSlot: schematic
    -- slotIndex -> true. CraftingOrderReagentInfo.slotIndex is the schematic slot (CraftingOrderUIShared
    -- 12.1.5.70448, checked 2026-10-17); dataSlotIndex alone collides across data slot types.
    local provided, providedSlot = {}, {}
    if type(order.reagents) == "table" then
        for i = 1, #order.reagents do
            local r = order.reagents[i]
            local info = r and r.reagentInfo
            if info and info.dataSlotIndex then
                provided[info.dataSlotIndex] = true
            end
            if r and r.slotIndex then
                providedSlot[r.slotIndex] = true
            end
        end
    end
    local RS = ns.RecipeService
    if not RS or not RS.GetMandatorySlots then
        return 0, true, provided
    end
    if order.isRecraft then
        --- Recrafts reuse the item; basic reagents are not re-bought.
        return 0, false, provided
    end
    local slots = RS:GetMandatorySlots(order.spellID)
    if #slots == 0 then
        return 0, true, provided
    end
    local econ = Economy()
    local total, missing = 0, false
    for si = 1, #slots do
        local slot = slots[si]
        local first = slot.candidates[1]
        local isProvided
        if first and first.slotIndex then
            isProvided = providedSlot[first.slotIndex] == true
        else
            -- Rows harvested before slotIndex was stored: only ModifiedReagent slots share the
            -- customer reagents' dataSlotIndex numbering.
            isProvided = first ~= nil and first.dataSlotType == 2 and first.dataSlotIndex ~= nil
                and provided[first.dataSlotIndex] == true
        end
        if not isProvided then
            local best
            for ci = 1, #slot.candidates do
                local c = slot.candidates[ci]
                if c.itemID then
                    local cost
                    if econ and econ.BuyCost then
                        cost = econ:BuyCost(c.itemID, slot.qty)
                    else
                        local p = ns.AHPriceService and ns.AHPriceService:GetPrice(c.itemID)
                        cost = p and p * slot.qty
                    end
                    if cost and (not best or cost < best) then
                        best = cost
                    end
                end
            end
            if best then
                total = total + best
            else
                missing = true
            end
        end
    end
    return total, missing, provided
end

--- Reagent table for GetCraftingOperationInfoForOrder: customer reagents + our cheapest picks elsewhere.
local function OrderReagents(order, provided)
    local out = {}
    if type(order.reagents) == "table" then
        for i = 1, #order.reagents do
            local info = order.reagents[i].reagentInfo
            if info and info.reagent then
                out[#out + 1] = { reagent = info.reagent, dataSlotIndex = info.dataSlotIndex, quantity = info.quantity }
            end
        end
    end
    local RS = ns.RecipeService
    if RS and RS.BuildCraftingReagentInfo then
        local mine = RS:BuildCraftingReagentInfo(order.spellID)
        for i = 1, #mine do
            if not provided[mine[i].dataSlotIndex] then
                out[#out + 1] = mine[i]
            end
        end
    end
    return out
end

--- Blizzard uses GetCraftingOperationInfoForOrder only for recraft orders and GetCraftingOperationInfo
--- (recipeID, reagents, allocationItemGUID, applyConcentration) otherwise
--- (Blizzard_ProfessionsRecipeSchematicForm.lua:279-287, 12.1.5, verified 2026-10-15).
local function OperationForOrder(order, reagents, applyConc)
    local T = C_TradeSkillUI
    if not T then
        return nil
    end
    local ok, op
    if order.isRecraft then
        if not T.GetCraftingOperationInfoForOrder then return nil end
        ok, op = pcall(T.GetCraftingOperationInfoForOrder, order.spellID, reagents, order.orderID, applyConc)
    else
        if not T.GetCraftingOperationInfo then return nil end
        ok, op = pcall(T.GetCraftingOperationInfo, order.spellID, reagents, nil, applyConc)
    end
    if ok and type(op) == "table" then
        return op
    end
    return nil
end

--- Concentration needed to reach minQuality. Returns concNeeded|nil, flags table additions.
local function ConcentrationForOrder(order, provided, flags)
    local minQ = tonumber(order.minQuality) or 0
    if minQ <= 1 then
        return 0
    end
    local T = C_TradeSkillUI
    if not T or not (T.IsTradeSkillReady and T.IsTradeSkillReady()) then
        flags[#flags + 1] = "noQualityData"
        return nil
    end
    local reagents = OrderReagents(order, provided)
    local base = OperationForOrder(order, reagents, false)
    if not base then
        flags[#flags + 1] = "noQualityData"
        return nil
    end
    local tier = tonumber(base.craftingQuality) or math.floor(tonumber(base.quality) or 0)
    if tier >= minQ then
        return 0
    end
    local cost = tonumber(base.concentrationCost) or 0
    --- Concentration lifts the craft to the next tier only.
    if tier + 1 < minQ or cost <= 0 then
        flags[#flags + 1] = "cantReachMinQuality"
        return nil
    end
    flags[#flags + 1] = "needsConcentration"
    local withConc = OperationForOrder(order, reagents, true)
    if not withConc then
        --- Blizzard returns nil with concentration when the pool cannot pay (SchematicForm.lua:276-299).
        flags[#flags + 1] = "notEnoughConcentration"
    elseif (tonumber(withConc.craftingQuality) or 0) < minQ then
        flags[#flags + 1] = "cantReachMinQuality"
        return nil
    end
    return cost
end

local function IsLearned(spellID)
    local T = C_TradeSkillUI
    if not T or not T.GetRecipeInfo then
        return nil
    end
    local ok, info = pcall(T.GetRecipeInfo, spellID)
    if ok and type(info) == "table" then
        return info.learned == true
    end
    return nil
end

---@return table evaluated row
function CraftingOrdersService:EvaluateOrder(order)
    local flags = {}
    local tipNet = (tonumber(order.tipAmount) or 0) - (tonumber(order.consortiumCut) or 0)
    local rewardsValue, heuristic = 0, false
    if type(order.npcOrderRewards) == "table" then
        for i = 1, #order.npcOrderRewards do
            local v, h = RewardValue(order.npcOrderRewards[i])
            rewardsValue = rewardsValue + (v or 0)
            heuristic = heuristic or h
        end
    end
    if heuristic then
        flags[#flags + 1] = "rewardHeuristic"
    end
    local learned = IsLearned(order.spellID)
    if learned == false then
        flags[#flags + 1] = "notLearned"
    end
    local reagentCost, missing, provided = CrafterReagentCost(order)
    if missing then
        flags[#flags + 1] = "missingPrices"
    end
    local concNeeded
    if learned ~= false then
        concNeeded = ConcentrationForOrder(order, provided, flags)
    end
    local profession = ns.RecipeService and ns.RecipeService.GetProfession and ns.RecipeService:GetProfession(order.spellID)
    local econ = Economy()
    local concValue = (econ and econ.ConcentrationValue and econ:ConcentrationValue(profession)) or 0
    local concCost = math.floor((concNeeded or 0) * concValue + 0.5)
    -- An order this character cannot fulfil has no profit to rank. ConcentrationForOrder returns
    -- nil on those paths, which made concCost 0 and handed the order the HIGHEST net of the batch,
    -- so it sorted first and became the recommended order in the per-character summary.
    local blocked = false
    for i = 1, #flags do
        if flags[i] == "cantReachMinQuality" or flags[i] == "notLearned"
            or flags[i] == "notEnoughConcentration" then
            blocked = true
            break
        end
    end
    local now = OrderNow()
    local expiresAt
    if now and tonumber(order.expirationTime) then
        expiresAt = time() + (tonumber(order.expirationTime) - now)
    end
    local customer = SafeString(order.customerName)
    if not customer and order.npcCustomerCreatureID then
        customer = "npc:" .. tostring(order.npcCustomerCreatureID)
    end
    return {
        orderID = order.orderID,
        orderType = order.orderType,
        spellID = order.spellID,
        itemID = order.itemID,
        profession = profession,
        customer = customer,
        minQuality = order.minQuality,
        isRecraft = order.isRecraft,
        tipNet = tipNet,
        rewardsValue = math.floor(rewardsValue + 0.5),
        reagentCost = math.floor(reagentCost + 0.5),
        concNeeded = concNeeded,
        concCost = concCost,
        -- nil net = "not rankable", not "worth nothing": the sort and the summary both skip it.
        net = (not blocked) and math.floor(tipNet + rewardsValue - reagentCost - concCost + 0.5) or nil,
        blocked = blocked or nil,
        flags = flags,
        expiresAt = expiresAt,
    }
end

--- Bucket rows (public browse without a recipe selected): tip is the bucket max, crafter supplies all basics.
local function EvaluateBucket(bucket, orderType)
    local fake = { spellID = bucket.spellID, reagents = {}, orderType = orderType }
    local reagentCost, missing = CrafterReagentCost(fake)
    local flags = { "bucket" }
    if missing then
        flags[#flags + 1] = "missingPrices"
    end
    if IsLearned(bucket.spellID) == false then
        flags[#flags + 1] = "notLearned"
    end
    local tip = tonumber(bucket.tipAmountMax) or tonumber(bucket.tipAmountAvg) or 0
    return {
        orderID = nil,
        orderType = orderType,
        spellID = bucket.spellID,
        itemID = bucket.itemID,
        profession = ns.RecipeService and ns.RecipeService.GetProfession and ns.RecipeService:GetProfession(bucket.spellID),
        numAvailable = bucket.numAvailable,
        tipNet = tip,
        tipAvg = tonumber(bucket.tipAmountAvg),
        rewardsValue = 0,
        reagentCost = math.floor(reagentCost + 0.5),
        concNeeded = nil,
        concCost = 0,
        net = math.floor(tip - reagentCost + 0.5),
        flags = flags,
    }
end

function CraftingOrdersService:Reevaluate(orderType)
    local rows = {}
    local raw = self._rawOrders[orderType]
    if type(raw) == "table" then
        for i = 1, #raw do
            local ok, row = pcall(self.EvaluateOrder, self, raw[i])
            if ok and row then
                rows[#rows + 1] = row
            end
        end
    end
    local buckets = self._buckets[orderType]
    if type(buckets) == "table" then
        for i = 1, #buckets do
            rows[#rows + 1] = EvaluateBucket(buckets[i], orderType)
        end
    end
    -- Rows with no net (blocked: cannot reach the quality, not learned, not enough concentration)
    -- sort last instead of ranking as zero-profit among real candidates.
    table.sort(rows, function(a, b)
        local an, bn = a.net, b.net
        if an and not bn then return true end
        if bn and not an then return false end
        if an and bn and an ~= bn then return an > bn end
        return (a.orderID or 0) < (b.orderID or 0)
    end)
    self._rows[orderType] = rows
    self:PersistSummary()
    Notify(orderType)
end

--- Short per-character summary (no order bodies persisted).
function CraftingOrdersService:PersistSummary()
    local c = ns.db and ns.db.char
    if not c then
        return
    end
    local summary = { at = time(), counts = {}, bestNet = nil, bestSpellID = nil }
    for orderType, rows in pairs(self._rows) do
        summary.counts[orderType] = #rows
        -- Bucket rows carry no orderID and (since they use the bucket's max tip without the
        -- consortium cut) tend to sort above real orders, so testing only rows[1] routinely
        -- skipped a type's best actual order. Take the first rankable real one.
        for i = 1, #rows do
            local row = rows[i]
            if row.net == nil then break end -- blocked rows are sorted last: nothing rankable left
            if row.orderID then
                if not summary.bestNet or row.net > summary.bestNet then
                    summary.bestNet = row.net
                    summary.bestSpellID = row.spellID
                    summary.bestOrderType = orderType
                end
                break
            end
        end
    end
    c.craftingOrdersSummary = summary
end

---@param orderType number|nil Enum.CraftingOrderType; nil = all types merged (sorted by net)
---@return table[] rows { orderID, orderType, spellID, itemID, profession, customer, minQuality, isRecraft,
---   tipNet, rewardsValue, reagentCost, concNeeded, concCost, net, flags = { flagKey... }, expiresAt,
---   numAvailable? (bucket rows) }
function CraftingOrdersService:GetEvaluatedOrders(orderType)
    if orderType ~= nil then
        return self._rows[orderType] or {}
    end
    local out = {}
    for _, rows in pairs(self._rows) do
        for i = 1, #rows do
            out[#out + 1] = rows[i]
        end
    end
    table.sort(out, function(a, b) return (a.net or 0) > (b.net or 0) end)
    return out
end

---@param flag string
---@return string localized label
function CraftingOrdersService:GetFlagLabel(flag)
    local def = FLAGS[flag]
    if not def then
        return tostring(flag)
    end
    local v = ns.L and ns.L[def[1]]
    if type(v) == "string" and v ~= "" then
        return v
    end
    return def[2]
end

---@return table|nil db.char summary { at, counts = {[orderType]=n}, bestNet, bestSpellID, bestOrderType }
function CraftingOrdersService:GetSummary()
    local c = ns.db and ns.db.char
    return c and c.craftingOrdersSummary
end

-- ─── Request chain ───────────────────────────────────────────────

local function BlizzardOrdersPage()
    local pf = _G.ProfessionsFrame
    return pf and pf.OrdersPage
end

local function BlizzardBusy()
    local page = BlizzardOrdersPage()
    return page ~= nil and page.requestCallback ~= nil
end

local function BlizzardPageShown()
    local page = BlizzardOrdersPage()
    if not page or not page.IsShown then return false end
    local ok, shown = pcall(page.IsShown, page)
    return ok and shown == true
end

--- Never request the type Blizzard's page is showing: GetCrafterOrders() is one shared cache that the
--- page re-reads cumulatively when paging (ProfessionsCraftingOrderPageMixin:RequestMoreOrders /
--- ShowOrders, Blizzard_ProfessionsCrafterOrderPage.lua 12.1.5, verified 2026-10-15), so our list
--- (other sort, no filter) would leak into it. The passive OrderRequestCallback hook captures that type
--- whenever Blizzard loads it unfiltered.
local function IsVisibleType(orderType)
    local page = BlizzardOrdersPage()
    return page ~= nil and page.orderType == orderType and BlizzardPageShown()
end

local function CurrentProfession()
    local T = C_TradeSkillUI
    if not T or not T.GetChildProfessionInfo then
        return nil
    end
    local ok, info = pcall(T.GetChildProfessionInfo)
    if ok and type(info) == "table" then
        return info.profession
    end
    return nil
end

function CraftingOrdersService:CancelInFlight()
    local f = self._inFlight
    self._inFlight = nil
    if f and f.callback and f.callback.Cancel then
        pcall(f.callback.Cancel, f.callback)
    end
end

function CraftingOrdersService:SendRequest(orderType, offset, profession)
    if not C_CraftingOrders or not C_CraftingOrders.RequestCrafterOrders
        or not C_FunctionContainers or not C_FunctionContainers.CreateCallback then
        return false
    end
    local sortT = Enum and Enum.CraftingOrderSortType
    local token = {}
    local callback = C_FunctionContainers.CreateCallback(function(result, cbOrderType, displayBuckets, expectMoreRows, cbOffset)
        CraftingOrdersService:OnRequestResult(token, cbOrderType, displayBuckets, expectMoreRows, cbOffset)
    end)
    token.callback = callback
    token.orderType = orderType
    token.offset = offset
    token.profession = profession
    token.pages = (self._inFlight and self._inFlight.orderType == orderType and self._inFlight.pages or 0) + 1
    self._inFlight = token
    local request = {
        orderType = orderType,
        searchFavorites = false,
        initialNonPublicSearch = false,
        primarySort = { sortType = sortT and sortT.Tip or 5, reversed = true },
        secondarySort = { sortType = sortT and sortT.TimeRemaining or 6, reversed = false },
        forCrafter = true,
        offset = offset or 0,
        callback = callback,
        profession = profession,
    }
    local ok = pcall(C_CraftingOrders.RequestCrafterOrders, request)
    if not ok then
        self._inFlight = nil
        return false
    end
    C_Timer.After(REQUEST_TIMEOUT_SEC, function()
        if CraftingOrdersService._inFlight == token then
            CraftingOrdersService:CancelInFlight()
            -- Pages already fetched for this type are in _rawOrders; value them before moving on.
            CraftingOrdersService:Reevaluate(token.orderType)
            CraftingOrdersService:ProcessQueue()
        end
    end)
    return true
end

function CraftingOrdersService:OnRequestResult(token, orderType, displayBuckets, expectMoreRows, offset)
    if self._inFlight ~= token then
        return
    end
    orderType = orderType or token.orderType
    if displayBuckets then
        local ok, buckets = pcall(C_CraftingOrders.GetCrafterBuckets)
        self._buckets[orderType] = (ok and type(buckets) == "table") and buckets or {}
        self._rawOrders[orderType] = {}
    else
        local ok, orders = pcall(C_CraftingOrders.GetCrafterOrders)
        self._rawOrders[orderType] = (ok and type(orders) == "table") and orders or {}
        self._buckets[orderType] = nil
    end
    -- Blizzard's page started its own request mid-chain: its response will replace the shared cache,
    -- so stop paging (pages copied so far are kept) and let ProcessQueue wait until it is done.
    -- While Blizzard's page is open only the first page of other types is fetched (fewer cache swaps).
    local maxPages = BlizzardPageShown() and 1 or MAX_PAGES
    if expectMoreRows and token.pages < maxPages and not BlizzardBusy() then
        local have = displayBuckets and #(self._buckets[orderType] or {}) or #(self._rawOrders[orderType] or {})
        --- Placeholder carries the page count into SendRequest (it increments it).
        self._inFlight = { orderType = orderType, pages = token.pages }
        if self:SendRequest(orderType, have, token.profession) then
            return
        end
    end
    self._inFlight = nil
    self:Reevaluate(orderType)
    self:ProcessQueue()
end

function CraftingOrdersService:ProcessQueue(busyRetries)
    if not self._enabled or self._inFlight or not self._queue then
        return
    end
    if BlizzardBusy() then
        busyRetries = (busyRetries or 0) + 1
        if busyRetries <= MAX_BUSY_RETRIES then
            C_Timer.After(BUSY_RETRY_SEC, function()
                CraftingOrdersService:ProcessQueue(busyRetries)
            end)
        end
        return
    end
    local orderType = table.remove(self._queue, 1)
    if orderType == nil then
        self._queue = nil
        return
    end
    local profession = CurrentProfession()
    if profession == nil then
        self._queue = nil
        return
    end
    if IsVisibleType(orderType) then
        self:ProcessQueue()
        return
    end
    self._requestedThisOpen[orderType] = true
    if not self:SendRequest(orderType, 0, profession) then
        self:ProcessQueue()
    end
end

--- Queue one request chain per type (once per crafter-page open unless forced).
---@param force boolean|nil re-request types already fetched during this open
function CraftingOrdersService:RequestAll(force)
    local types = OrderTypes()
    if not types then
        return
    end
    local page = BlizzardOrdersPage()
    local shown = page and page.orderType
    local queue = {}
    local last
    for i = 1, #types do
        local t = types[i]
        if force or not self._requestedThisOpen[t] then
            if t == shown then
                last = t
            else
                queue[#queue + 1] = t
            end
        end
    end
    if last ~= nil then
        queue[#queue + 1] = last
    end
    if #queue == 0 then
        return
    end
    self._queue = queue
    self:ProcessQueue()
end

--- Passive capture: Blizzard's own unfiltered page loads refresh our copy for free.
function CraftingOrdersService:HookBlizzardPage()
    if self._hooked then
        return
    end
    local page = BlizzardOrdersPage()
    if not page or not page.OrderRequestCallback or not hooksecurefunc then
        return
    end
    self._hooked = true
    hooksecurefunc(page, "OrderRequestCallback", function(pg, result, orderType, displayBuckets, expectMoreRows)
        if not CraftingOrdersService._enabled or CraftingOrdersService._inFlight then
            return
        end
        local req = pg.lastRequest
        if not req or req.selectedSkillLineAbility ~= nil or req.searchFavorites then
            return
        end
        if displayBuckets then
            local ok, buckets = pcall(C_CraftingOrders.GetCrafterBuckets)
            CraftingOrdersService._buckets[orderType] = (ok and type(buckets) == "table") and buckets or {}
            CraftingOrdersService._rawOrders[orderType] = {}
        else
            local ok, orders = pcall(C_CraftingOrders.GetCrafterOrders)
            CraftingOrdersService._rawOrders[orderType] = (ok and type(orders) == "table") and orders or {}
            CraftingOrdersService._buckets[orderType] = nil
        end
        CraftingOrdersService:Reevaluate(orderType)
    end)
end

--- Reward events arrive one per order right after a page; coalesce the re-valuation per type.
function CraftingOrdersService:ScheduleReevaluate(orderType)
    self._pendingReeval = self._pendingReeval or {}
    if self._pendingReeval[orderType] then
        return
    end
    self._pendingReeval[orderType] = true
    C_Timer.After(0, function()
        CraftingOrdersService._pendingReeval[orderType] = nil
        if CraftingOrdersService._enabled then
            CraftingOrdersService:Reevaluate(orderType)
        end
    end)
end

function CraftingOrdersService:OnRewardsUpdated(rewards, orderID)
    if not orderID or type(rewards) ~= "table" then
        return
    end
    for orderType, raw in pairs(self._rawOrders) do
        for i = 1, #raw do
            if raw[i].orderID == orderID then
                raw[i].npcOrderRewards = rewards
                self:ScheduleReevaluate(orderType)
                return
            end
        end
    end
end

function CraftingOrdersService:Enable()
    if self._enabled then
        return
    end
    self._enabled = true
    local owner = self._eventOwner or ns.NewEventOwner("CraftingOrdersService")
    self._eventOwner = owner
    owner:RegisterEvent("CRAFTINGORDERS_SHOW_CRAFTER", function()
        CraftingOrdersService._requestedThisOpen = {}
        C_Timer.After(START_DELAY_SEC, function()
            if CraftingOrdersService._enabled then
                CraftingOrdersService:HookBlizzardPage()
                CraftingOrdersService:RequestAll(false)
            end
        end)
    end)
    owner:RegisterEvent("CRAFTINGORDERS_HIDE_CRAFTER", function()
        CraftingOrdersService._queue = nil
        CraftingOrdersService:CancelInFlight()
    end)
    --- Fires when the request throttle clears; resume a stalled chain.
    owner:RegisterEvent("CRAFTINGORDERS_CAN_REQUEST", function()
        if CraftingOrdersService._queue and not CraftingOrdersService._inFlight then
            CraftingOrdersService:ProcessQueue()
        end
    end)
    --- CRAFTINGORDERS_UPDATE_REWARDS (npcOrderRewards, orderID): rewards arrive after the order.
    owner:RegisterEvent("CRAFTINGORDERS_UPDATE_REWARDS", function(_, rewards, orderID)
        CraftingOrdersService:OnRewardsUpdated(rewards, orderID)
    end)
    local function revalueAll()
        for orderType in pairs(CraftingOrdersService._rows) do
            CraftingOrdersService:Reevaluate(orderType)
        end
    end
    if E and E.ECONOMY_CONFIG_CHANGED then
        owner:RegisterMessage(E.ECONOMY_CONFIG_CHANGED, revalueAll)
    end
end

function CraftingOrdersService:Disable()
    if not self._enabled then
        return
    end
    self._enabled = false
    self._queue = nil
    self:CancelInFlight()
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
        self._eventOwner:UnregisterAllMessages()
    end
end

ns.CraftingOrdersService = CraftingOrdersService
