--[[
    Artisan Nexus — Posting Helper visible panel.

    A small floating advisor that anchors next to the AH sell frame
    (commodities or item) whenever it shows. Surfaces:
      * suggested unit price (PostingHelperService:SuggestPrice)
      * 7d avg / latest / trend (PriceHistoryService)
      * tiny sparkline (PriceHistoryUI)
      * "Strategy" cycle button: undercut / average / max
      * "Floor" lock toggle

    Pricing the actual sell input box requires SecureActionButtonTemplate
    in protected combat-safe contexts; we keep it advisory and let the
    player click "Copy" which puts a chat message they can drag onto the
    edit box, or just type the suggestion themselves.
]]

local ADDON_NAME, ns = ...

local L = ns.L

local PostingHelperUI = {}
local PANEL = nil
local CURRENT_ITEMID = nil
--- Last anchor so a theme-change rebuild can restore the panel in place.
local LAST_ANCHOR = nil

--- Live palette — resolve at call time (UI_RefreshColors swaps sub-tables).
local function C()
    return ns.UI_COLORS or {}
end

local function Font(role)
    local f = ns.UI_FONTS
    if f and role and f[role] then
        return f[role]
    end
    return (f and f.WINDOW_BODY) or "GameFontNormal"
end

local LAYOUT = ns.UI_LAYOUT or {}

--- Skin-branching surface styler: UI_StylePanelInset draws the classic
--- tooltip-border inset in Classic and pixel chrome in Modern. Bare
--- UI_ApplyVisuals is a NO-OP in Classic — using it alone shipped this panel
--- borderless there.
local function Apply(frame, bg, border)
    if ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(frame, bg, border)
    elseif ns.UI_ApplyVisuals then
        ns.UI_ApplyVisuals(frame, bg, border)
    elseif frame.SetBackdrop then
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
        frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    end
end

--- Semantic hex from the live palette (arrows / bullet markers).
local function HexRole(text, kind)
    local hex = ns.UI_GetSemanticHex and ns.UI_GetSemanticHex(kind)
    if not hex then
        return text
    end
    return "|cff" .. hex .. text .. "|r"
end

--- Shared money formatter (Modules/Utilities.lua; loads before this file per
--- TOC). This panel shows an em dash for missing values.
local function FormatCopper(c)
    return ns.FormatCopper(c) or "—"
end

local function StrategyLabel(strategy)
    if strategy == "average" then return (L and L["POSTING_STRAT_AVERAGE"]) or "7d avg" end
    if strategy == "max" then return (L and L["POSTING_STRAT_MAX"]) or "max(undercut, avg)" end
    return (L and L["POSTING_STRAT_UNDERCUT"]) or "undercut"
end

local function CycleStrategy(cur)
    if cur == "undercut" then return "average" end
    if cur == "average" then return "max" end
    return "undercut"
end

local function Build()
    local p = CreateFrame("Frame", "ArtisanNexusPostingPanel", UIParent, "BackdropTemplate")
    p:SetSize(LAYOUT.POSTING_PANEL_WIDTH or 272, LAYOUT.POSTING_PANEL_HEIGHT or 184)
    p:SetFrameStrata("HIGH")
    p:SetClampedToScreen(true)
    p:Hide()
    local bg = C().bg or { 0.065, 0.062, 0.076, 0.97 }
    local ac = C().accent or { 0.44, 0.32, 0.58, 1 }
    Apply(p, { bg[1], bg[2], bg[3], 0.98 }, { ac[1], ac[2], ac[3], 0.9 })

    local tb = C().textBright or { 0.96, 0.95, 0.97, 1 }
    local tn = C().textNormal or { 0.82, 0.80, 0.86, 1 }
    local tm = C().textMuted or { 0.72, 0.69, 0.78, 1 }
    local td = C().textDim or { 0.52, 0.50, 0.56, 1 }
    local warn = C().warning or { 0.90, 0.76, 0.46, 1 }

    local title = p:CreateFontString(nil, "OVERLAY", Font("WINDOW_SECTION"))
    title:SetPoint("TOPLEFT", 8, -6)
    title:SetText((L and L["POSTING_PANEL_TITLE"]) or "Posting Helper")
    title:SetTextColor(tb[1], tb[2], tb[3], 1)

    local nameRow = p:CreateFontString(nil, "OVERLAY", Font("WINDOW_BODY"))
    nameRow:SetPoint("TOPLEFT", 8, -30)
    nameRow:SetPoint("RIGHT", -8, 0)
    nameRow:SetJustifyH("LEFT")
    nameRow:SetWordWrap(false)
    nameRow:SetTextColor(tn[1], tn[2], tn[3])
    p._nameRow = nameRow

    local priceLabel = p:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    priceLabel:SetPoint("TOPLEFT", 8, -54)
    priceLabel:SetText((L and L["POSTING_SUGGESTED_LABEL"]) or "Suggested:")
    priceLabel:SetTextColor(tm[1], tm[2], tm[3])

    local priceVal = p:CreateFontString(nil, "OVERLAY", Font("WINDOW_EMPHASIS"))
    priceVal:SetPoint("LEFT", priceLabel, "RIGHT", 6, 0)
    priceVal:SetTextColor(warn[1], warn[2], warn[3])
    p._priceVal = priceVal

    local reasonRow = p:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    reasonRow:SetPoint("TOPLEFT", 8, -78)
    reasonRow:SetPoint("RIGHT", -8, 0)
    reasonRow:SetJustifyH("LEFT")
    reasonRow:SetWordWrap(false)
    reasonRow:SetTextColor(td[1], td[2], td[3])
    p._reasonRow = reasonRow

    local stats = p:CreateFontString(nil, "OVERLAY", Font("WINDOW_BODY"))
    stats:SetPoint("TOPLEFT", 8, -100)
    stats:SetPoint("RIGHT", -8, 0)
    stats:SetJustifyH("LEFT")
    stats:SetWordWrap(false)
    stats:SetTextColor(tn[1], tn[2], tn[3])
    p._stats = stats

    -- Strategy cycle button (toolbar factory: native art in Classic,
    -- themed pixel chrome in Modern)
    local btnH = LAYOUT.POSTING_BUTTON_HEIGHT or 26
    local stratBtn = (ns.UI_CreateToolbarButton and ns.UI_CreateToolbarButton(p, btnH))
        or CreateFrame("Button", nil, p)
    stratBtn:SetSize(148, btnH)
    stratBtn:SetPoint("BOTTOMLEFT", 8, 8)
    if ns.UI_StylePanelButton then
        ns.UI_StylePanelButton(stratBtn)
    end
    --- Bound the label inside the 148px button; the strategy names are long
    --- ("max(undercut, avg)") and used to bleed over the neighbouring button.
    local stratLbl = stratBtn._lbl or (stratBtn.GetFontString and stratBtn:GetFontString())
    if stratLbl then
        stratLbl:ClearAllPoints()
        stratLbl:SetPoint("LEFT", stratBtn, "LEFT", 4, 0)
        stratLbl:SetPoint("RIGHT", stratBtn, "RIGHT", -4, 0)
        stratLbl:SetJustifyH("CENTER")
        stratLbl:SetWordWrap(false)
        stratLbl:SetMaxLines(1)
    end
    p._stratBtn = stratBtn
    stratBtn:SetScript("OnClick", function()
        local svc = ns.PostingHelperService
        if not svc then return end
        local cfg = svc:GetConfig()
        cfg.strategy = CycleStrategy(cfg.strategy or "undercut")
        svc:SetConfig(cfg)
        PostingHelperUI:Refresh()
    end)
    stratBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine((L and L["POSTING_STRATEGY_TT_TITLE"]) or "Cycle posting strategy", 1, 1, 1)
        GameTooltip:AddLine((L and L["POSTING_STRATEGY_TT_DESC"]) or "undercut -> average -> max", 0.7, 0.7, 0.75)
        GameTooltip:Show()
    end)
    stratBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Copy-to-chat button (so the player can paste / read the price easily)
    local copyBtn = (ns.UI_CreateToolbarButton and ns.UI_CreateToolbarButton(p, btnH))
        or CreateFrame("Button", nil, p)
    copyBtn:SetSize(104, btnH)
    copyBtn:SetPoint("BOTTOMRIGHT", -8, 8)
    local warnBg, warnBd
    if ns.UI_GetSemanticButtonChrome then
        warnBg, warnBd = ns.UI_GetSemanticButtonChrome("warning")
    end
    if ns.UI_StylePanelButton then
        ns.UI_StylePanelButton(copyBtn, { bg = warnBg, border = warnBd })
    end
    if ns.UI_SetToolbarButtonText then
        ns.UI_SetToolbarButtonText(copyBtn, (L and L["POSTING_PRINT_TO_CHAT"]) or "Print to chat")
    end
    copyBtn:SetScript("OnClick", function()
        if not CURRENT_ITEMID or not ns.PostingHelperService then return end
        local price, reason = ns.PostingHelperService:SuggestPrice(CURRENT_ITEMID)
        if price and ns.ArtisanNexus and ns.ArtisanNexus.Print then
            ns.ArtisanNexus:Print(string.format(
                (L and L["POSTING_SUGGESTED_CHAT_FMT"]) or "|cffd4af37Suggested:|r %s |cff888888(%s)|r",
                FormatCopper(price), reason or ""))
        end
    end)

    p:EnableMouse(true)
    p:SetMovable(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", function() p:StartMoving() end)
    p:SetScript("OnDragStop", function() p:StopMovingOrSizing() end)

    return p
end

function PostingHelperUI:Refresh()
    if not PANEL or not CURRENT_ITEMID then return end
    local svc = ns.PostingHelperService
    if not svc then return end
    local price, reason = svc:SuggestPrice(CURRENT_ITEMID)
    local cfg = svc:GetConfig()

    PANEL._priceVal:SetText(FormatCopper(price))
    PANEL._reasonRow:SetText(reason or "")
    local stratText = string.format((L and L["POSTING_STRATEGY_LABEL_FMT"]) or "Strategy: %s", StrategyLabel(cfg.strategy))
    if ns.UI_SetToolbarButtonText and PANEL._stratBtn then
        ns.UI_SetToolbarButtonText(PANEL._stratBtn, stratText)
    end

    local hist = ns.PriceHistoryService and ns.PriceHistoryService:GetStats(CURRENT_ITEMID, 7 * 24 * 3600) or { count = 0 }
    if hist.count >= 2 then
        local trend = ns.PriceHistoryService:GetTrend(CURRENT_ITEMID, 7 * 24 * 3600)
        local arrow = (trend > 0 and HexRole("▲", "success"))
            or (trend < 0 and HexRole("▼", "danger"))
            or HexRole("•", "dim")
        PANEL._stats:SetText(string.format((L and L["POSTING_STATS_FMT"]) or "%s 7d avg %s - last %s",
            arrow, FormatCopper(hist.avg), FormatCopper(hist.latest)))
    else
        PANEL._stats:SetText((L and L["POSTING_NO_HISTORY"]) or "|cff888888No history yet - run /an ah|r")
    end

    local name = (GetItemInfo and GetItemInfo(CURRENT_ITEMID)) or ("item:" .. CURRENT_ITEMID)
    PANEL._nameRow:SetText(name)
end

function PostingHelperUI:Show(itemID, anchor)
    if not PANEL then PANEL = Build() end
    CURRENT_ITEMID = itemID
    LAST_ANCHOR = anchor
    PANEL:ClearAllPoints()
    if anchor and anchor.GetRight then
        PANEL:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
    else
        PANEL:SetPoint("CENTER")
    end
    PANEL:Show()
    self:Refresh()
end

function PostingHelperUI:Hide()
    if PANEL then PANEL:Hide() end
    CURRENT_ITEMID = nil
end

--- Hook AH sell frames to auto-show next to them.
local function HookSellFrame(f)
    if not f or f.ArtisanNexusPostingHooked then return end
    f.ArtisanNexusPostingHooked = true
    f:HookScript("OnShow", function(self)
        local itemID = self.itemKey and self.itemKey.itemID
            or (self.GetItemID and self:GetItemID())
            or (self.itemLocation and C_Item and C_Item.GetItemID and C_Item.GetItemID(self.itemLocation))
            or nil
        if itemID then PostingHelperUI:Show(itemID, _G.AuctionHouseFrame) end
    end)
    f:HookScript("OnHide", function() PostingHelperUI:Hide() end)
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("ADDON_LOADED")
hookFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
hookFrame:SetScript("OnEvent", function(_, event, addonName)
    if event == "ADDON_LOADED" and addonName == "Blizzard_AuctionHouseUI" then
        --- Sell frames are parentKey children of AuctionHouseFrame, not globals.
        local ah = _G.AuctionHouseFrame
        if ah then
            HookSellFrame(ah.CommoditiesSellFrame)
            HookSellFrame(ah.ItemSellFrame)
        end
        hookFrame:UnregisterEvent("ADDON_LOADED")
    elseif event == "AUCTION_HOUSE_CLOSED" then
        PostingHelperUI:Hide()
    end
end)

--- UI-mode switch: drop the cached panel so the next Show rebuilds with the
--- active skin (called from ns.UI_ResetMainWindowsForUiMode).
function PostingHelperUI:ResetForUiMode()
    if PANEL then
        PANEL:Hide()
        --- Panel + buttons went through ApplyVisuals — leave BORDER_REGISTRY
        --- before discarding (THEME_CHANGED rebuild comes through here too).
        if ns.UI_UnregisterVisuals then
            ns.UI_UnregisterVisuals(PANEL)
        end
        PANEL = nil
    end
end

--- Theme change: colors are baked at build time, so drop the cached panel.
--- If it was visible (AH sell frame open), rebuild immediately for the same item.
do
    local E = ns.Constants and ns.Constants.EVENTS
    if E and E.THEME_CHANGED and ns.NewEventOwner then
        local owner = ns.NewEventOwner("PostingHelperUI")
        PostingHelperUI._eventOwner = owner
        owner:RegisterMessage(E.THEME_CHANGED, function()
            local wasShown = PANEL and PANEL:IsShown()
            local itemID = CURRENT_ITEMID
            PostingHelperUI:ResetForUiMode()
            if wasShown and itemID then
                PostingHelperUI:Show(itemID, LAST_ANCHOR)
            end
        end)
    end
end

ns.PostingHelperUI = PostingHelperUI
