--[[
    Artisan Nexus — Posting Helper window.

    A companion window docked next to the AH sell frame (commodities or item). It is the only
    posting surface (chat output happens only from the "Print to chat" button). Surfaces:
      * suggested unit price + why (PostingHelperService:Analyze)
      * hold warning when the market is below the floor (cost basis / vendor / history)
      * live market: lowest other seller, wall depth, own listings
      * deposit for the chosen quantity & duration, net after cut, profit vs cost basis,
        expected deposit loss
      * 7d avg / latest / trend
      * Strategy dropdown (undercut / average / higher of both), Apply price, Print to chat

    Warband Nexus companion-window pattern (RecipeCompanionWindow.lua: floating window beside a
    Blizzard frame, shown / hidden with it, position saved):
      shell / title band / close / ESC + combat hide -> ns.ArtisanWindow.Create (PlansTrackerWindow shell)
      body rows                                       -> ProfessionInfoWindow.lua:243-271 text rows
      strategy dropdown                               -> ns.ArtisanWindow.CreateDropdown (PlansTrackerWindow.lua:1871)
      Apply / Print buttons                           -> ns.UI_CreateThemedButton (SharedWidgets.lua:3886)
    Rows with no text collapse; the window height follows its content (fixed width, not resizable).
    Docked beside the Auction House until the player drags it; then profile.postingPanel wins.

    Refresh is live: COMMODITY_SEARCH_RESULTS_UPDATED / ITEM_SEARCH_RESULTS_UPDATED, and hooks on
    the sell frames' SetItem (item change) and UpdatePostState (quantity / duration / price edits).
    verified 2026-10-14, wow-ui-source live 12.1.5.70391: AuctionHouseSellFrameMixin:SetItem /
    :UpdatePostState / :GetItem / :GetQuantity / :GetDuration; AuctionHouseCommoditiesSellFrame /
    ItemSellFrame register COMMODITY_SEARCH_RESULTS_UPDATED / ITEM_SEARCH_RESULTS_UPDATED.

    "Apply price" writes the suggestion into Blizzard's PriceInput (SetAmount) on a click;
    posting itself stays on Blizzard's Post button.
]]

local ADDON_NAME, ns = ...
-- Pixel-perfect frames (SharedWidgets_Pixel: SetPoint/SetSize snap to whole physical pixels).
local CreateFrame = function(...) return (ns.UI_CreateFrame or _G.CreateFrame)(...) end

-- 12.1.5 removed the global item/coin fallbacks; bind the namespaced APIs.
local GetItemInfo = C_Item.GetItemInfo

local PostingHelperUI = {}
local PANEL = nil
local CURRENT_ITEMID = nil
local LAST_RESULT = nil

-- Window metrics (fixed width; height follows the stacked rows).
local PANEL_W = 300
local POS_KEY = "postingPanel"
local DOCK_GAP = 6
local ROW_GAP = 4
local BLOCK_GAP = 8
local DROPDOWN_H = 26

local DURATION_LABELS = { "12h", "24h", "48h" }

local T = ns.SafeLocaleString

local function COLORS()
    return ns.UI_COLORS or { accent = { 0.5, 0.4, 0.7 }, border = { 0.25, 0.25, 0.3 } }
end

-- ── Inline semantic colors (RecipeCompanionWindow.lua TextRoleHex / Semantic*Hex pattern) ──

local function RoleHex(role)
    return "|cff" .. ((ns.UI_GetTextRoleHexRaw and ns.UI_GetTextRoleHexRaw(role)) or "ffffff")
end

local function GreenHex()
    return (ns.UI_GetSemanticGreenHex and ns.UI_GetSemanticGreenHex()) or "|cff44ff44"
end

local function RedHex()
    if ns.UI_GetSemanticRedColor then
        local r, g, b = ns.UI_GetSemanticRedColor()
        return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
    end
    return "|cffff6666"
end

local function Ink(text, hex)
    return hex .. text .. "|r"
end

--- Shared money formatter (Modules/Utilities.lua). This window shows an em dash for missing values.
local function FormatCopper(c)
    return ns.FormatCopper(c) or "—"
end

local function SignedCopper(c)
    if not c then return "—" end
    if c >= 0 then return Ink("+" .. FormatCopper(c), GreenHex()) end
    return Ink(FormatCopper(c), RedHex())
end

local function Count(n)
    n = tonumber(n) or 0
    return (BreakUpLargeNumbers and BreakUpLargeNumbers(n)) or tostring(n)
end

local function StrategyLabel(strategy)
    if strategy == "average" then return T("POSTING_STRAT_AVERAGE", "7d avg") end
    if strategy == "max" then return T("POSTING_STRAT_MAX", "Higher of both") end
    return T("POSTING_STRAT_UNDERCUT", "undercut")
end

local function StrategyText(strategy)
    return string.format(T("POSTING_STRATEGY_LABEL_FMT", "Strategy: %s"), StrategyLabel(strategy))
end

local MODE_LABELS = {
    match = { "POSTING_MODE_MATCH", "match" },
    undercut = { "POSTING_MODE_UNDERCUT", "undercut" },
    own = { "POSTING_MODE_OWN", "yours" },
    average = { "POSTING_MODE_AVERAGE", "average" },
    max = { "POSTING_MODE_MAX", "max" },
    history = { "POSTING_MODE_HISTORY", "history" },
    floor = { "POSTING_MODE_FLOOR", "floor" },
}

local function ModeLabel(mode)
    local m = MODE_LABELS[mode]
    return m and T(m[1], m[2]) or ""
end

local SOURCE_LABELS = {
    ledger = { "POSTING_SRC_LEDGER", "avg buy" },
    craft = { "POSTING_SRC_CRAFT", "craft cost" },
    vendor = { "POSTING_SRC_VENDOR", "vendor" },
    history = { "POSTING_SRC_HISTORY", "7d avg" },
}

local function SourceLabel(src)
    local m = SOURCE_LABELS[src]
    return m and T(m[1], m[2]) or ""
end

local STRATEGIES = { "undercut", "average", "max" }

local function GetStrategy()
    local svc = ns.PostingHelperService
    return svc and svc:GetConfig().strategy or "undercut"
end

local function SetStrategy(v)
    local svc = ns.PostingHelperService
    if not svc then return end
    local cfg = svc:GetConfig()
    cfg.strategy = v
    svc:SetConfig(cfg)
end

-- ── Text rows ──

--- Paint a font string with its ink: a WN text role ("Bright" / "Normal" / "Muted" / "Dim") or
--- "gold" (semantic gold: suggested price, hold warning). Re-run on theme change.
local function PaintInk(fs)
    if fs._anInk == "gold" then
        local r, g, b = 1, 0.82, 0
        if ns.UI_GetSemanticGoldColor then r, g, b = ns.UI_GetSemanticGoldColor() end
        fs:SetTextColor(r, g, b, 1)
    else
        ns.UI_SetTextColorRole(fs, fs._anInk or "Normal")
    end
end

--- One text row (ProfessionInfoWindow AddFullWidthLine): LayoutStack positions it.
local function MakeRow(p, parent, font, ink, wrap)
    local fs = ns.FontManager:CreateFontString(parent, font, "OVERLAY")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(wrap and true or false)
    fs._anInk = ink
    PaintInk(fs)
    p._anInkTexts[#p._anInkTexts + 1] = fs
    return fs
end

-- ── Strategy dropdown: the shared WN dropdown (ns.ArtisanWindow.CreateDropdown) ──

local function StrategyItems()
    local items = {}
    for i = 1, #STRATEGIES do
        items[i] = { key = STRATEGIES[i], label = StrategyLabel(STRATEGIES[i]) }
    end
    return items
end

local function CreateStrategyDropdown(parent, onSelected)
    return ns.ArtisanWindow.CreateDropdown(parent, {
        height = DROPDOWN_H,
        items = StrategyItems,
        value = GetStrategy,
        format = StrategyText,
        onSelected = function(value)
            SetStrategy(value)
            if onSelected then onSelected(value) end
        end,
    })
end

-- ── Layout ──

--- Stack the rows that have text, then the controls; size the window to fit.
local function LayoutStack(p)
    local body = p.contentArea
    local width = PANEL_W - 2 * ((ns.ArtisanWindow and ns.ArtisanWindow.PADDING) or 10)
    local y = 0
    for i = 1, #p._anStack do
        local row = p._anStack[i]
        if row == p._anRule then
            if y > 0 then
                y = y + BLOCK_GAP - ROW_GAP
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
                row:SetSize(width, 1)
                row:Show()
                y = y + 1 + BLOCK_GAP
            else
                row:Hide()
            end
        else
            local text = row:GetText()
            if text and text ~= "" then
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
                if row == p._priceLabel then
                    -- Value + mode tag hang off the label; the label keeps its natural width.
                    y = y + math.max(row:GetStringHeight() or 0, p._priceVal:GetStringHeight() or 0) + ROW_GAP
                else
                    row:SetWidth(width)
                    y = y + (row:GetStringHeight() or 0) + ROW_GAP
                end
                row:Show()
            else
                row:Hide()
                if row == p._priceLabel then
                    p._priceVal:SetText("")
                    p._modeTag:SetText("")
                end
            end
        end
    end
    y = y + BLOCK_GAP - ROW_GAP
    p._stratDropdown:ClearAllPoints()
    p._stratDropdown:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    p._stratDropdown:SetPoint("RIGHT", body, "RIGHT", 0, 0)
    y = y + DROPDOWN_H + BLOCK_GAP
    local btnH = p._applyBtn:GetHeight() or 32
    p._applyBtn:ClearAllPoints()
    p._applyBtn:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    p._applyBtn:SetPoint("RIGHT", body, "CENTER", -BLOCK_GAP / 2, 0)
    p._copyBtn:ClearAllPoints()
    p._copyBtn:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
    p._copyBtn:SetPoint("LEFT", body, "CENTER", BLOCK_GAP / 2, 0)
    y = y + btnH
    local W = ns.ArtisanWindow
    local chrome = (p._anHeaderH or 40) + ((W and W.ROW_BELOW_CHROME) or 10) + ((W and W.PADDING) or 10)
    p:SetHeight(math.ceil(chrome + y))
end

--- Theme / font change: shell chrome, row inks, controls. The window is kept (frames cannot be
--- destroyed; rebuilding under the same global name leaked a full frame tree per theme toggle).
local function SkinPanel(p)
    local W = ns.ArtisanWindow
    if W and W.RefreshChrome then
        W.RefreshChrome(p)
    end
    for i = 1, #p._anInkTexts do
        PaintInk(p._anInkTexts[i])
    end
    local br = COLORS().border or { 0.25, 0.25, 0.3 }
    p._anRule:SetColorTexture(br[1], br[2], br[3], 0.4)
    p._stratDropdown:Restyle()
end

local function SetApplyEnabled(btn, enabled)
    if enabled then
        btn:Enable()
        btn:SetAlpha(1)
    else
        btn:Disable()
        btn:SetAlpha(0.5)
    end
end

local function Build()
    local W = ns.ArtisanWindow
    if not (W and W.Create) then return nil end
    local p = W.Create({
        name = "ArtisanNexusPostingPanel",
        title = T("POSTING_PANEL_TITLE", "Posting Helper"),
        posKey = POS_KEY,
        width = PANEL_W,
        height = 260,
        resizable = false,
        onClose = function()
            CURRENT_ITEMID = nil
            LAST_RESULT = nil
        end,
        onDragStop = function()
            local prof = ns.db and ns.db.profile
            if prof then
                if type(prof[POS_KEY]) ~= "table" then prof[POS_KEY] = {} end
                prof[POS_KEY].userPlaced = true
            end
        end,
    })
    if not p then return nil end
    local body = p.contentArea
    p._anInkTexts = {}

    p._nameRow = MakeRow(p, body, "title", "Bright", false)

    --- Price line: "Suggested:" + value + [mode]; the label is the stacked row.
    local priceLabel = MakeRow(p, body, "body", "Muted", false)
    priceLabel:SetText(T("POSTING_SUGGESTED_LABEL", "Suggested:"))
    p._priceLabel = priceLabel

    local priceVal = MakeRow(p, body, "title", "gold", false)
    priceVal:SetPoint("LEFT", priceLabel, "RIGHT", 6, 0)
    p._priceVal = priceVal

    local modeTag = MakeRow(p, body, "small", "Dim", false)
    modeTag:SetPoint("LEFT", priceVal, "RIGHT", 6, 0)
    p._modeTag = modeTag

    p._reasonRow = MakeRow(p, body, "small", "Dim", true)
    p._warnRow = MakeRow(p, body, "small", "gold", true)

    -- Divider between the suggestion and the numbers (RecipeCompanionWindow.lua:375 CreateSeparator).
    local rule = body:CreateTexture(nil, "ARTWORK")
    if ns.UI_SetRuleThickness then ns.UI_SetRuleThickness(rule, "horizontal", 1) else rule:SetHeight(1) end
    p._anRule = rule

    p._marketRow = MakeRow(p, body, "body", "Normal", true)
    p._depositRow = MakeRow(p, body, "body", "Normal", true)
    p._netRow = MakeRow(p, body, "body", "Normal", true)
    p._profitRow = MakeRow(p, body, "body", "Normal", true)
    p._riskRow = MakeRow(p, body, "small", "Muted", true)
    p._stats = MakeRow(p, body, "body", "Normal", true)
    p._anStack = {
        p._nameRow, priceLabel, p._reasonRow, p._warnRow, rule, p._marketRow,
        p._depositRow, p._netRow, p._profitRow, p._riskRow, p._stats,
    }

    --- Controls: strategy dropdown, then Apply | Print to chat.
    p._stratDropdown = CreateStrategyDropdown(body, function()
        PostingHelperUI:Refresh()
    end)

    local half = math.floor((PANEL_W - 2 * ((W and W.PADDING) or 10) - BLOCK_GAP) / 2)
    p._applyBtn = ns.UI_CreateThemedButton(body, T("POSTING_APPLY", "Apply price"), half)
    p._applyBtn:SetScript("OnClick", function()
        local svc = ns.PostingHelperService
        if not (svc and LAST_RESULT and LAST_RESULT.price) then return end
        svc:ApplyPrice(LAST_RESULT.price)
    end)
    p._applyBtn:HookScript("OnEnter", function(btn)
        GameTooltip:SetOwner(btn, "ANCHOR_TOP")
        GameTooltip:SetText(T("POSTING_APPLY_TT", "Fills the suggested price into the sell frame."), 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    p._applyBtn:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    p._copyBtn = ns.UI_CreateThemedButton(body, T("POSTING_PRINT_TO_CHAT", "Print to chat"), half)
    p._copyBtn:SetScript("OnClick", function()
        local r = LAST_RESULT
        if r and r.price then
            ns.ArtisanNexus:Print(string.format(
                T("POSTING_SUGGESTED_CHAT_FMT", "|cffd4af37Suggested:|r %s |cff888888(%s)|r"),
                FormatCopper(r.price), r.reason or ""))
        else
            ns.ArtisanNexus:Print(T("POSTING_NO_SUGGESTION", "No suggestion yet. Sync AH prices first."))
        end
    end)

    p:HookScript("OnHide", function()
        p._stratDropdown:CloseMenu()
    end)
    SkinPanel(p)
    return p
end

local function MarketText(r)
    if not r.marketLowest and not r.ownLowest then
        return Ink(T("POSTING_MARKET_NONE", "No live listings loaded"), RoleHex("Dim"))
    end
    local parts = {}
    if r.marketLowest then
        parts[#parts + 1] = string.format(T("POSTING_MARKET_LOWEST_FMT", "Lowest %s"), FormatCopper(r.marketLowest))
        if r.isCommodity and r.wallQty and r.totalQty and r.totalQty > 0 then
            parts[#parts + 1] = string.format(T("POSTING_MARKET_WALL_FMT", "wall %s / %s"), Count(r.wallQty), Count(r.totalQty))
        end
    end
    if r.ownLowest then
        parts[#parts + 1] = Ink(string.format(T("POSTING_MARKET_OWN_FMT", "yours %s"), FormatCopper(r.ownLowest)), RoleHex("Muted"))
    end
    if r.demandPerDay then
        parts[#parts + 1] = string.format(T("POSTING_MARKET_DEMAND_FMT", "~%s/day"), Count(math.floor(r.demandPerDay + 0.5)))
    end
    return table.concat(parts, "  ·  ")
end

function PostingHelperUI:Refresh()
    if not PANEL or not CURRENT_ITEMID then return end
    local svc = ns.PostingHelperService
    if not svc then return end
    local ctx = svc:GetSellContext()
    if not (ctx and ctx.itemID == CURRENT_ITEMID) then
        ctx = { itemID = CURRENT_ITEMID }
    end
    local r = svc:Analyze(ctx)
    LAST_RESULT = r

    PANEL._priceVal:SetText(FormatCopper(r.price))
    PANEL._modeTag:SetText(r.price and ("[" .. ModeLabel(r.mode) .. "]") or "")
    PANEL._reasonRow:SetText(r.reason or "")
    if r.hold then
        PANEL._warnRow:SetText(string.format(T("POSTING_HOLD_FMT", "Hold: market %s is below your floor %s (%s)"),
            FormatCopper(r.marketLowest), FormatCopper(r.floor and math.floor(r.floor + 0.5)), SourceLabel(r.floorSource)))
    elseif r.floor then
        PANEL._warnRow:SetText(Ink(string.format(T("POSTING_FLOOR_FMT", "Floor %s (%s)"),
            FormatCopper(math.floor(r.floor + 0.5)), SourceLabel(r.floorSource)), RoleHex("Dim")))
    else
        PANEL._warnRow:SetText("")
    end

    PANEL._stratDropdown:Refresh()
    SetApplyEnabled(PANEL._applyBtn, r.price ~= nil and ctx.frame ~= nil)

    PANEL._marketRow:SetText(MarketText(r))

    local dur = DURATION_LABELS[r.duration or 2] or "?"
    local depText = FormatCopper(r.deposit)
    if r.depositEstimated and r.deposit then depText = depText .. Ink("*", RoleHex("Dim")) end
    PANEL._depositRow:SetText(string.format(T("POSTING_DEPOSIT_FMT", "Deposit (%s x %s): %s"),
        Count(r.quantity), dur, depText))

    if r.net then
        PANEL._netRow:SetText(string.format(T("POSTING_NET_FMT", "Net after %d%% cut: %s"),
            math.floor((r.cutRate or 0) * 100 + 0.5), FormatCopper(r.net)))
    else
        PANEL._netRow:SetText("")
    end
    if r.profit then
        PANEL._profitRow:SetText(string.format(T("POSTING_PROFIT_FMT", "Profit: %s (cost %s/u, %s)"),
            SignedCopper(r.profit), FormatCopper(math.floor(r.costBasis + 0.5)), SourceLabel(r.costSource)))
    else
        PANEL._profitRow:SetText(Ink(T("POSTING_NO_COST_BASIS", "No cost basis known"), RoleHex("Dim")))
    end
    if r.depositLoss and r.depositLoss > 0 then
        PANEL._riskRow:SetText(string.format(T("POSTING_DEPOSIT_RISK_FMT", "Expected deposit loss: %s"), FormatCopper(r.depositLoss)))
    else
        PANEL._riskRow:SetText("")
    end

    if r.avg then
        local trend = r.trend or 0
        local arrow = (trend > 0 and Ink("▲", GreenHex()))
            or (trend < 0 and Ink("▼", RedHex()))
            or Ink("•", RoleHex("Dim"))
        local hist = ns.PriceHistoryService and ns.PriceHistoryService:GetStats(CURRENT_ITEMID, 7 * 24 * 3600)
        PANEL._stats:SetText(string.format(T("POSTING_STATS_FMT", "%s 7d avg %s - last %s"),
            arrow, FormatCopper(r.avg), FormatCopper(hist and hist.latest)))
    else
        PANEL._stats:SetText(Ink(T("POSTING_NO_HISTORY", "No history yet. Press Sync AH Prices."), RoleHex("Dim")))
    end

    local name = (GetItemInfo and GetItemInfo(CURRENT_ITEMID)) or ("item:" .. CURRENT_ITEMID)
    PANEL._nameRow:SetText(name)
    LayoutStack(PANEL)
end

--- Coalesce bursts (search results + UpdatePostState fire together) into one refresh next frame.
local refreshPending = false
local function ScheduleRefresh()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0, function()
        refreshPending = false
        if PANEL and PANEL:IsShown() then
            PostingHelperUI:Refresh()
        end
    end)
end

local function UserPlaced()
    local prof = ns.db and ns.db.profile
    local s = prof and prof[POS_KEY]
    return type(s) == "table" and s.userPlaced == true
end

--- A position the player dragged to wins over the default dock beside the AH.
local function Place(p, anchor)
    local W = ns.ArtisanWindow
    if UserPlaced() and W.RestorePosition(p) then
        return
    end
    if anchor and anchor.GetRight and W.TileBeside(p, anchor, DOCK_GAP) then
        return
    end
    p:ClearAllPoints()
    p:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
end

function PostingHelperUI:Show(itemID, anchor)
    if not PANEL then PANEL = Build() end
    if not PANEL then return end
    local wasShown = PANEL:IsShown()
    CURRENT_ITEMID = itemID
    if not wasShown then
        Place(PANEL, anchor)
        PANEL:Show()
        if PANEL.Raise then PANEL:Raise() end
    end
    self:Refresh()
end

function PostingHelperUI:Hide()
    if PANEL then PANEL:Hide() end
    CURRENT_ITEMID = nil
    LAST_RESULT = nil
end

--- Re-read the visible sell frame: show for its item, hide when the slot is empty.
local function SyncToSellFrame()
    -- The sell frames keep their own shown flag after the AH closes (their OnHide still fires
    -- and schedules this sync), so the AH itself must be visible.
    local ah = _G.AuctionHouseFrame
    if not (ah and ah:IsVisible()) then
        PostingHelperUI:Hide()
        return
    end
    local svc = ns.PostingHelperService
    local ctx = svc and svc:GetSellContext()
    if ctx and ctx.itemID then
        if ctx.itemID ~= CURRENT_ITEMID or not (PANEL and PANEL:IsShown()) then
            PostingHelperUI:Show(ctx.itemID, _G.AuctionHouseFrame)
        else
            ScheduleRefresh()
        end
    else
        PostingHelperUI:Hide()
    end
end

local syncPending = false
local function ScheduleSync()
    if syncPending then return end
    syncPending = true
    C_Timer.After(0, function()
        syncPending = false
        SyncToSellFrame()
    end)
end

--- Hook AH sell frames: item change (SetItem), edits (UpdatePostState), show / hide.
local function HookSellFrame(f)
    if not f or f.ArtisanNexusPostingHooked then return end
    f.ArtisanNexusPostingHooked = true
    f:HookScript("OnShow", ScheduleSync)
    f:HookScript("OnHide", ScheduleSync)
    if type(f.SetItem) == "function" then
        hooksecurefunc(f, "SetItem", ScheduleSync)
    end
    if type(f.UpdatePostState) == "function" then
        hooksecurefunc(f, "UpdatePostState", ScheduleRefresh)
    end
end

local function HookAuctionHouse()
    --- Sell frames are parentKey children of AuctionHouseFrame, not globals.
    local ah = _G.AuctionHouseFrame
    if not ah then return false end
    HookSellFrame(ah.CommoditiesSellFrame)
    HookSellFrame(ah.ItemSellFrame)
    return true
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("ADDON_LOADED")
hookFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
hookFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
hookFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
hookFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == "Blizzard_AuctionHouseUI" and HookAuctionHouse() then
            hookFrame:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        PostingHelperUI:Hide()
    elseif PANEL and PANEL:IsShown() then
        -- Search results for the item on the sell frame changed (UniqueEvent: once per frame).
        if event == "COMMODITY_SEARCH_RESULTS_UPDATED" and arg1 ~= CURRENT_ITEMID then return end
        ScheduleRefresh()
    end
end)
-- Blizzard_AuctionHouseUI is load-on-demand, but another addon may have forced it earlier.
if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AuctionHouseUI") then
    if HookAuctionHouse() then
        hookFrame:UnregisterEvent("ADDON_LOADED")
    end
end

--- Theme change: re-skin the cached window in place (THEME_CHANGED listener below).
function PostingHelperUI:ResetForTheme()
    if PANEL then
        SkinPanel(PANEL)
    end
end

--- Theme / font change: repaint the kept window; a visible one refreshes its (colored) rows.
--- Economy messages that move any number refresh it while visible.
do
    local E = ns.Constants.EVENTS
    if E and ns.NewEventOwner then
        local owner = ns.NewEventOwner("PostingHelperUI")
        PostingHelperUI._eventOwner = owner
        local function Restyle()
            PostingHelperUI:ResetForTheme()
            if PANEL and PANEL:IsShown() and CURRENT_ITEMID then
                PostingHelperUI:Refresh()
            end
        end
        if E.THEME_CHANGED then owner:RegisterMessage(E.THEME_CHANGED, Restyle) end
        if E.FONT_CHANGED then owner:RegisterMessage(E.FONT_CHANGED, Restyle) end
        local live = {
            "AH_PRICES_UPDATED", "SALES_LEDGER_UPDATED", "OWNED_AUCTIONS_UPDATED",
            "MARKET_INTEL_UPDATED", "ECONOMY_CONFIG_CHANGED", "CRAFT_OPS_UPDATED",
        }
        for i = 1, #live do
            local msg = E[live[i]]
            if msg then owner:RegisterMessage(msg, ScheduleRefresh) end
        end
    end
end

ns.PostingHelperUI = PostingHelperUI
