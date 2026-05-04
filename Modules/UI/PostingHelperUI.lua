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

local PostingHelperUI = {}
local PANEL = nil
local CURRENT_ITEMID = nil

local function Apply(frame, bg, border)
    if ns.UI_ApplyVisuals then ns.UI_ApplyVisuals(frame, bg, border)
    elseif frame.SetBackdrop then
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
        frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    end
end

local function FormatCopper(c)
    if not c or c <= 0 then return "—" end
    local g = math.floor(c / 10000)
    local s = math.floor((c / 100) % 100)
    local cu = c % 100
    if g > 0 then return string.format("%dg %ds %dc", g, s, cu) end
    if s > 0 then return string.format("%ds %dc", s, cu) end
    return string.format("%dc", cu)
end

local function StrategyLabel(strategy)
    if strategy == "average" then return "7d avg" end
    if strategy == "max" then return "max(undercut, avg)" end
    return "undercut"
end

local function CycleStrategy(cur)
    if cur == "undercut" then return "average" end
    if cur == "average" then return "max" end
    return "undercut"
end

local function Build()
    local p = CreateFrame("Frame", "ArtisanNexusPostingPanel", UIParent, "BackdropTemplate")
    p:SetSize(260, 168)
    p:SetFrameStrata("HIGH")
    p:SetClampedToScreen(true)
    p:Hide()
    Apply(p, {0.10, 0.09, 0.12, 0.98}, {0.55, 0.42, 0.70, 0.9})

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 8, -6)
    title:SetText("Posting Helper")
    title:SetTextColor(0.95, 0.85, 1, 1)

    local nameRow = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameRow:SetPoint("TOPLEFT", 8, -28)
    nameRow:SetPoint("RIGHT", -8, 0)
    nameRow:SetJustifyH("LEFT")
    nameRow:SetWordWrap(false)
    nameRow:SetTextColor(0.85, 0.85, 0.9)
    p._nameRow = nameRow

    local priceLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    priceLabel:SetPoint("TOPLEFT", 8, -50)
    priceLabel:SetText("Suggested:")
    priceLabel:SetTextColor(0.7, 0.7, 0.75)

    local priceVal = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    priceVal:SetPoint("LEFT", priceLabel, "RIGHT", 6, 0)
    priceVal:SetTextColor(1, 0.95, 0.65)
    p._priceVal = priceVal

    local reasonRow = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    reasonRow:SetPoint("TOPLEFT", 8, -72)
    reasonRow:SetPoint("RIGHT", -8, 0)
    reasonRow:SetJustifyH("LEFT")
    reasonRow:SetWordWrap(false)
    reasonRow:SetTextColor(0.6, 0.6, 0.65)
    p._reasonRow = reasonRow

    local stats = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stats:SetPoint("TOPLEFT", 8, -94)
    stats:SetPoint("RIGHT", -8, 0)
    stats:SetJustifyH("LEFT")
    stats:SetWordWrap(false)
    stats:SetTextColor(0.78, 0.78, 0.85)
    p._stats = stats

    -- Strategy cycle button
    local stratBtn = CreateFrame("Button", nil, p)
    stratBtn:SetSize(140, 22)
    stratBtn:SetPoint("BOTTOMLEFT", 8, 8)
    Apply(stratBtn, {0.18, 0.16, 0.22, 1}, {0.55, 0.42, 0.70, 0.85})
    local stratLbl = stratBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stratLbl:SetPoint("CENTER")
    p._stratLbl = stratLbl
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
        GameTooltip:AddLine("Cycle posting strategy", 1, 1, 1)
        GameTooltip:AddLine("undercut → average → max", 0.7, 0.7, 0.75)
        GameTooltip:Show()
    end)
    stratBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Copy-to-chat button (so the player can paste / read the price easily)
    local copyBtn = CreateFrame("Button", nil, p)
    copyBtn:SetSize(96, 22)
    copyBtn:SetPoint("BOTTOMRIGHT", -8, 8)
    Apply(copyBtn, {0.20, 0.18, 0.10, 1}, {0.85, 0.65, 0.30, 0.85})
    local copyLbl = copyBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    copyLbl:SetPoint("CENTER")
    copyLbl:SetText("Print to chat")
    copyBtn:SetScript("OnClick", function()
        if not CURRENT_ITEMID or not ns.PostingHelperService then return end
        local price, reason = ns.PostingHelperService:SuggestPrice(CURRENT_ITEMID)
        if price and ns.ArtisanNexus and ns.ArtisanNexus.Print then
            ns.ArtisanNexus:Print(string.format("|cffd4af37Suggested:|r %s |cff888888(%s)|r",
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
    PANEL._stratLbl:SetText("Strategy: " .. StrategyLabel(cfg.strategy))

    local hist = ns.PriceHistoryService and ns.PriceHistoryService:GetStats(CURRENT_ITEMID, 7 * 24 * 3600) or { count = 0 }
    if hist.count >= 2 then
        local trend = ns.PriceHistoryService:GetTrend(CURRENT_ITEMID, 7 * 24 * 3600)
        local arrow = (trend > 0 and "|cff66ff66▲|r") or (trend < 0 and "|cffff6666▼|r") or "|cffaaaaaa•|r"
        PANEL._stats:SetText(string.format("%s 7d avg %s · last %s",
            arrow, FormatCopper(hist.avg), FormatCopper(hist.latest)))
    else
        PANEL._stats:SetText("|cff888888No history yet — run /an ah|r")
    end

    local name = (GetItemInfo and GetItemInfo(CURRENT_ITEMID)) or ("item:" .. CURRENT_ITEMID)
    PANEL._nameRow:SetText(name)
end

function PostingHelperUI:Show(itemID, anchor)
    if not PANEL then PANEL = Build() end
    CURRENT_ITEMID = itemID
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
local function HookSellFrame(name)
    local f = _G[name]
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
        HookSellFrame("AuctionHouseFrameCommoditiesSellFrame")
        HookSellFrame("AuctionHouseFrameItemSellFrame")
    elseif event == "AUCTION_HOUSE_CLOSED" then
        PostingHelperUI:Hide()
    end
end)

ns.PostingHelperUI = PostingHelperUI
