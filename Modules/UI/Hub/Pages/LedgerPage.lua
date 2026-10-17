--[[
    Artisan Nexus — Hub tab: Ledger (key "ledger"), drawn as a Warband Nexus main-window tab.

    "How much did I actually earn?" Realized economics over profile.hubLedgerDays (7 or 30).
    WN tab pattern (StatisticsUI / CurrencyUI): ArtisanNexus:DrawLedgerTab(scrollChild) returns the
    body height; UI_TabHost.lua dispatches it, the main window owns header/rail/scroll.

      fixedHeader  UI_BeginTabChromeLayout -> UI_CreateStandardTabTitleCard (+ title-toolbar period
                   button) -> UI_PageStack_Place -> UI_CommitTabFixedHeader
      Stat cards   H.NewTabBody StatCards: Net / Revenue / AH cut; deposits, purchases and tips are in
                   the Net card tooltip
                   (SalesLedgerService:GetSummary(days) + GetObservedCutRate(), Economy:CutRate())
      Groups       body kit collapsible headers with a right-side summary; expand state in
                   profile.hubLedgerExpanded:
        Crafts     right = craft count and realized profit; tooltip = predicted vs actual, output
                   value, reagent cost, returned reagents, proc counts; rows = proc calibration per
                   profession (observed factors in green, settings dim)
        Gold       daily gold total (chart card)
        Top items  sold / revenue / net per item (sortable)
      Gold         SalesLedgerService:GetGoldHistory(days).total -> bars on one WN card
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

local function Tone(c)
    c = tonumber(c) or 0
    return (c > 0 and "success") or (c < 0 and "danger") or "dim"
end

local function Pct(n, d)
    if not d or d <= 0 then
        return 0
    end
    return math.floor((n or 0) / d * 100 + 0.5)
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

local CALIB_COLS = {
    { key = "prof", label = SafeL("HUB_COL_PROFESSION", "Profession"), flex = 1, min = COL.NAME_MIN_NARROW },
    { key = "crafts", label = SafeL("HUB_COL_CRAFTS", "Crafts"), width = COL.COUNT, align = "RIGHT" },
    { key = "mc", label = SafeL("HUB_COL_MULTICRAFT", "Multicraft"), width = 104, align = "RIGHT" },
    { key = "res", label = SafeL("HUB_COL_RESOURCEFULNESS", "Resourcefulness"), width = 116, align = "RIGHT" },
    { key = "ing", label = SafeL("HUB_COL_INGENUITY", "Ingenuity"), width = 104, align = "RIGHT" },
    { key = "src", label = SafeL("HUB_COL_SOURCE", "Source"), width = 80, align = "RIGHT" },
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

--- Cut rate in use and where it comes from (observed / setting), for the AH cut card tooltip.
local function CutCardSub(samples)
    local econ = ns.Economy
    local used, src = 0.05, "config"
    if econ and econ.CutRate then
        used, src = econ:CutRate()
    end
    local fmt = (src == "observed")
        and SafeL("HUB_LEDGER_CUT_OBSERVED_FMT", "(observed, %d invoices)")
        or SafeL("HUB_LEDGER_CUT_CONFIG_FMT", "(setting, %d invoices seen)")
    return string.format("%.1f%%", (used or 0) * 100), string.format(fmt, samples or 0)
end

--- Three cards (Net, Revenue, AH cut) without card lines; the rest of the period breakdown
--- (deposits, purchases, order tips, sales count, cut source) lives in the card tooltips.
local statList = { {}, {}, {} }
local function StatList(sum)
    local list = statList
    for i = 1, #list do
        wipe(list[i])
    end
    local ledger = ns.SalesLedgerService
    local rate, samples
    if ledger and ledger.GetObservedCutRate then
        rate, samples = ledger:GetObservedCutRate()
    end
    local c = list[1]
    c.icon = "Interface\\Icons\\Achievement_General"
    c.label = SafeL("HUB_COL_NET", "Net")
    c.value = Signed(sum.net)
    c.tooltip = table.concat({
        SafeL("HUB_LEDGER_DEPOSITS", "Deposits lost") .. ": " .. Cost(sum.deposits),
        string.format(SafeL("HUB_LDG_DEPOSITS_SUB_FMT", "Paid %s, refunded %s"),
            Money(sum.depositsPaid, nil, true), Money(sum.depositsRefunded, nil, true)),
        string.format(SafeL("HUB_LEDGER_BUYS_FMT", "Purchases (%d)"), sum.purchases or 0) .. ": " .. Cost(sum.buys),
        SafeL("HUB_LEDGER_ORDER_TIPS", "Order tips") .. ": " .. Money(sum.orderTips),
    }, "\n")
    c = list[2]
    c.icon = "Interface\\Icons\\INV_Misc_Coin_01"
    c.label = SafeL("HUB_LEDGER_REVENUE", "Revenue")
    c.value = Money(sum.revenue)
    c.tooltip = string.format(SafeL("HUB_LDG_SALES_SUB_FMT", "%d sales"), sum.sales or 0)
    c = list[3]
    c.icon = "Interface\\Icons\\INV_Misc_Coin_02"
    c.label = SafeL("HUB_LEDGER_CUT", "AH cut")
    c.value = Cost(sum.cut)
    local cutRate, cutSrc = CutCardSub(samples)
    c.tooltip = string.format("%s %s %s", SafeL("HUB_LEDGER_CUT_RATE", "AH cut rate"), cutRate, cutSrc)
    if rate then
        c.tooltip = c.tooltip .. "\n" .. string.format("%s ~%.1f%%", SafeL("HUB_LEDGER_CUT_RATE", "AH cut rate"), rate * 100)
    end
    return list
end

-- ─────────────────────────────────────────────────────────────────
-- Crafts: predicted vs actual + calibration
-- ─────────────────────────────────────────────────────────────────

--- Crafts header tooltip: what the realized profit is made of, then how often each stat procced.
local function CraftsTooltip(cs)
    local n = cs.crafts or 0
    local lines = {}
    local function Add(label, value)
        lines[#lines + 1] = label .. ": " .. value
    end
    local hasPred = (cs.predictedCrafts or 0) > 0
    Add(SafeL("HUB_LEDGER_PREDICTED", "Predicted profit"), hasPred and (Signed(cs.predictedProfit, true) .. " "
        .. Dim(string.format(SafeL("HUB_LEDGER_PRED_N_FMT", "(%d crafts)"), cs.predictedCrafts))) or Dim("-"))
    Add(SafeL("HUB_LEDGER_REALIZED", "Realized profit"), Signed(cs.profit, true))
    if hasPred then
        Add(SafeL("HUB_LDG_ACTUAL_VS_PRED", "Actual vs predicted"), Signed((cs.profit or 0) - (cs.predictedProfit or 0), true))
    end
    Add(SafeL("HUB_LEDGER_CRAFT_VALUE", "Output value (net)"), Money(cs.net, nil, true))
    Add(SafeL("HUB_TT_REAGENT_COST", "Reagent cost"), Cost(cs.cost))
    Add(SafeL("HUB_LEDGER_RETURNED", "Reagents returned"), Money(cs.returnedValue, nil, true))
    if (cs.unpriced or 0) > 0 then
        lines[#lines + 1] = Dim(string.format(SafeL("HUB_SHOPPING_UNPRICED_FMT", "(%d unpriced)"), cs.unpriced))
    end
    local procs = cs.procs or {}
    local procFmt = SafeL("HUB_LDG_PROCS_FMT", "%d procs")
    local rateFmt = SafeL("HUB_LDG_RATE_FMT", "%d%% of crafts")
    local function Proc(label, count)
        Add(label, string.format(procFmt, count or 0) .. " " .. Dim("(" .. string.format(rateFmt, Pct(count, n)) .. ")"))
    end
    lines[#lines + 1] = " "
    Proc(SafeL("HUB_COL_MULTICRAFT", "Multicraft"), procs.mc)
    Proc(SafeL("HUB_COL_RESOURCEFULNESS", "Resourcefulness"), procs.res)
    Proc(SafeL("HUB_COL_INGENUITY", "Ingenuity"), procs.ing)
    lines[#lines + 1] = " "
    lines[#lines + 1] = SafeL("HUB_LDG_CALIB_DESC", "Observed from your crafts (green), else settings.")
    return table.concat(lines, "\n")
end

--- "0.62 (14)" in success ink when observed, else the setting in dim ink.
local function FactorText(value, observed, samples)
    local txt = string.format("%.2f", tonumber(value) or 0)
    if observed then
        if samples and samples > 0 then
            txt = txt .. " (" .. samples .. ")"
        end
        return Ink(txt, "success")
    end
    return Dim(txt)
end

local function CalibrationRows(cs)
    local econ = ns.Economy
    local profs = {}
    for prof in pairs(cs.byProfession or {}) do
        if prof ~= "?" then profs[#profs + 1] = prof end
    end
    table.sort(profs)
    local craftLedger = ns.CraftLedgerService
    local b = Buf("calib")
    local cfg = econ:ProcFactors(nil, nil)
    local r = BufRow(b)
    r.prof = Dim(SafeL("HUB_LEDGER_SETTINGS_ROW", "Settings (default)"))
    r.crafts = Dim("-")
    r.mc = FactorText(cfg.multicraftExtra, false)
    r.res = FactorText(cfg.resourcefulnessSave, false)
    r.ing = FactorText(cfg.ingenuityRefund, false)
    r.src = Dim(SafeL("HUB_TT_CONFIG", "settings"))
    for i = 1, #profs do
        local prof = profs[i]
        local f = econ:ProcFactors(nil, prof)
        local cal = craftLedger and craftLedger.GetCalibration and craftLedger:GetCalibration(nil, prof)
        local samples = cal and cal.samples or {}
        r = BufRow(b)
        r.prof = ns.GetProfessionDisplayName and ns.GetProfessionDisplayName(prof) or prof
        r.crafts = tostring(cs.byProfession[prof].crafts or 0)
        r.mc = FactorText(f.multicraftExtra, cal and cal.multicraftExtra ~= nil, samples.mc)
        r.res = FactorText(f.resourcefulnessSave, cal and cal.resourcefulnessSave ~= nil, samples.res)
        r.ing = FactorText(f.ingenuityRefund, cal and cal.ingenuityRefund ~= nil, samples.ing)
        r.src = (f.source == "observed") and Ink(SafeL("HUB_TT_OBSERVED", "observed"), "success")
            or Dim(SafeL("HUB_TT_CONFIG", "settings"))
    end
    return BufRows(b)
end

-- ─────────────────────────────────────────────────────────────────
-- Gold over time (pooled bars on one WN card)
-- ─────────────────────────────────────────────────────────────────

local function ChartColor()
    local c = ns.UI_COLORS
    return (c and (c.sparkLine or c.accent)) or { 0.85, 0.65, 1.0, 1 }
end

local chartHost = {}

local function DrawGoldChart(parent, width, pts)
    local chart = chartHost.chart
    if not chart then
        chart = ns.UI_CreateCard(parent, CHART_H)
        if ns.UI_ApplyStandardCardElevatedChrome then
            ns.UI_ApplyStandardCardElevatedChrome(chart)
        end
        chart._bars = {}
        chart._title = FontManager:CreateFontString(chart, "small", "OVERLAY")
        chart._title:SetPoint("TOPLEFT", chart, "TOPLEFT", CHART_PAD, -6)
        chart._title:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -CHART_PAD, -6)
        chart._title:SetJustifyH("LEFT")
        chart._title:SetWordWrap(false)
        chartHost.chart = chart
    end
    body:PlaceWide(chart, CHART_H)
    local mn, mx = pts[1].m, pts[1].m
    for i = 2, #pts do
        local m = pts[i].m
        if m < mn then mn = m end
        if m > mx then mx = m end
    end
    local first, last = pts[1].m, pts[#pts].m
    chart._title:SetText(string.format(SafeL("HUB_LEDGER_GOLD_FMT", "Now %s - change %s - low %s - high %s"),
        Money(last, nil, true), Signed(last - first, true), Money(mn, nil, true), Money(mx, nil, true)))
    ns.UI_SetTextColorRole(chart._title, "Muted")
    local span = math.max(1, mx - mn)
    local n = #pts
    local area = math.max(1, width - CHART_PAD * 2)
    local slot = area / n
    local barW = math.max(2, math.floor(slot) - 2)
    local maxH = CHART_H - CHART_TITLE_H - CHART_PAD - 6
    local col = ChartColor()
    local bars = chart._bars
    for i = 1, n do
        local tex = bars[i]
        if not tex then
            tex = chart:CreateTexture(nil, "ARTWORK")
            bars[i] = tex
        end
        tex:SetColorTexture(col[1], col[2], col[3], (i == n) and 0.95 or 0.6)
        tex:SetSize(barW, 2 + math.floor((pts[i].m - mn) / span * maxH))
        tex:ClearAllPoints()
        tex:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", CHART_PAD + math.floor((i - 1) * slot), CHART_PAD)
        tex:Show()
    end
    for i = n + 1, #bars do
        bars[i]:Hide()
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

    body:StatCards(StatList(sum))

    -- Crafts: realized profit (header) + proc calibration rows
    local nCrafts = cs.crafts or 0
    if body:Section("crafts", SafeL("HUB_COL_CRAFTS", "Crafts"), {
            tooltip = (nCrafts > 0) and CraftsTooltip(cs) or nil,
            count = (nCrafts > 0) and string.format(SafeL("HUB_LDG_CRAFTS_SUM_FMT", "%d crafts · realized %s"),
                nCrafts, Signed(cs.profit)) or nil,
        }) then
        if nCrafts == 0 then
            body:Line("noCrafts", SafeL("HUB_LEDGER_NO_CRAFTS", "No crafts recorded in this period."))
        elseif ns.Economy and ns.Economy.ProcFactors then
            body:Table("calib", CALIB_COLS, CalibrationRows(cs), CellValue)
        end
    end

    -- Gold over time (the chart card is not a body-kit block: hide it unless drawn below)
    if chartHost.chart then
        chartHost.chart:Hide()
    end
    if body:Section("gold", SafeL("HUB_LEDGER_GOLD", "Gold"),
            { tooltip = SafeL("HUB_LDG_GOLD_DESC", "Daily total of your characters' gold and the warband bank.") }) then
        local hist = sales and sales.GetGoldHistory and sales:GetGoldHistory(days)
        local pts = hist and hist.total or {}
        if #pts < 2 then
            body:Line("goldEmpty", SafeL("HUB_LEDGER_GOLD_NONE", "Gold history appears after logging in on two different days."))
        else
            DrawGoldChart(parent, body.width, pts)
        end
    end

    -- Top items by net
    local topRows = TopItemRows(sum)
    if body:Section("top", SafeL("HUB_LEDGER_TOP_ITEMS", "Top items by net"), {
            count = (#topRows > 0) and string.format(SafeL("HUB_MKT_ITEMS_FMT", "%d items"), #topRows) or nil,
        }) then
        body:Table("top", TOP_COLS, topRows, TopValue, {
            onRowEnter = RowEnter, onRowLeave = RowLeave, onRowClick = RowClick, sort = TOP_SORT,
            emptyText = SafeL("HUB_LEDGER_NO_SALES", "No sales in this period."),
        })
    end

    return body.y
end
