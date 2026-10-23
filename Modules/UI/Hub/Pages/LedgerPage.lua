--[[
    Artisan Nexus — Hub tab: Ledger (key "ledger"), drawn as a Warband Nexus main-window tab.

    A book of what actually happened to your gold over profile.hubLedgerDays (7 or 30): every AH sale,
    AH purchase, crafting-order tip and craft, one row each, grouped by day. The Crafting page shows
    what a craft WOULD earn; the Ledger shows what you DID earn.

      fixedHeader  WN title card + title-toolbar buttons: period (7 / 30 days), entry type filter
      Stat cards   In (sales + order tips) / Out (purchases + deposits lost) / Net (In - Out); the
                   breakdowns, crafting profit and the gold total trend are card tooltips
      Days         WN collapsible headers (Today, Yesterday, date) with the day's net on the right;
                   rows = [icon] item | what happened | amount (green in, red out, dim for crafts,
                   which are valued at market, not cash); row tooltip = the item + entry details
      Empty        one WN empty-state card saying where entries come from
    Data: SalesLedgerService GetSales / GetBuys / GetOrderTips / GetSummary / GetGoldHistory,
    CraftLedgerService GetCrafts / GetSummary. Expand state in profile.hubLedgerExpanded.
    Refresh: UI_RefreshRouter.lua maps SALES_LEDGER_UPDATED / CRAFT_LEDGER_UPDATED to this tab.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local H = ns.HubUI_Internal
assert(H and H.NewTabBody, "Hub/HubTabKit.lua must load before Hub/Pages/LedgerPage.lua")

local E = ns.Constants.EVENTS
local SafeL = H.SafeL
local ItemLink = H.ItemLink
local Dim, Ink = H.Dim, H.Ink
local Money, Signed = H.Money, H.Signed
local COL = H.COL

--- Rows per day group before "+N more" (the period can hold thousands of mail invoices).
local MAX_DAY_ROWS = 40
local KIND_COL_W = 150

local function Profile()
    return ns.db and ns.db.profile
end

--- Selected period in days (profile.hubLedgerDays: 7 default, or 30).
local function LedgerDays()
    local p = Profile()
    return (p and p.hubLedgerDays == 30) and 30 or 7
end

--- Entry type filter (profile.hubLedgerKind): "all" | "sales" | "buys" | "crafts".
local KINDS = { "all", "sales", "buys", "crafts" }
local function KindFilter()
    local p = Profile()
    local k = p and p.hubLedgerKind
    for i = 1, #KINDS do
        if KINDS[i] == k then return k end
    end
    return "all"
end

local function KindLabel(k)
    if k == "sales" then return SafeL("HUB_LDG_KIND_SALES", "Sales") end
    if k == "buys" then return SafeL("HUB_LDG_KIND_BUYS", "Purchases") end
    if k == "crafts" then return SafeL("HUB_LDG_KIND_CRAFTS", "Crafts") end
    return SafeL("HUB_LDG_KIND_ALL", "All entries")
end

local function Cost(c)
    c = tonumber(c) or 0
    return (c > 0) and ("-" .. Money(c, nil, true)) or Dim("0")
end

-- ─────────────────────────────────────────────────────────────────
-- Entries
-- ─────────────────────────────────────────────────────────────────

local function DayIndex(t)
    local d = date("*t", t)
    return d.year * 10000 + d.month * 100 + d.day
end

--- "Today", "Yesterday", else the localized short date.
local function DayTitle(day, today, yesterday)
    if day == today then return SafeL("HUB_LDG_TODAY", "Today") end
    if day == yesterday then return SafeL("HUB_LDG_YESTERDAY", "Yesterday") end
    local y, m, d = math.floor(day / 10000), math.floor(day / 100) % 100, day % 100
    return date("%a %d %b", time({ year = y, month = m, day = d, hour = 12 }))
end

local function ItemOf(id, name)
    if id then
        return ns.GetItemDisplayName and ns.GetItemDisplayName(id) or tostring(id)
    end
    return (ns.CoerceUiString and ns.CoerceUiString(name, "?")) or tostring(name or "?")
end

--- One flat list of entries (newest first): { t, kind, itemID?, item, what, amount, cash, detail = {} }.
--- cash = false for crafts (market value of what was made, not money that moved).
local function CollectEntries(days, filter)
    local out = {}
    local sales, crafts = ns.SalesLedgerService, ns.CraftLedgerService
    if sales and (filter == "all" or filter == "sales") then
        for _, r in ipairs(sales.GetSales and sales:GetSales(days) or {}) do
            local qty = tonumber(r.qty) or 0
            out[#out + 1] = {
                t = r.t, kind = "sale", itemID = r.itemID, item = ItemOf(r.itemID, r.name),
                what = (qty > 0) and string.format(SafeL("HUB_LDG_SOLD_FMT", "Sold %d"), qty)
                    or SafeL("HUB_LDG_SOLD", "Sold"),
                -- Invoices: sale price minus cut (the refunded deposit is not income; GetSummary does
                -- the same). Header-only rows carry just the money received.
                amount = (tonumber(r.bid) and tonumber(r.cut)) and (r.bid - r.cut) or (tonumber(r.net) or 0),
                cash = true,
                detail = { gross = tonumber(r.bid) or tonumber(r.buyout), cut = tonumber(r.cut),
                    deposit = tonumber(r.deposit), qty = qty },
            }
        end
        for _, o in ipairs(sales.GetOrderTips and sales:GetOrderTips(days) or {}) do
            out[#out + 1] = {
                t = o.t, kind = "tip", item = ItemOf(nil, o.item),
                what = SafeL("HUB_LDG_ORDER_TIP", "Order tip"), amount = tonumber(o.tip) or 0, cash = true,
                detail = { customer = o.customer },
            }
        end
    end
    if sales and (filter == "all" or filter == "buys") then
        for _, b in ipairs(sales.GetBuys and sales:GetBuys(days) or {}) do
            local qty = tonumber(b.qty) or 0
            out[#out + 1] = {
                t = b.t, kind = "buy", itemID = b.itemID, item = ItemOf(b.itemID),
                what = string.format(SafeL("HUB_LDG_BOUGHT_FMT", "Bought %d"), qty),
                amount = -(tonumber(b.total) or 0), cash = true,
                detail = { qty = qty, estimated = b.est },
            }
        end
    end
    if crafts and (filter == "all" or filter == "crafts") then
        for _, r in ipairs(crafts.GetCrafts and crafts:GetCrafts(days) or {}) do
            local o = r.outputs and r.outputs[1]
            local qty = 0
            for _, out1 in ipairs(r.outputs or {}) do qty = qty + (tonumber(out1.qty) or 0) end
            local profit = crafts.RowProfit and crafts:RowProfit(r)
            local name = (o and o.itemID) and ItemOf(o.itemID)
                or (ns.RecipeService and r.spellID and ns.RecipeService:GetRecipeName(r.spellID)) or "?"
            out[#out + 1] = {
                t = r.t, kind = "craft", itemID = o and o.itemID, item = name,
                what = string.format(SafeL("HUB_LDG_CRAFTED_FMT", "Crafted %d"), qty),
                amount = profit, cash = false,
                detail = { row = r },
            }
        end
    end
    table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return out
end

--- Entries grouped by day, newest day first: { { day, title, rows, net, n } }.
local function GroupByDay(entries)
    local now = time()
    local today, yesterday = DayIndex(now), DayIndex(now - 86400)
    local groups, byDay = {}, {}
    for i = 1, #entries do
        local e = entries[i]
        local d = DayIndex(e.t or now)
        local g = byDay[d]
        if not g then
            g = { day = d, title = DayTitle(d, today, yesterday), rows = {}, net = 0, n = 0 }
            byDay[d] = g
            groups[#groups + 1] = g
        end
        g.n = g.n + 1
        if e.cash then g.net = g.net + (e.amount or 0) end
        g.rows[#g.rows + 1] = e
    end
    return groups
end

-- ─────────────────────────────────────────────────────────────────
-- Table
-- ─────────────────────────────────────────────────────────────────

local COLS = {
    H.IconColumn(),
    { key = "item", label = SafeL("HUB_COL_ITEM", "Item"), flex = 1, min = COL.NAME_MIN },
    { key = "what", label = "", width = KIND_COL_W },
    { key = "amount", label = "", width = COL.MONEY_EXACT, align = "RIGHT" },
}

--- Row view (pooled tables reused between paints).
local rowBufs = {}
local function RowsFor(key, list)
    local b = rowBufs[key]
    if not b then
        b = {}
        rowBufs[key] = b
    end
    local n = math.min(#list, MAX_DAY_ROWS)
    for i = 1, n do
        local e = list[i]
        local r = b[i] or {}
        b[i] = r
        r.entry = e
        r.icon = (e.itemID and ns.GetItemIconFileID and ns.GetItemIconFileID(e.itemID))
            or (e.kind == "tip" and 133784) or 134400
        r.item = e.item
        r.what = Dim(e.what)
        if e.amount == nil then
            r.amount = Dim(SafeL("HUB_NO_PRICE", "no price"))
        elseif e.cash then
            r.amount = Signed(e.amount)
        else
            -- Crafts: market value, not money that moved.
            r.amount = Dim(ns.UI_TableKit.FormatSignedMoneyPlain(math.floor(e.amount + 0.5), 12))
        end
    end
    for i = #b, n + 1, -1 do
        b[i] = nil
    end
    return b
end

local function RowValue(col, d)
    if col.key == "icon" then return d.icon end
    return d[col.key]
end

local function RowEnter(row, d)
    local e = d and d.entry
    if not e then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if e.itemID then
        GameTooltip:SetItemByID(e.itemID)
        GameTooltip:AddLine(" ")
    else
        GameTooltip:AddLine(e.item, 1, 1, 1)
    end
    local function Pair(label, value)
        GameTooltip:AddDoubleLine(label, value, 0.75, 0.75, 0.75, 1, 1, 1)
    end
    Pair(e.what, date("%H:%M", e.t or time()))
    local x = e.detail or {}
    if e.kind == "sale" then
        if x.gross then Pair(SafeL("HUB_LDG_GROSS", "Sale price"), Money(x.gross, nil, true)) end
        if x.cut then Pair(SafeL("HUB_LEDGER_CUT", "AH cut"), Cost(x.cut)) end
        Pair(SafeL("HUB_LDG_RECEIVED", "Received"), Money(e.amount, nil, true))
    elseif e.kind == "buy" then
        if (x.qty or 0) > 0 then
            Pair(SafeL("HUB_LDG_PER_UNIT", "Per unit"), Money(-(e.amount or 0) / x.qty, nil, true))
        end
        if x.estimated then
            GameTooltip:AddLine(SafeL("HUB_LDG_ESTIMATED", "Estimated until the AH invoice arrives."), 0.7, 0.7, 0.7, true)
        end
    elseif e.kind == "craft" then
        -- Same breakdown as Session Loot (LootHistoryUI_Draw.lua AddCraftBreakdown).
        if x.row and ns.UI_AddCraftBreakdown then
            ns.UI_AddCraftBreakdown(GameTooltip, x.row)
        end
        GameTooltip:AddLine(SafeL("HUB_LDG_CRAFT_NOTE", "Valued at market prices; not counted in In / Out."), 0.7, 0.7, 0.7, true)
    elseif e.kind == "tip" and x.customer then
        Pair(SafeL("HUB_LDG_CUSTOMER", "Customer"), tostring(x.customer))
    end
    GameTooltip:Show()
end

local function RowLeave()
    GameTooltip:Hide()
end

local function RowClick(row, d, button)
    local e = d and d.entry
    if button == "LeftButton" and e and e.itemID and IsModifiedClick() then
        HandleModifiedItemClick(ItemLink(e.itemID))
    end
end

-- ─────────────────────────────────────────────────────────────────
-- Stat cards
-- ─────────────────────────────────────────────────────────────────

local function TipLine(label, value)
    return label .. ": " .. value
end

local statList = { {}, {}, {} }
local function StatList(sum, cs, gold)
    for i = 1, #statList do
        wipe(statList[i])
    end
    local income = (sum.revenue or 0) - (sum.cut or 0) + (sum.orderTips or 0)
    local spent = (sum.buys or 0) + (sum.deposits or 0)
    local c = statList[1]
    c.icon = "Interface\\Icons\\INV_Misc_Coin_01"
    c.label = SafeL("HUB_LDG_CARD_IN", "In")
    c.value = (income > 0) and Money(income, nil, true) or Dim("-")
    c.sub = string.format(SafeL("HUB_LDG_SALES_SUB_FMT", "%d sales"), sum.sales or 0)
    c.tooltip = table.concat({
        TipLine(SafeL("HUB_LEDGER_REVENUE", "Revenue"), Money(sum.revenue, nil, true)),
        TipLine(SafeL("HUB_LEDGER_CUT", "AH cut"), Cost(sum.cut)),
        TipLine(SafeL("HUB_LEDGER_ORDER_TIPS", "Order tips"), Money(sum.orderTips, nil, true)),
    }, "\n")
    c = statList[2]
    c.icon = "Interface\\Icons\\INV_Misc_Coin_02"
    c.label = SafeL("HUB_LDG_CARD_OUT", "Out")
    c.value = (spent > 0) and ("-" .. Money(spent, nil, true)) or Dim("-")
    c.sub = string.format(SafeL("HUB_LDG_BUYS_SUB_FMT", "%d purchases"), sum.purchases or 0)
    c.tooltip = table.concat({
        TipLine(string.format(SafeL("HUB_LEDGER_BUYS_FMT", "Purchases (%d)"), sum.purchases or 0), Cost(sum.buys)),
        TipLine(SafeL("HUB_LEDGER_DEPOSITS", "Deposits lost"), Cost(sum.deposits)),
    }, "\n")
    c = statList[3]
    c.icon = "Interface\\Icons\\Achievement_General"
    c.label = SafeL("HUB_COL_NET", "Net")
    c.value = (income > 0 or spent > 0) and Signed(income - spent) or Dim("-")
    local lines = {}
    if (cs.crafts or 0) > 0 then
        lines[#lines + 1] = TipLine(string.format(SafeL("HUB_LDG_CRAFT_PROFIT_FMT", "Crafting profit (%d crafts)"), cs.crafts),
            Signed(cs.profit, true))
        -- Where it came from: multicraft extras and Resourcefulness are inside the profit.
        if (cs.mcValue or 0) > 0 then
            lines[#lines + 1] = TipLine(string.format(SafeL("HUB_LDG_MC_FMT", "  Multicraft (%d procs)"), cs.procs.mc),
                Signed(cs.mcValue, true))
        end
        if (cs.returnedValue or 0) > 0 then
            lines[#lines + 1] = TipLine(string.format(SafeL("HUB_LDG_RES_FMT", "  Resourcefulness (%d procs)"), cs.procs.res),
                Signed(cs.returnedValue, true))
        end
        if (cs.ingValue or 0) > 0 then
            lines[#lines + 1] = TipLine(string.format(SafeL("HUB_LDG_ING_FMT", "  Ingenuity (%d procs, concentration)"), cs.procs.ing),
                Signed(cs.ingValue, true))
        end
    end
    if gold then
        lines[#lines + 1] = TipLine(SafeL("HUB_LDG_GOLD_CHANGE", "Gold total change"), Signed(gold.last - gold.first, true))
        lines[#lines + 1] = TipLine(SafeL("HUB_LDG_GOLD_NOW", "Gold total now"), Money(gold.last, nil, true))
    end
    c.sub = gold and string.format(SafeL("HUB_LDG_GOLD_CHANGE_FMT", "%s this period"), Signed(gold.last - gold.first, true)) or nil
    c.tooltip = (#lines > 0) and table.concat(lines, "\n") or SafeL("HUB_LDG_NET_DESC", "In minus Out for the period.")
    return statList
end

--- First and last daily gold total of the period (nil with fewer than two days).
local function GoldRange(sales, days)
    local hist = sales and sales.GetGoldHistory and sales:GetGoldHistory(days)
    local pts = hist and hist.total
    if not pts or #pts < 2 then return nil end
    return { first = pts[1].m, last = pts[#pts].m }
end

-- ─────────────────────────────────────────────────────────────────
-- Tab
-- ─────────────────────────────────────────────────────────────────

local body = H.NewTabBody("ledger", "hubLedgerExpanded")
local EMPTY_SALES = { byItem = {} }
local EMPTY_CRAFTS = { crafts = 0, procs = {}, byProfession = {} }
local EMPTY_KEY = "an_ledger_empty"

local function Reload()
    ArtisanNexus:SendMessage(E.UI_MAIN_REFRESH_REQUESTED, { tab = "ledger", instantPopulate = true })
end

---@param parent Frame main-window scrollChild
---@return number contentHeight
function ArtisanNexus:DrawLedgerTab(parent)
    local mf = body:Begin(parent)
    local days, filter = LedgerDays(), KindFilter()

    -- Fixed header: WN title card + toolbar (period, entry type).
    local chrome = ns.UI_BeginTabChromeLayout and ns.UI_BeginTabChromeLayout(mf)
    if chrome then
        local titleCard, _, textContainer = ns.UI_CreateStandardTabTitleCard(chrome.headerParent, {
            tabKey = "ledger",
            titleText = H.AccentTitle(SafeL("HUB_TAB_SHORT_LEDGER", "Ledger")),
            subtitleText = string.format(SafeL("HUB_LDG_SUBTITLE_FMT",
                "Every sale, purchase and craft of the last %d days"), days),
            showUnderline = false,
        })
        titleCard:Show()
        H.LayoutToolbar(titleCard, textContainer, {
            H.ToolbarButton(titleCard, string.format(SafeL("HUB_LEDGER_PERIOD_FMT", "Period: %d days"), days), function()
                local p = Profile()
                if not p then return end
                p.hubLedgerDays = (days == 30) and 7 or 30
                Reload()
            end, SafeL("HUB_LEDGER_PERIOD_TT", "7 / 30 days")),
            H.ToolbarButton(titleCard, KindLabel(filter), function()
                local p = Profile()
                if not p then return end
                local nextKind = "all"
                for i = 1, #KINDS do
                    if KINDS[i] == filter then nextKind = KINDS[i % #KINDS + 1] break end
                end
                p.hubLedgerKind = nextKind
                Reload()
            end, SafeL("HUB_LDG_KIND_TT", "Show all entries, only sales, purchases or crafts.")),
        })
        ns.UI_CommitTabFixedHeader(mf, ns.UI_PageStack_Place(chrome, titleCard))
    end

    local sales, crafts = ns.SalesLedgerService, ns.CraftLedgerService
    local sum = sales and sales.GetSummary and sales:GetSummary(days) or EMPTY_SALES
    local cs = crafts and crafts.GetSummary and crafts:GetSummary(days) or EMPTY_CRAFTS
    body:StatCards(StatList(sum, cs, GoldRange(sales, days)))

    if ns.UI_HideEmptyStateCard then
        ns.UI_HideEmptyStateCard(parent, EMPTY_KEY)
    end
    local groups = GroupByDay(CollectEntries(days, filter))
    if #groups == 0 then
        body:Empty(EMPTY_KEY, SafeL("HUB_LDG_EMPTY_TITLE", "Nothing recorded yet"),
            SafeL("HUB_LDG_EMPTY_DESC2", "Sales and purchases are read from your Auction House mail, crafts while the profession window is open."),
            "Professions-Icon-Accept-Order")
        return body.y
    end

    for gi = 1, #groups do
        local g = groups[gi]
        local key = "d" .. g.day
        local summary = string.format(SafeL("HUB_LDG_DAY_SUM_FMT", "%d entries"), g.n)
        if g.net ~= 0 then
            summary = summary .. "  ·  " .. Signed(g.net)
        end
        if body:Section(key, g.title, { count = summary, gap = (gi > 1) and 8 or nil }) then
            local rows = RowsFor(key, g.rows)
            body:Table(key, COLS, rows, RowValue, {
                onRowEnter = RowEnter, onRowLeave = RowLeave, onRowClick = RowClick,
            })
            if #g.rows > MAX_DAY_ROWS then
                body:Line(key .. ":more", Dim(string.format(SafeL("HUB_LDG_MORE_FMT", "+%d more entries"),
                    #g.rows - MAX_DAY_ROWS)))
            end
        end
    end
    return body.y
end
