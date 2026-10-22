--[[
    Artisan Nexus — Economy core.
    Single home for fee / deposit / valuation math so every surface (profit, shopping,
    posting, ledger, planner) agrees on what a copper is worth.

    Facts used here (verified 2026-10-14 against Blizzard_APIDocumentationGenerated 12.1.5.70391):
      - C_AuctionHouse.CalculateCommodityDeposit(itemID, duration, quantity) -> depositCost?
      - Durations: 1 = 12h, 2 = 24h, 3 = 48h.
      - Posted prices must be whole silver unless C_AuctionHouse.SupportsCopperValues().
      - CommoditySearchResultInfo { unitPrice, quantity, numOwnerItems, ... } (book stored by AHPriceService).
    Not exposed by the client (fallbacks only, refined from data):
      - House cut (5% per warcraft.wiki.gg Auction_House, page marked outdated) -> learned from
        mail invoice consignment by SalesLedgerService.
      - Deposit % of vendor sell price per duration (15/30/60%, same wiki page) -> only used when
        the AH is closed; live calls win.
]]

local ADDON_NAME, ns = ...

-- 12.1.5 removed the global item/coin fallbacks; bind the namespaced APIs.
local GetItemInfo = C_Item.GetItemInfo

local Economy = {}

--- Core.lua defaults.profile.economy (ns.DEFAULTS is set when Core.lua loads, before this file).
local CONFIG_DEFAULTS = ns.DEFAULTS.profile.economy

--- Units in a typical post when spreading a per-post deposit over units (stackables only).
local REPRESENTATIVE_POST_QTY = 20

--- Fallback deposit share of vendor sell price per duration index (AH closed, or non-commodity items).
--- UNVERIFIED for 12.x: no Blizzard source states these shares; results are flagged as estimated.
local DEPOSIT_VSP_SHARE = { 0.15, 0.30, 0.60 }

--- Below this many invoices the configured cut is used instead of the observed one.
local MIN_INVOICES_FOR_OBSERVED_CUT = 5

--- Read-through proxy: resolves profile.economy (current profile, read live) then defaults.
--- Never attaches a metatable to the SavedVariables table itself (AceDB owns those).
local CONFIG_PROXY = setmetatable({}, {
    __index = function(_, key)
        local p = ns.db and ns.db.profile
        local cfg = p and p.economy
        local v
        if type(cfg) == "table" then v = cfg[key] end
        -- `false` is a real setting; only nil falls through to the default.
        if v == nil then v = CONFIG_DEFAULTS[key] end
        return v
    end,
    __newindex = function()
        error("Economy:Config() is read-only; use Economy:SetConfig(key, value)", 2)
    end,
})

---@return table read-only view of profile.economy with defaults filled in (never nil)
function Economy:Config()
    return CONFIG_PROXY
end

---@param key string
---@param value any
function Economy:SetConfig(key, value)
    local p = ns.db and ns.db.profile
    if not p then return end
    p.economy = p.economy or {}
    p.economy[key] = value
    local E = ns.Constants.EVENTS
    ns.ArtisanNexus:SendMessage(E.ECONOMY_CONFIG_CHANGED, key)
end

--- House cut rate: observed from invoices when the ledger has enough samples, else configured.
---@return number rate 0..1
---@return string source "observed"|"config"
function Economy:CutRate()
    local ledger = ns.SalesLedgerService
    if ledger and ledger.GetObservedCutRate then
        local rate, samples = ledger:GetObservedCutRate()
        if rate and samples and samples >= MIN_INVOICES_FOR_OBSERVED_CUT and rate > 0 and rate < 0.5 then
            return rate, "observed"
        end
    end
    local cfg = tonumber(self:Config().ahCutRate) or 0.05
    return math.max(0, math.min(0.5, cfg)), "config"
end

---@return boolean
function Economy:IsAuctionHouseOpen()
    local f = _G.AuctionHouseFrame
    return f ~= nil and f.IsShown ~= nil and f:IsShown() == true
end

--- Round a unit price to what the AH accepts (whole silver unless copper is supported).
---@param copper number
---@param mode "down"|"up"|"nearest"|nil default "down" (never post above the intended price)
---@return number
function Economy:RoundPostPrice(copper, mode)
    copper = tonumber(copper) or 0
    if copper <= 0 then return 0 end
    local copperOK = C_AuctionHouse and C_AuctionHouse.SupportsCopperValues and C_AuctionHouse.SupportsCopperValues()
    if copperOK then
        return math.max(1, math.floor(copper + 0.5))
    end
    local silver
    if mode == "up" then
        silver = math.ceil(copper / 100)
    elseif mode == "nearest" then
        silver = math.floor(copper / 100 + 0.5)
    else
        silver = math.floor(copper / 100)
    end
    return math.max(100, silver * 100)
end

--- Smallest legal undercut step in copper (1 silver unless the AH accepts copper).
---@return number
function Economy:UndercutStep()
    local copperOK = C_AuctionHouse and C_AuctionHouse.SupportsCopperValues and C_AuctionHouse.SupportsCopperValues()
    return copperOK and 1 or 100
end

---@param itemID number
---@return number|nil copper vendor sell price per unit
function Economy:VendorSellPrice(itemID)
    if not itemID then return nil end
    local sell = select(11, GetItemInfo(itemID))
    sell = tonumber(sell)
    if sell and sell > 0 then return sell end
    return nil
end

--- Deposit for posting `qty` of a commodity.
---@param itemID number
---@param qty number
---@param duration number|nil 1/2/3 (defaults to config)
---@return number|nil copper
---@return boolean estimated true when the AH was closed and the wiki fallback was used
function Economy:EstimateDeposit(itemID, qty, duration)
    qty = math.max(1, tonumber(qty) or 1)
    duration = tonumber(duration) or tonumber(self:Config().postDuration) or 2
    -- CalculateCommodityDeposit(itemID, duration, quantity) is the commodity API; the item (non-
    -- commodity) deposit, CalculateItemDeposit, needs an ItemLocation of an owned item
    -- (AuctionHouseDocumentation 12.1.5.70448, checked 2026-10-17), so unstackable items such as gear
    -- take the vendor-price estimate below.
    local stack = tonumber((select(8, GetItemInfo(itemID))))
    local isCommodity = stack ~= nil and stack > 1
    if isCommodity and self:IsAuctionHouseOpen() and C_AuctionHouse and C_AuctionHouse.CalculateCommodityDeposit then
        local ok, dep = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, duration, qty)
        if ok and type(dep) == "number" then
            return dep, false
        end
    end
    local vsp = self:VendorSellPrice(itemID)
    if not vsp then
        return nil, true
    end
    local share = DEPOSIT_VSP_SHARE[duration] or DEPOSIT_VSP_SHARE[2]
    return math.max(100, math.floor(vsp * share * qty + 0.5)), true
end

--- Expected deposit lost per sold unit: each failed post forfeits the deposit, so with
--- sell-through s the expected number of extra posts per sale is (1/s - 1).
---@return number copper per unit (0 when no deposit is known)
function Economy:ExpectedDepositLossPerUnit(itemID)
    -- Deposits are charged per post (with a per-post minimum), so price a representative post
    -- and spread it over its units; pricing qty = 1 applied the minimum to every single unit.
    local stack = tonumber((select(8, GetItemInfo(itemID)))) or 1
    local postQty = math.max(1, math.min(stack, REPRESENTATIVE_POST_QTY))
    local depPost = self:EstimateDeposit(itemID, postQty)
    if not depPost or depPost <= 0 then return 0 end
    local dep = depPost / postQty
    local s = tonumber(self:Config().sellThroughRate) or 0.7
    s = math.max(0.05, math.min(1, s))
    return dep * (1 / s - 1)
end

--- What selling `qty` at `unitPrice` actually puts in the mailbox, after cut and expected deposit loss.
---@param itemID number
---@param unitPrice number
---@param qty number|nil default 1
---@return number copper
function Economy:NetSaleValue(itemID, unitPrice, qty)
    qty = tonumber(qty) or 1
    unitPrice = tonumber(unitPrice) or 0
    if unitPrice <= 0 or qty <= 0 then return 0 end
    local cut = self:CutRate()
    local gross = unitPrice * qty * (1 - cut)
    return gross - self:ExpectedDepositLossPerUnit(itemID) * qty
end

--- Unit price a new listing actually gets: one legal undercut below the market reference, rounded
--- to what the AH accepts. Craft revenue at the bare reference assumed we sell at the current
--- cheapest listing instead of beneath it.
---@param unitPrice number market reference price
---@return number copper (0 when unitPrice is not positive)
function Economy:SaleUnitPrice(unitPrice)
    unitPrice = tonumber(unitPrice) or 0
    if unitPrice <= 0 then return 0 end
    -- The highest legal price strictly below the reference (whole silver unless copper is accepted).
    local step = self:UndercutStep()
    local posted = math.ceil(unitPrice / step) * step - step
    -- At the AH's minimum price there is no room to undercut: match the reference.
    if posted <= 0 then return unitPrice end
    return posted
end

---@param itemID number
---@return table|nil raw ahPrices row { buyout, updatedAt, qty?, book? }
function Economy:GetMarketRow(itemID)
    local g = ns.db and ns.db.global
    local db = g and g.ahPrices
    if type(db) ~= "table" or not itemID then return nil end
    return db[itemID] or db[tonumber(itemID)] or db[tostring(itemID)]
end

--- Cost of buying `qty` units: walks the stored commodity book cheapest-first, then
--- continues at the last known level. Vendor price wins when cheaper.
--- The book is AN's own scan, so it is used only when AHPriceService resolves this item to
--- AN's scan too (source "an": the user's price source and the staleness rule both agree);
--- otherwise the resolved unit price is used, the same rule that prices craft outputs.
---@param itemID number
---@param qty number
---@return number|nil copper total
---@return string|nil source "vendor"|"book"|"price"
function Economy:BuyCost(itemID, qty)
    qty = math.max(0, tonumber(qty) or 0)
    if qty == 0 then return 0, nil end
    local vendor = ns.VendorPriceService and ns.VendorPriceService.GetBuyPrice
        and ns.VendorPriceService:GetBuyPrice(itemID)
    local bookCost
    local prices = ns.AHPriceService
    local unit, src
    if prices and prices.GetPriceInfo then
        local _
        unit, _, _, _, src = prices:GetPriceInfo(itemID)
    end
    local row = (src == "an") and self:GetMarketRow(itemID) or nil
    local book = row and row.book
    if type(book) == "table" and #book > 0 then
        local remaining, total, lastP = qty, 0, nil
        for i = 1, #book do
            local lvl = book[i]
            local take = math.min(remaining, tonumber(lvl.q) or 0)
            total = total + take * (tonumber(lvl.p) or 0)
            remaining = remaining - take
            lastP = tonumber(lvl.p)
            if remaining <= 0 then break end
        end
        if remaining > 0 and lastP then
            total = total + remaining * lastP
        end
        bookCost = total
    end
    if not bookCost and unit then
        bookCost = unit * qty
    end
    if vendor and (not bookCost or vendor * qty < bookCost) then
        return vendor * qty, "vendor"
    end
    if bookCost then
        return bookCost, (type(book) == "table" and #book > 0) and "book" or "price"
    end
    return nil, nil
end

--- Unit cost of a reagent the player will consume. Owned stock is valued at what it would
--- net on the AH (opportunity cost) when configured; missing stock at buy cost.
---@param itemID number
---@param qty number units consumed
---@param owned number|nil units already in bags
---@return number|nil copper total
function Economy:ReagentCost(itemID, qty, owned)
    qty = math.max(0, tonumber(qty) or 0)
    if qty == 0 then return 0 end
    owned = math.max(0, math.min(qty, tonumber(owned) or 0))
    local total = 0
    if owned > 0 then
        local unit = ns.AHPriceService and ns.AHPriceService.GetPrice and ns.AHPriceService:GetPrice(itemID)
        if not unit then
            local vendor = ns.VendorPriceService and ns.VendorPriceService:GetBuyPrice(itemID)
            unit = vendor
        end
        if not unit then return nil end
        if self:Config().ownedReagentsAtSellValue then
            total = total + self:NetSaleValue(itemID, unit, owned)
        else
            total = total + unit * owned
        end
    end
    local need = qty - owned
    if need > 0 then
        local buy = self:BuyCost(itemID, need)
        if not buy then return nil end
        total = total + buy
    end
    return total
end

--- Proc expectation factors for a recipe/profession. Calibrated values from the craft ledger
--- win once enough procs were observed; otherwise the configured defaults.
---@param spellID number|nil
---@param profession string|nil
---@return table { multicraftExtra, resourcefulnessSave, ingenuityRefund, source }
function Economy:ProcFactors(spellID, profession)
    local cfg = self:Config()
    local out = {
        multicraftExtra = tonumber(cfg.multicraftExtraFactor) or 0.5,
        resourcefulnessSave = tonumber(cfg.resourcefulnessSaveFactor) or 0.3,
        ingenuityRefund = tonumber(cfg.ingenuityRefundFactor) or 0.5,
        source = "config",
    }
    local ledger = ns.CraftLedgerService
    if ledger and ledger.GetCalibration then
        local cal = ledger:GetCalibration(spellID, profession)
        if type(cal) == "table" then
            if cal.multicraftExtra then out.multicraftExtra = cal.multicraftExtra; out.source = "observed" end
            if cal.resourcefulnessSave then out.resourcefulnessSave = cal.resourcefulnessSave; out.source = "observed" end
            if cal.ingenuityRefund then out.ingenuityRefund = cal.ingenuityRefund; out.source = "observed" end
        end
    end
    return out
end

--- Copper value of one concentration point: explicit setting, else the planner's shadow price.
---@param profession string|nil
---@return number copper (0 when unknown)
function Economy:ConcentrationValue(profession)
    local v = tonumber(self:Config().concentrationValue) or 0
    if v > 0 then return v end
    local planner = ns.ConcentrationPlannerService
    if planner and planner.GetShadowPrice then
        local sp = planner:GetShadowPrice(profession)
        if sp and sp > 0 then return sp end
    end
    return 0
end

ns.Economy = Economy
