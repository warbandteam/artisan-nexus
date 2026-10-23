--[[
    Artisan Nexus — Hub tab: Auction House (key "market"), drawn as a Warband Nexus main-window tab.

    "What are prices doing, are my auctions undercut, any deals?"
    WN tab pattern (LedgerPage.lua / WN CurrencyUI collapsible sections + TableKit rows):
    ArtisanNexus:DrawMarketTab(scrollChild) returns the body height; UI_TabHost.lua dispatches it.

      fixedHeader  WN title card; subtitle = AH data freshness (AHPriceService:GetCacheStats, hover for the
                   cache counts); title toolbar: sort dropdown (profile.hubMarketSort, every table) + Sync
                   (AHPriceService:StartScan(false, true); usable only while the AH is open and idle, shows
                   progress while IsScanActive())
      Empty        no cached price at all -> one WN tab empty-state card, nothing else
      Groups       WN collapsible headers with the count on the right (Professions-tab section count font;
                   what each group shows is its header tooltip); rows: icon | Item | values, no column
                   strip (what a value is reads from the row tooltip):
        My auctions    OwnedAuctionsService:GetOwned / UnitPrice / GetMarketPrice / GetCancelInfo; right =
                       active / undercut; per-row Cancel button (WN Professions row action button,
                       ProfessionsUI.lua:1697)
        Price watch    ShoppingListService:Aggregate reagents + ProfitabilityService:ListRecipes outputs,
                       priced by AHPriceService:GetPriceInfo, PriceHistoryService:GetStats / GetTrend;
                       listed quantity and price source / age are in the row tooltip
        Opportunities  MarketIntelService:GetDeals (listings far below the 7-day average) then
                       GetMovers (biggest changes against it) in one table with a Type column
    Body kit / ink / money: H.NewTabBody, H.Ink, H.Money (Hub/HubTabKit.lua, Hub/HubData.lua).
    Refresh: UI_RefreshRouter.lua routes AH_PRICES_UPDATED, MARKET_INTEL_UPDATED, OWNED_AUCTIONS_UPDATED
    and AUCTION_HOUSE_SHOW / _CLOSED to this tab. While a scan runs and the tab is visible a 2 s timer
    requests a repaint (scan progress has no message of its own).
    Rail badge: H.MarketUndercutCount() (undercut auctions).

    Cancel flow mirrors Blizzard's StaticPopupDialogs["CANCEL_AUCTION"]: OnAccept calls
    C_AuctionHouse.CancelAuction(auctionID) from the popup button click (hardware event).
    -- verified 2026-10-14, wow-ui-source-live Blizzard_AuctionHouseFrame.lua:77-97 and
    research_ah_api.md (CancelAuction HasRestrictions; CanCancelAuction / GetCancelCost).
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local H = ns.HubUI_Internal
assert(H and H.NewTabBody, "Hub/HubTabKit.lua must load before Hub/Pages/MarketPage.lua")

local FontManager = ns.FontManager
local TK = ns.UI_TableKit
local E = ns.Constants.EVENTS
local SafeL = H.SafeL
local FormatDuration = H.FormatDuration
local ItemLink = H.ItemLink
local Ink = H.Ink

local WEEK = 7 * 86400
local MAX_OWNED = 40
local MAX_WATCH = 40
local MAX_WATCH_OUTPUTS = 20
local MAX_MOVERS = 20
local MAX_DEALS = 20
local WATCH_TTL = 60          -- seconds before the tracked item set is rebuilt
local STATS_TTL = 2           -- GetCacheStats walks every cached price row
local SCAN_TICK = 2
local NAME_MIN, MONEY_W, PCT_W, TIME_W = H.COL.NAME_MIN, H.COL.MONEY, H.COL.PCT, H.COL.TIME
local CANCEL_W = 76
--- WN Professions row action button height (ProfessionsUI.lua PROFESSION_PANEL_BTN_H / modern 18).
local ROW_BTN_H_CLASSIC, ROW_BTN_H = 22, 18
local CANCEL_POPUP = "ARTISANNEXUS_CANCEL_AUCTION"

local SOURCE_KEY = {
    an = { "HUB_SRC_AH", "AH" },
    vendor = { "HUB_SRC_VENDOR", "Vendor" },
}
local SOURCE_NAME = { auctionator = "Auctionator", tsm = "TSM" }

-- ─────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────

local function AuctionHouseOpen()
    return ns.Economy and ns.Economy.IsAuctionHouseOpen and ns.Economy:IsAuctionHouseOpen() or false
end

local function ScanActive()
    local svc = ns.AHPriceService
    return svc and svc.IsScanActive and svc:IsScanActive() or false
end

local function Refresh()
    H.Refresh("market")
end

local Money = H.Money

local function Ago(t)
    t = tonumber(t)
    if not t or t <= 0 then
        return nil
    end
    return string.format(SafeL("AH_TT_AGO_FMT", "%s ago"), FormatDuration(time() - t))
end

--- Fills the shared item fields of a row: icon (icon column), item (name), sortName.
local function SetItem(r, itemID)
    r.icon = (itemID and ns.GetItemIconFileID and ns.GetItemIconFileID(itemID)) or 134400
    r.item = (itemID and ns.GetItemDisplayName and ns.GetItemDisplayName(itemID)) or "?"
    r.sortName = tostring(r.item)
end

local function SourceLabel(src)
    local k = src and SOURCE_KEY[src]
    if k then
        return SafeL(k[1], k[2])
    end
    return (src and SOURCE_NAME[src]) or Ink("-", "Dim")
end

--- Row-data tables reused between paints (frames are pooled by the body kit; this pools the data).
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
    local list = b.list
    for i = #list, b.n + 1, -1 do
        list[i] = nil
    end
    return list
end

local function CellValue(col, d)
    if col.cell == "icon" then
        return d.icon
    end
    return d[col.key], d.role or "Bright"
end

--- Header sort for every Market table: raw numbers live on the row data as <column>N.
local function SortValue(d, key)
    if key == "item" then
        return d.sortName
    end
    return d[key .. "N"]
end

--- Sort modes of the title-toolbar sort dropdown (CraftingPage.lua pattern); "default" keeps each
--- table's own order (undercut first / tracked order / deals then movers).
local SORT_OPTIONS = {
    { key = "default", label = SafeL("HUB_SORT_DEFAULT", "Default") },
    { key = "name", label = SafeL("HUB_SORT_NAME", "Name (A-Z)"), sortKey = "item", asc = true },
    { key = "price", label = SafeL("HUB_SORT_PRICE", "Price (highest)"), sortKey = "price", asc = false },
}

--- profile.hubMarketSort = { key = <SORT_OPTIONS key> } (the dropdown writes .key).
local function SortTable()
    local p = ns.db and ns.db.profile
    if not p then return { key = "default" } end
    if type(p.hubMarketSort) ~= "table" then
        p.hubMarketSort = { key = "default" }
    end
    return p.hubMarketSort
end

local SORT = { value = SortValue }

--- Shared sort of every Market table, from the dropdown pick.
local function Sort()
    local key = SortTable().key
    SORT.key, SORT.asc = nil, false
    for i = 1, #SORT_OPTIONS do
        local o = SORT_OPTIONS[i]
        if o.key == key then
            SORT.key, SORT.asc = o.sortKey, o.asc == true
        end
    end
    return SORT
end

--- Item tooltip, then the row's extra lines (d.tip = { { label, value }, ... }) under a blank line.
local function RowEnter(row, d)
    if not d or not d.itemID then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if d.link then
        GameTooltip:SetHyperlink(d.link)
    else
        GameTooltip:SetItemByID(d.itemID)
    end
    local tip = d.tip
    if tip and #tip > 0 then
        GameTooltip:AddLine(" ")
        for i = 1, #tip do
            GameTooltip:AddDoubleLine(tip[i][1], tip[i][2], 0.75, 0.75, 0.75, 1, 1, 1)
        end
    end
    GameTooltip:Show()
end

local function RowClick(row, d, button)
    if button == "LeftButton" and d and d.itemID and IsModifiedClick() then
        HandleModifiedItemClick(d.link or ItemLink(d.itemID))
    end
end

local body = H.NewTabBody("market", "hubMarketExpanded")

-- ─────────────────────────────────────────────────────────────────
-- Columns (labels resolved once at load; locale is loaded before UI files)
-- ─────────────────────────────────────────────────────────────────

local L_ITEM = SafeL("HUB_COL_ITEM", "Item")
local L_AVG7 = SafeL("TOOLTIP_AVG_7D", "7-day avg")
local L_LISTED = SafeL("HUB_COL_QTY", "Listed")
local L_PRICE = SafeL("HUB_COL_PRICE", "Price")

--- Name column (sortable A-Z) after the WN icon column.
local function ItemCol()
    return { key = "item", label = L_ITEM, flex = 1, min = NAME_MIN }
end

--- Right-aligned value column.
local function NumCol(key, label, width)
    return { key = key, label = label, width = width, align = "RIGHT" }
end

local OWNED_COLS = {
    H.IconColumn(), ItemCol(),
    NumCol("mine", SafeL("HUB_COL_MY_PRICE", "My price"), H.COL.MONEY_EXACT),
    NumCol("lowest", SafeL("HUB_COL_LOWEST", "Lowest"), H.COL.MONEY_EXACT),
    NumCol("qty", SafeL("HUB_COL_QTY_SHORT", "Qty"), 44),
    NumCol("left", SafeL("HUB_COL_TIME_LEFT", "Time left"), TIME_W),
    { key = "cancel", label = "", width = CANCEL_W, align = "CENTER" },
}
local OWNED_CANCEL_CI = #OWNED_COLS

local WATCH_COLS = {
    H.IconColumn(), ItemCol(),
    NumCol("price", L_PRICE, MONEY_W),
    NumCol("avg", L_AVG7, MONEY_W),
    NumCol("trend", SafeL("HUB_COL_TREND", "Trend"), PCT_W),
}

local OPP_COLS = {
    H.IconColumn(), ItemCol(),
    { key = "kind", label = SafeL("HUB_COL_TYPE", "Type"), width = 80 },
    NumCol("price", L_PRICE, MONEY_W),
    NumCol("avg", L_AVG7, MONEY_W),
    NumCol("pct", SafeL("HUB_COL_CHANGE_PCT", "Change %"), 76),
}

-- ─────────────────────────────────────────────────────────────────
-- Header: freshness subtitle + Sync
-- ─────────────────────────────────────────────────────────────────

local statsMemo = { at = -1, stats = nil }

local function CacheStats()
    local now = GetTime()
    if statsMemo.stats and now - statsMemo.at < STATS_TTL then
        return statsMemo.stats
    end
    local svc = ns.AHPriceService
    local st = svc and svc.GetCacheStats and svc:GetCacheStats()
    statsMemo.stats = type(st) == "table" and st or { total = 0, fresh = 0, stale = 0, newest = 0 }
    statsMemo.at = now
    return statsMemo.stats
end

local function FreshText()
    local st = CacheStats()
    if (st.total or 0) == 0 then
        return SafeL("HUB_MKT_NO_DATA", "No AH data")
    end
    local text = string.format(SafeL("HUB_OV_AH_AGE_FMT", "Last update %s ago"), FormatDuration(time() - (st.newest or 0)))
    if (st.fresh or 0) == 0 then
        text = Ink(text, "orange")
    end
    return text
end

local function FreshTooltip(owner)
    local st = CacheStats()
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    GameTooltip:SetText(SafeL("AH_TT_CACHED", "Cached"), 1, 1, 1)
    GameTooltip:AddDoubleLine(SafeL("AH_TT_CACHED", "Cached"),
        string.format(SafeL("AH_TT_ITEMS_FMT", "%d items"), st.total or 0), 0.75, 0.75, 0.75, 1, 1, 1)
    GameTooltip:AddDoubleLine(SafeL("AH_TT_FRESH_STALE", "Fresh / stale"),
        string.format(SafeL("HUB_OV_AH_FRESH_FMT", "%d fresh / %d stale"), st.fresh or 0, st.stale or 0), 0.75, 0.75, 0.75, 1, 1, 1)
    local ago = Ago(st.newest)
    if ago then
        GameTooltip:AddDoubleLine(SafeL("AH_TT_LAST_UPDATE", "Last update"), ago, 0.75, 0.75, 0.75, 1, 1, 1)
    end
    GameTooltip:Show()
end

--- Scan progress (AHPriceService:GetScanProgress -> done, total).
local function SyncText()
    if not ScanActive() then
        return SafeL("AH_SYNC_PRICES", "Sync AH Prices")
    end
    local svc = ns.AHPriceService
    local done, total = 0, 0
    if svc.GetScanProgress then
        done, total = svc:GetScanProgress()
    end
    local pct = (total > 0) and math.floor(math.min(1, done / total) * 100) or 0
    return string.format(SafeL("AH_SYNC_PROGRESS_FMT", "Syncing %d / %d  (%d%%)"), done, total, pct)
end

local function SyncOnEnter(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
    GameTooltip:SetText(SafeL("AH_SYNC_PRICES", "Sync AH Prices"), 1, 1, 1)
    local tip
    if not AuctionHouseOpen() then
        tip = SafeL("AH_SCAN_NEED_OPEN", "Open the Auction House window first.")
    elseif ScanActive() then
        tip = SafeL("AH_TT_SCANNING", "Scanning")
    else
        tip = SafeL("HUB_MKT_SYNC_TT", "Scan AH prices for out-of-date items.")
    end
    GameTooltip:AddLine(tip, 0.85, 0.85, 0.85, true)
    GameTooltip:Show()
end

local function SyncOnClick()
    if not AuctionHouseOpen() then
        ArtisanNexus:Print(SafeL("AH_SCAN_NEED_OPEN", "Open the Auction House window first."))
        return
    end
    local svc = ns.AHPriceService
    if svc and svc.StartScan and not ScanActive() then
        svc:StartScan(false, true)
    end
    statsMemo.at = -1
    Refresh()
end

local scanTickArmed = false
local function ArmScanTick()
    if scanTickArmed then
        return
    end
    scanTickArmed = true
    C_Timer.After(SCAN_TICK, function()
        scanTickArmed = false
        local mf = ArtisanNexus.UI and ArtisanNexus.UI.mainFrame
        if not mf or not mf:IsShown() or mf.currentTab ~= "market" then
            return
        end
        statsMemo.at = -1
        ArtisanNexus:SendMessage(E.UI_MAIN_REFRESH_REQUESTED, { tab = "market" })
    end)
end

--- Disabled look of the WN Professions row / panel buttons (ProfessionsUI.lua:1668 SetProfessionOpenButtonState).
local function SetButtonUsable(btn, label, usable)
    if btn._wnBlizzardButton then
        btn:SetEnabled(usable)
        btn:SetAlpha(1)
        return
    end
    btn:SetEnabled(usable)
    btn:SetAlpha(usable and 1 or 0.45)
    if label then ns.UI_SetTextColorRole(label, usable and "Bright" or "Dim") end
end

-- ─────────────────────────────────────────────────────────────────
-- My auctions (+ per-row Cancel)
-- ─────────────────────────────────────────────────────────────────

local function EnsureCancelPopup()
    if StaticPopupDialogs[CANCEL_POPUP] then
        return
    end
    StaticPopupDialogs[CANCEL_POPUP] = {
        text = "%s",
        button1 = YES,
        button2 = NO,
        OnAccept = function(_, data)
            -- Runs inside the popup button's OnClick (hardware event), like Blizzard's CANCEL_AUCTION.
            if data and data.auctionID then
                C_AuctionHouse.CancelAuction(data.auctionID)
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

local function CancelOnClick(b)
    if not AuctionHouseOpen() then
        ArtisanNexus:Print(SafeL("HUB_MARKET_CANCEL_NEED_AH", "Open the Auction House to cancel auctions."))
        return
    end
    local svc = ns.OwnedAuctionsService
    local id, cost
    if svc and svc.GetCancelInfo then
        id, cost = svc:GetCancelInfo(b._anAuctionID)
    end
    if not id or not (C_AuctionHouse and C_AuctionHouse.CancelAuction) then
        ArtisanNexus:Print(SafeL("HUB_MARKET_CANCEL_UNAVAILABLE", "This auction can't be cancelled right now."))
        return
    end
    local text
    if cost and cost > 0 then
        text = string.format(SafeL("HUB_MARKET_CANCEL_CONFIRM_COST_FMT", "Cancel this auction? Cancelling costs %s."), Money(cost, nil, true))
    else
        text = SafeL("HUB_MARKET_CANCEL_CONFIRM", "Cancel this auction?")
    end
    EnsureCancelPopup()
    StaticPopup_Show(CANCEL_POPUP, text, nil, { auctionID = id })
end

local function CancelOnEnter(b)
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    GameTooltip:SetText(SafeL("HUB_MARKET_CANCEL_BTN", "Cancel"), 1, 1, 1)
    GameTooltip:AddLine(b._anTT or "", 0.85, 0.85, 0.85, true)
    GameTooltip:Show()
end

--- WN Professions row action button (ProfessionsUI.lua:1697 WireProfessionLineOpenButton).
local function EnsureCancelButton(row)
    local btn = row._anCancelBtn
    if btn then
        return btn
    end
    local useBlizz = ns.UI_ShouldUseBlizzardChrome and ns.UI_ShouldUseBlizzardChrome()
    local btnH = useBlizz and ROW_BTN_H_CLASSIC or ROW_BTN_H
    btn = ns.UI.Factory:CreateButton(row, CANCEL_W, btnH, not useBlizz)
    local text = SafeL("HUB_MARKET_CANCEL_BTN", "Cancel")
    if btn._wnBlizzardButton then
        btn:SetText(text)
        if ns.UI_NormalizeBlizzardButtonChrome then
            ns.UI_NormalizeBlizzardButtonChrome(btn)
        end
    else
        if ns.UI_ApplyVisuals and (not ns.UI_CanApplyCustomChrome or ns.UI_CanApplyCustomChrome(btn)) then
            local ac = (ns.UI_COLORS and ns.UI_COLORS.accent) or { 0.5, 0.5, 0.5 }
            ns.UI_ApplyVisuals(btn, (ns.UI_GetControlChromeBackdrop and ns.UI_GetControlChromeBackdrop()) or { 0.12, 0.12, 0.15, 1 },
                { ac[1], ac[2], ac[3], 0.5 })
        end
        btn.label = FontManager:CreateFontString(btn, "small", "OVERLAY")
        btn.label:SetPoint("CENTER", 0, 0)
        btn.label:SetText(text)
        if ns.UI.Factory.ApplyHighlight then
            ns.UI.Factory:ApplyHighlight(btn)
        end
    end
    if btn.SetMotionScriptsWhileDisabled then
        btn:SetMotionScriptsWhileDisabled(true)
    end
    btn:SetScript("OnClick", CancelOnClick)
    btn:HookScript("OnEnter", CancelOnEnter)
    btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    if ns.UI_ForwardMouseWheelToScrollAncestor then
        btn:EnableMouseWheel(true)
        btn:SetScript("OnMouseWheel", ns.UI_ForwardMouseWheelToScrollAncestor)
    end
    row._anCancelBtn = btn
    return btn
end

--- Cancel buttons ride on the pooled row frames of table "owned" (rendered after the table paint).
local function PlaceCancelButtons(rows, ahOpen)
    -- rows = the painted (sorted) list returned by body:Table
    local poolRows, widths, offsets = body:TableRows("owned")
    if not poolRows then
        return
    end
    local x, w = offsets[OWNED_CANCEL_CI] or 0, widths[OWNED_CANCEL_CI] or CANCEL_W
    local tt = ahOpen and SafeL("HUB_MARKET_CANCEL_TT", "Cancel this auction (asks for confirmation).")
        or SafeL("HUB_MARKET_CANCEL_NEED_AH", "Open the Auction House to cancel auctions.")
    for i = 1, #poolRows do
        local row = poolRows[i]
        local d = rows[i]
        if d then
            local b = EnsureCancelButton(row)
            b:ClearAllPoints()
            b:SetPoint("CENTER", row, "LEFT", x + w * 0.5, 0)
            b:SetWidth(math.max(40, w - 8))
            b._anAuctionID = d.auctionID
            b._anTT = tt
            SetButtonUsable(b, b.label, ahOpen)
            b:Show()
        elseif row._anCancelBtn then
            row._anCancelBtn:Hide()
        end
    end
end

--- Default order: undercut first, biggest loss first.
local function OwnedSort(a, b)
    if a.undercut ~= b.undercut then
        return a.undercut
    end
    return (a.loss or 0) > (b.loss or 0)
end

local function DrawOwned(ahOpen)
    local svc = ns.OwnedAuctionsService
    local snap = svc and svc.GetOwned and svc:GetOwned()
    local b = Buf("owned")
    local auctions = snap and type(snap.auctions) == "table" and snap.auctions or {}
    local elapsed = (snap and snap.at) and (time() - snap.at) or 0
    for i = 1, #auctions do
        local a = auctions[i]
        if a.status == 0 and b.n < MAX_OWNED then -- Enum.AuctionStatus.Active = 0
            local mine = svc:UnitPrice(a)
            local lowest = svc:GetMarketPrice(a.itemID, a.itemKey)
            local r = BufRow(b)
            r.itemID, r.link, r.auctionID = a.itemID, a.itemLink, a.auctionID
            SetItem(r, a.itemID)
            r.mine, r.mineN = Money(mine, nil, true), mine
            r.priceN = mine
            r.undercut = (mine and lowest and lowest < mine) and true or false
            -- Undercut: the lowest price in red (its distance to yours is in the item tooltip context).
            r.lowest = lowest and (r.undercut and Ink(TK.FormatSignedMoneyPlain(math.floor(lowest + 0.5), 12), "red")
                or Money(lowest, nil, true)) or Ink("-", "Dim")
            r.lowestN = lowest
            if mine and lowest then
                r.loss = (mine - lowest) * (tonumber(a.quantity) or 1)
            end
            r.qtyN = tonumber(a.quantity) or 1
            r.qty = tostring(r.qtyN)
            local left = tonumber(a.timeLeftSeconds)
            left = left and (left - elapsed) or nil
            r.left = (left and left > 0) and FormatDuration(left) or Ink("-", "Dim")
            r.leftN = (left and left > 0) and left or nil
            r.cancel = ""
        end
    end
    local rows = BufRows(b)
    table.sort(rows, OwnedSort)
    local ago = snap and Ago(snap.at)
    local undercut = 0
    for i = 1, #rows do
        if rows[i].undercut then undercut = undercut + 1 end
    end
    local tip = SafeL("HUB_MKT_OWNED_DESC", "Your auctions; undercut ones first.")
    if ago then
        tip = tip .. "\n" .. string.format("%s: %s", SafeL("AH_TT_LAST_UPDATE", "Last update"), ago)
    end
    if not body:Section("owned", SafeL("HUB_MKT_OWNED_TITLE", "My auctions"), {
            tooltip = tip,
            count = (#rows > 0) and string.format(SafeL("HUB_MKT_OWNED_COUNT_FMT", "%d listed · %d undercut"), #rows, undercut) or nil,
            countRole = undercut > 0 and "Bright" or "Muted",
        }) then
        return
    end
    rows = body:Table("owned", OWNED_COLS, rows, CellValue, {
        onRowEnter = RowEnter, onRowClick = RowClick, sort = Sort(),
        emptyText = snap and SafeL("HUB_MKT_OWNED_NONE", "You have no active auctions.")
            or SafeL("HUB_MARKET_UNDERCUT_NO_SNAPSHOT", "Open the Auction House once to read your auctions."),
    })
    PlaceCancelButtons(rows, ahOpen)
end

-- ─────────────────────────────────────────────────────────────────
-- Price watch
-- ─────────────────────────────────────────────────────────────────

--- Tracked items: shopping-list reagents (biggest spend first), then top recipe outputs.
local function BuildWatchIDs(out)
    wipe(out)
    local seen = {}
    local shop = ns.ShoppingListService
    if shop and shop.Aggregate then
        local ok, agg = pcall(shop.Aggregate, shop, {})
        if ok and type(agg) == "table" then
            -- Aggregate rows are the service's cached tables: sort (id, cost) pairs, never the rows.
            local list = {}
            for id, row in pairs(agg) do
                if type(id) == "number" and type(row) == "table" then
                    list[#list + 1] = { id = id, cost = tonumber(row.cost) or 0 }
                end
            end
            table.sort(list, function(a, b)
                if a.cost ~= b.cost then return a.cost > b.cost end
                return a.id < b.id
            end)
            for i = 1, #list do
                local id = list[i].id
                if #out < MAX_WATCH and not seen[id] then
                    seen[id] = true
                    out[#out + 1] = id
                end
            end
        end
    end
    local prof = ns.ProfitabilityService
    if prof and prof.ListRecipes and #out < MAX_WATCH then
        local p = ns.db and ns.db.profile
        local ok, rows = pcall(prof.ListRecipes, prof, {
            harvestedOnly = true, compareConcentration = false,
            knownBy = p and p.hubKnownBy or nil,
        })
        if ok and type(rows) == "table" then
            local added = 0
            for i = 1, #rows do
                local id = rows[i].outputItem
                if added >= MAX_WATCH_OUTPUTS or #out >= MAX_WATCH then break end
                if id and not seen[id] and (rows[i].margin or 0) > 0 then
                    seen[id] = true
                    out[#out + 1] = id
                    added = added + 1
                end
            end
        end
    end
    return out
end

--- Default order: the tracked order (shopping-list spend, then top crafts).
local watch = { ids = {}, at = nil }

local function WatchIDs()
    if not watch.at or GetTime() - watch.at > WATCH_TTL then
        BuildWatchIDs(watch.ids)
        watch.at = GetTime()
    end
    return watch.ids
end

local function DrawWatch()
    local ids = WatchIDs()
    local ah, hist, econ = ns.AHPriceService, ns.PriceHistoryService, ns.Economy
    local b = Buf("watch")
    for i = 1, #ids do
        local id = ids[i]
        local r = BufRow(b)
        r.itemID = id
        SetItem(r, id)
        local price, updatedAt, _, isStale, src
        if ah and ah.GetPriceInfo then
            price, updatedAt, _, isStale, src = ah:GetPriceInfo(id)
        end
        if price and isStale then
            r.price = Money(price) .. Ink("*", "Dim")
        else
            r.price = price and Money(price) or Ink("-", "Dim")
        end
        r.priceN = price
        local stats = hist and hist.GetStats and hist:GetStats(id, WEEK)
        local avg = stats and (stats.count or 0) > 0 and stats.avg or nil
        r.avg, r.avgN = avg and Money(avg) or Ink("-", "Dim"), avg
        local dir, pct = 0, 0
        if hist and hist.GetTrend then
            dir, pct = hist:GetTrend(id, WEEK)
        end
        if dir > 0 then
            r.trend, r.trendN = Ink(string.format("%+.0f%%", pct), "green"), pct
        elseif dir < 0 then
            r.trend, r.trendN = Ink(string.format("%+.0f%%", pct), "red"), pct
        elseif stats and (stats.count or 0) >= 2 then
            r.trend, r.trendN = Ink(string.format("%+.0f%%", pct or 0), "Dim"), pct or 0
        else
            r.trend = Ink("-", "Dim")
        end
        local row = econ and econ.GetMarketRow and econ:GetMarketRow(id)
        local qty = row and tonumber(row.qty)
        local age = updatedAt and FormatDuration(time() - updatedAt)
        local srcText = price and SourceLabel(src) or Ink("-", "Dim")
        r.tip = {
            { L_LISTED, qty and tostring(qty) or Ink("-", "Dim") },
            { SafeL("HUB_COL_SOURCE_AGE", "Source / age"), age and (srcText .. " " .. Ink(age, "Dim")) or srcText },
        }
    end
    local rows = BufRows(b)
    if not body:Section("watch", SafeL("HUB_MKT_WATCH_TITLE", "Price watch"), {
            tooltip = SafeL("HUB_MKT_WATCH_DESC", "Reagents on your shopping list and your most profitable crafts.")
                .. "\n" .. SafeL("HUB_TT_MARK_STALE", "*  Price is older than the freshness window"),
            count = (#rows > 0) and string.format(SafeL("HUB_MKT_ITEMS_FMT", "%d items"), #rows) or nil,
        }) then
        return
    end
    body:Table("watch", WATCH_COLS, rows, CellValue, {
        onRowEnter = RowEnter, onRowClick = RowClick, sort = Sort(),
        emptyText = SafeL("HUB_MKT_WATCH_NONE", "Add recipes to the shopping list to track prices."),
    })
end

-- ─────────────────────────────────────────────────────────────────
-- Movers / Deals
-- ─────────────────────────────────────────────────────────────────

--- Deals (listings far below the 7-day average) first, then movers (biggest changes against it).
local function DrawOpportunities(intel)
    local b = Buf("opps")
    local deals = intel and intel.GetDeals and intel:GetDeals(MAX_DEALS) or {}
    local dealLabel, moverLabel = SafeL("HUB_MKT_KIND_DEAL", "Deal"), SafeL("HUB_MKT_KIND_MOVER", "Mover")
    for i = 1, #deals do
        local d = deals[i]
        local r = BufRow(b)
        r.itemID = d.itemID
        SetItem(r, d.itemID)
        r.kind, r.kindN = Ink(dealLabel, "green"), dealLabel
        r.price, r.priceN = Money(d.price), tonumber(d.price)
        r.avg, r.avgN = Money(d.mean7d), tonumber(d.mean7d)
        local pct = -math.floor((1 - (tonumber(d.ratio) or 1)) * 100 + 0.5)
        r.pct, r.pctN = Ink(string.format("%+d%%", pct), "green"), pct
        r.tip = { { L_LISTED, tostring(tonumber(d.qty) or 0) } }
    end
    local movers = intel and intel.GetMovers and intel:GetMovers(MAX_MOVERS) or {}
    for i = 1, #movers do
        local m = movers[i]
        local r = BufRow(b)
        r.itemID = m.itemID
        SetItem(r, m.itemID)
        r.kind, r.kindN = Ink(moverLabel, "Muted"), moverLabel
        r.price, r.priceN = Money(m.latest), tonumber(m.latest)
        r.avg, r.avgN = Money(m.mean7d), tonumber(m.mean7d)
        local pct = tonumber(m.pct) or 0
        r.pct, r.pctN = Ink(string.format("%+.0f%%", pct), pct >= 0 and "green" or "red"), pct
        if m.state and intel.GetStateLabel then
            r.tip = { { SafeL("HUB_COL_TREND", "Trend"), intel:GetStateLabel(m.state) } }
        end
    end
    local rows = BufRows(b)
    if not body:Section("opps", SafeL("HUB_MKT_OPPS_TITLE", "Opportunities"), {
            tooltip = SafeL("HUB_MKT_DEALS_DESC", "Current listings well below their 7-day average.")
                .. "\n" .. SafeL("HUB_MKT_MOVERS_DESC", "Biggest price changes against the 7-day average."),
            count = (#rows > 0) and string.format(SafeL("HUB_MKT_ITEMS_FMT", "%d items"), #rows) or nil,
        }) then
        return
    end
    body:Table("opps", OPP_COLS, rows, CellValue, {
        onRowEnter = RowEnter, onRowClick = RowClick, sort = Sort(),
        emptyText = SafeL("HUB_MARKET_NO_HISTORY", "Not enough price history yet."),
    })
end

-- ─────────────────────────────────────────────────────────────────
-- Rail badge
-- ─────────────────────────────────────────────────────────────────

--- Undercut auction count for the Market rail badge (Modules/UI.lua UpdateTabCountBadges).
function H.MarketUndercutCount()
    local svc = ns.OwnedAuctionsService
    local list = svc and svc.GetUndercut and svc:GetUndercut()
    return type(list) == "table" and #list or 0
end

-- ─────────────────────────────────────────────────────────────────
-- Tab
-- ─────────────────────────────────────────────────────────────────

---@param parent Frame main-window scrollChild
---@return number contentHeight
function ArtisanNexus:DrawMarketTab(parent)
    local mf = body:Begin(parent)
    local ahOpen = AuctionHouseOpen()
    local scanning = ScanActive()

    -- Fixed header: WN title card (freshness subtitle); title toolbar: sort dropdown, Sync to its left.
    local chrome = ns.UI_BeginTabChromeLayout and ns.UI_BeginTabChromeLayout(mf)
    if chrome then
        local titleCard, _, textContainer = ns.UI_CreateStandardTabTitleCard(chrome.headerParent, {
            tabKey = "market",
            titleText = H.AccentTitle(SafeL("HUB_PAGE_MARKET", "Auction House")),
            subtitleText = FreshText(),
            showUnderline = false,
        })
        titleCard:Show()
        titleCard:EnableMouse(true)
        titleCard:SetScript("OnEnter", FreshTooltip)
        titleCard:SetScript("OnLeave", function() GameTooltip:Hide() end)
        local syncBtn, syncLabel = ns.UI_CreateTitleToolbarTextButton(titleCard, {
            text = SyncText(),
            autoWidth = true,
            onClick = SyncOnClick,
            onEnter = SyncOnEnter,
            onLeave = function() GameTooltip:Hide() end,
        })
        if syncBtn then
            if syncLabel then
                syncBtn:SetWidth(math.max(64, math.ceil(syncLabel:GetStringWidth() or 0) + 24))
            end
            if syncBtn.SetMotionScriptsWhileDisabled then
                -- Keep the "open the AH first" tooltip while the button is disabled.
                syncBtn:SetMotionScriptsWhileDisabled(true)
            end
            SetButtonUsable(syncBtn, syncLabel, ahOpen and not scanning)
            if scanning then syncBtn:SetAlpha(1) end
        end
        local sortBtn = ns.UI_CreateCharacterSortDropdown and ns.UI_CreateCharacterSortDropdown(titleCard,
            SORT_OPTIONS, SortTable(), Refresh, nil)
        if sortBtn then
            ns.UI_AnchorTitleToolbarControlRight(titleCard, sortBtn)
        end
        H.LayoutToolbar(titleCard, textContainer, { syncBtn }, sortBtn)
        ns.UI_CommitTabFixedHeader(mf, ns.UI_PageStack_Place(chrome, titleCard))
    end
    if scanning then
        ArmScanTick()
    end

    if (CacheStats().total or 0) == 0 then
        body:Empty("an_market", SafeL("HUB_MKT_EMPTY_TITLE", "No Auction House prices yet"),
            SafeL("HUB_OV_NEED_PRICES", "Open the Auction House and press Sync AH Prices."), "Auctioneer")
        return body.y
    end

    local intel = ns.MarketIntelService
    DrawOwned(ahOpen)
    DrawWatch()
    DrawOpportunities(intel)
    return body.y
end
