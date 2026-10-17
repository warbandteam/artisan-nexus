--[[
    Artisan Nexus — Hub tab "plan": the Shopping group.

    Split from PlanPage.lua (loads right after it). Adds to ns.HubPlan (P):
      P.DrawShopping(parent, side, y, width, entries, profOpt) -> y
          WN collapsible header "Shopping" (right = total cost; unpriced count, Acuity and the alt
          stock note in its tooltip), then
            reagents  Aggregate() shorts priced through the order book (Item | Have / need | Short |
                      Avg unit cost | Total | Source); gatherable reagents
                      (ShoppingListService:GetFarmTargets) name their gathering profession in the
                      Source column when no price source applies, and a click opens that Session Loot
                      tab beside the main window (LootHistoryUI:Show(category, { tileAfter }), open
                      world only)
            recipes   the shopping-list recipes (Recipe | Crafts + WN icon-only row buttons -, +, remove
                      via ShoppingListService:SetCount / Add / Remove)
      P.ClearShoppingList()   title-toolbar "Clear list" (StaticPopup confirm)
    Uses P.SectionHeader / P.DrawTable / P.DimLine / P.ReleaseTable / P.Confirm / P.ModifiedLink /
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
local BLOCK_GAP = (ns.UI_LAYOUT.PAGE_STACK and ns.UI_LAYOUT.PAGE_STACK.BLOCK_GAP) or 8

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

local SCOLS, BCOLS

local function ShopColumns()
    if SCOLS then
        return SCOLS, BCOLS
    end
    SCOLS = {
        H.IconColumn(),
        { key = "name", label = SafeL("HUB_COL_RECIPE", "Recipe"), flex = 1, min = COL.NAME_MIN },
        { key = "count", label = SafeL("HUB_COL_CRAFTS", "Crafts"), width = COL.COUNT, align = "RIGHT" },
        { key = "actions", label = "", width = P.ButtonsWidth(#SHOP_BTNS) },
    }
    BCOLS = {
        H.IconColumn(),
        { key = "name", label = SafeL("HUB_COL_ITEM", "Item"), flex = 1, min = COL.NAME_MIN_NARROW },
        { key = "have", label = SafeL("HUB_COL_HAVE_NEED", "Have / need"), width = 88, align = "RIGHT" },
        { key = "short", label = SafeL("HUB_COL_SHORT", "Short"), width = COL.COUNT, align = "RIGHT" },
        { key = "unit", label = SafeL("HUB_COL_AVG_UNIT", "Avg unit cost"), width = COL.MONEY, align = "RIGHT" },
        { key = "total", label = SafeL("HUB_COL_TOTAL", "Total"), width = COL.MONEY, align = "RIGHT" },
        { key = "source", label = SafeL("HUB_COL_SOURCE", "Source"), width = 96, align = "RIGHT" },
    }
    return SCOLS, BCOLS
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

local function ShopValue(col, d)
    local k = col.key
    if k == "icon" then
        return d.icon
    elseif k == "name" then
        return d.name
    elseif k == "count" then
        return string.format(SafeL("HUB_COUNT_FMT", "x%d"), d.count or 1)
    end
    return ""
end

local function BuyValue(col, d)
    local k = col.key
    if k == "icon" then
        return ItemIcon(d.itemID)
    elseif k == "name" then
        return ItemName(d.itemID)
    elseif k == "have" then
        -- "have / need"; alt stock (Warband Nexus) as an accent "+n" after what this character holds.
        local txt = tostring(d.have or 0)
        if (d.altHave or 0) > 0 then
            txt = txt .. " " .. Hex("+" .. d.altHave, "accent")
        end
        return txt .. Dim(" / " .. tostring(d.needed or 0))
    elseif k == "short" then
        return Hex(tostring(d.short or 0), "warning")
    elseif k == "unit" then
        if IsSoulboundRow(d) or not d.unitPrice then
            return Dim("-")
        end
        local unit = d.avgUnitCost or d.unitPrice
        local txt = Money(unit)
        if d.avgUnitCost and d.avgUnitCost > d.unitPrice * 1.01 then
            txt = Hex(txt, "warning")
        end
        return txt
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

local function BuyRowEnter(row, d)
    if not d then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(d.itemID)
    if d.unitPrice and d.avgUnitCost and (d.short or 0) > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine(SafeL("HUB_TT_LOWEST_UNIT", "Cheapest listing"), Money(d.unitPrice, nil, true), 0.75, 0.75, 0.75, 1, 1, 1)
        GameTooltip:AddDoubleLine(string.format(SafeL("HUB_TT_AVG_UNIT_FMT", "Average buying %d"), d.short),
            Money(d.avgUnitCost, nil, true), 0.75, 0.75, 0.75, 1, 1, 1)
    end
    local src, stale = PriceSource(d.itemID)
    if src == "vendor" then
        GameTooltip:AddLine(string.format(SafeL("HUB_TT_VENDOR_SOURCED_FMT", "%s Sold by a vendor - priced at the vendor cost"),
            SafeL("HUB_VENDOR_MARK", "[V]")), 0.6, 0.8, 1)
    elseif stale then
        GameTooltip:AddLine(SafeL("HUB_TT_PRICE_STALE", "* Price data is old - sync the Auction House."), 0.6, 0.6, 0.6)
    end
    local cat = farmCategory[d.itemID]
    if cat then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string.format(SafeL("HUB_SHOP_GATHER_FMT", "Gatherable: %s"), FarmLabel(cat)), 0.6, 0.8, 1)
        GameTooltip:AddLine(SafeL("HUB_FARM_GOTO_TT", "Click to open Session loot for this profession."), 0.7, 0.7, 0.7)
    end
    if d.altDetails and #d.altDetails > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(SafeL("HUB_ALTS_INVENTORY_HEADER", "Warband Characters:"), 0.9, 0.8, 0.5)
        local bagsLbl, bankLbl = SafeL("HUB_BAGS", "bags"), SafeL("HUB_BANK", "bank")
        for i = 1, #d.altDetails do
            local a = d.altDetails[i]
            GameTooltip:AddDoubleLine(a.name, string.format("x%d (%s: %d, %s: %d)", a.total or 0, bagsLbl, a.bagCount or 0,
                bankLbl, a.bankCount or 0), 0.8, 0.8, 0.8, 1, 1, 1)
        end
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
    end
end

local function ShopRowEnter(row, d)
    if not d then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if d.outID then
        GameTooltip:SetItemByID(d.outID)
    else
        GameTooltip:AddLine(d.name, 1, 1, 1)
    end
    GameTooltip:Show()
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

local function BuyCompare(a, b)
    local ac, bc = a.cost or -1, b.cost or -1
    if ac ~= bc then return ac > bc end
    return (a.itemID or 0) < (b.itemID or 0)
end

--- Header tooltip: what the header total leaves out.
local function ShoppingTooltip(missing, acuity)
    local lines = {}
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
    return #lines > 0 and table.concat(lines, "\n") or nil
end

function P.DrawShopping(parent, side, y, width, entries, profOpt)
    local svc = ShopSvc()
    local total, missing, acuity = 0, 0, 0
    if svc.TotalCost then
        total, missing, acuity = svc:TotalCost({ profession = profOpt })
    end
    local right, tip
    if #entries > 0 then
        right = string.format(SafeL("HUB_SHOP_TOTAL_FMT", "Total: %s"), Money(total, "0"))
        tip = ShoppingTooltip(missing or 0, acuity)
    end
    local expanded
    y, expanded = P.SectionHeader(parent, side, y, "buy", SafeL("HUB_PLAN_SHOP_TITLE", "Shopping"), right, tip)
    if not expanded or #entries == 0 then
        P.ReleaseTable("shop")
        P.ReleaseTable("buy")
        if expanded then
            return P.DimLine(parent, side, y, "shopEmpty", SafeL("HUB_SHOP_EMPTY", "The shopping list is empty."))
        end
        return y
    end
    local scols, bcols = ShopColumns()

    -- Reagents still to get.
    CollectFarmCategories(profOpt)
    local agg = svc:Aggregate({ subtractBags = true, profession = profOpt })
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
    if n == 0 then
        P.ReleaseTable("buy")
        y = P.DimLine(parent, side, y, "buyNone", Hex(SafeL("HUB_SHOPPING_ALL_IN_BAGS", "All reagents already in bags."), "success"))
    else
        y = P.DrawTable(parent, side, y, width, "buy", bcols, buyRows, {
            valueFn = BuyValue, onRowEnter = BuyRowEnter, onRowClick = ItemRowClick,
        })
    end

    -- Recipes on the list.
    local rs = ns.RecipeService
    for i = 1, #entries do
        local e = entries[i]
        local d = shopRows[i] or {}
        shopRows[i] = d
        local outID = rs and rs:GetOutputItem(e.spellID) or nil
        d.spellID, d.count, d.outID = e.spellID, e.count or 1, outID
        d.icon = RecipeIconTexture(e.spellID, outID)
        d.name = (rs and rs:GetRecipeName(e.spellID)) or H.RecipeFallbackName(e.spellID)
    end
    for i = #entries + 1, #shopRows do
        shopRows[i] = nil
    end
    return P.DrawTable(parent, side, y + BLOCK_GAP, width, "shop", scols, shopRows, {
        valueFn = ShopValue, onRowEnter = ShopRowEnter, rowButtons = SHOP_BTNS,
    })
end
