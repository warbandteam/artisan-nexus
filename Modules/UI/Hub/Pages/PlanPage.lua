--[[
    Artisan Nexus — Hub tab: Queue & Shopping (key "plan"), drawn as a Warband Nexus main-window tab.

      fixedHeader  WN title card (subtitle = queued recipes / shopping-list recipes) + title-toolbar
                   buttons, right to left: Profession filter (shared) · Finishing on/off · Alts
                   subtract/ignore · Clear list · Clear queue · Queue to shopping (the list actions only
                   while that list has entries).
      Groups       two WN collapsible headers (expand state in profile.hubPlanExpanded), each with its
                   totals on the right (Professions-tab section count font):
        1. Queue      CraftingQueueService:GetQueue() + CraftEVService:Evaluate (cost / profit of the
                      remaining crafts); right = crafted / total, remaining cost, expected profit
                      (unpriced recipes are named in the header tooltip). TableKit rows with WN
                      icon-only row buttons (Characters tab pattern): - / + (SetTarget / Add),
                      up / down (Move), remove. Row click shows the recipe on the Crafting tab
                      (ArtisanNexus:OpenCraftingRecipe).
        2. Shopping   [PlanPage_Shopping.lua] reagents still to get (Aggregate() shorts priced
                      through the order book; gatherable ones name their gathering profession and
                      open that Session Loot tab on click), then the recipes on the list; right =
                      total cost (unpriced / Acuity / alt-stock notes in the header tooltip).
      Empty        WN empty-state card when the queue and the shopping list are both empty.
    Refresh: UI_RefreshRouter.lua (CRAFT_QUEUE_UPDATED / SHOPPING_LIST_UPDATED / WN_DATA_UPDATED /
    price messages -> "plan"). Clear actions confirm through a StaticPopup (WN PlansUI Reset pattern).

    Shared helpers live on ns.HubPlan (P): Profile, Chat, SectionHeader, DrawTable, DimLine,
    PaintRowButtons, Confirm, ModifiedLink, ReleaseTable, CollectBadgeCounts. PlanPage_Shopping.lua
    (loads next) adds P.DrawShopping / P.ClearShoppingList, which DrawPlanTab calls at draw time.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local H = ns.HubUI_Internal
local C = ns.HubCrafting
assert(H and C, "Hub/Pages/CraftingPage.lua must load before Hub/Pages/PlanPage.lua")

--- Shared with PlanPage_Shopping.lua (loads next and adds DrawShopping / ClearShoppingList).
local P = {}
ns.HubPlan = P

local Factory = ns.UI.Factory
local FontManager = ns.FontManager
local TK = ns.UI_TableKit
local TABLE = ns.UI_LAYOUT.TABLE
local SafeL = H.SafeL
local RecipeIconTexture = H.RecipeIconTexture
local ItemLink = H.ItemLink
local Hex, Dim = H.Ink, H.Dim

local Money = H.Money

local TAB = "plan"
local COLLAPSE_H = H.COLLAPSE_H
--- Column widths (px) shared with PlanPage_Shopping.lua (the Hub table widths, Hub/HubTabKit.lua).
P.COL = H.COL
--- WN icon-only row buttons (CharactersUI_Row tracking / delete buttons).
P.BTN = { SIZE = 20, GAP = 4 }
local COL = P.COL
local BTN = P.BTN

local Profile = H.Profile
P.Profile = Profile

local function Chat(text)
    if ArtisanNexus and ArtisanNexus.Print then
        ArtisanNexus:Print(text)
    end
end
P.Chat = Chat

local function ProfFilter()
    local f = H.GetHubProfessionFilter()
    return (f ~= "All") and f or nil
end

local function TipOnLeave()
    GameTooltip:Hide()
end

-- ─────────────────────────────────────────────────────────────────
-- WN body helpers (frames cached here, re-parented into the scrollChild on every paint)
-- ─────────────────────────────────────────────────────────────────

local cache = { strips = {}, pools = {}, lines = {} }
P.cache = cache

--- right (optional): right inset when the left edge is indented (nested groups).
local function PlaceWide(frame, parent, side, y, height, right)
    frame:SetParent(parent)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", side, -y)
    frame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(right or side), -y)
    if height then frame:SetHeight(height) end
    frame:Show()
end

local function ExpandedState()
    local p = Profile()
    if p and type(p.hubPlanExpanded) ~= "table" then
        p.hubPlanExpanded = {}
    end
    return p and p.hubPlanExpanded or {}
end

--- Collapse state of a Companion-list block (reagent headers, ns.UI_CompanionList) in the same
--- profile table as the section headers.
function P.IsCollapsed(key)
    return ExpandedState()[key] == false
end

function P.ToggleCollapsed(key)
    local st = ExpandedState()
    st[key] = (st[key] == false)
    H.Refresh(TAB)
end

--- Companion-list frames (reagent headers / storage rows) of this tab, released by HideBody.
P.companion = ns.UI_CompanionList and ns.UI_CompanionList.NewPool()
--- Factory chrome is baked in at creation: a theme change rebuilds them on the next paint.
do
    local E = ns.Constants and ns.Constants.EVENTS
    if P.companion and E and E.THEME_CHANGED and ns.NewEventOwner then
        ns.NewEventOwner("HubPlanCompanion"):RegisterMessage(E.THEME_CHANGED, function()
            ns.UI_CompanionList.Discard(P.companion)
        end)
    end
end

local function OnSectionToggle(isExpanded, header)
    local key = header and header._anPlanKey
    if key then
        ExpandedState()[key] = isExpanded and true or false
    end
    H.Refresh(TAB)
end

local function HeaderOnEnter(header)
    if not header._anTooltip then return end
    GameTooltip:SetOwner(header, "ANCHOR_TOP")
    GameTooltip:SetText(header._anTitle or "", 1, 1, 1)
    GameTooltip:AddLine(header._anTooltip, 0.85, 0.85, 0.85, true)
    GameTooltip:Show()
end

--- WN collapsible section header at y; `right` = summary text (WN Professions section count font,
--- RIGHT -14), `tooltip` = header hover lines. Returns new y and expanded.
--- opts (one header per top item; nested data goes through ns.UI_CompanionList, never indented headers):
---   icon    category icon (file ID / path, or atlas with isAtlas); fixed per key (set on creation)
---   height  header height (WN companion reagent headers are shorter)
---   buttons, data   WN icon-only buttons on the header's right (P.PaintRowButtons defs; fn(data)),
---           the summary text moves left of them
function P.SectionHeader(parent, side, y, key, title, right, tooltip, opts)
    local st = ExpandedState()
    local expanded = st[key] ~= false
    local h = opts and opts.height or COLLAPSE_H
    local header, isNew = H.PooledHeader(cache, key, parent, title, "plan:" .. key, expanded, OnSectionToggle,
        opts and opts.icon, opts and opts.isAtlas, h ~= COLLAPSE_H and { sectionHeaderHeight = h } or nil)
    if isNew then
        header._anRight = FontManager:CreateFontString(header, FontManager:GetFontRole("mainNavTabCount"), "OVERLAY")
        header._anRight:SetJustifyH("RIGHT")
        header._anRight:SetPoint("RIGHT", header, "RIGHT", -14, 0)
        header:HookScript("OnEnter", HeaderOnEnter)
        header:HookScript("OnLeave", TipOnLeave)
    end
    header._anPlanKey = key
    header._anTitle, header._anTooltip = title, tooltip
    PlaceWide(header, parent, side, y, h, side)
    local rt = header._anRight
    local buttons = opts and opts.buttons
    header._anData = opts and opts.data
    local width = opts and opts.width
    if buttons and width then
        P.PaintRowButtons(header, buttons, width - 10)
    elseif header._anBtns then
        for i = 1, #header._anBtns do header._anBtns[i]:Hide() end
    end
    rt:ClearAllPoints()
    rt:SetPoint("RIGHT", header, "RIGHT", -14 - ((buttons and width) and (P.ButtonsWidth(#buttons) + 4) or 0), 0)
    rt:SetText(right or "")
    ns.UI_SetTextColorRole(rt, "Muted")
    rt:Show()
    return y + h, expanded
end

--- One dim line (empty state / footer) at y (LedgerPage.lua DimLine); returns new y.
function P.DimLine(parent, side, y, key, text)
    local holder = cache.lines[key]
    if not holder then
        holder = Factory:CreateContainer(parent, 1, 20, false)
        holder._fs = FontManager:CreateFontString(holder, "body", "OVERLAY")
        holder._fs:SetPoint("TOPLEFT", holder, "TOPLEFT", 12, -6)
        holder._fs:SetPoint("TOPRIGHT", holder, "TOPRIGHT", -12, -6)
        holder._fs:SetJustifyH("LEFT")
        holder._fs:SetWordWrap(true)
        cache.lines[key] = holder
    end
    holder._fs:SetText(text or "")
    ns.UI_SetTextColorRole(holder._fs, "Dim")
    local h = math.max(28, (holder._fs:GetStringHeight() or 14) + 12)
    PlaceWide(holder, parent, side, y, h)
    return y + h
end

local function RowOnMouseUp(row, button)
    local t = row._anPlanTbl
    if t and t.onRowClick then t.onRowClick(row, row._anData, button) end
end

local function RowOnEnter(row)
    local t = row._anPlanTbl
    if t and t.onRowEnter then
        t.onRowEnter(row, row._anData)
    elseif t then
        H.ShowTruncatedCells(row, t.n)
    end
end

--- WN TableKit rows at y (no column strip: the header card is followed directly by the groups);
--- returns new y and the row count. opts: onRowClick, onRowEnter, rowButtons (defs for P.PaintRowButtons),
--- rowHeight (pool row height on first use).
function P.DrawTable(parent, side, y, width, key, cols, rows, opts)
    opts = opts or {}
    local strip = cache.strips[key]
    if not strip then
        strip = TK.CreateHeaderStrip(parent, { mode = "text", bottomRule = true })
        strip._widths, strip._offsets = {}, {}
        cache.strips[key] = strip
        cache.pools[key] = TK.CreateRowPool(opts.rowHeight or TABLE.ROW_H.standard)
    end
    local pool = cache.pools[key]
    local n = #cols
    opts.n = n
    TK.ResolveWidths(cols, width, strip._widths, strip._offsets)
    strip:Hide()
    local rh = pool.height
    local last = strip._offsets[n] + strip._widths[n]
    cache.culls = cache.culls or {}
    cache.culls[key] = cache.culls[key] or {}
    local cull = H.CullBegin(cache.culls[key], parent)
    for i = 1, #rows do
        local row = TK.AcquireRow(pool, parent, i, width, rh)
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", side, -y)
        H.CullAdd(cull, row, y, rh)
        row._anData, row._anPlanTbl = rows[i], opts
        if not row._anPlanWired then
            row._anPlanWired = true
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnMouseUp", RowOnMouseUp)
            row:SetScript("OnEnter", RowOnEnter)
            row:SetScript("OnLeave", TipOnLeave)
        end
        TK.PaintRowCells(row, cols, strip._widths, strip._offsets, n, rows[i], opts.valueFn)
        P.PaintRowButtons(row, opts.rowButtons, last - 4)
        y = y + rh
    end
    TK.ReleaseRowsFrom(pool, #rows + 1)
    H.CullCommit(cull)
    return y
end

function P.ReleaseTable(key)
    local strip = cache.strips[key]
    if strip then
        strip:Hide()
        TK.ReleaseRowsFrom(cache.pools[key], 1)
    end
    local cull = cache.culls and cache.culls[key]
    if cull then
        cull.n = 0
    end
end

-- ─────────────────────────────────────────────────────────────────
-- WN icon-only row buttons (CharactersUI_Row: Factory:CreateButton + ApplyIconOnlyButtonChrome)
-- ─────────────────────────────────────────────────────────────────

local function RowButtonOnClick(b)
    local def, row = b._anDef, b:GetParent()
    if def and def.fn and row and row._anData then
        def.fn(row._anData)
    end
end

local function RowButtonOnEnter(b)
    local def = b._anDef
    if def and def.tt then
        GameTooltip:SetOwner(b, "ANCHOR_TOP")
        GameTooltip:SetText(SafeL(def.ttKey, def.tt), 1, 1, 1)
        GameTooltip:Show()
    end
end

--- def.icon: IconRegistry key ("plus", "minus"), def.atlas (WN reorder arrows) or def.file
--- (WN delete glyph, tinted red like CharactersUI_Row StyleCharacterDeleteIcon).
local function ApplyRowButtonIcon(tex, def)
    tex:SetTexCoord(0, 1, 0, 1)
    if def.icon and ns.UI_SetIcon then
        ns.UI_SetIcon(tex, def.icon)
    elseif def.atlas then
        tex:SetAtlas(def.atlas)
        tex:SetVertexColor(1, 1, 1, 1)
    elseif def.file then
        tex:SetTexture(def.file)
        if def.danger then
            tex:SetVertexColor(0.95, 0.35, 0.35, 0.98)
        else
            tex:SetVertexColor(1, 1, 1, 1)
        end
    end
end

--- Row buttons laid out right to left, ending at `right` (x from the row's left edge). Pooled on the
--- row (rows are pooled per table, so every row of a table carries the same set).
function P.PaintRowButtons(row, defs, right)
    local btns = row._anBtns
    defs = defs or {}
    if not btns then
        if #defs == 0 then return end
        btns = {}
        row._anBtns = btns
    end
    local x = right
    for i = 1, #defs do
        local def = defs[i]
        local b = btns[i]
        if not b then
            b = Factory:CreateButton(row, BTN.SIZE, BTN.SIZE, true)
            if Factory.ApplyIconOnlyButtonChrome then Factory:ApplyIconOnlyButtonChrome(b) end
            b.isPersistentRowElement = true
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetAllPoints()
            b:RegisterForClicks("LeftButtonUp")
            b:SetScript("OnClick", RowButtonOnClick)
            b:SetScript("OnEnter", RowButtonOnEnter)
            b:SetScript("OnLeave", TipOnLeave)
            btns[i] = b
        end
        b._anDef = def
        ApplyRowButtonIcon(b.icon, def)
        b:ClearAllPoints()
        b:SetPoint("RIGHT", row, "LEFT", x, 0)
        b:Show()
        x = x - BTN.SIZE - BTN.GAP
    end
    for i = #defs + 1, #btns do
        btns[i]:Hide()
    end
end

function P.ButtonsWidth(count)
    return count * BTN.SIZE + (count - 1) * BTN.GAP + 8
end

--- WN StaticPopup confirm (PlansUI Reset pattern).
function P.Confirm(which, text, onAccept)
    StaticPopupDialogs[which] = {
        text = text,
        button1 = YES,
        button2 = CANCEL or NO,
        OnAccept = onAccept,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopup_Show(which)
end

function P.ModifiedLink(link)
    return link and IsModifiedClick() and HandleModifiedItemClick(link)
end
local ModifiedLink = P.ModifiedLink

-- ─────────────────────────────────────────────────────────────────
-- Queue
-- ─────────────────────────────────────────────────────────────────

--- Per-craft EV: reagentCost, profit (nil when unpriced), incomplete flag.
local function QueueEV(spellID)
    local evSvc = ns.CraftEVService
    if not (evSvc and evSvc.Evaluate) then
        return nil, nil, true
    end
    local ev = evSvc:Evaluate(spellID, { useAverage = true, knownBy = H.HubKnownBy() })
    local base = ev and ev.bestNoConc
    if not base then
        return nil, nil, true
    end
    return tonumber(base.reagentCost), tonumber(base.profit), (#(ev.missing or {}) > 0)
end

local function QueueSvc()
    return ns.CraftingQueueService
end

--- Right to left: remove, down, up, +, -. "-" lowers the target by one (SetTarget); at or below
--- the crafts already done the entry is removed instead.
local QUEUE_BTNS = {
    { file = "Interface\\Buttons\\UI-GroupLoot-Pass-Up", danger = true, ttKey = "HUB_QUEUE_TT_REMOVE", tt = "Remove from queue",
      fn = function(d) local s = QueueSvc(); if s then s:Remove(d.spellID) end end },
    { atlas = "housing-floor-arrow-down-default", ttKey = "HUB_QUEUE_TT_DOWN", tt = "Move down",
      fn = function(d) local s = QueueSvc(); if s then s:Move(d.spellID, 1) end end },
    { atlas = "housing-floor-arrow-up-default", ttKey = "HUB_QUEUE_TT_UP", tt = "Move up",
      fn = function(d) local s = QueueSvc(); if s then s:Move(d.spellID, -1) end end },
    { icon = "plus", ttKey = "HUB_QUEUE_TT_ADD", tt = "Queue one more craft",
      fn = function(d) local s = QueueSvc(); if s then s:Add(d.spellID, 1) end end },
    { icon = "minus", ttKey = "HUB_QUEUE_TT_SUB", tt = "Queue one craft less",
      fn = function(d)
          local s = QueueSvc()
          if not s then return end
          if (d.target or 1) - 1 <= (d.progress or 0) then
              s:Remove(d.spellID)
          else
              s:SetTarget(d.spellID, d.target - 1)
          end
      end },
}

local QCOLS

local function QueueColumns()
    if not QCOLS then
        QCOLS = {
            H.IconColumn(),
            { key = "name", label = SafeL("HUB_COL_RECIPE", "Recipe"), flex = 1, min = COL.NAME_MIN },
            { key = "progress", label = SafeL("HUB_COL_PROGRESS", "Progress"), width = 72, align = "RIGHT" },
            { key = "cost", label = SafeL("HUB_COL_COST_REMAINING", "Cost (remaining)"), width = COL.MONEY_WIDE, align = "RIGHT" },
            { key = "profit", label = SafeL("HUB_COL_EXPECTED_PROFIT", "Expected profit"), width = COL.MONEY_WIDE, align = "RIGHT" },
            { key = "actions", label = "", width = P.ButtonsWidth(#QUEUE_BTNS) },
        }
    end
    return QCOLS
end

local function QueueValue(col, d)
    local k = col.key
    if k == "icon" then
        return d.icon
    elseif k == "name" then
        return d.name, "Normal"
    elseif k == "progress" then
        local txt = string.format("%d/%d", d.progress or 0, d.target or 0)
        return Hex(txt, ((d.progress or 0) >= (d.target or 0)) and "success" or "warning")
    elseif k == "cost" then
        if not d.cost then
            return Dim("-")
        end
        return Money(d.cost, "0") .. (d.incomplete and (" " .. Dim("?")) or "")
    elseif k == "profit" then
        if d.profit then
            return H.Signed(d.profit)
        end
        return Dim((d.remaining or 0) > 0 and SafeL("HUB_NO_DATA", "no data") or "-")
    end
    return ""
end

local function QueueRowClick(row, d, button)
    if button ~= "LeftButton" or not d then
        return
    end
    if IsModifiedClick() then
        local link
        if d.outID then
            link = ItemLink(d.outID)
        elseif d.spellID then
            link = C_Spell.GetSpellLink(d.spellID)
        end
        if ModifiedLink(link) then
            return
        end
    end
    ArtisanNexus:OpenCraftingRecipe(d.spellID)
end

local function QueueRowEnter(row, d)
    if not d then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(d.name, 1, 1, 1)
    if d.perCost or d.perProfit then
        GameTooltip:AddDoubleLine(SafeL("HUB_TT_PER_CRAFT_COST", "Reagent cost per craft"), Money(d.perCost, nil, true), 0.75, 0.75, 0.75, 1, 1, 1)
        GameTooltip:AddDoubleLine(SafeL("HUB_TT_PER_CRAFT_PROFIT", "Expected profit per craft"), H.Signed(d.perProfit, true), 0.75, 0.75, 0.75, 1, 1, 1)
        if d.incomplete then
            GameTooltip:AddLine(SafeL("HUB_TT_MISSING_SOME", "Some reagents have no price."), 1, 0.5, 0.3)
        end
        GameTooltip:AddLine(" ")
    end
    GameTooltip:AddLine(SafeL("HUB_OV_TT_CLICK_CRAFTING", "Click: show in the Crafting tab"), 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

--- Add every queued recipe's remaining crafts to the shopping list (AddMany takes one count for
--- all ids, so entries are grouped by remaining count).
local function AddQueueToShopping()
    local qs, shop = ns.CraftingQueueService, ns.ShoppingListService
    if not (qs and qs.GetQueue and shop) then
        return
    end
    local byCount, recipes, crafts = {}, 0, 0
    local q = qs:GetQueue()
    for i = 1, #q do
        local e = q[i]
        local n = e.remaining or math.max(0, (e.target or 1) - (e.progress or 0))
        if n > 0 and e.spellID then
            byCount[n] = byCount[n] or {}
            local list = byCount[n]
            list[#list + 1] = e.spellID
            recipes = recipes + 1
            crafts = crafts + n
        end
    end
    if recipes == 0 then
        Chat(SafeL("HUB_QUEUE_TO_SHOP_NONE", "Nothing left to craft in the queue."))
        return
    end
    for n, ids in pairs(byCount) do
        if shop.AddMany then
            shop:AddMany(ids, n)
        else
            for j = 1, #ids do shop:Add(ids[j], n) end
        end
    end
    Chat(string.format(SafeL("HUB_QUEUE_TO_SHOP_DONE_FMT", "Added %d recipes (%d crafts) to the shopping list."), recipes, crafts))
end

local function ClearQueue()
    local svc = QueueSvc()
    local n = svc and #svc:GetQueue() or 0
    if n == 0 or not svc.Clear then return end
    P.Confirm("ARTISANNEXUS_CLEAR_QUEUE",
        string.format(SafeL("HUB_CLEAR_QUEUE_CONFIRM", "Remove all %d recipes from the crafting queue?"), n),
        function()
            svc:Clear()
            Chat(SafeL("HUB_CLEAR_QUEUE_DONE", "Crafting queue cleared."))
        end)
end

local queueRows = {}
local EMPTY_SUM = { recipes = 0, completed = 0, total = 0, remaining = 0 }

local function QueueSummary(svc)
    return svc and svc.GetSummary and svc:GetSummary() or EMPTY_SUM
end

--- Header right: "3 / 10 crafted · 1.2k cost · +340 profit" (profit of the priced recipes).
local function QueueHeaderText(sum, cost, profit)
    return string.format(SafeL("HUB_QUEUE_HEADER_FMT", "%d / %d crafted · %s cost · %s profit"),
        sum.completed, sum.total, Money(cost, "0"), profit and H.Signed(profit) or Dim("-"))
end

local function DrawQueue(parent, side, y, width, queue, sum)
    local rs = ns.RecipeService
    local totalCost, totalProfit, unpriced = 0, 0, 0
    for i = 1, #queue do
        local e = queue[i]
        local d = queueRows[i] or {}
        queueRows[i] = d
        local outID = rs and rs:GetOutputItem(e.spellID) or nil
        local perCost, perProfit, incomplete = QueueEV(e.spellID)
        local remaining = e.remaining or math.max(0, (e.target or 1) - (e.progress or 0))
        d.spellID, d.outID = e.spellID, outID
        d.icon = RecipeIconTexture(e.spellID, outID)
        d.name = (rs and rs:GetRecipeName(e.spellID)) or H.RecipeFallbackName(e.spellID)
        d.progress, d.target, d.remaining = e.progress or 0, e.target or 1, remaining
        d.perCost, d.perProfit, d.incomplete = perCost, perProfit, incomplete
        d.cost = (remaining > 0 and perCost) and perCost * remaining or nil
        d.profit = (remaining > 0 and perProfit and not incomplete) and perProfit * remaining or nil
        if d.cost then totalCost = totalCost + d.cost end
        if d.profit then
            totalProfit = totalProfit + d.profit
        elseif remaining > 0 then
            unpriced = unpriced + 1
        end
    end
    for i = #queue + 1, #queueRows do
        queueRows[i] = nil
    end
    local right, tip
    if #queue > 0 then
        right = QueueHeaderText(sum, totalCost, (unpriced < #queue) and totalProfit or nil)
        tip = string.format(SafeL("HUB_STATUS_QUEUE_FMT", "%d recipes - %d / %d crafted (%d remaining)"),
            sum.recipes, sum.completed, sum.total, sum.remaining)
        if unpriced > 0 then
            tip = tip .. "\n" .. string.format(SafeL("HUB_QUEUE_UNPRICED_FMT", "(%d without price)"), unpriced)
        end
    end
    local expanded
    y, expanded = P.SectionHeader(parent, side, y, "queue", SafeL("HUB_PLAN_QUEUE_TITLE", "Crafting queue"), right, tip)
    if not expanded then
        P.ReleaseTable("queue")
        return y
    end
    if #queue == 0 then
        P.ReleaseTable("queue")
        return P.DimLine(parent, side, y, "queueEmpty", SafeL("HUB_QUEUE_EMPTY", "Nothing queued."))
    end
    return P.DrawTable(parent, side, y, width, "queue", QueueColumns(), queueRows, {
        valueFn = QueueValue, onRowClick = QueueRowClick, onRowEnter = QueueRowEnter, rowButtons = QUEUE_BTNS,
    })
end

--- Rail count badge of this tab (queued recipes); read by the main window's UpdateTabCountBadges.
function P.CollectBadgeCounts(counts)
    local svc = QueueSvc()
    local q = svc and svc.GetQueue and svc:GetQueue()
    local n = type(q) == "table" and #q or 0
    if n > 0 then
        counts.plan = n
    end
end

-- ─────────────────────────────────────────────────────────────────
-- Tab
-- ─────────────────────────────────────────────────────────────────

local function HideBody()
    if P.companion then ns.UI_CompanionList.Begin(P.companion) end
    H.HeaderPassBegin(cache)
    for key in pairs(cache.strips) do P.ReleaseTable(key) end
    for _, line in pairs(cache.lines) do line:Hide() end
end

--- Profile boolean toggle; Aggregate output depends on both flags, so the shopping list
--- re-broadcasts (which also repaints this tab).
local function ToggleFlag(field)
    return function()
        local p = Profile()
        if not p then return end
        p[field] = not p[field]
        local svc = ns.ShoppingListService
        if svc and svc.Notify then svc:Notify() else H.Refresh(TAB) end
    end
end

local function FlagOn(field)
    local p = Profile()
    return p and p[field] == true
end

---@param parent Frame main-window scrollChild
---@return number contentHeight
function ArtisanNexus:DrawPlanTab(parent)
    local mf = self.UI and self.UI.mainFrame
    H.state.frame = mf
    local metrics = ns.UI_GetMainTabLayoutMetrics and ns.UI_GetMainTabLayoutMetrics(mf)
    local side = metrics and metrics.sideMargin or 12
    local width = ((metrics and metrics.contentWidth) or (parent:GetWidth() or 600)) - side * 2
    local sectionGap = math.max((ns.UI_LAYOUT.PAGE_STACK and ns.UI_LAYOUT.PAGE_STACK.SECTION_GAP) or 12, H.SECTION_GAP)

    local qs, shop = QueueSvc(), ns.ShoppingListService
    local profOpt = ProfFilter()
    local queue = qs and qs.GetQueue and qs:GetQueue() or {}
    local entries = shop and shop.GetEntries and shop:GetEntries() or {}
    if profOpt and ns.RecipeService then
        local filtered = {}
        for i = 1, #entries do
            if ns.RecipeService:GetProfession(entries[i].spellID) == profOpt then
                filtered[#filtered + 1] = entries[i]
            end
        end
        entries = filtered
    end
    local sum = QueueSummary(qs)
    local allEntries = shop and shop.GetEntries and shop:GetEntries() or {}

    -- Fixed header: WN title card + toolbar (profession filter, finishing, alts, list actions).
    local chrome = ns.UI_BeginTabChromeLayout and ns.UI_BeginTabChromeLayout(mf)
    if chrome then
        local titleCard, _, textContainer = ns.UI_CreateStandardTabTitleCard(chrome.headerParent, {
            tabKey = TAB,
            titleText = H.AccentTitle(SafeL("HUB_PAGE_PLAN", "Queue & Shopping")),
            subtitleText = (#queue + #allEntries > 0) and string.format(SafeL("HUB_PLAN_SUB_FMT",
                "%d queued · %d on the shopping list"), #queue, #allEntries) or "",
            showUnderline = false,
        })
        titleCard:Show()
        local buttons = {
            H.ProfessionFilterButton(titleCard, TAB),
            H.ToolbarButton(titleCard,
                FlagOn("shoppingIncludeFinishing") and SafeL("HUB_FINISHING_ON", "Finishing: on") or SafeL("HUB_FINISHING_OFF", "Finishing: off"),
                ToggleFlag("shoppingIncludeFinishing"),
                SafeL("HUB_FINISHING_TT", "Also counts finishing reagents, one per craft.")),
            H.ToolbarButton(titleCard,
                FlagOn("shoppingSubtractAlts") and SafeL("HUB_ALTS_SUBTRACT_ON", "Alts: subtract") or SafeL("HUB_ALTS_SUBTRACT_OFF", "Alts: ignore"),
                ToggleFlag("shoppingSubtractAlts"),
                SafeL("HUB_ALTS_SUBTRACT_TT", "Subtracts reagents your alts hold (Warband Nexus).")),
        }
        if #allEntries > 0 then
            buttons[#buttons + 1] = H.ToolbarButton(titleCard, SafeL("HUB_CLEAR_SHOP_BTN", "Clear list"), P.ClearShoppingList)
        end
        if #queue > 0 then
            buttons[#buttons + 1] = H.ToolbarButton(titleCard, SafeL("HUB_CLEAR_QUEUE_BTN", "Clear queue"), ClearQueue)
            buttons[#buttons + 1] = H.ToolbarButton(titleCard, SafeL("HUB_QUEUE_TO_SHOP_BTN", "Queue to shopping"),
                AddQueueToShopping, SafeL("HUB_QUEUE_TO_SHOP_TT", "Add the remaining queued crafts to the shopping list."))
        end
        H.LayoutToolbar(titleCard, textContainer, buttons)
        ns.UI_CommitTabFixedHeader(mf, ns.UI_PageStack_Place(chrome, titleCard))
    end

    local y = (ns.UI_GetTabScrollContentStartY and ns.UI_GetTabScrollContentStartY()) or 8
    HideBody()
    ns.UI_HideEmptyStateCard(parent, "plan_empty")
    if not (qs and shop) then
        local _, h = ns.UI_CreateEmptyStateCard(parent, "plan_empty", y, { sideInset = side, cacheKey = "plan_empty",
            atlas = "poi-workorders", titleText = SafeL("HUB_PAGE_PLAN", "Queue & Shopping"),
            descText = SafeL("HUB_PLAN_NO_SERVICE", "Queue and shopping list are not available.") })
        return y + (h or 200)
    end
    if #queue == 0 and #entries == 0 then
        local _, h = ns.UI_CreateEmptyStateCard(parent, "plan_empty", y, { sideInset = side, cacheKey = "plan_empty",
            atlas = "poi-workorders", titleText = SafeL("HUB_PLAN_EMPTY_TITLE", "Nothing planned yet"),
            descText = SafeL("HUB_PLAN_EMPTY_DESC", "Add crafts from Crafting or the Recipe Matcher.") })
        return y + (h or 200)
    end
    y = DrawQueue(parent, side, y, width, queue, sum)
    return P.DrawShopping(parent, side, y + sectionGap, width, entries, profOpt)
end
