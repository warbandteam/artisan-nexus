--[[
    Artisan Nexus — Hub tab: Overview (key "overview"), drawn as a Warband Nexus main-window tab.

    "What should I do right now to make gold?" Three WN stat cards (icon + short label + one value;
    only Best craft keeps a line, the recipe name; details are in the card tooltip; click opens the tab
    that answers the follow-up), then a Top crafts table.
    Every read is pcall-guarded, so a disabled service shows a dim "-" card:
      Best craft now    ProfitabilityService:ListRecipes  (top margin, priced rows only) -> Crafting
                        with that recipe pinned to the top (ArtisanNexus:OpenCraftingRecipe)
      Net, 7 days       SalesLedgerService:GetSummary(7).net, tooltip = GetSummary(1).net -> Ledger
      Undercut auctions OwnedAuctionsService:GetUndercut, tooltip = active auctions (GetOwned) -> Auction House
      Top crafts        the five most profitable crafts of the Best craft list; row click = Best craft
    Title-card subtitle: what the page is for, then AH price freshness (AHPriceService:GetCacheStats),
    orange when stale. Top crafts header: profitable recipe count on the right.

    WN tab pattern (StatisticsUI): fixedHeader UI_BeginTabChromeLayout -> UI_CreateStandardTabTitleCard
    -> UI_PageStack_Place -> UI_CommitTabFixedHeader; body = H.NewTabBody (stat cards, collapsible
    section, TableKit table; Hub/HubTabKit.lua).
    Refresh: UI_RefreshRouter.lua (AN_TAB_REFRESH rows naming "overview" or "*").
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local H = ns.HubUI_Internal
assert(H and H.NewTabBody, "Hub/HubTabKit.lua must load before Hub/Pages/OverviewPage.lua")

local TK = ns.UI_TableKit
local SafeL = H.SafeL
local SafeNumber = H.SafeNumber
local FormatDuration = H.FormatDuration
local RecipeRowName = H.RecipeRowName
local Money, Signed, Dim, Ink = H.Money, H.Signed, H.Dim, H.Ink
local COL = H.COL

local DASH = "-"
local TOP_CRAFTS = 5

local function Call(svc, method, ...)
    if svc and svc[method] then
        local ok, a = pcall(svc[method], svc, ...)
        if ok then
            return a
        end
    end
    return nil
end

local function Nav(key)
    return function()
        ArtisanNexus:ShowMainWindow(key)
    end
end

local function NoData(card)
    card.value, card.tone = DASH, "dim"
    card.tooltip = SafeL("HUB_NO_DATA", "no data")
end

-- ─────────────────────────────────────────────────────────────────
-- Profitable crafts (Best craft card + Top crafts table)
-- ─────────────────────────────────────────────────────────────────

--- Unpriced reagents make a fake margin; such rows are left out (CraftingPage ProfitOf).
local function PricedMargin(r)
    if (SafeNumber(r.missingReagentPrices) or 0) > 0 or (SafeNumber(r.cost) or 0) <= 0 then
        return nil
    end
    return SafeNumber(r.margin)
end

local function MarginDesc(a, b)
    return a._anMargin > b._anMargin
end

local profitable = {}

--- Profitable priced crafts, highest margin first (rows are the service's tables; _anMargin cached).
local function ProfitableCrafts()
    wipe(profitable)
    local rows = Call(ns.ProfitabilityService, "ListRecipes", {
        harvestedOnly = true, compareConcentration = true, knownBy = H.HubKnownBy(),
    })
    if type(rows) == "table" then
        for i = 1, #rows do
            local m = PricedMargin(rows[i])
            if m and m > 0 then
                rows[i]._anMargin = m
                profitable[#profitable + 1] = rows[i]
            end
        end
    end
    table.sort(profitable, MarginDesc)
    return profitable
end

local function HasRecipes()
    local st = Call(ns.RecipeService, "GetStats")
    return type(st) == "table" and (st.harvested or 0) > 0
end

local function CacheStats()
    local st = Call(ns.AHPriceService, "GetCacheStats")
    return type(st) == "table" and st or nil
end

-- ─────────────────────────────────────────────────────────────────
-- Cards
-- ─────────────────────────────────────────────────────────────────

--- Best craft: the most profitable row whose prices are trustworthy (EV confidence not "low":
--- stale output price, missing prices); falls back to the top row when every row is low.
local function BestRow(list)
    for i = 1, #list do
        if list[i].confidence ~= "low" then
            return list[i]
        end
    end
    return list[1]
end

local function BestCraftCard(card, list)
    local best = BestRow(list)
    card.label = SafeL("HUB_OV_BEST_CRAFT", "Best craft now")
    card.icon = best and H.RecipeIconTexture(best.spellID, best.outputItem) or "Interface\\Icons\\Trade_Engineering"
    if best then
        local spellID = best.spellID
        card.value, card.tone = Signed(best._anMargin), nil
        card.sub = RecipeRowName(best)
        card.onClick = function()
            ArtisanNexus:OpenCraftingRecipe(spellID)
        end
        return
    end
    card.onClick = Nav("crafting")
    card.value, card.tone = DASH, "dim"
    local st = CacheStats()
    if not HasRecipes() then
        card.sub = SafeL("HUB_CRAFT_EMPTY_RECIPES", "No recipes read yet")
    elseif not st or (st.total or 0) == 0 then
        card.sub = SafeL("HUB_MKT_NO_DATA", "No AH data")
    else
        card.sub = SafeL("HUB_OV_NONE_PROFITABLE", "None profitable")
    end
end

local function NetCard(card)
    local week = Call(ns.SalesLedgerService, "GetSummary", 7)
    local day = Call(ns.SalesLedgerService, "GetSummary", 1)
    card.icon = "Interface\\Icons\\INV_Misc_Coin_01"
    card.label = SafeL("HUB_OV_NET_7D", "Net, 7 days")
    card.onClick = Nav("ledger")
    local net = type(week) == "table" and SafeNumber(week.net) or nil
    if not net then
        NoData(card)
        return
    end
    card.value, card.tone = Signed(net), nil
    local today = type(day) == "table" and SafeNumber(day.net) or 0
    card.tooltip = string.format(SafeL("HUB_OV_24H_FMT", "24h: %s"), Signed(today))
end

local function UndercutCard(card)
    local svc = ns.OwnedAuctionsService
    local list = Call(svc, "GetUndercut")
    local snap = Call(svc, "GetOwned")
    card.icon = "Interface\\Icons\\INV_Misc_Coin_02"
    card.label = SafeL("HUB_OV_UNDERCUT", "Undercut auctions")
    card.onClick = Nav("market")
    if type(snap) ~= "table" then
        NoData(card)
        return
    end
    local n = type(list) == "table" and #list or 0
    card.value = tostring(n)
    card.tone = n > 0 and "danger" or nil
    local active = 0
    local auctions = type(snap.auctions) == "table" and snap.auctions or {}
    for i = 1, #auctions do
        if auctions[i].status == 0 then -- Enum.AuctionStatus.Active = 0 (MarketPage DrawOwned)
            active = active + 1
        end
    end
    card.tooltip = string.format(SafeL("HUB_OV_ACTIVE_FMT", "%d active"), active)
end

--- Builders in display order; each fills one reused card-data table.
local BUILDERS = { BestCraftCard, NetCard, UndercutCard }
local cardData = {}

-- ─────────────────────────────────────────────────────────────────
-- Top crafts (WN TableKit)
-- ─────────────────────────────────────────────────────────────────

local TOP_COLS = {
    H.IconColumn(),
    { key = "name", label = SafeL("HUB_COL_RECIPE", "Recipe"), flex = 1, min = COL.NAME_MIN },
    { key = "prof", label = SafeL("HUB_COL_PROFESSION", "Profession"), width = 110 },
    { key = "cost", label = SafeL("HUB_CRAFT_COL_COST", "Craft cost"), width = COL.MONEY, align = "RIGHT" },
    { key = "profit", label = SafeL("HUB_COL_PROFIT", "Profit"), width = COL.MONEY, align = "RIGHT" },
    { key = "pct", label = SafeL("HUB_CRAFT_COL_PROFIT_PCT", "Profit %"), width = COL.PCT, align = "RIGHT" },
}

local function TopValue(col, r)
    local k = col.key
    if k == "icon" then
        return H.RecipeIconTexture(r.spellID, r.outputItem)
    elseif k == "name" then
        return RecipeRowName(r), "Bright"
    elseif k == "prof" then
        local p = r.profession
        return p and (ns.GetProfessionDisplayName and ns.GetProfessionDisplayName(p) or tostring(p)) or DASH, "Muted"
    elseif k == "cost" then
        return Money(r.cost), "Normal"
    elseif k == "profit" then
        if r.confidence == "low" then
            return Dim(TK.FormatSignedMoneyPlain(math.floor(r._anMargin + 0.5), 12)), "Normal"
        end
        return Signed(r._anMargin), "Normal"
    end
    local pct = SafeNumber(r.marginPct)
    if not pct then
        return Dim(DASH)
    end
    return Ink(string.format("%+d%%", math.floor(pct + 0.5)), pct >= 0 and "success" or "danger"), "Normal"
end

local function TopRowClick(row, r, button)
    if button == "LeftButton" and r and r.spellID then
        ArtisanNexus:OpenCraftingRecipe(r.spellID)
    end
end

local function TopRowEnter(row, r)
    if not r then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(RecipeRowName(r), 1, 1, 1)
    GameTooltip:AddDoubleLine(SafeL("HUB_TT_PER_CRAFT_PROFIT", "Expected profit per craft"), Signed(r._anMargin, true),
        0.75, 0.75, 0.75, 1, 1, 1)
    if r.confidence == "low" then
        GameTooltip:AddLine(SafeL("HUB_TT_LOW_CONFIDENCE", "Low confidence: the sale price is old or missing."), 1, 0.5, 0.3, true)
    end
    GameTooltip:AddLine(SafeL("HUB_OV_TT_CLICK_CRAFTING", "Click: show in the Crafting tab"), 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local topRows = {}

-- ─────────────────────────────────────────────────────────────────
-- Tab
-- ─────────────────────────────────────────────────────────────────

local body = H.NewTabBody("overview", "hubOverviewExpanded")

--- Title-card subtitle: AH price age; orange when most cached prices are stale or none exist.
local function FreshnessText()
    local st = CacheStats()
    if not st or (st.total or 0) == 0 then
        return Ink(SafeL("HUB_MKT_NO_DATA", "No AH data"), "orange")
    end
    local newest = SafeNumber(st.newest) or 0
    local text = newest > 0 and string.format(SafeL("HUB_OV_AH_SUB_FMT", "AH prices: %s ago"), FormatDuration(time() - newest))
        or SafeL("HUB_MKT_NO_DATA", "No AH data")
    if (st.stale or 0) > (st.fresh or 0) then
        return Ink(text, "orange")
    end
    return text
end

---@param parent Frame main-window scrollChild
---@return number contentHeight
function ArtisanNexus:DrawOverviewTab(parent)
    local mf = body:Begin(parent)
    H.state.frame = mf

    -- Fixed header: WN title card (no toolbar; every card is a shortcut).
    local chrome = ns.UI_BeginTabChromeLayout and ns.UI_BeginTabChromeLayout(mf)
    if chrome then
        local titleCard = select(1, ns.UI_CreateStandardTabTitleCard(chrome.headerParent, {
            tabKey = "overview",
            titleText = H.AccentTitle(SafeL("HUB_PAGE_OVERVIEW", "Overview")),
            subtitleText = SafeL("HUB_OV_SUB", "Best gold moves right now") .. "  " .. Dim("\194\183") .. "  "
                .. FreshnessText(),
            showUnderline = false,
        }))
        titleCard:Show()
        ns.UI_CommitTabFixedHeader(mf, ns.UI_PageStack_Place(chrome, titleCard))
    end

    local crafts = ProfitableCrafts()
    for i = 1, #BUILDERS do
        local d = cardData[i]
        if not d then
            d = {}
            cardData[i] = d
        end
        wipe(d)
        BUILDERS[i](d, crafts)
    end
    body:StatCards(cardData)

    if #crafts > 0 then
        local n = math.min(TOP_CRAFTS, #crafts)
        for i = 1, n do
            topRows[i] = crafts[i]
        end
        for i = n + 1, #topRows do
            topRows[i] = nil
        end
        if body:Section("top", SafeL("HUB_OV_TOP_CRAFTS", "Top crafts"), {
                count = string.format(SafeL("HUB_CRAFT_GROUP_COUNT_FMT", "%d profitable"), #crafts),
            }) then
            body:Table("top", TOP_COLS, topRows, TopValue, { onRowClick = TopRowClick, onRowEnter = TopRowEnter })
        end
    end
    return body.y
end
