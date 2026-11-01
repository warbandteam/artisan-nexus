--[[
    Artisan Nexus — Hub tab "plan": the Shopping group.

    Split from PlanPage.lua (loads right after it). Adds to ns.HubPlan (P):
      P.DrawShopping(parent, side, y, width, entries, profOpt) -> y
          one WN section header per recipe on the list (recipe icon, check when the list covers all
          its reagents, right = N reagents short + xN, WN icon-only buttons -, +, remove on the header:
          ShoppingListService:SetCount / Add / Remove), under it the WN Recipe Companion body per
          reagent (Modules/UI/CompanionList.lua CL.Reagent: header with xN for these crafts, storage
          rows for this character, alts and the Warband bank with quality columns, "Buy N" and its
          order-book cost when the list is short, Total), then "To buy" (right = N to buy · cost):
          Item | Buy N | Total | Source for the whole list; tooltip with stock per location, the
          recipes that need it, unit prices and alt holders; gatherable reagents name their gathering
          profession and a click opens that Session Loot tab (LootHistoryUI:Show, open world only).
          Stock = bags + bank + warband bank (ShoppingListService:Aggregate over
          RecipeService:GetStockByLocation), refreshed by BAG_STOCK_UPDATED (purchases, mail, crafts,
          posted auctions, bank moves).
      P.ClearShoppingList()   title-toolbar "Clear list" (StaticPopup confirm)
    Uses P.SectionHeader / P.DrawTable / P.DimLine / P.Confirm / P.ModifiedLink /
    P.Profile / P.Chat from PlanPage.lua.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local H = ns.HubUI_Internal
local P = ns.HubPlan
local C = ns.HubCrafting
assert(H and P and C, "Hub/Pages/PlanPage.lua must load before Hub/Pages/PlanPage_Shopping.lua")

local SafeL = H.SafeL
local RecipeIconTexture = H.RecipeIconTexture
local ItemLink = H.ItemLink
local Hex, Dim = H.Ink, H.Dim

local Money = H.Money
local ItemName = ns.GetItemDisplayName
local ItemIcon = ns.GetItemIconFileID
local COL = P.COL
local ModifiedLink, Profile = P.ModifiedLink, P.Profile

local ACUITY_ITEM_ID = (ns.Constants and ns.Constants.ARTISANS_ACUITY_ITEM_ID) or 210814

-- ─────────────────────────────────────────────────────────────────
-- Gatherable reagents (ShoppingListService:GetFarmTargets -> Session Loot tab)
-- ─────────────────────────────────────────────────────────────────

local farmCategory = {}

local function ValidLootTab(cat)
    local ui = ns.LootHistoryUI
    if ui and ui.IsValidTab then
        return ui:IsValidTab(cat)
    end
    return false
end

local function FarmLabel(cat)
    if ns.GetGatheringTabDisplayName and ValidLootTab(cat) then
        return ns.GetGatheringTabDisplayName(cat)
    end
    return ns.CoerceUiString and ns.CoerceUiString(cat, "?") or "?"
end

--- itemID -> Session Loot category for every gatherable short reagent.
local function CollectFarmCategories(profOpt)
    wipe(farmCategory)
    local svc = ns.ShoppingListService
    local targets = svc and svc.GetFarmTargets and svc:GetFarmTargets({ profession = profOpt }) or {}
    for i = 1, #targets do
        local t = targets[i]
        if t.itemID and t.category then
            farmCategory[t.itemID] = t.category
        end
    end
end

--- Session Loot opens beside the main window (tileAfter keeps it open; LootHistoryUI:Show itself
--- only works in the open world, so say so instead of a silent no-op).
local function OpenFarmTab(cat)
    if not (ValidLootTab(cat) and ns.LootHistoryUI.Show) then
        return false
    end
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        P.Chat(SafeL("HUB_LOOT_OPEN_WORLD_ONLY", "Session Loot opens in the open world only."))
        return true
    end
    ns.LootHistoryUI:Show(cat, { tileAfter = ArtisanNexus.UI and ArtisanNexus.UI.mainFrame })
    return true
end

-- ─────────────────────────────────────────────────────────────────
-- Shopping
-- ─────────────────────────────────────────────────────────────────

local function ShopSvc()
    return ns.ShoppingListService
end

--- Right to left: remove, +, -.
local SHOP_BTNS = {
    { file = "Interface\\Buttons\\UI-GroupLoot-Pass-Up", danger = true, ttKey = "HUB_SHOP_TT_REMOVE", tt = "Remove from the shopping list",
      fn = function(d) local s = ShopSvc(); if s then s:Remove(d.spellID) end end },
    { icon = "plus", ttKey = "HUB_SHOP_TT_ADD", tt = "One more craft",
      fn = function(d) local s = ShopSvc(); if s then s:Add(d.spellID, 1) end end },
    { icon = "minus", ttKey = "HUB_SHOP_TT_SUB", tt = "One craft less",
      -- SetCount removes the entry at 0.
      fn = function(d) local s = ShopSvc(); if s then s:SetCount(d.spellID, (d.count or 1) - 1) end end },
}

--- Reagent blocks are the WN Recipe Companion's (Modules/UI/CompanionList.lua); the to-buy list is a
--- TableKit list without a column strip: icon | item | Buy N | total | source.
local CL = ns.UI_CompanionList
local ATLAS_BUY = "Auctioneer"
local CHECK = ns.UI_GetIconMarkup and ns.UI_GetIconMarkup("status_ok", 14, 14, 0, 0) or ""

local BCOLS

local function BuyColumns()
    if not BCOLS then
        BCOLS = {
            H.IconColumn(),
            { key = "name", label = "", flex = 1, min = COL.NAME_MIN_NARROW },
            { key = "buy", label = "", width = 80, align = "RIGHT" },
            { key = "total", label = "", width = COL.MONEY, align = "RIGHT" },
            { key = "source", label = "", width = 96, align = "RIGHT" },
        }
    end
    return BCOLS
end

local SOURCE_LABELS = {
    an = { "HUB_SRC_AH", "AH" },
    auctionator = { nil, "Auctionator" },
    tsm = { nil, "TSM" },
    vendor = { "HUB_SRC_VENDOR", "Vendor" },
}

local function PriceSource(itemID)
    local ahs = ns.AHPriceService
    if not (itemID and ahs and ahs.GetPriceInfo) then
        return nil
    end
    local _, _, _, isStale, source = ahs:GetPriceInfo(itemID)
    return source, isStale
end

local function IsSoulboundRow(r)
    return r.isAcuity or r.itemID == ACUITY_ITEM_ID or r.isSoulbound
end

--- To-buy rows (short reagents only).
local function BuyValue(col, d)
    local k = col.key
    if k == "icon" then
        return ItemIcon(d.itemID)
    elseif k == "name" then
        return ItemName(d.itemID), "Bright"
    elseif k == "buy" then
        return Hex(string.format(SafeL("HUB_SHOP_BUY_FMT", "Buy %d"), d.short or 0), "warning")
    elseif k == "total" then
        if d.isAcuity or d.itemID == ACUITY_ITEM_ID then
            return Hex(SafeL("HUB_SOULBOUND_ACUITY", "[Acuity]"), "warning")
        elseif d.isSoulbound then
            return Dim(SafeL("HUB_SOULBOUND_BADGE", "[Soulbound]"))
        end
        return d.cost and Money(d.cost) or Dim(SafeL("HUB_NO_PRICE", "no price"))
    elseif k == "source" then
        if IsSoulboundRow(d) then
            return Dim("-")
        end
        local src, stale = PriceSource(d.itemID)
        local lbl = src and SOURCE_LABELS[src]
        if not lbl then
            local cat = farmCategory[d.itemID]
            return cat and FarmLabel(cat) or Dim("-"), "Muted"
        end
        local txt = lbl[1] and SafeL(lbl[1], lbl[2]) or lbl[2]
        return stale and Dim(txt .. "*") or txt
    end
    return ""
end

--- Alt holders listed in the short shopping-row tooltip.
local ALT_LINES = 3

local function TipLine(label, value)
    GameTooltip:AddDoubleLine(label, value, 0.75, 0.75, 0.75, 1, 1, 1)
end

local function RecipeName(spellID)
    local rs = ns.RecipeService
    return (rs and rs:GetRecipeName(spellID)) or H.RecipeFallbackName(spellID)
end

local function BuyRowEnter(row, d)
    if not d then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(d.itemID)
    GameTooltip:AddLine(" ")
    -- Where the stock is (the counts the Have cell adds up).
    TipLine(SafeL("HUB_BAGS", "bags"), tostring(d.bags or 0))
    TipLine(SafeL("HUB_BANK", "bank"), tostring(d.bank or 0))
    TipLine(SafeL("SIDECAR_WARBAND_BANK", "Warband bank"), tostring(d.warband or 0))
    if d.bySpell and next(d.bySpell) then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(SafeL("HUB_SHOP_NEEDED_BY", "Needed by"), 0.9, 0.8, 0.5)
        for spellID, qty in pairs(d.bySpell) do
            TipLine(RecipeName(spellID), "x" .. tostring(qty))
        end
    end
    if d.unitPrice and d.avgUnitCost and (d.short or 0) > 0 then
        GameTooltip:AddLine(" ")
        TipLine(SafeL("HUB_TT_LOWEST_UNIT", "Cheapest listing"), Money(d.unitPrice, nil, true))
        TipLine(string.format(SafeL("HUB_TT_AVG_UNIT_FMT", "Average buying %d"), d.short), Money(d.avgUnitCost, nil, true))
    end
    local src, stale = PriceSource(d.itemID)
    if src == "vendor" then
        GameTooltip:AddLine(string.format(SafeL("HUB_TT_VENDOR_SOURCED_FMT", "%s Sold by a vendor - priced at the vendor cost"),
            SafeL("HUB_VENDOR_MARK", "[V]")), 0.6, 0.8, 1)
    elseif stale then
        GameTooltip:AddLine(SafeL("HUB_TT_PRICE_STALE", "* Price data is old - sync the Auction House."), 0.6, 0.6, 0.6)
    end
    local cat = farmCategory[d.itemID]
    if cat and (d.short or 0) > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string.format(SafeL("HUB_SHOP_GATHER_FMT", "Gatherable: %s"), FarmLabel(cat)), 0.6, 0.8, 1)
        GameTooltip:AddLine(SafeL("HUB_FARM_GOTO_TT", "Click to open Session loot for this profession."), 0.7, 0.7, 0.7)
    elseif (d.short or 0) > 0 and ns.Economy and ns.Economy.IsAuctionHouseOpen and ns.Economy:IsAuctionHouseOpen() then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(SafeL("HUB_SHOP_AH_GOTO_TT", "Click to search the Auction House for this reagent."), 0.7, 0.7, 0.7)
    end
    if d.altDetails and #d.altDetails > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(SafeL("HUB_ALTS_INVENTORY_HEADER", "Warband Characters:"), 0.9, 0.8, 0.5)
        local bagsLbl, bankLbl = SafeL("HUB_BAGS", "bags"), SafeL("HUB_BANK", "bank")
        -- Short view: the top ALT_LINES holders with their totals; Shift lists all with bags / bank.
        local detailed = IsShiftKeyDown()
        local shown = detailed and #d.altDetails or math.min(#d.altDetails, ALT_LINES)
        for i = 1, shown do
            local a = d.altDetails[i]
            local right = detailed and string.format("x%d (%s: %d, %s: %d)", a.total or 0, bagsLbl, a.bagCount or 0,
                bankLbl, a.bankCount or 0) or ("x" .. tostring(a.total or 0))
            GameTooltip:AddDoubleLine(a.name, right, 0.8, 0.8, 0.8, 1, 1, 1)
        end
        if shown < #d.altDetails then
            GameTooltip:AddLine(string.format(SafeL("HUB_TT_MORE_SHIFT_FMT", "+%d more (Shift)"), #d.altDetails - shown),
                0.7, 0.7, 0.7)
        end
        H.WatchShift(row, function(r) BuyRowEnter(r, d) end)
    end
    GameTooltip:Show()
end

local function ItemRowClick(row, d, button)
    if button ~= "LeftButton" or not d or not d.itemID then
        return
    end
    if IsModifiedClick() then
        ModifiedLink(ItemLink(d.itemID))
        return
    end
    local cat = farmCategory[d.itemID]
    if cat then
        OpenFarmTab(cat)
        return
    end
    --- Bought, not gathered: with the auction house open, put it on the Buy tab so the
    --- player can buy it there. The purchase itself stays Blizzard's (see BrowseItemAtAH).
    local ahs = ns.AHPriceService
    if ahs and ahs.BrowseItemAtAH then
        ahs:BrowseItemAtAH(d.itemID)
    end
end

local function ClearList()
    local svc = ShopSvc()
    local n = (svc and svc.GetEntries) and #svc:GetEntries() or 0
    if n == 0 or not svc.Clear then return end
    P.Confirm("ARTISANNEXUS_CLEAR_SHOPPING",
        string.format(SafeL("HUB_CLEAR_SHOP_CONFIRM", "Remove all %d recipes from the shopping list?"), n),
        function()
            svc:Clear()
            P.Chat(SafeL("HUB_CLEAR_SHOP_DONE", "Shopping list cleared."))
        end)
end

P.ClearShoppingList = ClearList

local shopRows, buyRows = {}, {}

--- Still to buy first (biggest spend first).
local function BuyCompare(a, b)
    local ac, bc = a.cost or -1, b.cost or -1
    if ac ~= bc then return ac > bc end
    return (a.itemID or 0) < (b.itemID or 0)
end

--- To-buy header tooltip: what the stock counts and what the total leaves out.
local function ReagentsTooltip(missing, acuity)
    local lines = { SafeL("HUB_SHOP_REAGENTS_DESC", "Every reagent the list needs. Stock counts bags, bank and warband bank.") }
    if missing > 0 then
        lines[#lines + 1] = string.format(SafeL("HUB_SHOPPING_UNPRICED_FMT", "(%d unpriced)"), missing)
    end
    if acuity and acuity > 0 then
        lines[#lines + 1] = string.format(SafeL("HUB_ACUITY_TOTAL_FMT", "Acuity: %d"), acuity)
    end
    local p = Profile()
    if p and p.shoppingSubtractAlts then
        lines[#lines + 1] = SafeL("HUB_ALTS_SUBTRACTED", "(alt stock subtracted)")
    end
    return table.concat(lines, "\n")
end

--- The whole list's Aggregate row for a slot (its pick is one of the slot's tiers).
local function AggRowFor(agg, slot)
    for i = 1, #slot.candidates do
        local r = agg[slot.candidates[i]]
        if r then return r end
    end
    return nil
end

--- One recipe: a WN section header (recipe icon, check when the list covers all its reagents, right =
--- short count + xN, -, +, remove on the header), then the Recipe Companion block per reagent
--- (header with xN for these crafts, storage rows, "Buy N" with its cost when the list is short, total).
local function DrawRecipe(parent, side, y, width, d, agg, sectionGap)
    local rs = ns.RecipeService
    local slots = rs and rs.GetRequiredBasicSlots and rs:GetRequiredBasicSlots(d.spellID) or {}
    local missing = 0
    for i = 1, #slots do
        local r = AggRowFor(agg, slots[i])
        if r and (r.short or 0) > 0 then
            missing = missing + 1
        end
    end
    local ready = missing == 0 and #slots > 0
    local title = (ready and (CHECK .. " ") or "") .. Hex(d.name, ready and "success" or "Bright")
    local right = string.format(SafeL("HUB_COUNT_FMT", "x%d"), d.count or 1)
    if missing > 0 then
        right = Hex(string.format(SafeL("HUB_SHOP_SHORT_FMT", "%d reagents short"), missing), "warning") .. "   " .. right
    end
    local rkey = "sr:" .. d.spellID
    local expanded
    y, expanded = P.SectionHeader(parent, side, y, rkey, title, right,
        string.format(SafeL("HUB_SHOP_TT_CRAFTS_FMT", "%d crafts on the shopping list"), d.count or 1),
        { icon = d.icon, buttons = SHOP_BTNS, data = d, width = width })
    if not expanded or not CL or not P.companion then
        return y + sectionGap
    end
    y = y + CL.SECTION_SPACING
    local rowIndex = 0
    for i = 1, #slots do
        local slot = slots[i]
        local needed = (tonumber(slot.qty) or 0) * (d.count or 1)
        if needed > 0 then
            local r = AggRowFor(agg, slot)
            local opts
            if r then
                opts = { sufficient = (r.short or 0) == 0 }
                if (r.short or 0) > 0 then
                    local cost
                    if IsSoulboundRow(r) then
                        cost = Dim(SafeL("HUB_SOULBOUND_BADGE", "[Soulbound]"))
                    else
                        cost = r.cost and Money(r.cost) or Dim(SafeL("HUB_NO_PRICE", "no price"))
                    end
                    opts.extraRow = { atlas = ATLAS_BUY, value = cost,
                        name = Hex(string.format(SafeL("HUB_SHOP_BUY_FMT", "Buy %d"), r.short), "warning") }
                end
            end
            local gkey = "sg:" .. d.spellID .. ":" .. i
            y, rowIndex = CL.Reagent(P.companion, parent, side, y, side, rowIndex, slot, needed,
                P.IsCollapsed(gkey), function() P.ToggleCollapsed(gkey) end, opts)
        end
    end
    return y + sectionGap - CL.SECTION_SPACING
end

--- One WN section per recipe on the list (Recipe Companion body under it), then "To buy": everything
--- the whole list is still short of, for the AH run.
function P.DrawShopping(parent, side, y, width, entries, profOpt)
    local svc = ShopSvc()
    local sectionGap = math.max((ns.UI_LAYOUT.PAGE_STACK and ns.UI_LAYOUT.PAGE_STACK.SECTION_GAP) or 12, H.SECTION_GAP or 12)
    if #entries == 0 then
        local expanded
        y, expanded = P.SectionHeader(parent, side, y, "shopList", SafeL("HUB_SHOP_LIST_TITLE", "Shopping list"), nil,
            SafeL("HUB_SHOP_LIST_DESC", "Recipes you added (Crafting: right-click). - / + change the craft count."))
        if expanded then
            y = P.DimLine(parent, side, y, "shopEmpty", SafeL("HUB_SHOP_EMPTY_HINT",
                "The shopping list is empty. Right-click a recipe on the Crafting page to add it."))
        end
        return y
    end

    CollectFarmCategories(profOpt)
    local agg = svc:Aggregate({ subtractBags = true, profession = profOpt })
    local total, missing, acuity = 0, 0, 0
    if svc.TotalCost then
        total, missing, acuity = svc:TotalCost({ profession = profOpt })
    end

    local rs = ns.RecipeService
    for i = 1, #entries do
        local e = entries[i]
        local d = shopRows[i] or {}
        shopRows[i] = d
        local outID = rs and rs:GetOutputItem(e.spellID) or nil
        d.spellID, d.count, d.outID = e.spellID, e.count or 1, outID
        d.icon = RecipeIconTexture(e.spellID, outID)
        d.name = RecipeName(e.spellID)
        y = DrawRecipe(parent, side, y, width, d, agg, sectionGap)
    end
    for i = #entries + 1, #shopRows do
        shopRows[i] = nil
    end

    local n = 0
    for _, r in pairs(agg) do
        if (r.short or 0) > 0 then
            n = n + 1
            buyRows[n] = r
        end
    end
    for i = n + 1, #buyRows do
        buyRows[i] = nil
    end
    table.sort(buyRows, BuyCompare)
    local buyRight
    if n == 0 then
        buyRight = Hex(SafeL("HUB_SHOP_REAGENTS_DONE", "All in stock"), "success")
    else
        buyRight = string.format(SafeL("HUB_SHOP_REAGENTS_SUM_FMT", "%d to buy · %s"), n, Money(total, "0"))
    end
    local expanded
    y, expanded = P.SectionHeader(parent, side, y, "buy", SafeL("HUB_SHOP_TO_BUY_TITLE", "To buy"),
        buyRight, ReagentsTooltip(missing or 0, acuity))
    if not expanded or n == 0 then
        return y
    end
    return P.DrawTable(parent, side, y, width, "buy", BuyColumns(), buyRows, {
        valueFn = BuyValue, onRowEnter = BuyRowEnter, onRowClick = ItemRowClick,
    })
end
