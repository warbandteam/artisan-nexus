--[[
    Artisan Nexus — Hub tab: Ledger (key "ledger"), drawn as a Warband Nexus main-window tab.

    "How much did I actually earn?" Realized economics over profile.hubLedgerDays (7 or 30).
    WN tab pattern (StatisticsUI / CurrencyUI): ArtisanNexus:DrawLedgerTab(scrollChild) returns the
    body height; UI_TabHost.lua dispatches it, the main window owns header/rail/scroll.

      fixedHeader  UI_BeginTabChromeLayout -> UI_CreateStandardTabTitleCard (+ title-toolbar period
                   button) -> UI_PageStack_Place -> UI_CommitTabFixedHeader
      Stat cards   H.NewTabBody StatCards: Sales (net) / Crafting profit / Gold (now, change this period);
                   a card without data shows a dash and says how it fills; breakdowns are card tooltips
                   (SalesLedgerService:GetSummary(days), CraftLedgerService:GetSummary(days), GetGoldHistory)
      Empty        nothing recorded in the period -> one WN empty-state card instead of empty sections
      Groups       body kit collapsible headers with a right-side summary, shown only when they have data;
                   expand state in profile.hubLedgerExpanded:
        Gold       daily total bars on one WN card, baseline below the low, day labels, bar tooltips
        Top items  sold / revenue / net per item (sortable)
        Crafts     profession / crafts / profit; proc factors (observed or settings) in the row tooltip
    Refresh: UI_RefreshRouter.lua maps SALES_LEDGER_UPDATED / CRAFT_LEDGER_UPDATED (and
    ECONOMY_CONFIG_CHANGED for the visible tab) to this tab.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local H = ns.HubUI_Internal
assert(H and H.NewTabBody, "Hub/HubTabKit.lua must load before Hub/Pages/LedgerPage.lua")

local FontManager = ns.FontManager
local E = ns.Constants.EVENTS
local SafeL = H.SafeL
local ItemLink = H.ItemLink
local Dim, Ink = H.Dim, H.Ink
local COL = H.COL

local TOP_ITEMS = 15
--- Gold chart card (body height, inner pad, title band).
local CHART_H, CHART_PAD, CHART_TITLE_H = 120, 10, 22

local function Profile()
    return ns.db and ns.db.profile
end

--- Selected period in days (profile.hubLedgerDays: 7 default, or 30).
local function LedgerDays()
    local p = Profile()
    return (p and p.hubLedgerDays == 30) and 30 or 7
end

local Money, Signed = H.Money, H.Signed

local function Cost(c)
    c = tonumber(c) or 0
    return (c > 0) and ("-" .. Money(c)) or Dim("0")
end



local function CellValue(col, d)
    return d[col.key], d.role
end

local function TopValue(col, d)
    if col.key == "icon" then
        return d.icon
    end
    return d[col.key], d.role
end

local function RowEnter(row, d)
    if not d or not d.itemID then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(d.itemID)
    GameTooltip:Show()
end

local function RowLeave()
    GameTooltip:Hide()
end

local function RowClick(row, d, button)
    if button == "LeftButton" and d and d.itemID and IsModifiedClick() then
        HandleModifiedItemClick(ItemLink(d.itemID))
    end
end

--- Data tables reused between draws.
local bufs = {}
local function Buf(name)
    local b = bufs[name]
    if not b then
        b = { list = {}, n = 0 }
        bufs[name] = b
    end
    b.n = 0
    return b
end

local function BufRow(b)
    b.n = b.n + 1
    local r = b.list[b.n]
    if r then
        wipe(r)
    else
        r = {}
        b.list[b.n] = r
    end
    return r
end

local function BufRows(b)
    for i = #b.list, b.n + 1, -1 do
        b.list[i] = nil
    end
    return b.list
end

local body = H.NewTabBody("ledger", "hubLedgerExpanded")

-- ─────────────────────────────────────────────────────────────────
-- Columns
-- ─────────────────────────────────────────────────────────────────

--- Crafts by profession: what each profession earned. Proc factors live in the row tooltip.
local PROF_COLS = {
    { key = "prof", label = SafeL("HUB_COL_PROFESSION", "Profession"), flex = 1, min = COL.NAME_MIN_NARROW },
    { key = "crafts", label = SafeL("HUB_COL_CRAFTS", "Crafts"), width = COL.COUNT, align = "RIGHT" },
    { key = "profit", label = SafeL("HUB_COL_PROFIT", "Profit"), width = COL.MONEY_WIDE, align = "RIGHT" },
}

local TOP_COLS = {
    H.IconColumn(),
    { key = "item", label = SafeL("HUB_COL_ITEM", "Item"), flex = 1, min = COL.NAME_MIN, sortable = true },
    { key = "sold", label = SafeL("HUB_COL_SOLD", "Sold"), width = COL.COUNT, align = "RIGHT", sortable = true,
        defaultAscending = false },
    { key = "revenue", label = SafeL("HUB_LEDGER_REVENUE", "Revenue"), width = COL.MONEY_WIDE, align = "RIGHT",
        sortable = true, defaultAscending = false },
    { key = "net", label = SafeL("HUB_COL_NET", "Net"), width = COL.MONEY_WIDE, align = "RIGHT", sortable = true,
        defaultAscending = false },
}

--- Top items header sort (raw values kept on the row data).
local TOP_SORT = {
    key = "net", asc = false,
    value = function(d, key)
        if key == "item" then return d.sortName end
        if key == "sold" then return d.soldN end
        if key == "revenue" then return d.revenueN end
        return d.netN
    end,
}

-- ─────────────────────────────────────────────────────────────────
-- Stat cards
-- ─────────────────────────────────────────────────────────────────

--- "label: value" tooltip line.
local function TipLine(label, value)
    return label .. ": " .. value
end

--- Gold series of the period: first, last, low, high (nil when fewer than two days are known).
local function GoldRange(pts)
    if not pts or #pts < 2 then return nil end
    local mn, mx = pts[1].m, pts[1].m
    for i = 2, #pts do
        local m = pts[i].m
        if m < mn then mn = m end
        if m > mx then mx = m end
    end
    return { first = pts[1].m, last = pts[#pts].m, low = mn, high = mx }
end

--- Three cards answering "did I earn?": sales, crafting, gold. A card with no data shows a dash, not
--- "0 copper"; breakdowns (cut, deposits, purchases, tips, predicted profit, low / high) are tooltips.
local statList = { {}, {}, {} }
local function StatList(sum, cs, gold)
    local list = statList
    for i = 1, #list do
        wipe(list[i])
    end
    local c = list[1]
    c.icon = "Interface\\Icons\\INV_Misc_Coin_01"
    c.label = SafeL("HUB_LDG_CARD_SALES", "Sales")
    if (sum.sales or 0) > 0 or (sum.purchases or 0) > 0 then
        c.value = Signed(sum.net)
        c.sub = string.format(SafeL("HUB_LDG_SALES_SUB_FMT", "%d sales"), sum.sales or 0)
        c.tooltip = table.concat({
            TipLine(SafeL("HUB_LEDGER_REVENUE", "Revenue"), Money(sum.revenue, nil, true)),
            TipLine(SafeL("HUB_LEDGER_CUT", "AH cut"), Cost(sum.cut)),
            TipLine(SafeL("HUB_LEDGER_DEPOSITS", "Deposits lost"), Cost(sum.deposits)),
            TipLine(string.format(SafeL("HUB_LEDGER_BUYS_FMT", "Purchases (%d)"), sum.purchases or 0), Cost(sum.buys)),
            TipLine(SafeL("HUB_LEDGER_ORDER_TIPS", "Order tips"), Money(sum.orderTips, nil, true)),
        }, "\n")
    else
        c.value = Dim("-")
        c.sub = SafeL("HUB_LDG_NO_SALES_SUB", "No sales yet")
        c.tooltip = SafeL("HUB_LDG_SALES_HOW", "Sales are read from your Auction House mail.")
    end
    c = list[2]
    c.icon = "Interface\\Icons\\Trade_BlackSmithing"
    c.label = SafeL("HUB_LDG_CARD_CRAFTS", "Crafting profit")
    local nCrafts = cs.crafts or 0
    if nCrafts > 0 then
        c.value = Signed(cs.profit)
        c.sub = string.format(SafeL("HUB_LDG_CRAFTS_SUB_FMT", "%d crafts"), nCrafts)
        local lines = {
            TipLine(SafeL("HUB_LEDGER_CRAFT_VALUE", "Output value (net)"), Money(cs.net, nil, true)),
            TipLine(SafeL("HUB_TT_REAGENT_COST", "Reagent cost"), Cost(cs.cost)),
            TipLine(SafeL("HUB_LEDGER_RETURNED", "Reagents returned"), Money(cs.returnedValue, nil, true)),
        }
        if (cs.predictedCrafts or 0) > 0 then
            lines[#lines + 1] = TipLine(SafeL("HUB_LEDGER_PREDICTED", "Predicted profit"), Signed(cs.predictedProfit, true))
        end
        c.tooltip = table.concat(lines, "\n")
    else
        c.value = Dim("-")
        c.sub = SafeL("HUB_LDG_NO_CRAFTS_SUB", "No crafts yet")
        c.tooltip = SafeL("HUB_LDG_CRAFTS_HOW", "Crafts are recorded while the profession window is open.")
    end
    c = list[3]
    c.icon = "Interface\\Icons\\INV_Misc_Coin_02"
    c.label = SafeL("HUB_LDG_CARD_GOLD", "Gold")
    if gold then
        c.value = Money(gold.last, nil, true)
        local change = gold.last - gold.first
        c.sub = string.format(SafeL("HUB_LDG_GOLD_CHANGE_FMT", "%s this period"), Signed(change, true))
        c.tooltip = table.concat({
            TipLine(SafeL("HUB_LDG_GOLD_LOW", "Lowest"), Money(gold.low, nil, true)),
            TipLine(SafeL("HUB_LDG_GOLD_HIGH", "Highest"), Money(gold.high, nil, true)),
            SafeL("HUB_LDG_GOLD_DESC", "Daily total of your characters' gold and the warband bank."),
        }, "\n")
    else
        c.value = Money(GetMoney and GetMoney() or 0, nil, true)
        c.sub = SafeL("HUB_LDG_GOLD_WAIT", "Change shows from the second day")
        c.tooltip = SafeL("HUB_LDG_GOLD_DESC", "Daily total of your characters' gold and the warband bank.")
    end
    return list
end

-- ─────────────────────────────────────────────────────────────────
-- Crafts by profession (proc factors in the row tooltip)
-- ─────────────────────────────────────────────────────────────────

local function ProfRows(cs)
    local profs = {}
    for prof in pairs(cs.byProfession or {}) do
        if prof ~= "?" then profs[#profs + 1] = prof end
    end
    table.sort(profs)
    local b = Buf("prof")
    for i = 1, #profs do
        local prof = profs[i]
        local bp = cs.byProfession[prof]
        local r = BufRow(b)
        r.profKey = prof
        r.prof = ns.GetProfessionDisplayName and ns.GetProfessionDisplayName(prof) or prof
        r.crafts = tostring(bp.crafts or 0)
        r.profit = Signed((bp.net or 0) - (bp.cost or 0))
    end
    return BufRows(b)
end

--- Profession row tooltip: the proc factors its profit estimates use and whether they were observed.
local function ProfRowEnter(row, d)
    if not d or not d.profKey then return end
    local econ = ns.Economy
    if not (econ and econ.ProcFactors) then return end
    local f = econ:ProcFactors(nil, d.profKey)
    local observed = f.source == "observed"
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(d.prof, 1, 1, 1)
    local function Pair(label, v)
        GameTooltip:AddDoubleLine(label, string.format("%.2f", tonumber(v) or 0), 0.75, 0.75, 0.75, 1, 1, 1)
    end
    Pair(SafeL("HUB_COL_MULTICRAFT", "Multicraft"), f.multicraftExtra)
    Pair(SafeL("HUB_COL_RESOURCEFULNESS", "Resourcefulness"), f.resourcefulnessSave)
    Pair(SafeL("HUB_COL_INGENUITY", "Ingenuity"), f.ingenuityRefund)
    GameTooltip:AddLine(observed and SafeL("HUB_LDG_FACTORS_OBSERVED", "Learned from your crafts.")
        or SafeL("HUB_LDG_FACTORS_SETTINGS", "From settings until enough crafts are recorded."), 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
end

-- ─────────────────────────────────────────────────────────────────
-- Gold over time (pooled bars on one WN card)
-- ─────────────────────────────────────────────────────────────────

local function ChartColor()
    local c = ns.UI_COLORS
    return (c and (c.sparkLine or c.accent)) or { 0.85, 0.65, 1.0, 1 }
end

--- Day label "10/21" from SalesLedgerService DayIndex (yyyymmdd).
local function DayLabel(d)
    d = tonumber(d) or 0
    return string.format("%d/%d", math.floor(d / 100) % 100, d % 100)
end

local chartHost = {}

local function BarOnEnter(tex)
    local pt = tex._anPoint
    if not pt then return end
    GameTooltip:SetOwner(tex, "ANCHOR_TOP")
    GameTooltip:AddDoubleLine(DayLabel(pt.d), Money(pt.m, nil, true), 0.75, 0.75, 0.75, 1, 1, 1)
    GameTooltip:Show()
end

local function DrawGoldChart(parent, width, pts, range)
    local chart = chartHost.chart
    if not chart then
        chart = ns.UI_CreateCard(parent, CHART_H)
        if ns.UI_ApplyStandardCardElevatedChrome then
            ns.UI_ApplyStandardCardElevatedChrome(chart)
        end
        chart._bars, chart._labels = {}, {}
        chartHost.chart = chart
    end
    body:PlaceWide(chart, CHART_H)
    -- Baseline below the period low so the lowest day still shows a bar (scaling from the low made
    -- it zero-height: two days of data drew one lone bar).
    local span = math.max(1, range.high - range.low)
    local base = math.max(0, range.low - span * 0.5)
    local top = range.high - base
    local n = #pts
    local area = math.max(1, width - CHART_PAD * 2)
    local slot = area / n
    local barW = math.max(2, math.min(48, math.floor(slot) - 4))
    local maxH = CHART_H - CHART_TITLE_H - CHART_PAD
    local labelEvery = (n <= 10) and 1 or math.ceil(n / 8)
    local col = ChartColor()
    local bars, labels = chart._bars, chart._labels
    for i = 1, n do
        local bar = bars[i]
        if not bar then
            bar = CreateFrame("Frame", nil, chart)
            bar._tex = bar:CreateTexture(nil, "ARTWORK")
            bar._tex:SetAllPoints()
            bar:EnableMouse(true)
            bar:SetScript("OnEnter", BarOnEnter)
            bar:SetScript("OnLeave", RowLeave)
            bars[i] = bar
        end
        bar._anPoint = pts[i]
        bar._tex:SetColorTexture(col[1], col[2], col[3], (i == n) and 0.95 or 0.6)
        local x = CHART_PAD + math.floor((i - 1) * slot + (slot - barW) / 2)
        bar:SetSize(barW, 2 + math.floor((pts[i].m - base) / top * maxH))
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", x, CHART_TITLE_H - 4)
        bar:Show()
        local fs = labels[i]
        if not fs then
            fs = FontManager:CreateFontString(chart, "small", "OVERLAY")
            fs:SetJustifyH("CENTER")
            labels[i] = fs
        end
        fs:ClearAllPoints()
        fs:SetPoint("BOTTOM", chart, "BOTTOMLEFT", x + barW / 2, 4)
        fs:SetText(DayLabel(pts[i].d))
        ns.UI_SetTextColorRole(fs, "Dim")
        fs:SetShown((i - 1) % labelEvery == 0 or i == n)
    end
    for i = n + 1, #bars do
        bars[i]:Hide()
        if labels[i] then labels[i]:Hide() end
    end
    body.y = body.y + CHART_H
end

-- ─────────────────────────────────────────────────────────────────
-- Top items
-- ─────────────────────────────────────────────────────────────────

local function NetDesc(a, b)
    if (a.net or 0) ~= (b.net or 0) then
        return (a.net or 0) > (b.net or 0)
    end
    return (a.revenue or 0) > (b.revenue or 0)
end

local function TopItemRows(sum)
    local list = {}
    for _, it in pairs(sum.byItem or {}) do
        if (it.sold or 0) > 0 then list[#list + 1] = it end
    end
    table.sort(list, NetDesc)
    local b = Buf("top")
    for i = 1, math.min(TOP_ITEMS, #list) do
        local it = list[i]
        local r = BufRow(b)
        r.itemID = it.itemID
        local name = it.itemID and ns.GetItemDisplayName(it.itemID)
            or (ns.CoerceUiString and ns.CoerceUiString(it.name, "?")) or "?"
        r.icon = (it.itemID and ns.GetItemIconFileID and ns.GetItemIconFileID(it.itemID)) or 134400
        r.item, r.sortName = name, tostring(name)
        r.soldN, r.revenueN, r.netN = it.sold or 0, it.revenue or 0, it.net or 0
        r.sold = tostring(r.soldN)
        r.revenue = Money(it.revenue)
        r.net = Signed(it.net)
    end
    return BufRows(b)
end

-- ─────────────────────────────────────────────────────────────────
-- Tab
-- ─────────────────────────────────────────────────────────────────

local EMPTY_SALES = { byItem = {} }
local EMPTY_CRAFTS = { crafts = 0, procs = {}, byProfession = {} }
local EMPTY_KEY = "an_ledger_empty"

local function PeriodText()
    return string.format(SafeL("HUB_LEDGER_PERIOD_FMT", "Period: %d days"), LedgerDays())
end

---@param parent Frame main-window scrollChild
---@return number contentHeight
function ArtisanNexus:DrawLedgerTab(parent)
    local mf = body:Begin(parent)

    -- Fixed header: WN title card + title-toolbar period toggle.
    local chrome = ns.UI_BeginTabChromeLayout and ns.UI_BeginTabChromeLayout(mf)
    if chrome then
        local titleCard = select(1, ns.UI_CreateStandardTabTitleCard(chrome.headerParent, {
            tabKey = "ledger",
            titleText = H.AccentTitle(SafeL("HUB_TAB_SHORT_LEDGER", "Ledger")),
            subtitleText = string.format(SafeL("HUB_LEDGER_SUB_FMT", "What you earned in the last %d days"), LedgerDays()),
            showUnderline = false,
        }))
        titleCard:Show()
        H.LayoutToolbar(titleCard, nil, {
            H.ToolbarButton(titleCard, PeriodText(), function()
                local p = Profile()
                if not p then return end
                p.hubLedgerDays = (p.hubLedgerDays == 30) and 7 or 30
                ArtisanNexus:SendMessage(E.UI_MAIN_REFRESH_REQUESTED, { tab = "ledger", instantPopulate = true })
            end, SafeL("HUB_LEDGER_PERIOD_TT", "7 / 30 days")),
        })
        ns.UI_CommitTabFixedHeader(mf, ns.UI_PageStack_Place(chrome, titleCard))
    end

    local days = LedgerDays()
    local sales, crafts = ns.SalesLedgerService, ns.CraftLedgerService
    local sum = sales and sales.GetSummary and sales:GetSummary(days) or EMPTY_SALES
    local cs = crafts and crafts.GetSummary and crafts:GetSummary(days) or EMPTY_CRAFTS
    local hist = sales and sales.GetGoldHistory and sales:GetGoldHistory(days)
    local pts = hist and hist.total or {}
    local gold = GoldRange(pts)

    body:StatCards(StatList(sum, cs, gold))

    if chartHost.chart then
        chartHost.chart:Hide()
    end
    if ns.UI_HideEmptyStateCard then
        ns.UI_HideEmptyStateCard(parent, EMPTY_KEY)
    end
    local nCrafts = cs.crafts or 0
    local topRows = TopItemRows(sum)
    -- Nothing recorded: one explanation instead of three empty sections.
    if nCrafts == 0 and #topRows == 0 and not gold then
        body:Empty(EMPTY_KEY, SafeL("HUB_LDG_EMPTY_TITLE", "Nothing recorded yet"),
            SafeL("HUB_LDG_EMPTY_DESC", "Collect your Auction House mail and craft with the profession window open; earnings show up here."),
            "Professions-Icon-Accept-Order")
        return body.y
    end

    if gold and body:Section("gold", SafeL("HUB_LEDGER_GOLD", "Gold"), {
            tooltip = SafeL("HUB_LDG_GOLD_DESC", "Daily total of your characters' gold and the warband bank."),
        }) then
        DrawGoldChart(parent, body.width, pts, gold)
    end

    if #topRows > 0 and body:Section("top", SafeL("HUB_LEDGER_TOP_ITEMS", "Top items by net"), {
            count = string.format(SafeL("HUB_MKT_ITEMS_FMT", "%d items"), #topRows),
        }) then
        body:Table("top", TOP_COLS, topRows, TopValue, {
            onRowEnter = RowEnter, onRowLeave = RowLeave, onRowClick = RowClick, sort = TOP_SORT,
        })
    end

    if nCrafts > 0 and body:Section("crafts", SafeL("HUB_COL_CRAFTS", "Crafts"), {
            count = string.format(SafeL("HUB_LDG_CRAFTS_SUM_FMT", "%d crafts · realized %s"), nCrafts, Signed(cs.profit)),
        }) then
        body:Table("prof", PROF_COLS, ProfRows(cs), CellValue, { onRowEnter = ProfRowEnter, onRowLeave = RowLeave })
    end

    return body.y
end
