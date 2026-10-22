--[[
    Artisan Nexus — Hub tab: Crafting (key "crafting"), drawn as a Warband Nexus main-window tab.

    "What is profitable to craft, what does each craft cost and what will it sell for?"

      fixedHeader  WN title card (subtitle = profitable / break-even / loss counts) + title-toolbar
                   buttons, right to left:
                   Profession filter (shared by every Hub tab) · Session only · Known by ·
                   Price basis · Clear link (only while a recipe is linked);
                   WN search box below (SearchStateManager "crafting"). Pattern: CurrencyUI.lua
                   DrawCurrencyTab (title card + toolbar toggle + search box in the fixedHeader).
      Body         one results container (CurrencyUI resultsContainer): search typing repaints only
                   the container (RedrawCraftingResults), every other gesture repaints the tab.
                   WN Professions layout: actionable notices (harvest progress, no AH prices) as dim
                   lines, ONE TableKit column strip ([icon] Recipe | Craft cost | Profit | Profit %),
                   then one WN collapsible header per profession (profession icon, name, profitable
                   count on the right; expand state in profile.hubCraftingExpanded) with that
                   profession's recipe rows under it. Sortable headers sort inside every group.
      Rows         hover = recipe summary + the full craft breakdown (CraftingPage_Detail.lua) ·
                   click = open the recipe in the profession window (when learned) ·
                   shift-click = link the crafted item · ctrl-click = +1 queue ·
                   alt-click = price history · right-click = +1 shopping list.
      Empty        WN empty-state cards (no recipes read / no match; search-empty card while a query
                   is active).

    ArtisanNexus:OpenCraftingRecipe(spellID) opens this tab with that recipe pinned to the top
    (its profession group first and expanded, the row first in it, name in accent ink), shown even
    when the profession / known-by / session filters would hide it (state.pinned). Leaving the tab or
    closing the window unpins it.

    This file also creates ns.HubCrafting (C): Minus / TierBadge / IconMarkup / ConfidenceLabel /
    CONF_ROLE / KnownByText / RowLink / AddToQueue / AddToShopping and C.state, used by
    CraftingPage_Detail.lua (loads next, adds AddBreakdown / OutputItem) and PlanPage.lua. Ink, money
    text, the title toolbar and the profession filter are the shared Hub kit (Hub/HubData.lua,
    Hub/HubTabKit.lua).

    Profile keys (read with code fallbacks): hubKnownBy ("me" | "any", default "any"),
    hubProfitSort ("margin" | "concentration", default "margin"; "concentration" sorts by gold per
    concentration), hubPriceBasis ("spot" | "avg",
    default "spot"), hubSessionOnly (boolean; UI_RefreshRouter repaints on SESSION_LOOT_UPDATED
    while it is on), hubProfessionFilter (shared). Session only keeps rows with
    RecipeService:MaxCraftsForCounts(spellID, GetSessionCounts(profile.lootHistoryActiveTab)) >= 1.
]]

local ADDON_NAME, ns = ...

-- 12.1.5 removed the global item APIs; bind the namespaced one.
local GetItemInfo = C_Item.GetItemInfo

local ArtisanNexus = ns.ArtisanNexus
local H = ns.HubUI_Internal
assert(H, "Hub/HubData.lua must load before Hub/Pages/CraftingPage.lua")

--- Shared with CraftingPage_Detail.lua (loads next and adds AddBreakdown / OutputItem) and PlanPage.lua.
local C = {}
ns.HubCrafting = C

local Factory = ns.UI.Factory
local FontManager = ns.FontManager
local TK = ns.UI_TableKit
local TABLE = ns.UI_LAYOUT.TABLE

local SafeL = H.SafeL
local SafeNumber = H.SafeNumber
local RecipeRowName = H.RecipeRowName
local ItemName = ns.GetItemDisplayName

local TAB = "crafting"
--- Column widths (px): name floor, money, percent.
local COL_NAME_MIN, COL_MONEY, COL_PCT = H.COL.NAME_MIN, H.COL.MONEY, H.COL.PCT
--- Profession group header height (WN SECTION_COLLAPSE_HEADER_HEIGHT) and header icon size (WN
--- Professions section icons: 24).
local GROUP_H, GROUP_ICON = 36, 24

--- Tab state (session): pinned spellID, header sort override.
C.state = { pinned = nil, sortKey = nil, sortAsc = nil }
local state = C.state

-- ─────────────────────────────────────────────────────────────────
-- WN ink (semantic theme colors) and formatting helpers
-- ─────────────────────────────────────────────────────────────────

local Profile = H.Profile
local Hex, Dim, Money, Signed = H.Ink, H.Dim, H.Money, H.Signed

--- A deduction ("-1g 20s"); 0 / nil shows a plain zero.
function C.Minus(copper)
    local v = math.floor((SafeNumber(copper) or 0) + 0.5)
    if v <= 0 then
        return Money(0)
    end
    return "-" .. Money(v)
end

function C.IconMarkup(fileID, size)
    if not fileID then
        return ""
    end
    size = size or 16
    return "|T" .. tostring(fileID) .. ":" .. size .. ":" .. size .. ":0:0:64:64:5:59:5:59|t"
end

local badgeCache = {}

--- Midnight crafting quality badge (ProfessionQualityAtlas.lua lists); "Q<n>" when no atlas resolves.
function C.TierBadge(tier, size)
    tier = SafeNumber(tier)
    if not tier or tier < 1 then
        return ""
    end
    size = size or 14
    local key = tier * 1000 + size
    local s = badgeCache[key]
    if s then
        return s
    end
    local list = (tier == 1 and ns.PROFESSION_QUALITY_ATLAS_RANK1) or (tier == 2 and ns.PROFESSION_QUALITY_ATLAS_RANK2) or nil
    if list and CreateAtlasMarkup then
        for i = 1, #list do
            if TK.AtlasExists(list[i]) then
                s = CreateAtlasMarkup(list[i], size, size)
                break
            end
        end
    end
    s = s or Dim("Q" .. tostring(tier))
    badgeCache[key] = s
    return s
end

C.CONF_ROLE = { high = "success", medium = "warning", low = "danger" }

function C.ConfidenceLabel(conf)
    if conf == "high" then return SafeL("HUB_CONFIDENCE_HIGH", "high") end
    if conf == "medium" then return SafeL("HUB_CONFIDENCE_MEDIUM", "medium") end
    return SafeL("HUB_CONFIDENCE_LOW", "low")
end

--- "you", "you + 2 alts", "3 alts" or nil when nothing is known about the recipe.
function C.KnownByText(r)
    local count = SafeNumber(r.knownByCount) or 0
    local alts = math.max(0, count - (r.knownByMe and 1 or 0))
    local altsTxt = string.format(SafeL("HUB_KNOWN_ALTS_FMT", "%d alts"), alts)
    if r.knownByMe then
        local me = SafeL("HUB_TT_KNOWN_ME", "you")
        return alts > 0 and (me .. " + " .. altsTxt) or me
    end
    return alts > 0 and altsTxt or nil
end

function C.RowLink(r)
    if r.outputItem then
        local _, link = GetItemInfo(r.outputItem)
        if link then
            return link
        end
    end
    if r.spellID and C_Spell and C_Spell.GetSpellLink then
        return C_Spell.GetSpellLink(r.spellID)
    end
    return nil
end

local function Print(fmtKey, fmtFb, r)
    if ArtisanNexus and ArtisanNexus.Print then
        ArtisanNexus:Print(string.format(SafeL(fmtKey, fmtFb), RecipeRowName(r)))
    end
end

function C.AddToQueue(r)
    local svc = ns.CraftingQueueService
    if r and svc and svc.Add then
        svc:Add(r.spellID, 1)
        Print("HUB_CHAT_QUEUE_ADD_FMT", "|cffd4af37+1 to queue:|r %s", r)
    end
end

function C.AddToShopping(r)
    local svc = ns.ShoppingListService
    if r and svc and svc.Add then
        svc:Add(r.spellID, 1)
        Print("HUB_CHAT_SHOP_ADD_FMT", "|cffd4af37+1 to shopping:|r %s", r)
    end
end

--- Repaint `tab` now (WN in-page gesture: UI_MAIN_REFRESH_REQUESTED, instantPopulate).
local function Refresh()
    H.Refresh(TAB)
end

local function TipOnLeave()
    GameTooltip:Hide()
end

-- ─────────────────────────────────────────────────────────────────
-- Filters
-- ─────────────────────────────────────────────────────────────────

local KnownBy = H.HubKnownBy

local function SessionOnly()
    local p = Profile()
    return p and p.hubSessionOnly == true or false
end

--- Session only: keep recipes craftable at least once from the session loot of the Session
--- Loot window's active tab (nil tab = every tab).
local function FilterSessionCraftable(rows, rs)
    local p = Profile()
    local tab = p and p.lootHistoryActiveTab
    if tab == "" then
        tab = nil
    end
    local counts = rs:GetSessionCounts(tab)
    local out = {}
    for i = 1, #rows do
        local r = rows[i]
        if rs:MaxCraftsForCounts(r.spellID, counts) >= 1 then
            out[#out + 1] = r
        end
    end
    return out
end

local function PriceBasis()
    local p = Profile()
    return (p and p.hubPriceBasis == "avg") and "avg" or "spot"
end

--- Default sort (profile.hubProfitSort), set by clicking the Profit / Gold per conc headers.
local function SortMode()
    local p = Profile()
    return (p and p.hubProfitSort == "concentration") and "concentration" or "margin"
end

--- Unpriced reagents count as 0 cost: such a margin would be a fake profit, so it is "no data".
local function ProfitOf(r)
    if (SafeNumber(r.missingReagentPrices) or 0) > 0 then
        return nil
    end
    local cost = SafeNumber(r.cost)
    if not cost or cost <= 0 then
        return nil
    end
    return SafeNumber(r.margin)
end

local function Query()
    local ssm = ns.SearchStateManager
    return ssm and ssm:GetQuery(TAB) or ""
end

-- ─────────────────────────────────────────────────────────────────
-- Columns + sorting
-- ─────────────────────────────────────────────────────────────────

local COLS

local function Columns()
    if not COLS then
        COLS = {
            H.IconColumn(),
            { key = "recipe", label = SafeL("HUB_COL_RECIPE", "Recipe"), flex = 1, min = COL_NAME_MIN, sortable = true },
            { key = "cost", label = SafeL("HUB_CRAFT_COL_COST", "Craft cost"), width = COL_MONEY, align = "RIGHT",
                sortable = true },
            { key = "profit", label = SafeL("HUB_COL_PROFIT", "Profit"), width = COL_MONEY, align = "RIGHT",
                sortable = true },
            { key = "pct", label = SafeL("HUB_CRAFT_COL_PROFIT_PCT", "Profit %"), width = COL_PCT, align = "RIGHT",
                sortable = true },
        }
    end
    return COLS
end

--- Columns whose first click sorts high -> low.
local DESC_FIRST = { profit = true, pct = true }

local SORT_KEY, SORT_ASC = "profit", false

local function SortValue(r, key)
    if key == "recipe" then
        return tostring(r.name or "")
    elseif key == "cost" then
        return SafeNumber(r.cost)
    elseif key == "profit" then
        return ProfitOf(r)
    elseif key == "pct" then
        return ProfitOf(r) and SafeNumber(r.marginPct) or nil
    elseif key == "gpc" then
        return SafeNumber(r.goldPerConcentration)
    end
    return nil
end

--- nil values always sort last; ties fall back to the recipe name.
local function Compare(a, b)
    local va, vb = SortValue(a, SORT_KEY), SortValue(b, SORT_KEY)
    if va ~= nil and vb == nil then return true end
    if va == nil and vb ~= nil then return false end
    if va ~= nil and va ~= vb then
        if SORT_ASC then return va < vb end
        return va > vb
    end
    return tostring(a.name or "") < tostring(b.name or "")
end

local function ResolveSort()
    if state.sortKey then
        return state.sortKey, state.sortAsc == true
    end
    if SortMode() == "concentration" then
        return "gpc", false
    end
    return "profit", false
end

local function OnSortClick(key, ascending)
    if state.sortKey ~= key and DESC_FIRST[key] then
        ascending = false
    end
    state.sortKey, state.sortAsc = key, ascending
    -- Profit also becomes the default sort of the next session.
    local p = Profile()
    if p and key == "profit" then
        p.hubProfitSort = "margin"
    end
    Refresh()
end
C.OnSortClick = OnSortClick

-- ─────────────────────────────────────────────────────────────────
-- Cells
-- ─────────────────────────────────────────────────────────────────

--- Plain recipe name; the pinned (linked) recipe is drawn in accent ink. Tier, known-by and price
--- markers live in the row tooltip.
--- Name ink by craft status: red = not learned here, gold = learned but short of reagents
--- (bags + bank + warband bank), green = craftable now.
local STATUS_INK = { unlearned = "danger", short = "gold", craftable = "success" }

function C.CraftStatus(r)
    local rs = ns.RecipeService
    if not (rs and rs.GetCraftStatus and r.spellID) then return nil, 0 end
    return rs:GetCraftStatus(r.spellID, r.knownByMe == true)
end

local function RecipeCell(r)
    local name = RecipeRowName(r)
    if r._anPinned then
        return Hex(name, "accent")
    end
    local status = C.CraftStatus(r)
    local ink = status and STATUS_INK[status]
    return ink and Hex(name, ink) or name
end

local function CellValue(col, r)
    local k = col.key
    if k == "icon" then
        return H.RecipeIconTexture(r.spellID, r.outputItem)
    elseif k == "recipe" then
        return RecipeCell(r), "Bright"
    elseif k == "cost" then
        return r.cost and Money(r.cost) or Dim("-"), "Normal"
    elseif k == "profit" then
        local m = ProfitOf(r)
        if not m then
            return Dim(SafeL("HUB_NO_DATA", "no data")), "Normal"
        end
        return Signed(m), "Normal"
    end
    local pct = ProfitOf(r) and SafeNumber(r.marginPct)
    if not pct then
        return Dim("-"), "Normal"
    end
    return Hex(string.format("%+d%%", math.floor(pct + 0.5)), pct >= 0 and "success" or "danger"), "Normal"
end

-- ─────────────────────────────────────────────────────────────────
-- Row handlers (shared; read row._anData)
-- ─────────────────────────────────────────────────────────────────

local function EvalOpts()
    return { useAverage = PriceBasis() == "avg", knownBy = KnownBy() }
end

--- verified 2026-10-15, TradeSkillUIDocumentation 12.1.5.70391 + Blizzard_ProfessionsRecipeTracker.lua
--- (IsRecipeProfessionLearned guard before OpenRecipe).
local function CanOpenRecipe(r)
    if not (r.knownByMe and C_TradeSkillUI and C_TradeSkillUI.IsRecipeProfessionLearned and C_TradeSkillUI.OpenRecipe) then
        return false
    end
    local ok, v = pcall(C_TradeSkillUI.IsRecipeProfessionLearned, r.spellID)
    return ok and v == true
end

local function RowOnMouseUp(row, button)
    local r = row._anData
    if not r then return end
    if button == "RightButton" then
        C.AddToShopping(r)
        return
    end
    if button ~= "LeftButton" then return end
    if IsShiftKeyDown() then
        local link = C.RowLink(r)
        if link and HandleModifiedItemClick(link) then
            return
        end
    elseif IsControlKeyDown() then
        C.AddToQueue(r)
    elseif IsAltKeyDown() then
        local ui = ns.PriceHistoryUI
        local itemID = C.OutputItem(r, EvalOpts())
        if ui and itemID then
            ui:ShowPopup(itemID, row, "TOPLEFT", "BOTTOMLEFT", 0, -4)
        end
    elseif CanOpenRecipe(r) and not InCombatLockdown() then
        C_TradeSkillUI.OpenRecipe(r.spellID)
    end
end

local function Hint(text)
    GameTooltip:AddLine(text, 0.7, 0.7, 0.7)
end

local function RowOnEnter(row)
    local r = row._anData
    if not r then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local title = RecipeRowName(r)
    if r.qualityTier then
        title = title .. " " .. C.TierBadge(r.qualityTier, 14)
    end
    GameTooltip:AddLine(title, 1, 1, 1)
    if not IsShiftKeyDown() then
        -- Short view: what a crafter decides on. The full breakdown is one Shift away.
        if r.knownByMe == false then
            GameTooltip:AddLine(SafeL("HUB_TT_NOT_LEARNED", "Not learned on this character"), 1, 0.4, 0.4)
        end
        if r.fresh == false and r.outputItem then
            GameTooltip:AddLine(SafeL("HUB_TT_STALE_NOTE", "Price is older than the freshness window."), 1, 0.5, 0.3)
        end
        if C.AddSummary then
            C.AddSummary(GameTooltip, r, EvalOpts())
        end
        GameTooltip:AddLine(" ")
        Hint(SafeL("HUB_TT_SHIFT_DETAILS", "Shift: full breakdown"))
        Hint(SafeL("HUB_CRAFT_TT_HINTS_SHORT", "Click: open  ·  Ctrl: queue  ·  Right-click: shopping list"))
        GameTooltip:Show()
        H.WatchShift(row, RowOnEnter)
        return
    end
    if r.outputItem then
        GameTooltip:AddLine(string.format(SafeL("HUB_TT_ITEM_FMT", "Item: %s"), ItemName(r.outputItem)), 0.7, 0.7, 0.7)
    end
    local who = C.KnownByText(r)
    if who then
        GameTooltip:AddLine(SafeL("HUB_TT_KNOWN_BY", "Known by") .. ": " .. who, 0.7, 0.7, 0.7)
    end
    if r.hasHistory then
        Hint(SafeL("HUB_TT_AVG_NOTE", "Value uses the 7-day price average."))
    end
    if r.fresh == false and r.outputItem then
        GameTooltip:AddLine(SafeL("HUB_TT_STALE_NOTE", "Price is older than the freshness window."), 1, 0.5, 0.3)
    end
    C.AddBreakdown(GameTooltip, r, EvalOpts())
    C.AddStock(GameTooltip, r)
    GameTooltip:AddLine(" ")
    if CanOpenRecipe(r) then
        Hint(SafeL("HUB_CRAFT_TT_CLICK_OPEN", "Click: open the recipe"))
    end
    Hint(SafeL("HUB_CRAFT_TT_SHIFT", "Shift-click: link the crafted item"))
    Hint(SafeL("HUB_CRAFT_TT_CTRL_QUEUE", "Ctrl-click: add one craft to the queue"))
    Hint(SafeL("HUB_CRAFT_TT_ALT_HISTORY", "Alt-click: price history"))
    Hint(SafeL("HUB_TT_RIGHT_CLICK_SHOP", "Right-click: add to shopping list"))
    GameTooltip:Show()
    H.WatchShift(row, RowOnEnter)
end

-- ─────────────────────────────────────────────────────────────────
-- Data
-- ─────────────────────────────────────────────────────────────────

local function NoPrices()
    local ah = ns.AHPriceService
    local stats = ah and ah.GetCacheStats and ah:GetCacheStats()
    return stats ~= nil and (stats.total or 0) == 0
end

local function FilterByName(rows, query)
    local out = {}
    for i = 1, #rows do
        local name = RecipeRowName(rows[i]):lower()
        if name:find(query, 1, true) then
            out[#out + 1] = rows[i]
        end
    end
    return out
end

--- Linked recipe: move its row to the top, or fetch it unfiltered when the profession / known-by /
--- session filters dropped it. Returns the new row list.
local function PinLinkedRow(rows, svc, rs, useAverage)
    local id = state.pinned
    if not id then
        return rows
    end
    local pinned
    local out = {}
    for i = 1, #rows do
        local r = rows[i]
        if r.spellID == id then
            pinned = r
        else
            out[#out + 1] = r
        end
    end
    if not pinned then
        local prof = rs.GetProfession and rs:GetProfession(id)
        local all = svc:ListRecipes({ useAverage = useAverage, harvestedOnly = true, compareConcentration = true,
            knownBy = "any", profession = prof })
        for i = 1, #all do
            if all[i].spellID == id then
                pinned = all[i]
                break
            end
        end
    end
    if not pinned then
        return rows
    end
    pinned._anPinned = true
    table.insert(out, 1, pinned)
    return out
end

--- Builds the visible row list. Returns rows (nil when no recipe was read yet) and the unfiltered
--- row count of the current filters (before the name search).
local function BuildRows()
    local svc, rs = ns.ProfitabilityService, ns.RecipeService
    if not svc or not rs then
        return nil
    end
    local stats = rs.GetStats and rs:GetStats()
    if not stats or (stats.harvested or 0) == 0 then
        return nil
    end
    local useAverage = PriceBasis() == "avg"
    local opts = { useAverage = useAverage, harvestedOnly = true, compareConcentration = true, knownBy = KnownBy() }
    local prof = H.ProfessionListOpt(H.GetHubProfessionFilter())
    if prof then
        opts.profession = prof
    end
    local rows = svc:ListRecipes(opts)
    if SessionOnly() and rs.GetSessionCounts and rs.MaxCraftsForCounts then
        rows = FilterSessionCraftable(rows, rs)
    end
    local q = Query()
    if q ~= "" then
        rows = FilterByName(rows, q)
    end
    SORT_KEY, SORT_ASC = ResolveSort()
    table.sort(rows, Compare)
    return PinLinkedRow(rows, svc, rs, useAverage)
end

--- Profitable rows of a list (priced, margin > 0); the pinned row is not counted.
local function CountProfitable(rows)
    local n, total = 0, 0
    for i = 1, #rows do
        local r = rows[i]
        if not r._anPinned then
            total = total + 1
            local m = ProfitOf(r)
            if m and m > 0 then
                n = n + 1
            end
        end
    end
    return n, total
end

--- Title-card subtitle: one line, "N of M recipes profitable" (empty while there are no rows).
local function Subtitle(rows)
    if not rows or #rows == 0 then
        return ""
    end
    local n, total = CountProfitable(rows)
    return string.format(SafeL("HUB_CRAFT_SUB_FMT", "%d of %d recipes profitable"), n, total)
end

--- Rows split by profession, in display order: the pinned recipe's group first, then by name.
--- Each group keeps the sorted row order (the pinned row stays first in its group).
local groupList, groupByProf = {}, {}

local function ProfessionLabel(prof)
    return prof and (ns.GetProfessionDisplayName and ns.GetProfessionDisplayName(prof) or tostring(prof))
        or SafeL("HUB_PROF_OTHER", "Other")
end

local function GroupOrder(a, b)
    if a.pinned ~= b.pinned then
        return a.pinned
    end
    return a.label < b.label
end

local function GroupRows(rows)
    for _, g in pairs(groupByProf) do
        wipe(g.rows)
        g.pinned = false
    end
    wipe(groupList)
    for i = 1, #rows do
        local r = rows[i]
        local key = r.profession or "?"
        local g = groupByProf[key]
        if not g then
            g = { key = key, prof = r.profession, rows = {} }
            groupByProf[key] = g
        end
        if #g.rows == 0 then
            g.label = ProfessionLabel(r.profession)
            groupList[#groupList + 1] = g
        end
        g.rows[#g.rows + 1] = r
        if r._anPinned then
            g.pinned = true
        end
    end
    table.sort(groupList, GroupOrder)
    return groupList
end

-- ─────────────────────────────────────────────────────────────────
-- Body (results container; frames cached here and re-parented every paint)
-- ─────────────────────────────────────────────────────────────────

local cache = { lines = {} }
C.cache = cache

local function Results(parent)
    local rc = cache.results
    if not rc then
        rc = Factory:CreateContainer(parent, 1, 1, false)
        cache.results = rc
        cache.strip = TK.CreateHeaderStrip(rc, { mode = "text", bottomRule = true, onSortClick = OnSortClick })
        cache.pool = TK.CreateRowPool(TABLE.ROW_H.standard)
        cache.widths, cache.offsets = {}, {}
        cache.headers = {}
    end
    return rc
end

local function PlaceWide(frame, host, y, height)
    frame:SetParent(host)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -y)
    frame:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -y)
    if height then frame:SetHeight(height) end
    frame:Show()
end

--- One body line (LedgerPage.lua DimLine) at y; returns new y.
local function NoticeLine(host, y, key, text, role)
    local holder = cache.lines[key]
    if not holder then
        holder = Factory:CreateContainer(host, 1, 20, false)
        holder._fs = FontManager:CreateFontString(holder, "body", "OVERLAY")
        holder._fs:SetPoint("TOPLEFT", holder, "TOPLEFT", 12, -6)
        holder._fs:SetPoint("TOPRIGHT", holder, "TOPRIGHT", -12, -6)
        holder._fs:SetJustifyH("LEFT")
        holder._fs:SetWordWrap(true)
        cache.lines[key] = holder
    end
    holder._fs:SetText(text or "")
    ns.UI_SetTextColorRole(holder._fs, role or "Dim")
    local h = math.max(28, (holder._fs:GetStringHeight() or 14) + 12)
    PlaceWide(holder, host, y, h)
    return y + h
end

local function HideNotices()
    for _, holder in pairs(cache.lines) do
        holder:Hide()
    end
end

local EMPTY_KEYS = { "crafting_recipes", "crafting_filter" }

local function HideEmptyCards(rc)
    for i = 1, #EMPTY_KEYS do
        ns.UI_HideEmptyStateCard(rc, EMPTY_KEYS[i])
    end
    if rc["emptyStateCard_" .. (ns.UI_SEARCH_EMPTY_TAB_KEY or "search")] then
        rc["emptyStateCard_" .. (ns.UI_SEARCH_EMPTY_TAB_KEY or "search")]:Hide()
    end
end

local function EmptyCard(rc, y, key, atlas, title, desc)
    local _, h = ns.UI_CreateEmptyStateCard(rc, key, y, {
        fillParent = true, cacheKey = key, atlas = atlas, titleText = title, descText = desc,
    })
    return y + (h or 200)
end

-- ─────────────────────────────────────────────────────────────────
-- Profession groups (WN ProfessionsUI_DrawTab section headers: icon, label, right-aligned count)
-- ─────────────────────────────────────────────────────────────────

local function ExpandedState()
    local p = Profile()
    if p and type(p.hubCraftingExpanded) ~= "table" then
        p.hubCraftingExpanded = {}
    end
    return p and p.hubCraftingExpanded or {}
end

local function GroupOnToggle(isExpanded, header)
    local key = header and header._anGroupKey
    if key then
        ExpandedState()[key] = isExpanded and true or false
    end
    Refresh()
end

local function ProfessionIcon(prof)
    local icons = ns.KNOWN_PROFESSION_ICONS
    return (prof and icons and icons[prof]) or "Interface\\Icons\\Trade_Engineering"
end

local function HideHeaders()
    for _, header in pairs(cache.headers) do
        header:Hide()
    end
end

--- WN collapsible header for group `g` at y (cached per profession); returns expanded.
local function GroupHeader(rc, y, width, g)
    local expanded = g.pinned or ExpandedState()[g.key] ~= false
    local header = cache.headers[g.key]
    if not header then
        local _, _, hdrIcon
        header, _, hdrIcon = ns.UI_CreateCollapsibleHeader(rc, g.label, TAB .. ":" .. g.key, expanded, GroupOnToggle,
            ProfessionIcon(g.prof), false)
        if hdrIcon then
            hdrIcon:SetSize(GROUP_ICON, GROUP_ICON)
        end
        header._anGroupKey = g.key
        -- WN Professions count badge: mainNavTabCount font, right-aligned (ProfessionsUI_DrawTab.lua).
        header._anCount = FontManager:CreateFontString(header, FontManager:GetFontRole("mainNavTabCount"), "OVERLAY")
        header._anCount:SetJustifyH("RIGHT")
        header._anCount:SetPoint("RIGHT", header, "RIGHT", -14, 0)
        cache.headers[g.key] = header
    else
        header:SetParent(rc)
        ns.UI_RebindCollapsibleHeader(header, g.label, expanded, GroupOnToggle)
    end
    local n = CountProfitable(g.rows)
    header._anCount:SetText(string.format(SafeL("HUB_CRAFT_GROUP_COUNT_FMT", "%d profitable"), n))
    ns.UI_SetTextColorRole(header._anCount, n > 0 and "Muted" or "Dim")
    PlaceWide(header, rc, y, GROUP_H)
    return expanded
end

local function WireRow(row)
    if row._anWired then return end
    row._anWired = true
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnMouseUp", RowOnMouseUp)
    row:SetScript("OnEnter", RowOnEnter)
    row:SetScript("OnLeave", TipOnLeave)
end

--- One column strip, then each profession group: header + its rows (when expanded).
local function DrawTable(rc, y, width, rows)
    local cols = Columns()
    local n = #cols
    local strip, pool = cache.strip, cache.pool
    TK.ResolveWidths(cols, width, cache.widths, cache.offsets)
    PlaceWide(strip, rc, y)
    strip:SetWidth(width)
    strip:SetColumns(cols, cache.widths, cache.offsets, n)
    strip:SetSort(SORT_KEY, SORT_ASC)
    y = y + strip:GetStripHeight()
    local rh = pool.height
    local gap = H.SECTION_GAP or 12
    cache.cull = cache.cull or {}
    local cull = H.CullBegin(cache.cull, rc)
    local groups = GroupRows(rows)
    local ri = 0
    for gi = 1, #groups do
        local g = groups[gi]
        if gi > 1 then
            y = y + gap
        else
            y = y + 4
        end
        local expanded = GroupHeader(rc, y, width, g)
        y = y + GROUP_H
        if expanded then
            for i = 1, #g.rows do
                ri = ri + 1
                local row = TK.AcquireRow(pool, rc, ri, width, rh)
                row:SetPoint("TOPLEFT", rc, "TOPLEFT", 0, -y)
                row._anData = g.rows[i]
                WireRow(row)
                TK.PaintRowCells(row, cols, cache.widths, cache.offsets, n, g.rows[i], CellValue)
                H.CullAdd(cull, row, y, rh)
                y = y + rh
            end
        end
    end
    TK.ReleaseRowsFrom(pool, ri + 1)
    H.CullCommit(cull)
    return y
end

--- Paints the results container; returns its content height.
local function DrawResults(rc, width, rows)
    HideNotices()
    HideEmptyCards(rc)
    HideHeaders()
    cache.strip:Hide()
    TK.ReleaseRowsFrom(cache.pool, 1)
    if cache.cull then
        cache.cull.n = 0
    end
    local y = 0
    if not rows then
        return EmptyCard(rc, y, "crafting_recipes", "Professions-Icon-Accept-Order",
            SafeL("HUB_CRAFT_EMPTY_RECIPES", "No recipes read yet"),
            SafeL("HUB_CRAFT_EMPTY_RECIPES_DESC", "Open your profession window once."))
    end
    local harvest = H.HarvestNotice()
    if harvest then
        y = NoticeLine(rc, y, "harvest", harvest, "Muted")
    end
    if NoPrices() then
        y = NoticeLine(rc, y, "prices", SafeL("HUB_OV_NEED_PRICES", "Open the Auction House and press Sync AH Prices."), "Muted")
    end
    if #rows == 0 then
        local q = Query()
        if q ~= "" and ns.UI_ShowSearchEmptyStateCard then
            return ns.UI_ShowSearchEmptyStateCard(rc, q, y, { fillParent = true })
        end
        return EmptyCard(rc, y, "crafting_filter", "Professions-Icon-Accept-Order",
            SafeL("HUB_CRAFT_EMPTY_FILTER", "No recipes match these filters"),
            SafeL("HUB_CRAFT_EMPTY_FILTER_DESC", "Change the filters above or clear the search."))
    end
    return DrawTable(rc, y, width, rows)
end

local function BodyTop()
    return (ns.UI_GetTabScrollContentStartY and ns.UI_GetTabScrollContentStartY()) or 8
end

--- Search typing: repaint the results container only (CurrencyUI RedrawCurrencyResultsOnly).
local function RedrawCraftingResults()
    local mf = ArtisanNexus.UI and ArtisanNexus.UI.mainFrame
    if not mf or not mf:IsShown() or mf.currentTab ~= TAB then return end
    local scrollChild = mf.scrollChild
    local rc = cache.results
    if not scrollChild or not rc or rc:GetParent() ~= scrollChild then return end
    local width = math.max(1, rc:GetWidth() or 1)
    local h = DrawResults(rc, width, BuildRows())
    rc:SetHeight(math.max(1, h))
    if ns.UI_SyncMainTabScrollChrome then
        ns.UI_SyncMainTabScrollChrome(mf, scrollChild, h)
    end
end

local function OnSearch(text)
    local ssm = ns.SearchStateManager
    if ssm then
        ssm:SetSearchQuery(TAB, text)
    end
    RedrawCraftingResults()
end

-- ─────────────────────────────────────────────────────────────────
-- Linked recipe navigation + unpin on leave
-- ─────────────────────────────────────────────────────────────────

local function Unpin()
    state.pinned = nil
    if ns.PriceHistoryUI and ns.PriceHistoryUI.HidePopup then
        ns.PriceHistoryUI:HidePopup()
    end
end

local hooked
local function HookLeave(mf)
    if hooked or not mf then return end
    hooked = true
    -- Any repaint of another tab (tab switch) or closing the window unpins the linked recipe.
    hooksecurefunc(ArtisanNexus, "PopulateContent", function()
        local f = ArtisanNexus.UI and ArtisanNexus.UI.mainFrame
        if f and f.currentTab ~= TAB and state.pinned then
            Unpin()
        end
    end)
    mf:HookScript("OnHide", Unpin)
end

--- Opens the Crafting tab with `spellID` pinned to the top, its profession group expanded
--- (Overview Best craft, Queue rows, other windows).
function ArtisanNexus:OpenCraftingRecipe(spellID)
    local id = SafeNumber(spellID)
    if not id then
        self:ShowMainWindow(TAB)
        return
    end
    state.pinned = id
    local mf = self.UI and self.UI.mainFrame
    if mf and mf:IsShown() and mf.currentTab == TAB then
        Refresh()
    else
        self:ShowMainWindow(TAB)
    end
end

-- ─────────────────────────────────────────────────────────────────
-- Tab
-- ─────────────────────────────────────────────────────────────────

local function ToggleProfile(field, value)
    return function()
        local p = Profile()
        if not p then return end
        p[field] = value()
        Refresh()
    end
end

---@param parent Frame main-window scrollChild
---@return number contentHeight
function ArtisanNexus:DrawCraftingTab(parent)
    local mf = self.UI and self.UI.mainFrame
    H.state.frame = mf
    HookLeave(mf)
    local metrics = ns.UI_GetMainTabLayoutMetrics and ns.UI_GetMainTabLayoutMetrics(mf)
    local side = metrics and metrics.sideMargin or 12
    local contentW = (metrics and metrics.contentWidth) or (parent:GetWidth() or 600)
    local bodyW = (metrics and metrics.bodyWidth) or math.max(200, contentW - side * 2)

    local rows = BuildRows()

    -- Fixed header: WN title card + toolbar (right to left), then the WN search box.
    local chrome = ns.UI_BeginTabChromeLayout and ns.UI_BeginTabChromeLayout(mf)
    if chrome then
        local titleCard, _, textContainer = ns.UI_CreateStandardTabTitleCard(chrome.headerParent, {
            tabKey = TAB,
            titleText = H.AccentTitle(SafeL("HUB_PAGE_CRAFTING", "Crafting")),
            subtitleText = Subtitle(rows),
            showUnderline = false,
        })
        titleCard:Show()
        local buttons = {}
        buttons[#buttons + 1] = H.ProfessionFilterButton(titleCard, TAB)
        buttons[#buttons + 1] = H.ToolbarButton(titleCard,
            SessionOnly() and SafeL("HUB_SESSION_ONLY_ON", "Session only") or SafeL("HUB_SESSION_ONLY_OFF", "Bags + session"),
            ToggleProfile("hubSessionOnly", function() return not SessionOnly() end),
            SafeL("HUB_SESSION_ONLY_TT", "Only recipes craftable from this session's loot."))
        buttons[#buttons + 1] = H.ToolbarButton(titleCard,
            (KnownBy() == "me") and SafeL("HUB_KNOWN_BY_ME", "Known by: me") or SafeL("HUB_KNOWN_BY_ANY", "Known by: any"),
            ToggleProfile("hubKnownBy", function() return (KnownBy() == "me") and "any" or "me" end),
            SafeL("HUB_KNOWN_BY_TT", "Recipes known by you or by any alt."))
        buttons[#buttons + 1] = H.ToolbarButton(titleCard,
            (PriceBasis() == "avg") and SafeL("HUB_CRAFT_BASIS_AVG", "Prices: 7-day avg") or SafeL("HUB_CRAFT_BASIS_SPOT", "Prices: current"),
            ToggleProfile("hubPriceBasis", function() return (PriceBasis() == "avg") and "spot" or "avg" end),
            SafeL("HUB_CRAFT_BASIS_TT", "Use current AH prices or 7-day averages."))
        if state.pinned then
            buttons[#buttons + 1] = H.ToolbarButton(titleCard, SafeL("HUB_CRAFT_CLEAR_LINK", "Clear link"), function()
                Unpin()
                Refresh()
            end, SafeL("HUB_CRAFT_CLEAR_LINK_TT", "Unpin the linked recipe."))
        end
        H.LayoutToolbar(titleCard, textContainer, buttons)
        local headerY = ns.UI_PageStack_Place(chrome, titleCard)

        local searchBox = ns.UI_CreateSearchBox(chrome.headerParent, contentW,
            SafeL("HUB_CRAFT_SEARCH", "Search recipes..."), OnSearch, nil, Query(), TAB)
        C.searchBox = searchBox
        headerY = ns.UI_PageStack_Place(chrome, searchBox, ns.UI_LAYOUT.PAGE_STACK.SEARCH_HEIGHT or 32)
        ns.UI_CommitTabFixedHeader(mf, headerY)
    end

    local bodyTop = BodyTop()
    local rc = Results(parent)
    rc:SetParent(parent)
    ns.UI_PageStack_AnchorBody(parent, rc, bodyTop)
    rc:SetWidth(bodyW)
    rc:Show()
    local h = DrawResults(rc, bodyW, rows)
    rc:SetHeight(math.max(1, h))
    return bodyTop + h
end
