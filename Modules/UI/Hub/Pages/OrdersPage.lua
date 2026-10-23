--[[
    Artisan Nexus — Hub tab: Crafting orders (key "orders"), drawn as a Warband Nexus main-window tab.

    WN tab pattern (LedgerPage.lua / WN CurrencyUI collapsible sections + TableKit rows):
    ArtisanNexus:DrawOrdersTab(scrollChild) returns the body height; UI_TabHost.lua dispatches it.

      fixedHeader  WN title card (subtitle = time of the last scan) + title toolbar: sort dropdown
                   (profile.hubOrdersSort), profession filter flyout, Refresh
                   (CraftingOrdersService:RequestAll(true); works while the crafter order page is open,
                   the tooltip carries the time of the last scan from CraftingOrdersService:GetSummary().at)
      Body         WN Professions layout, no column strip ([icon] Item | Conc | Net | Expires rows):
                   one WN collapsible header per order type that has orders (Patron / Public /
                   Personal / Guild; right = order count and best net; the type's meaning is the header
                   tooltip) with its rows from CraftingOrdersService:GetEvaluatedOrders(orderType),
                   sorted by the sort dropdown (default net). Tip, rewards, your reagents, concentration cost,
                   customer, minimum quality and flag labels (GetFlagLabel) are in the row tooltip; rows
                   with non-informational flags are dimmed and marked (!).
      Empty        no order at all -> one WN tab empty-state card
    Body kit / toolbar / filter / ink: H.NewTabBody, H.ToolbarButton, H.ProfessionFilterButton, H.Ink, H.Money
    (Hub/HubTabKit.lua, Hub/HubData.lua).
    Refresh: UI_RefreshRouter.lua routes CRAFTING_ORDERS_UPDATED to this tab.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local H = ns.HubUI_Internal
assert(H and H.NewTabBody, "Hub/HubTabKit.lua must load before Hub/Pages/OrdersPage.lua")

local TK = ns.UI_TableKit
local SafeL = H.SafeL
local FormatDuration = H.FormatDuration
local RecipeIconTexture = H.RecipeIconTexture
local Ink = H.Ink

--- Enum.CraftingOrderType Public=0 Guild=1 Personal=2 Npc=3
--- (verified 2026-10-14, CraftingOrdersService header / CraftingOrderUIDocumentation 12.1.5.70391).
local function OrderTypeEnum()
    local T = Enum and Enum.CraftingOrderType
    return {
        Public = T and T.Public or 0,
        Guild = T and T.Guild or 1,
        Personal = T and T.Personal or 2,
        Npc = T and T.Npc or 3,
    }
end

--- Flags that only describe the order (still dimmed rows would hide most patron orders).
local INFO_FLAGS = { needsConcentration = true, rewardHeuristic = true }

local function Svc()
    return ns.CraftingOrdersService
end

local function HasFlags(o)
    return type(o.flags) == "table" and #o.flags > 0
end

--- Dimmed when any flag is more than informational.
local function IsDimmed(o)
    if not HasFlags(o) then
        return false
    end
    for i = 1, #o.flags do
        if not INFO_FLAGS[o.flags[i]] then
            return true
        end
    end
    return false
end

local function RecipeLabel(o)
    local rs = ns.RecipeService
    local name = o.spellID and rs and rs:GetRecipeName(o.spellID)
    if (not name or name == "") and o.itemID then
        name = ns.GetItemDisplayName(o.itemID)
    end
    return name or H.RecipeFallbackName(o.spellID)
end

local function CustomerLabel(o)
    local c = o.customer
    if type(c) ~= "string" or c == "" then
        return o.numAvailable and string.format(SafeL("HUB_ORDER_AVAILABLE_FMT", "%d available"), o.numAvailable) or "-"
    end
    if c:sub(1, 4) == "npc:" then
        return SafeL("HUB_ORDER_NPC_CUSTOMER", "NPC patron")
    end
    return c
end

local function OrderTypeLabel(orderType)
    local T = OrderTypeEnum()
    if orderType == T.Npc then return SafeL("HUB_ORDER_TYPE_NPC", "Patron") end
    if orderType == T.Personal then return SafeL("HUB_ORDER_TYPE_PERSONAL", "Personal") end
    if orderType == T.Public then return SafeL("HUB_ORDER_TYPE_PUBLIC", "Public") end
    if orderType == T.Guild then return SafeL("HUB_ORDER_TYPE_GUILD", "Guild") end
    return "?"
end

local function LastScanText()
    local svc = Svc()
    local sum = svc and svc.GetSummary and svc:GetSummary()
    if sum and sum.at then
        return string.format(SafeL("HUB_ORDERS_UPDATED_FMT", "Updated %s ago"), FormatDuration(time() - sum.at))
    end
    return SafeL("HUB_ORDERS_NOT_SCANNED", "Not scanned yet")
end

local Money = H.Money

local body = H.NewTabBody("orders", "hubOrdersExpanded")

-- ─────────────────────────────────────────────────────────────────
-- Table
-- ─────────────────────────────────────────────────────────────────

local function NumCol(key, label, width, tooltip)
    return { key = key, label = label, width = width, align = "RIGHT", tooltip = tooltip }
end

local ORDER_COLS = {
    H.IconColumn(),
    { key = "item", label = SafeL("HUB_COL_ITEM", "Item"), flex = 1, min = 100 },
    NumCol("conc", SafeL("HUB_COL_CONC_SHORT", "Conc"), 56),
    NumCol("net", SafeL("HUB_COL_NET", "Net"), H.COL.MONEY_WIDE, SafeL("HUB_PAGE_ORDERS_DESC", "Net value: rewards minus what you supply.")),
    { key = "expires", label = SafeL("HUB_COL_EXPIRES", "Expires"), width = 72, align = "RIGHT" },
}

--- Sort modes of the title-toolbar sort dropdown (CraftingPage.lua pattern).
local SORT_OPTIONS = {
    { key = "net", label = SafeL("HUB_SORT_NET", "Net (highest)"), asc = false },
    { key = "item", label = SafeL("HUB_SORT_NAME", "Name (A-Z)"), asc = true },
    { key = "conc", label = SafeL("HUB_SORT_CONC", "Concentration (lowest)"), asc = true },
    { key = "expires", label = SafeL("HUB_SORT_EXPIRES", "Expires (soonest)"), asc = true },
}

--- profile.hubOrdersSort = { key = <SORT_OPTIONS key> } (the dropdown writes .key).
local function SortTable()
    local p = ns.db and ns.db.profile
    if not p then return { key = "net" } end
    if type(p.hubOrdersSort) ~= "table" then
        p.hubOrdersSort = { key = "net" }
    end
    return p.hubOrdersSort
end

local ORDER_SORT = {
    key = "net", asc = false,
    value = function(o, key)
        if key == "item" then return RecipeLabel(o) end
        if key == "conc" then return tonumber(o.concNeeded) end
        if key == "expires" then return tonumber(o.expiresAt) end
        return tonumber(o.net)
    end,
}

local function OrderValue(col, o)
    local k = col.key
    local dim = IsDimmed(o)
    local role = dim and "Dim" or "Bright"
    if k == "icon" then
        return RecipeIconTexture(o.spellID, o.itemID)
    elseif k == "item" then
        local txt = RecipeLabel(o)
        if HasFlags(o) then
            txt = txt .. " " .. Ink("(!)", "orange")
        end
        return txt, role
    elseif k == "conc" then
        if o.concNeeded and o.concNeeded > 0 then
            return tostring(math.floor(o.concNeeded + 0.5)), role
        end
        return Ink("-", "Dim")
    elseif k == "net" then
        -- WN signed money cell: plain digits + coins in one semantic ink (TableKit SetSignedMoneyCell).
        local v = math.floor((o.net or 0) + 0.5)
        local txt = TK.FormatSignedMoneyPlain(v, 12)
        if dim or v == 0 then
            return txt, dim and "Dim" or "Normal"
        end
        if v > 0 then
            return txt, "Normal", ns.UI_GetSemanticGreenColor()
        end
        return txt, "Normal", ns.UI_GetSemanticRedColor()
    elseif k == "expires" then
        if o.expiresAt then
            return FormatDuration(o.expiresAt - time()), "Muted"
        end
        return Ink("-", "Dim")
    end
    return ""
end

local function OrderRowEnter(row, o)
    if not o then return end
    local svc = Svc()
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(RecipeLabel(o), 1, 1, 1)
    GameTooltip:AddLine(OrderTypeLabel(o.orderType) .. " - " .. CustomerLabel(o), 0.9, 0.8, 0.5)
    local function Pair(label, value)
        GameTooltip:AddDoubleLine(label, value, 0.75, 0.75, 0.75, 1, 1, 1)
    end
    -- Short view: net, the tip and what it costs you, plus warnings; the rest is the Shift view.
    if not IsShiftKeyDown() then
        Pair(SafeL("HUB_COL_NET", "Net"), Money(o.net or 0, nil, true))
        Pair(SafeL("HUB_ORDER_TIP", "Tip (after cut)"), Money(o.tipNet or 0, nil, true))
        Pair(SafeL("HUB_ORDER_REAGENTS", "Your reagents"), "-" .. Money(o.reagentCost or 0, nil, true))
        if HasFlags(o) and svc and svc.GetFlagLabel then
            for i = 1, #o.flags do
                GameTooltip:AddLine("(!) " .. svc:GetFlagLabel(o.flags[i]), 1, 0.7, 0.3)
            end
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(SafeL("HUB_TT_SHIFT_DETAILS", "Shift: full breakdown"), 0.7, 0.7, 0.7)
        GameTooltip:Show()
        H.WatchShift(row, function(r) OrderRowEnter(r, o) end)
        return
    end
    Pair(SafeL("HUB_ORDER_TIP", "Tip (after cut)"), Money(o.tipNet or 0, nil, true))
    if o.tipAvg then
        Pair(SafeL("HUB_ORDER_TIP_AVG", "Average tip"), Money(o.tipAvg, nil, true))
    end
    Pair(SafeL("HUB_COL_REWARDS", "Rewards"), Money(o.rewardsValue or 0, nil, true))
    Pair(SafeL("HUB_ORDER_REAGENTS", "Your reagents"), "-" .. Money(o.reagentCost or 0, nil, true))
    if o.concNeeded and o.concNeeded > 0 then
        Pair(SafeL("HUB_COL_CONCENTRATION", "Concentration"),
            string.format("%d (-%s)", math.floor(o.concNeeded + 0.5), Money(o.concCost or 0, nil, true)))
    end
    Pair(SafeL("HUB_COL_NET", "Net"), Money(o.net or 0, nil, true))
    if o.minQuality and o.minQuality > 0 then
        Pair(SafeL("HUB_ORDER_MIN_QUALITY", "Minimum quality"), "Q" .. tostring(o.minQuality))
    end
    if o.isRecraft then
        GameTooltip:AddLine(SafeL("HUB_ORDER_RECRAFT", "Recraft order"), 0.7, 0.7, 0.7)
    end
    if o.expiresAt then
        Pair(SafeL("HUB_ORDER_EXPIRES", "Expires in"), FormatDuration(o.expiresAt - time()))
    end
    if HasFlags(o) and svc and svc.GetFlagLabel then
        GameTooltip:AddLine(" ")
        for i = 1, #o.flags do
            GameTooltip:AddLine("(!) " .. svc:GetFlagLabel(o.flags[i]), 1, 0.7, 0.3)
        end
    end
    GameTooltip:Show()
    H.WatchShift(row, function(r) OrderRowEnter(r, o) end)
end

local function OrderRowClick(row, o, button)
    if button ~= "LeftButton" or not o or not IsModifiedClick() then return end
    local link
    if o.itemID then
        link = H.ItemLink(o.itemID)
    elseif o.spellID then
        link = C_Spell.GetSpellLink(o.spellID)
    end
    if link then HandleModifiedItemClick(link) end
end

-- ─────────────────────────────────────────────────────────────────
-- Tab
-- ─────────────────────────────────────────────────────────────────

local SECTION_DEFS
local function SectionDefs()
    if SECTION_DEFS then return SECTION_DEFS end
    local T = OrderTypeEnum()
    SECTION_DEFS = {
        { type = T.Npc, key = "npc", titleKey = "HUB_ORDER_TYPE_NPC", titleFb = "Patron",
          tooltipKey = "HUB_ORDERS_PATRON_DESC", tooltipFb = "NPC orders. Rewards can include reagents, Moxie and Knowledge." },
        { type = T.Public, key = "public", titleKey = "HUB_ORDER_TYPE_PUBLIC", titleFb = "Public",
          tooltipKey = "HUB_ORDERS_PUBLIC_DESC", tooltipFb = "Orders any crafter can fill. The customer supplies most reagents." },
        { type = T.Personal, key = "personal", titleKey = "HUB_ORDER_TYPE_PERSONAL", titleFb = "Personal",
          tooltipKey = "HUB_ORDERS_PERSONAL_DESC", tooltipFb = "Orders placed for you by name." },
        { type = T.Guild, key = "guild", titleKey = "HUB_ORDER_TYPE_GUILD", titleFb = "Guild",
          tooltipKey = "HUB_ORDERS_GUILD_DESC", tooltipFb = "Orders from your guild members." },
    }
    return SECTION_DEFS
end

local function NetDesc(a, b)
    return (a.net or 0) > (b.net or 0)
end

local rowsByKey = {}

local function RefreshOnClick()
    local svc = Svc()
    if svc and svc.RequestAll then
        svc:RequestAll(true)
    end
    H.Refresh("orders")
end

local function RefreshOnEnter(btn)
    GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
    GameTooltip:SetText(SafeL("HUB_ORDERS_REFRESH", "Refresh"), 1, 1, 1)
    GameTooltip:AddLine(LastScanText(), 0.85, 0.85, 0.85, true)
    GameTooltip:AddLine(SafeL("HUB_ORDERS_REFRESH_TT", "Re-reads orders while the orders window is open."),
        0.85, 0.85, 0.85, true)
    GameTooltip:Show()
end

---@param parent Frame main-window scrollChild
---@return number contentHeight
function ArtisanNexus:DrawOrdersTab(parent)
    local mf = body:Begin(parent)

    -- Fixed header: WN title card + title toolbar (sort dropdown right-most, Refresh and the profession
    -- filter chained to its left).
    local chrome = ns.UI_BeginTabChromeLayout and ns.UI_BeginTabChromeLayout(mf)
    if chrome then
        local titleCard = select(1, ns.UI_CreateStandardTabTitleCard(chrome.headerParent, {
            tabKey = "orders",
            titleText = H.AccentTitle(SafeL("HUB_TAB_ORDERS", "Crafting orders")),
            subtitleText = LastScanText(),
            showUnderline = false,
            textRightInset = H.TitleToolbarReserve({ 90, 90, 180 }),
        }))
        titleCard:Show()
        local sortBtn = ns.UI_CreateCharacterSortDropdown and ns.UI_CreateCharacterSortDropdown(titleCard,
            SORT_OPTIONS, SortTable(), function() H.Refresh("orders") end, nil)
        if sortBtn then
            ns.UI_AnchorTitleToolbarControlRight(titleCard, sortBtn)
        end
        H.LayoutToolbar(titleCard, nil, {
            H.ToolbarButton(titleCard, SafeL("HUB_ORDERS_REFRESH", "Refresh"), RefreshOnClick, nil, RefreshOnEnter),
            H.ProfessionFilterButton(titleCard, "orders"),
        }, sortBtn)
        ns.UI_CommitTabFixedHeader(mf, ns.UI_PageStack_Place(chrome, titleCard))
    end

    local svc = Svc()
    local profFilter = H.ProfessionListOpt(H.GetHubProfessionFilter())
    local defs = SectionDefs()
    local total = 0
    for i = 1, #defs do
        local def = defs[i]
        local src = svc and svc.GetEvaluatedOrders and svc:GetEvaluatedOrders(def.type) or {}
        local rows = rowsByKey[def.key] or {}
        rowsByKey[def.key] = rows
        local n = 0
        for j = 1, #src do
            local o = src[j]
            if not profFilter or not o.profession or o.profession == profFilter then
                n = n + 1
                rows[n] = o
            end
        end
        for j = n + 1, #rows do
            rows[j] = nil
        end
        table.sort(rows, NetDesc)
        total = total + n
    end

    if total == 0 then
        body:Empty("an_orders", SafeL("HUB_ORDERS_EMPTY_TITLE", "No crafting orders loaded"),
            SafeL("HUB_ORDERS_EMPTY", "Open the crafting orders window to load orders."),
            "Professions-Crafting-Orders-Icon")
        return body.y
    end

    local sortKey = SortTable().key
    ORDER_SORT.key, ORDER_SORT.asc = "net", false
    for i = 1, #SORT_OPTIONS do
        if SORT_OPTIONS[i].key == sortKey then
            ORDER_SORT.key, ORDER_SORT.asc = sortKey, SORT_OPTIONS[i].asc
        end
    end
    for i = 1, #defs do
        local def = defs[i]
        local rows = rowsByKey[def.key]
        if #rows > 0 then
            local best = rows[1].net
            local count = string.format(SafeL("HUB_ORDERS_GROUP_FMT", "%d orders · best %s"), #rows,
                best and H.Signed(best) or Ink("-", "Dim"))
            local tooltip = def.tooltipKey and SafeL(def.tooltipKey, def.tooltipFb) or nil
            if body:Section(def.key, SafeL(def.titleKey, def.titleFb), { tooltip = tooltip, count = count, gap = 8 }) then
                body:Table(def.key, ORDER_COLS, rows, OrderValue, {
                    sort = ORDER_SORT,
                    onRowEnter = OrderRowEnter, onRowClick = OrderRowClick,
                })
            end
        end
    end
    return body.y
end
