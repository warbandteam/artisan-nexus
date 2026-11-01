--[[
    Artisan Nexus - shopping list at the auction house.

    A panel docked to the right of AuctionHouseFrame listing the reagents the craft
    queue is short of, so the player does not have to type each name into the search
    box. Clicking a row searches it on the Buy tab (AHPriceService:BrowseItemAtAH).

    Deliberately read-only toward Blizzard's frame: nothing here calls an
    AuctionHouseFrame method. Buying runs through that frame, and taint picked up from
    an addon call would surface as a blocked action on the player's own Buy click.
    Our own frame is merely parented to it, which is what the AH sync button already does.

    Rows come from ShoppingListService:GetPurchaseShorts, which already subtracts bags,
    bank and warband stock, so a row disappearing means the shortfall is covered.
]]

local ADDON_NAME, ns = ...
local ArtisanNexus = ns.ArtisanNexus
local L = ns.SafeLocaleString
local E = ns.Constants.EVENTS

local M = {}
ns.ShoppingAHPanel = M

local PANEL_WIDTH = 280
local PANEL_GAP = 6
local ROW_HEIGHT = 26
local PAD = 10
local HEADER_H = 52
local ICON = 18

local panel, scroll, content
local rows = {}
local sessionHidden = false

local function Money(copper)
    if ns.UI_FormatMoney then
        return ns.UI_FormatMoney(copper or 0, 12, true)
    end
    return tostring(copper or 0)
end

--- Shortfalls that have to be bought, newest aggregate each call (the service memoizes per frame).
local function PurchaseRows()
    local svc = ns.ShoppingListService
    if not svc or not svc.GetPurchaseShorts then
        return {}
    end
    local ok, out = pcall(svc.GetPurchaseShorts, svc, {})
    if not ok or type(out) ~= "table" then
        return {}
    end
    return out
end

local function RowClick(row)
    local itemID = row and row._anItemID
    if not itemID then
        return
    end
    local ahs = ns.AHPriceService
    if ahs and ahs.BrowseItemAtAH then
        ahs:BrowseItemAtAH(itemID)
    end
end

local function RowEnter(row)
    local itemID = row and row._anItemID
    if not itemID then return end
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    GameTooltip:SetItemByID(itemID)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L("AH_PANEL_ROW_TT", "Click to search this reagent on the Buy tab."), 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function AcquireRow(index)
    local row = rows[index]
    if row then
        return row
    end
    row = CreateFrame("Button", nil, content)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT", content, "LEFT", 0, 0)
    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    row:SetPoint("TOP", content, "TOP", 0, -(index - 1) * ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON, ICON)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetJustifyH("LEFT")

    row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.cost:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.cost:SetJustifyH("RIGHT")

    row.need = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.need:SetPoint("RIGHT", row.cost, "LEFT", -8, 0)
    row.need:SetJustifyH("RIGHT")

    row.name:SetPoint("RIGHT", row.need, "LEFT", -6, 0)

    row:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight", "ADD")
    row:SetScript("OnClick", RowClick)
    row:SetScript("OnEnter", RowEnter)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    rows[index] = row
    return row
end

local function PaintRow(row, data)
    row._anItemID = data.itemID
    row.icon:SetTexture((ns.GetItemIconFileID and ns.GetItemIconFileID(data.itemID)) or 134400)
    local name = (ns.GetItemDisplayName and ns.GetItemDisplayName(data.itemID)) or ("item:" .. tostring(data.itemID))
    row.name:SetText(name)
    row.need:SetText("x" .. tostring(data.short or 0))
    row.cost:SetText(data.cost and Money(data.cost) or "")
    row:Show()
end

function M:Refresh()
    if not panel or not panel:IsShown() then
        return
    end
    local data = PurchaseRows()
    local total = 0
    for i = 1, #data do
        local row = AcquireRow(i)
        PaintRow(row, data[i])
        total = total + (tonumber(data[i].cost) or 0)
    end
    for i = #data + 1, #rows do
        rows[i]:Hide()
        rows[i]._anItemID = nil
    end
    content:SetHeight(math.max(1, #data * ROW_HEIGHT))

    if #data < 1 then
        panel.empty:Show()
    else
        panel.empty:Hide()
    end

    local money = GetMoney and GetMoney() or 0
    panel.total:SetText(string.format(L("AH_PANEL_TOTAL_FMT", "Needed: %s"), Money(total)))
    --- Affordability is the one number the player cannot read off the rows. The shortfall
    --- line carries the warning colour through its font object, so no hardcoded RGB here.
    if total > money then
        panel.gold:SetText(string.format(L("AH_PANEL_SHORT_FMT", "Short by %s"), Money(total - money)))
        panel.gold:Show()
    else
        panel.gold:Hide()
    end
end

local function EnsurePanel()
    if panel then
        return panel
    end
    local af = _G.AuctionHouseFrame
    if not af then
        return nil
    end
    panel = CreateFrame("Frame", "ArtisanNexusShoppingAHPanel", af, "BackdropTemplate")
    panel:SetWidth(PANEL_WIDTH)
    panel:SetPoint("TOPLEFT", af, "TOPRIGHT", PANEL_GAP, 0)
    panel:SetPoint("BOTTOMLEFT", af, "BOTTOMRIGHT", PANEL_GAP, 0)
    if panel.SetBackdrop then
        local bd = ns.UI_GetControlChromeBackdrop and ns.UI_GetControlChromeBackdrop()
        if bd then
            panel:SetBackdrop(bd)
        end
    end

    panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD)
    panel.title:SetText(L("AH_PANEL_TITLE", "Shopping List"))

    panel.close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
    panel.close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)
    panel.close:SetScript("OnClick", function()
        sessionHidden = true
        panel:Hide()
    end)

    panel.total = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.total:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)

    panel.gold = panel:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    panel.gold:SetPoint("LEFT", panel.total, "RIGHT", 8, 0)

    panel.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -HEADER_H - 8)
    panel.empty:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
    panel.empty:SetJustifyH("LEFT")
    panel.empty:SetText(L("AH_PANEL_EMPTY", "Nothing to buy - the queue's reagents are covered."))

    local factory = ns.UI and ns.UI.Factory
    scroll = factory and factory.CreateScrollFrame and factory:CreateScrollFrame(panel)
    if not scroll then
        scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    end
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -HEADER_H)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD - 18, PAD)

    content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(PANEL_WIDTH - PAD * 2 - 18)
    content:SetHeight(1)
    scroll:SetScrollChild(content)

    return panel
end

--- Show only when there is something to buy; an empty panel beside the AH is noise.
local function ShouldShow()
    if sessionHidden then
        return false
    end
    local data = PurchaseRows()
    return #data > 0
end

function M:Attach()
    if not EnsurePanel() then
        return
    end
    if ShouldShow() then
        panel:Show()
        self:Refresh()
    else
        panel:Hide()
    end
end

function M:Detach()
    if panel then
        panel:Hide()
    end
end

function M:Init()
    if self._inited then
        return
    end
    self._inited = true

    local owner = ns.NewEventOwner("ShoppingAHPanel")
    self._eventOwner = owner

    local function refresh()
        if panel and panel:IsShown() then
            M:Refresh()
        elseif _G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown() then
            M:Attach()
        end
    end

    owner:RegisterMessage(E.SHOPPING_LIST_UPDATED, refresh)
    owner:RegisterMessage(E.AH_PRICES_UPDATED, refresh)
    --- Rows drop out as the bought reagents land in the bags. Bucketed on the addon
    --- object, which carries AceBucket; the plain event owner only embeds AceEvent.
    if ArtisanNexus and ArtisanNexus.RegisterBucketEvent and not self._bagBucket then
        self._bagBucket = ArtisanNexus:RegisterBucketEvent("BAG_UPDATE", 0.5, refresh)
    end

    local f = CreateFrame("Frame")
    f:RegisterEvent("AUCTION_HOUSE_SHOW")
    f:RegisterEvent("AUCTION_HOUSE_CLOSED")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(_, event, arg1)
        if event == "ADDON_LOADED" then
            if arg1 == "Blizzard_AuctionHouseUI" then
                EnsurePanel()
            end
            return
        end
        if event == "AUCTION_HOUSE_SHOW" then
            sessionHidden = false
            M:Attach()
        else
            M:Detach()
        end
    end)
end
