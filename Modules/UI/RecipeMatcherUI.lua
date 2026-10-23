--[[
    Artisan Nexus - Recipe Matcher window.

    Two questions, one window:
      1. "From bag"   - scan bags, list Midnight recipes whose reagents I hold.
      2. "By recipe"  - pick any cached recipe, see what you still need to farm.

    Reagent data only exists for recipes whose profession window has been
    opened at least once (see RecipeService:HarvestOpenProfession). Until
    then the list is empty - open the profession, browse once, done.

    Built exactly like a Warband Nexus floating window (ns.ArtisanWindow, ArtisanWindow.lua):
      shell / title band / close / settings gear / resize / position  -> PlansTrackerWindow.lua (via ns.ArtisanWindow)
      mode tabs                                                       -> ns.UI_CreateSubTabBar (SharedWidgets.lua:1857)
      search box                                                      -> ns.UI_CreateSearchBox (ItemsUI.lua:1474 usage)
      profession filter                                               -> ns.ArtisanWindow.CreateDropdown (PlansTrackerWindow.lua:1871)
      list rows + section headers                                     -> ns.UI_TableKit row pool + ns.UI_CreateCollapsibleHeader
      detail pane (section headers, data rows, empty text)            -> RecipeCompanionWindow.lua:438 RenderContent,
                                                                         ProfessionInfoWindow.lua:226 AddSectionHeader / AddLine
      footer status line                                              -> UI_MainShell.lua main-window footer (rule + small Dim text)
]]

local ADDON_NAME, ns = ...
-- Pixel-perfect frames (SharedWidgets_Pixel: SetPoint/SetSize snap to whole physical pixels).
local CreateFrame = function(...) return (ns.UI_CreateFrame or _G.CreateFrame)(...) end

-- 12.1.5 removed the global item/coin fallbacks; bind the namespaced APIs.
local GetItemInfo = C_Item.GetItemInfo

local L = ns.L
local E = ns.Constants.EVENTS
local FontManager = ns.FontManager

---@class RecipeMatcherUI
local RecipeMatcherUI = {}
ns.RecipeMatcherUI = RecipeMatcherUI

-- ── Window-specific metrics ──
local WINDOW_W, WINDOW_H = 960, 660
local MIN_W, MIN_H = 720, 420
local MAX_W, MAX_H = 1600, 1200
local LEFT_PANE_FRAC = 0.46
local PROF_DROPDOWN_W = 180
local ROW_GAP = 8                 -- between toolbar rows / toolbar and panes
local SECTION_GAP = 6             -- after a profession group in the list
local HEADER_GAP = 2              -- section header -> first row
local LIST_ICON = 20
local COUNT_COL_W = 64
local DETAIL_PAD = 8              -- RecipeCompanionWindow.lua PADDING
local DETAIL_ROW_H = 26           -- UI_SPACING.ROW_HEIGHT
local DETAIL_LINE_H = 18
local DETAIL_SECTION_GAP = 10
local GRIP_RESERVE = 22           -- footer lane kept clear of the resize grip

local function T(key, fallback)
    local v = L and L[key]
    if v == nil or v == "" then return fallback end
    return v
end

local function Layout() return ns.UI_LAYOUT or {} end
local function MainShell() return Layout().MAIN_SHELL or {} end
local function TableTokens() return Layout().TABLE or { ROW_H = { standard = 30 }, CELL_PAD_X = 8 } end
local function Factory() return ns.UI and ns.UI.Factory end
local function COLORS() return ns.UI_COLORS or { accent = { 0.5, 0.4, 0.7 }, border = { 0.3, 0.3, 0.35 } } end
local function Win() return ns.ArtisanWindow end

local function ButtonHeight()
    return (ns.UI_CONSTANTS and ns.UI_CONSTANTS.BUTTON_HEIGHT) or 32
end
local function SearchHeight()
    return (ns.UI_CONSTANTS and ns.UI_CONSTANTS.SEARCH_BOX_HEIGHT) or 32
end
local function RowHeight()
    local t = TableTokens()
    return (t.ROW_H and t.ROW_H.standard) or 30
end
local function SectionHeaderHeight()
    return Layout().SECTION_COLLAPSE_HEADER_HEIGHT or 36
end
local function PaneGap()
    return MainShell().SETTINGS_NAV_GAP or 10
end
local function FooterHeight()
    return MainShell().FOOTER_HEIGHT or 26
end

--- `|cffrrggbb` prefixes (Modules/UI/InlineColors.lua).
local IC = ns.UI_InlineHex
local RoleHex, GreenHex, GoldHex, RedHex, AccentHex = IC.Role, IC.Green, IC.Gold, IC.Red, IC.Accent
local function Wrap(hex, text)
    return hex .. tostring(text) .. "|r"
end

--- WN money string (TableKit SetMoneyCell: 12px coins, zero shown).
local function Money(copper)
    if copper == nil then return nil end
    if ns.UI_FormatMoney then return ns.UI_FormatMoney(copper, 12, true) end
    return ns.FormatCopper and ns.FormatCopper(copper) or tostring(copper)
end

local function SignedMoney(copper)
    local TK = ns.UI_TableKit
    if TK and TK.FormatSignedMoneyPlain then return TK.FormatSignedMoneyPlain(copper, 12) end
    return Money(copper) or ""
end

local function ProfessionLabel(prof)
    if not prof or prof == "" then return "" end
    return (ns.GetProfessionDisplayName and ns.GetProfessionDisplayName(prof)) or prof
end

--- ThemedButton has no disabled skin; WN sub-tab disabled pattern (Disable + 0.5 alpha).
local function SetButtonEnabled(btn, on)
    if not btn then return end
    if on then btn:Enable() else btn:Disable() end
    btn:SetAlpha(on and 1 or 0.5)
end

local function AttachButtonTooltip(btn, title, desc)
    btn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(title, 1, 1, 1)
        if desc and desc ~= "" then
            GameTooltip:AddLine(desc, 0.85, 0.85, 0.85, true)
        end
        GameTooltip:Show()
    end)
    btn:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

--- Async item name + icon: triggers a ContinueOnItemLoad that refreshes UI.
---@type table<number, string>
local ITEM_NAME_CACHE = {}
---@type table<number, number>
local ITEM_ICON_CACHE = {}
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local pendingRefresh = false
local pendingRightRefresh = false

local LEFT_DRAW_CHUNK = 45
local leftDrawGen = 0

local listCache = {
    recipeKey = nil,
    recipeEntries = nil,
    bagKey = nil,
    bagResults = nil,
}

local rightPaintCache = { spellID = nil, bagGen = -1 }

local function InvalidateListCaches()
    listCache.recipeKey = nil
    listCache.recipeEntries = nil
    listCache.bagKey = nil
    listCache.bagResults = nil
    rightPaintCache.spellID = nil
    rightPaintCache.bagGen = -1
end

--- Force the detail pane to repaint on its next refresh (also when nothing is selected).
local function InvalidateRightPaint()
    rightPaintCache.spellID = nil
    rightPaintCache.bagGen = -1
end

local function BumpLeftDraw()
    leftDrawGen = leftDrawGen + 1
    return leftDrawGen
end

local function RequestRightRefresh()
    if pendingRightRefresh then return end
    pendingRightRefresh = true
    C_Timer.After(0.08, function()
        pendingRightRefresh = false
        if RecipeMatcherUI.main and RecipeMatcherUI.main:IsShown() then
            InvalidateRightPaint()
            RecipeMatcherUI:Refresh({ rightOnly = true })
        end
    end)
end

local function RequestItemLoad(itemID, onRefresh)
    if ITEM_NAME_CACHE[itemID] then return end
    if not Item or not Item.CreateFromItemID then return end
    local item = Item:CreateFromItemID(itemID)
    if item.IsItemEmpty and item:IsItemEmpty() then return end
    item:ContinueOnItemLoad(function()
        --- Cache only real names: "" is truthy in Lua and would pin a blank name for the session.
        local loadedName = item:GetItemName()
        if type(loadedName) == "string" and loadedName ~= "" then
            ITEM_NAME_CACHE[itemID] = loadedName
        end
        local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
        if icon then ITEM_ICON_CACHE[itemID] = icon end
        if onRefresh then
            onRefresh()
        end
    end)
end

local function RequestFullRefresh()
    if pendingRefresh then return end
    pendingRefresh = true
    C_Timer.After(0.1, function()
        pendingRefresh = false
        if RecipeMatcherUI.main and RecipeMatcherUI.main:IsShown() then
            RecipeMatcherUI:Refresh()
        end
    end)
end

--- Item icon (fileID) or the question mark while the item loads.
local function ItemIcon(itemID, onLoad)
    if not itemID then return QUESTION_ICON end
    local tex = ITEM_ICON_CACHE[itemID]
    if not tex then
        local live = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
        if live and live > 0 then
            tex = live
            ITEM_ICON_CACHE[itemID] = live
        end
    end
    if tex and tex > 0 then
        return tex
    end
    RequestItemLoad(itemID, onLoad)
    return QUESTION_ICON
end

--- Prefer crafted item icon; else recipe UI icon (fileID) from harvest or live GetRecipeInfo.
local function RecipeIcon(spellID, outputItemID, recipeIconFile, onRefresh)
    if outputItemID and outputItemID > 0 then
        return ItemIcon(outputItemID, onRefresh)
    end
    local fid = recipeIconFile
    if (not fid or fid <= 0) and ns.RecipeService and ns.RecipeService.GetRecipeDisplayIconFileID then
        fid = ns.RecipeService:GetRecipeDisplayIconFileID(spellID)
    end
    if type(fid) == "number" and fid > 0 then
        return fid
    end
    return 136243
end

local function ItemName(itemID, onLoad)
    if ITEM_NAME_CACHE[itemID] then return ITEM_NAME_CACHE[itemID] end
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if name and name ~= "" then
        ITEM_NAME_CACHE[itemID] = name
        return name
    end
    local ok, cached = pcall(GetItemInfo, itemID)
    if ok and cached and cached ~= "" then
        ITEM_NAME_CACHE[itemID] = cached
        return cached
    end
    RequestItemLoad(itemID, onLoad)
    return Wrap(RoleHex("Dim"), "item:" .. tostring(itemID))
end

--==========================================================================
-- Left list (TableKit row pool + collapsible profession headers)
--==========================================================================

local LIST_COLS = {
    { key = "icon", cell = "icon", width = LIST_ICON + 16, align = "CENTER", iconSize = LIST_ICON },
    { key = "name", flex = 1, min = 60, align = "LEFT" },
    { key = "count", width = COUNT_COL_W, align = "RIGHT" },
}

local function ListValue(col, data)
    if col.key == "icon" then
        return data.icon
    elseif col.key == "name" then
        if data.green and ns.UI_GetSemanticGreenColor then
            local r, g, b, a = ns.UI_GetSemanticGreenColor()
            return data.label, "Bright", r, g, b, a
        end
        return data.label, data.dim and "Dim" or "Bright"
    end
    if data.green and ns.UI_GetSemanticGreenColor then
        local r, g, b, a = ns.UI_GetSemanticGreenColor()
        return data.count, "Bright", r, g, b, a
    end
    return data.count, "Dim"
end

local function ListRowOnEnter(self)
    if self._anSpellID then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(self._anSpellID)
        GameTooltip:Show()
    end
end

local function ListRowOnLeave()
    GameTooltip:Hide()
end

local function OnRecipeRowClick(spellID)
    if RecipeMatcherUI.selectedSpellID == spellID then
        return
    end
    RecipeMatcherUI.selectedSpellID = spellID
    RecipeMatcherUI:RefreshSelection()
end

local function ListRowOnClick(self)
    local sid = self._anSpellID
    if not sid then return end
    if IsModifiedClick() then
        local link = C_Spell.GetSpellLink(sid)
        if link and HandleModifiedItemClick(link) then
            return
        end
    end
    OnRecipeRowClick(sid)
end

--- Selected row: WN active-row highlight (accent stripe + tint); others keep the alternating fill.
local function PaintRowSelected(row, on)
    local F = Factory()
    if F and F.ApplyOnlineCharacterHighlight then
        F:ApplyOnlineCharacterHighlight(row, on and true or false)
    end
end

local function ListContentWidth(list)
    local w = Win().SyncScrollChildWidth(list.vp)
    if not w or w < 1 then
        w = (list.vp.shell:GetWidth() or 0) - 2 * Win().ViewportInnerInset() - Win().ScrollRightReserve()
    end
    return math.max(1, w)
end

local function AcquireListRow(list, rowIndex, y)
    local TK = ns.UI_TableKit
    local child = list.vp.scrollChild
    local width = list.paintWidth
    local row = TK.AcquireRow(list.pool, child, rowIndex, width, RowHeight())
    row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
    if not row._anMatcherWired then
        row._anMatcherWired = true
        row:SetScript("OnEnter", ListRowOnEnter)
        row:SetScript("OnLeave", ListRowOnLeave)
        row:SetScript("OnClick", ListRowOnClick)
    end
    return row
end

local function PaintListRow(list, rowIndex, y, data)
    local TK = ns.UI_TableKit
    local row = AcquireListRow(list, rowIndex, y)
    TK.PaintRowCells(row, LIST_COLS, list.widths, list.offsets, #LIST_COLS, data, ListValue)
    row._anSpellID = data.spellID
    PaintRowSelected(row, data.spellID ~= nil and RecipeMatcherUI.selectedSpellID == data.spellID)
    return row
end

--- Pooled collapsible header (ns.UI_CreateCollapsibleHeader once, ns.UI_RebindCollapsibleHeader after).
local function AcquireSectionHeader(list, index, y, text, expanded, onToggle)
    local child = list.vp.scrollChild
    local h = list.headers[index]
    if not h then
        h = ns.UI_CreateCollapsibleHeader(child, text, "recipeMatcher_" .. index, expanded, onToggle,
            nil, nil, 0, true, { sectionHeaderHeight = SectionHeaderHeight(), useFullParentWidth = true })
        list.headers[index] = h
    end
    ns.UI_RebindCollapsibleHeader(h, text, expanded, onToggle)
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
    h:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
    h:Show()
    return h
end

local function ReleaseList(list)
    local TK = ns.UI_TableKit
    TK.ReleaseRowsFrom(list.pool, 1)
    for i = 1, #list.headers do
        list.headers[i]:Hide()
    end
    if list.emptyText then
        list.emptyText:Hide()
    end
end

--- Theme change: headers carry creation-time chrome; drop them so the next paint rebuilds them.
local function DiscardListHeaders(list)
    local bin = ns.UI_RecycleBin
    for i = 1, #list.headers do
        local h = list.headers[i]
        h:Hide()
        h:ClearAllPoints()
        if bin then h:SetParent(bin) end
        list.headers[i] = nil
    end
end

--- One empty message (RecipeCompanionWindow.lua:453 noData pattern).
local function ShowListEmpty(list, message)
    BumpLeftDraw()
    ReleaseList(list)
    local child = list.vp.scrollChild
    local fs = list.emptyText
    if not fs then
        fs = FontManager:CreateFontString(child, "body", "OVERLAY")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        list.emptyText = fs
    end
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", child, "TOPLEFT", DETAIL_PAD, -DETAIL_PAD)
    fs:SetPoint("RIGHT", child, "RIGHT", -DETAIL_PAD, 0)
    fs:SetText(Wrap(RoleHex("Muted"), message))
    fs:Show()
    child:SetHeight(40)
    Win().SyncScroll(list.vp)
end

--==========================================================================
-- Forward declarations
--==========================================================================

local RefreshLeft_Bag, RefreshLeft_Recipe, RefreshRight
local UpdateStatus

--==========================================================================
-- Layout
--==========================================================================

--- Left pane width follows the window (live resize).
local function RelayoutPanes()
    local self = RecipeMatcherUI
    local f = self.main
    if not f or not self.left then return end
    local ca = f.contentArea
    local cw = ca and ca:GetWidth() or 0
    if cw < 1 then cw = WINDOW_W - 2 * (Win().PADDING or 10) end
    self.left.vp.shell:SetWidth(math.max(160, math.floor(cw * LEFT_PANE_FRAC)))
    Win().SyncScrollChildWidth(self.left.vp)
    Win().SyncScrollChildWidth(self.right.vp)
    Win().SyncScroll(self.left.vp)
    Win().SyncScroll(self.right.vp)
end

local function ProfessionFilterItems()
    local out = {}
    for _, prof in ipairs(ns.Constants.CRAFT_PROFESSION_FILTERS) do
        out[#out + 1] = {
            key = prof,
            label = (prof == "All") and T("RECIPE_MATCHER_PROF_ALL", "All professions") or ProfessionLabel(prof),
        }
    end
    return out
end

local function RunRecipeScan()
    local svc = ns.RecipeService
    if not svc then return end
    if svc.IsHarvestChunkActive and svc:IsHarvestChunkActive() then
        ns.ArtisanNexus:Print(T("RECIPE_SCAN_BUSY", "Recipe scan already in progress."))
        return
    end
    local function onDone(n, _, considered)
        if n == 0 and (considered or 0) > 0 then
            ns.ArtisanNexus:Print(string.format(T("RECIPE_SCAN_UPTODATE_FMT", "All %d recipes are already up to date."), considered))
        elseif n == 0 then
            ns.ArtisanNexus:Print(T("RECIPE_MATCHER_NO_PROF_OPEN", "Open a profession window, then click Scan."))
        else
            ns.ArtisanNexus:Print(string.format(T("RECIPE_SCAN_DONE_FMT", "Scanned %d recipes."), n))
        end
        InvalidateListCaches()
        RecipeMatcherUI:Refresh()
    end
    local started = svc.HarvestOpenProfessionChunked and svc:HarvestOpenProfessionChunked(onDone)
    if not started then
        onDone(0)
    end
end

local function AddSelectedToShopping()
    local sid = RecipeMatcherUI.selectedSpellID
    if not sid or not ns.ShoppingListService then return end
    ns.ShoppingListService:Add(sid, 1)
    local nm = (ns.RecipeService and ns.RecipeService.GetRecipeName and ns.RecipeService:GetRecipeName(sid)) or ("#" .. tostring(sid))
    if not nm or (issecretvalue and issecretvalue(nm)) then nm = "#" .. tostring(sid) end
    ns.ArtisanNexus:Print(string.format(T("RECIPE_MATCHER_SHOP_ONE_FMT", "|cffd4af37+1 shopping:|r %s"), nm))
end

local function AddFilteredToShopping()
    if not ns.ShoppingListService or not ns.ShoppingListService.AddMany then return end
    local ids = RecipeMatcherUI:CollectFilteredSpellIDs()
    if #ids == 0 then
        ns.ArtisanNexus:Print(T("RECIPE_MATCHER_SHOP_NONE", "Nothing to add for the current filter."))
        return
    end
    local n = ns.ShoppingListService:AddMany(ids, 1)
    if n > 0 then
        ns.ArtisanNexus:Print(string.format(T("RECIPE_MATCHER_SHOP_BATCH_FMT", "|cffd4af37Shopping list:|r merged %d recipe(s)."), n))
    end
end

function RecipeMatcherUI:Init()
    if self.main then return end
    local W = Win()
    local TK = ns.UI_TableKit

    local f = W.Create({
        name = "ArtisanNexusRecipeMatcher",
        title = T("HUB_RAIL_RECIPE_MATCHER", "Recipe Matcher"),
        posKey = "recipeMatcherFrame",
        width = WINDOW_W,
        height = WINDOW_H,
        minW = MIN_W,
        minH = MIN_H,
        maxW = MAX_W,
        maxH = MAX_H,
        tileSiblings = true,
        onClose = function()
            Win().CloseOpenDropdown()
        end,
        onLive = function()
            RelayoutPanes()
        end,
        onCommit = function()
            RelayoutPanes()
            if RecipeMatcherUI.main and RecipeMatcherUI.main:IsShown() then
                InvalidateRightPaint()
                RecipeMatcherUI:Refresh()
            end
        end,
    })
    if not f then return end
    f:Hide()

    -- Header utility buttons, right to left: close, settings, Hub, Session Loot.
    W.AddHeaderButton(f, {
        icon = "settings",
        tooltip = T("HUB_RAIL_SETTINGS", "Settings"),
        onClick = function()
            if ns.OpenAddonSettings then ns.OpenAddonSettings() end
        end,
    })
    W.AddHeaderButton(f, {
        texture = "Interface\\AddOns\\ArtisanNexus\\Media\\anlogo",
        tooltip = T("HUB_WINDOW_TITLE", "Artisan Hub"),
        desc = T("LOOT_OPEN_HUB_DESC", "Profit, queue, orders, market and ledger."),
        onClick = function()
            W.ShowHubBeside(f)
        end,
    })
    W.AddHeaderButton(f, {
        texture = "Interface\\Icons\\INV_Misc_Bag_10",
        tooltip = T("HUB_RAIL_SESSION_LOOT", "Session Loot"),
        desc = T("HUB_RAIL_SESSION_LOOT_DESC", "Gathering and fishing loot from this session."),
        onClick = function()
            if ns.LootHistoryUI then
                ns.LootHistoryUI:Show(nil, { tileAfter = f })
            end
        end,
    })

    local ca = f.contentArea
    local btnH = ButtonHeight()

    -- ── Toolbar row 1: mode tabs (left), shopping + scan actions (right) ──
    local toolRow1 = Factory():CreateContainer(ca, 400, btnH, false)
    toolRow1:SetPoint("TOPLEFT", ca, "TOPLEFT", 0, 0)
    toolRow1:SetPoint("TOPRIGHT", ca, "TOPRIGHT", 0, 0)
    toolRow1:SetHeight(btnH)

    f.mode = "bag"
    local modeBar = ns.UI_CreateSubTabBar(toolRow1, {
        tabs = {
            { key = "bag", label = T("RECIPE_MATCHER_TAB_BAG", "From bag"), hideIcon = true },
            { key = "recipe", label = T("RECIPE_MATCHER_TAB_RECIPE", "By recipe"), hideIcon = true },
        },
        activeKey = f.mode,
        btnHeight = btnH,
        onSelect = function(key)
            RecipeMatcherUI:SetMode(key)
        end,
    })
    modeBar:SetPoint("TOPLEFT", toolRow1, "TOPLEFT", 0, 0)
    f.modeBar = modeBar

    local btnScan = ns.UI_CreateThemedButton(toolRow1, T("RECIPE_MATCHER_HARVEST", "Scan"), 80)
    btnScan:SetPoint("RIGHT", toolRow1, "RIGHT", 0, 0)
    btnScan:SetScript("OnClick", RunRecipeScan)
    AttachButtonTooltip(btnScan, T("RECIPE_MATCHER_HARVEST", "Scan"),
        T("RECIPE_MATCHER_SCAN_TT", "Read recipe reagents from the open profession window."))

    local btnShopFiltered = ns.UI_CreateThemedButton(toolRow1, T("RECIPE_MATCHER_SHOP_ADD_FILTERED", "Add all filtered"), 120)
    btnShopFiltered:SetPoint("RIGHT", btnScan, "LEFT", -ROW_GAP, 0)
    btnShopFiltered:SetScript("OnClick", AddFilteredToShopping)
    AttachButtonTooltip(btnShopFiltered, T("RECIPE_MATCHER_SHOP_ADD_FILTERED", "Add all filtered"),
        T("RECIPE_MATCHER_SHOP_TT_FILTERED", "Add every listed recipe."))

    local btnShopSelected = ns.UI_CreateThemedButton(toolRow1, T("RECIPE_MATCHER_SHOP_ADD_SELECTED", "Add selected"), 110)
    btnShopSelected:SetPoint("RIGHT", btnShopFiltered, "LEFT", -ROW_GAP, 0)
    btnShopSelected:SetScript("OnClick", AddSelectedToShopping)
    AttachButtonTooltip(btnShopSelected, T("RECIPE_MATCHER_SHOP_ADD_SELECTED", "Add selected"),
        T("RECIPE_MATCHER_SHOP_TT_SELECTED", "Add selected recipe (+1 craft)."))

    -- ── Toolbar row 2: search (fills) + profession filter (right) ──
    local searchH = SearchHeight()
    local toolRow2 = Factory():CreateContainer(ca, 400, searchH, false)
    toolRow2:SetPoint("TOPLEFT", toolRow1, "BOTTOMLEFT", 0, -ROW_GAP)
    toolRow2:SetPoint("TOPRIGHT", toolRow1, "BOTTOMRIGHT", 0, -ROW_GAP)
    toolRow2:SetHeight(searchH)

    f.profFilter = "All"
    -- Profession filter: the shared WN dropdown (ns.ArtisanWindow.CreateDropdown).
    local profDropdown = Win().CreateDropdown(toolRow2, {
        width = PROF_DROPDOWN_W,
        height = searchH,
        items = ProfessionFilterItems,
        value = function() return f.profFilter end,
        onSelected = function(key)
            f.profFilter = key
            RecipeMatcherUI:Refresh()
        end,
    })
    profDropdown:SetPoint("RIGHT", toolRow2, "RIGHT", 0, 0)
    f.profDropdown = profDropdown

    f.searchText = ""
    local search, clearSearch = ns.UI_CreateSearchBox(toolRow2, WINDOW_W, T("RECIPE_MATCHER_SEARCH", "Search recipes..."),
        function(text)
            f.searchText = text or ""
            RecipeMatcherUI:Refresh({ leftOnly = true })
        end)
    search:ClearAllPoints()
    search:SetPoint("LEFT", toolRow2, "LEFT", 0, 0)
    search:SetPoint("RIGHT", profDropdown, "LEFT", -ROW_GAP, 0)
    f.searchBox = search
    f.clearSearch = clearSearch
    do
        local kids = { search:GetChildren() }
        for i = 1, #kids do
            if kids[i].GetObjectType and kids[i]:GetObjectType() == "EditBox" then
                f.searchEditBox = kids[i]
                break
            end
        end
    end

    -- ── Footer status line (main-window footer: top rule + small Dim text) ──
    local footer = Factory():CreateContainer(ca, 400, FooterHeight(), false)
    footer:SetHeight(FooterHeight())
    footer:SetPoint("BOTTOMLEFT", ca, "BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", ca, "BOTTOMRIGHT", -GRIP_RESERVE, 0)
    footer:EnableMouse(false)
    local footerTop = footer:CreateTexture(nil, "ARTWORK")
    footerTop:SetHeight((ns.GetPixelScale and ns.GetPixelScale(footer)) or 1)
    if ns.UI_SnapRuleTexture then ns.UI_SnapRuleTexture(footerTop) end
    footerTop:SetPoint("TOPLEFT", footer, "TOPLEFT", 0, 0)
    footerTop:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, 0)
    f.footerTop = footerTop
    local status = FontManager:CreateFontString(footer, "small", "OVERLAY")
    status:SetPoint("LEFT", footer, "LEFT", 8, 0)
    status:SetPoint("RIGHT", footer, "RIGHT", -8, 0)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)
    status:SetMaxLines(1)
    ns.UI_SetTextColorRole(status, "Dim", 0.92)
    f.status = status
    f.footer = footer

    -- ── Panes: list viewport (left) + detail viewport (right) ──
    local leftVp = W.CreateScrollViewport(f, ca)
    leftVp.shell:SetPoint("TOPLEFT", toolRow2, "BOTTOMLEFT", 0, -ROW_GAP)
    leftVp.shell:SetPoint("BOTTOMLEFT", ca, "BOTTOMLEFT", 0, FooterHeight() + ROW_GAP)
    leftVp.shell:SetWidth(math.floor((WINDOW_W - 2 * (W.PADDING or 10)) * LEFT_PANE_FRAC))

    local rightVp = W.CreateScrollViewport(f, ca)
    rightVp.shell:SetPoint("TOPLEFT", leftVp.shell, "TOPRIGHT", PaneGap(), 0)
    rightVp.shell:SetPoint("BOTTOMRIGHT", ca, "BOTTOMRIGHT", 0, FooterHeight() + ROW_GAP)

    self.main = f
    self.left = {
        vp = leftVp,
        pool = TK.CreateRowPool(RowHeight()),
        headers = {},
        widths = {},
        offsets = {},
        paintWidth = 1,
    }
    self.right = { vp = rightVp }
    self.btnShopSelected = btnShopSelected
    self.btnShopFiltered = btnShopFiltered
    self.btnScan = btnScan
    self.selectedSpellID = nil

    f:HookScript("OnShow", function()
        RelayoutPanes()
        RecipeMatcherUI:Refresh()
    end)
    f:HookScript("OnHide", function()
        Win().CloseOpenDropdown()
    end)

    self:ApplyThemeColors()

    if not RecipeMatcherUI._eventOwner then
        RecipeMatcherUI._eventOwner = ns.NewEventOwner("RecipeMatcherUI")
    end
    local owner = RecipeMatcherUI._eventOwner
    --- Schematics + snapshot messages arrive in bursts while the trade skill
    --- frame loads; RequestFullRefresh collapses them into one Refresh.
    owner:RegisterMessage(E.RECIPE_SCHEMATICS_UPDATED, function()
        InvalidateListCaches()
        local main = RecipeMatcherUI.main
        if main and main:IsShown() then RequestFullRefresh() end
    end)
    if E.PROFESSION_SNAPSHOT_UPDATED then
        owner:RegisterMessage(E.PROFESSION_SNAPSHOT_UPDATED, function()
            local main = RecipeMatcherUI.main
            if main and main:IsShown() then RequestFullRefresh() end
        end)
    end
    if E.THEME_CHANGED then
        owner:RegisterMessage(E.THEME_CHANGED, function()
            RecipeMatcherUI:RefreshTheme()
        end)
    end
    if E.FONT_CHANGED then
        owner:RegisterMessage(E.FONT_CHANGED, function()
            local main = RecipeMatcherUI.main
            if main and main:IsShown() then
                InvalidateRightPaint()
                RecipeMatcherUI:Refresh()
            end
        end)
    end
    if not RecipeMatcherUI._bagBucket and ns.ArtisanNexus and ns.ArtisanNexus.RegisterBucketEvent then
        RecipeMatcherUI._bagBucket = true
        ns.ArtisanNexus:RegisterBucketEvent("BAG_UPDATE", 0.45, function()
            if not RecipeMatcherUI.main or not RecipeMatcherUI.main:IsShown() then
                return
            end
            if RecipeMatcherUI.main.mode ~= "bag" then
                return
            end
            InvalidateListCaches()
            RequestFullRefresh()
        end)
    end
end

--- Mode tab switch ("bag" | "recipe").
function RecipeMatcherUI:SetMode(mode)
    local f = self.main
    if not f or (mode ~= "bag" and mode ~= "recipe") then return end
    if f.modeBar then f.modeBar:SetActiveTab(mode) end
    if f.mode == mode then return end
    f.mode = mode
    self.selectedSpellID = nil
    self:Refresh()
end

--- Theme-dependent inks owned by this file (footer rule, dropdown chrome).
function RecipeMatcherUI:ApplyThemeColors()
    local f = self.main
    if not f then return end
    if f.footerTop then
        local C = COLORS()
        local div = (ns.UI_GetFooterDividerColor and ns.UI_GetFooterDividerColor())
            or { C.accent[1], C.accent[2], C.accent[3], 0.28 }
        f.footerTop:SetColorTexture(div[1], div[2], div[3], div[4] or 0.28)
    end
    if f.status then
        ns.UI_SetTextColorRole(f.status, "Dim", 0.92)
    end
    if f.profDropdown then
        f.profDropdown:Restyle()
    end
    if f.searchBox and ns.UI_ApplySearchBoxChrome then
        ns.UI_ApplySearchBoxChrome(f.searchBox, { editBoxHost = true })
    end
    if f.modeBar then
        f.modeBar:SetActiveTab(f.mode)
    end
end

function RecipeMatcherUI:RefreshTheme()
    if not self.main then return end
    Win().RefreshChrome(self.main)
    self:ApplyThemeColors()
    --- Painted strings carry palette-resolved hex: force both panes to repaint with the new theme.
    InvalidateRightPaint()
    if self.left then
        DiscardListHeaders(self.left)
    end
    if self.main:IsShown() then
        self:Refresh()
    end
end

--==========================================================================
-- Refresh
--==========================================================================

UpdateStatus = function(self)
    local svc = ns.RecipeService
    if not svc then return end
    local stats = svc:GetStats()
    local statusFs = self.main.status
    if stats.total > 0 and stats.harvested < 1 then
        statusFs:SetText(Wrap(GoldHex(), T("RECIPE_MATCHER_HARVEST_ONBOARDING",
            "Open a profession window, then click Scan.")))
        return
    end
    local text
    if stats.total > 0 and stats.harvested < stats.total then
        text = string.format(
            T("RECIPE_MATCHER_STATUS_PARTIAL", "%d / %d recipes cached (%d%%)"),
            stats.harvested, stats.total, math.floor((stats.harvested / stats.total) * 100))
    else
        text = string.format(T("RECIPE_MATCHER_STATUS_LINE", "%d recipes cached"), stats.harvested)
    end
    local snapSvc = ns.ProfessionSnapshotService
    if snapSvc and snapSvc.GetChipText then
        local chip = snapSvc:GetChipText()
        if chip and chip ~= "" then
            text = text .. "  |  " .. chip
        end
    end
    statusFs:SetText(text)
end

local function GroupByProfession(entries)
    local groups = {}
    local order = {}
    for i = 1, #entries do
        local e = entries[i]
        local p = e.profession or "?"
        if not groups[p] then
            groups[p] = {}
            order[#order + 1] = p
        end
        groups[p][#groups[p] + 1] = e
    end
    table.sort(order)
    return order, groups
end

--- Per-profession collapse state, persisted across refreshes within the session.
RecipeMatcherUI.collapsed = RecipeMatcherUI.collapsed or {}

local function IsCollapsed(prof)
    return RecipeMatcherUI.collapsed[prof] == true
end

local function ListCacheKeyPrefix(filter, svc)
    local stats = svc:GetStats()
    local bagGen = svc.GetBagCacheGeneration and svc:GetBagCacheGeneration() or 0
    return string.format("%s:%d:%d", filter or "ALL", bagGen, stats.harvested or 0)
end

local function GetRecipeEntriesCached(svc, filter)
    local key = "r:" .. ListCacheKeyPrefix(filter, svc)
    if listCache.recipeKey == key and listCache.recipeEntries then
        return listCache.recipeEntries
    end
    local cat = ns.MidnightRecipeCatalog or {}
    local entries = {}
    for prof, data in pairs(cat) do
        if not filter or prof == filter then
            for spellID, name in pairs(data.recipes or {}) do
                local sch = svc:GetSchematic(spellID)
                local displayName = (sch and sch.name ~= "" and sch.name) or (name ~= "" and name)
                    or ("spell:" .. spellID)
                entries[#entries + 1] = {
                    spellID = spellID,
                    name = displayName,
                    profession = prof,
                    cached = sch ~= nil,
                    outputItemID = sch and sch.output and sch.output.itemID or nil,
                    recipeIcon = sch and sch.recipeIcon or nil,
                }
            end
        end
    end
    listCache.recipeKey = key
    listCache.recipeEntries = entries
    return entries
end

local function GetBagResultsCached(svc, filter, bagCounts)
    local key = "b:" .. ListCacheKeyPrefix(filter, svc)
    if listCache.bagKey == key and listCache.bagResults then
        return listCache.bagResults
    end
    local results = svc:FindCraftableFromBags(filter, bagCounts)
    listCache.bagKey = key
    listCache.bagResults = results
    return results
end

--- Scratch row data (one table reused per paint; PaintRowCells reads it synchronously).
local ROW_DATA = {}

local function PaintEntryRow(list, entry, mode, rowIndex, y)
    local data = ROW_DATA
    data.spellID = entry.spellID
    data.icon = RecipeIcon(entry.spellID, entry.outputItemID, entry.recipeIcon, RequestFullRefresh)
    if mode == "bag" then
        data.label = (entry.name ~= "" and entry.name) or ("spell:" .. entry.spellID)
        data.count = string.format("%d/%d", entry.matched, entry.total)
        data.green = entry.craftable and true or false
        data.dim = false
    else
        data.label = entry.name
        data.count = entry.cached and "" or "?"
        data.green = false
        data.dim = not entry.cached
    end
    PaintListRow(list, rowIndex, y, data)
end

local function BuildLeftPaintQueue(order, groups, mode)
    local queue = {}
    for oi = 1, #order do
        local prof = order[oi]
        local g = groups[prof]
        local craftableCount, cachedCount = 0, 0
        for gi = 1, #g do
            if mode == "bag" then
                if g[gi].craftable then craftableCount = craftableCount + 1 end
            elseif g[gi].cached then
                cachedCount = cachedCount + 1
            end
        end
        local rightText
        if mode == "bag" then
            rightText = string.format(T("RECIPE_MATCHER_READY_TOTAL_FMT", "%d ready / %d total"), craftableCount, #g)
        else
            rightText = string.format(T("RECIPE_MATCHER_CACHED_FMT", "%d / %d cached"), cachedCount, #g)
        end
        queue[#queue + 1] = { kind = "header", prof = prof, label = ProfessionLabel(prof), right = rightText }
        if not IsCollapsed(prof) then
            for ei = 1, #g do
                queue[#queue + 1] = { kind = "row", entry = g[ei], mode = mode }
            end
        end
        queue[#queue + 1] = { kind = "gap" }
    end
    return queue
end

local function MakeHeaderToggle(prof)
    return function(expanded)
        RecipeMatcherUI.collapsed[prof] = not expanded
        RecipeMatcherUI:Refresh({ leftOnly = true })
    end
end

local function PaintLeftQueue(self, queue, gen, qi, y, rowIndex, sectionIndex)
    if gen ~= leftDrawGen then
        return
    end
    local list = self.left
    local limit = math.min(qi + LEFT_DRAW_CHUNK - 1, #queue)
    local rowH = RowHeight()
    for i = qi, limit do
        local item = queue[i]
        if item.kind == "header" then
            sectionIndex = sectionIndex + 1
            local text = item.label .. "  " .. Wrap(RoleHex("Dim"), item.right)
            AcquireSectionHeader(list, sectionIndex, y, text, not IsCollapsed(item.prof), MakeHeaderToggle(item.prof))
            y = y - SectionHeaderHeight() - HEADER_GAP
        elseif item.kind == "row" then
            rowIndex = rowIndex + 1
            PaintEntryRow(list, item.entry, item.mode, rowIndex, y)
            y = y - rowH
        elseif item.kind == "gap" then
            y = y - SECTION_GAP
        end
    end
    if limit < #queue then
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                PaintLeftQueue(self, queue, gen, limit + 1, y, rowIndex, sectionIndex)
            end)
        else
            PaintLeftQueue(self, queue, gen, limit + 1, y, rowIndex, sectionIndex)
        end
        return
    end
    list.vp.scrollChild:SetHeight(math.max(1, -y))
    --- Chunked paint finishes async: bar visibility / thumb follow the final content height.
    Win().SyncScroll(list.vp)
end

local function StartLeftPaint(self, queue)
    local gen = BumpLeftDraw()
    local list = self.left
    ReleaseList(list)
    list.paintWidth = ListContentWidth(list)
    ns.UI_TableKit.ResolveWidths(LIST_COLS, list.paintWidth, list.widths, list.offsets)
    PaintLeftQueue(self, queue, gen, 1, 0, 0, 0)
end

--- Entries whose name contains the search text (lowercased by the search box); all when empty.
local function ApplySearch(entries, query)
    if not query or query == "" then
        return entries
    end
    local out = {}
    for i = 1, #entries do
        local e = entries[i]
        local name = e.name
        if type(name) == "string" and name:lower():find(query, 1, true) then
            out[#out + 1] = e
        end
    end
    return out
end

--- Spell IDs for the current mode + profession filter + search (deduped), for shopping list batch add.
function RecipeMatcherUI:CollectFilteredSpellIDs()
    local svc = ns.RecipeService
    if not svc or not self.main then return {} end
    local filter = self.main.profFilter
    if filter == "All" then filter = nil end
    local out = {}
    local seen = {}
    if self.main.mode == "bag" then
        local bagCounts = self._bagCounts or svc:GetBagCounts()
        local results = ApplySearch(GetBagResultsCached(svc, filter, bagCounts), self.main.searchText)
        for i = 1, #results do
            local sid = results[i].spellID
            if sid and not seen[sid] then
                seen[sid] = true
                out[#out + 1] = sid
            end
        end
    else
        local entries = ApplySearch(GetRecipeEntriesCached(svc, filter), self.main.searchText)
        for i = 1, #entries do
            local sid = entries[i].spellID
            -- Only recipes with harvested reagents that a tracked character knows; the full
            -- catalog (1000+ rows incl. unlearned / never-opened) is not a shopping list.
            local sch = sid and svc:GetSchematic(sid)
            local usable = sch and type(sch.reagents) == "table" and #sch.reagents > 0 and sch.learned ~= false
            if usable and not seen[sid] then
                seen[sid] = true
                out[#out + 1] = sid
            end
        end
    end
    return out
end

RefreshLeft_Bag = function(self)
    local svc = ns.RecipeService
    if not svc then return end
    local filter = self.main.profFilter
    if filter == "All" then filter = nil end
    local bagCounts = self._bagCounts or svc:GetBagCounts()
    local results = GetBagResultsCached(svc, filter, bagCounts)
    local searching = self.main.searchText ~= ""
    results = ApplySearch(results, self.main.searchText)

    if #results == 0 then
        --- No-scan onboarding lives in the status line; this only says why the list is empty.
        if searching then
            ShowListEmpty(self.left, T("RECIPE_MATCHER_EMPTY_RECIPE", "No recipes match the current filter."))
        else
            ShowListEmpty(self.left, T("RECIPE_MATCHER_EMPTY_BAG", "No bag reagents match a known recipe."))
        end
        return
    end

    local order, groups = GroupByProfession(results)
    StartLeftPaint(self, BuildLeftPaintQueue(order, groups, "bag"))
end

RefreshLeft_Recipe = function(self)
    local svc = ns.RecipeService
    if not svc then return end
    local filter = self.main.profFilter
    if filter == "All" then filter = nil end
    local entries = ApplySearch(GetRecipeEntriesCached(svc, filter), self.main.searchText)

    if #entries == 0 then
        ShowListEmpty(self.left, T("RECIPE_MATCHER_EMPTY_RECIPE", "No recipes match the current filter."))
        return
    end

    local order, groups = GroupByProfession(entries)
    for _, g in pairs(groups) do
        table.sort(g, function(a, b) return (a.name or "") < (b.name or "") end)
    end
    StartLeftPaint(self, BuildLeftPaintQueue(order, groups, "recipe"))
end

--==========================================================================
-- Detail pane (RecipeCompanionWindow RenderContent + ProfessionInfoWindow AddSectionHeader / AddLine)
--==========================================================================

--- ProfessionInfoWindow.lua:648-660: recycle the previous render.
local function ClearDetail(child)
    local bin = ns.UI_RecycleBin
    local regions = { child:GetRegions() }
    for i = 1, #regions do
        local region = regions[i]
        region:Hide()
        if bin then region:SetParent(bin) end
    end
    local children = { child:GetChildren() }
    for i = 1, #children do
        local c = children[i]
        c:Hide()
        c:ClearAllPoints()
        if bin then c:SetParent(bin) end
    end
end

--- ProfessionInfoWindow.lua:226 AddSectionHeader (accent title + hairline).
local function AddSectionHeader(child, yOffset, text)
    yOffset = yOffset + DETAIL_SECTION_GAP
    local header = FontManager:CreateFontString(child, "body", "OVERLAY")
    header:SetPoint("TOPLEFT", DETAIL_PAD, -yOffset)
    header:SetPoint("RIGHT", child, "RIGHT", -DETAIL_PAD, 0)
    header:SetJustifyH("LEFT")
    header:SetText(Wrap(AccentHex(), text))
    yOffset = yOffset + DETAIL_LINE_H + 2

    local C = COLORS()
    local line = child:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", DETAIL_PAD, -yOffset)
    line:SetPoint("RIGHT", child, "RIGHT", -DETAIL_PAD, 0)
    if ns.UI_SetRuleThickness then ns.UI_SetRuleThickness(line, "horizontal", 1) else line:SetHeight(1) end
    line:SetColorTexture(C.border[1], C.border[2], C.border[3], 0.35)
    return yOffset + 4
end

--- ProfessionInfoWindow.lua:262 AddFullWidthLine (wrapping body text).
local function AddTextLine(child, yOffset, text)
    local fs = FontManager:CreateFontString(child, "body", "OVERLAY")
    fs:SetPoint("TOPLEFT", DETAIL_PAD, -yOffset)
    fs:SetPoint("RIGHT", child, "RIGHT", -DETAIL_PAD, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetText(text)
    local h = fs:GetStringHeight() or 0
    return yOffset + math.max(DETAIL_LINE_H, h + 4)
end

local function DetailRowOnEnter(self)
    if self._anItemID then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self._anItemID)
        GameTooltip:Show()
    end
end

local function DetailRowOnMouseUp(self)
    local itemID = self._anItemID
    if not itemID then return end
    local _, link = C_Item.GetItemInfo(itemID)
    if link then
        HandleModifiedItemClick(link)
    end
end

--- RecipeCompanionWindow.lua data row: Factory:CreateDataRow + icon + name (left) + value (right).
local function AddDataRow(child, yOffset, rowIndex, icon, label, value, itemID)
    local F = Factory()
    local row
    row, yOffset = F:CreateDataRow(child, yOffset, rowIndex, DETAIL_ROW_H)
    local tex = row:CreateTexture(nil, "ARTWORK")
    ns.UI_TableKit.ApplyIcon(tex, icon, 18)
    tex:SetPoint("LEFT", DETAIL_PAD, 0)

    local right = FontManager:CreateFontString(row, "body", "OVERLAY")
    right:SetPoint("RIGHT", row, "RIGHT", -DETAIL_PAD, 0)
    right:SetJustifyH("RIGHT")
    right:SetWordWrap(false)
    right:SetText(value or "")

    local nameText = FontManager:CreateFontString(row, "body", "OVERLAY")
    nameText:SetPoint("LEFT", tex, "RIGHT", 6, 0)
    nameText:SetPoint("RIGHT", right, "LEFT", -8, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    nameText:SetText(label or "")
    ns.UI_SetTextColorRole(nameText, "Bright")

    if itemID then
        row._anItemID = itemID
        row:EnableMouse(true)
        row:SetScript("OnEnter", DetailRowOnEnter)
        row:SetScript("OnLeave", ListRowOnLeave)
        row:SetScript("OnMouseUp", DetailRowOnMouseUp)
    end
    return yOffset
end

RefreshRight = function(self)
    local svc = ns.RecipeService
    if not svc then return end
    local vp = self.right.vp
    local child = vp.scrollChild

    local sid = self.selectedSpellID
    local bagGen = svc.GetBagCacheGeneration and svc:GetBagCacheGeneration() or 0
    if rightPaintCache.spellID == sid and rightPaintCache.bagGen == bagGen and child._anPainted then
        return
    end
    Win().SyncScrollChildWidth(vp)
    ClearDetail(child)
    child._anPainted = true
    rightPaintCache.spellID = sid
    rightPaintCache.bagGen = bagGen

    if not sid then
        --- One hint for the empty detail pane.
        local yOffset = AddTextLine(child, DETAIL_PAD, Wrap(RoleHex("Muted"), T("RECIPE_MATCHER_SELECT_HINT", "Choose a recipe")))
        child:SetHeight(yOffset + DETAIL_PAD)
        Win().SyncScroll(vp)
        return
    end

    local refreshCb = RequestRightRefresh
    local name = svc:GetRecipeName(sid) or ("spell:" .. sid)
    local bagCounts = self._bagCounts or svc:GetBagCounts()
    local rows, craftable = svc:MatchReagents(sid, bagCounts)
    local prof = svc:GetProfession(sid) or ""

    -- Title block: recipe name (+ Ready) and profession.
    local yOffset = DETAIL_PAD
    local title = FontManager:CreateFontString(child, "title", "OVERLAY")
    title:SetPoint("TOPLEFT", DETAIL_PAD, -yOffset)
    title:SetPoint("RIGHT", child, "RIGHT", -DETAIL_PAD, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    local line = Wrap(RoleHex("Bright"), name)
    if craftable then
        line = line .. "  " .. Wrap(GreenHex(), "+ " .. T("RECIPE_MATCHER_READY", "Ready"))
    end
    title:SetText(line)
    yOffset = yOffset + math.max(DETAIL_LINE_H + 4, (title:GetStringHeight() or 0) + 4)
    if prof ~= "" then
        local sub = FontManager:CreateFontString(child, "small", "OVERLAY")
        sub:SetPoint("TOPLEFT", DETAIL_PAD, -yOffset)
        sub:SetPoint("RIGHT", child, "RIGHT", -DETAIL_PAD, 0)
        sub:SetJustifyH("LEFT")
        sub:SetText(ProfessionLabel(prof))
        ns.UI_SetTextColorRole(sub, "Muted")
        yOffset = yOffset + DETAIL_LINE_H
    end

    local rowCounter = 0

    -- Output
    yOffset = AddSectionHeader(child, yOffset, T("HUB_CRAFT_OUTPUT", "Output"))
    local outputID = svc:GetOutputItem(sid)
    if outputID then
        local outPrice = svc:EstimateOutputValue(sid)
        rowCounter = rowCounter + 1
        yOffset = AddDataRow(child, yOffset, rowCounter, ItemIcon(outputID),
            Wrap(GoldHex(), T("RECIPE_MATCHER_PRODUCES_LABEL", "Produces:")) .. " " .. ItemName(outputID, refreshCb),
            Money(outPrice) or Wrap(RoleHex("Dim"), T("RECIPE_MATCHER_NO_AH_PRICE", "no AH price")),
            outputID)
    else
        yOffset = AddTextLine(child, yOffset, Wrap(RoleHex("Dim"),
            T("RECIPE_MATCHER_PRODUCES_UNKNOWN", "Unknown until the profession is opened.")))
    end

    -- Reagents
    yOffset = AddSectionHeader(child, yOffset, T("HUB_COL_REAGENTS", "Reagents"))
    if #rows == 0 then
        yOffset = AddTextLine(child, yOffset, Wrap(RoleHex("Muted"),
            T("RECIPE_MATCHER_NO_SCHEMATIC", "No reagent data. Open this profession once.")))
        child:SetHeight(yOffset + DETAIL_PAD)
        Win().SyncScroll(vp)
        return
    end

    -- Reagent cost summary (+ margin vs output value)
    local cost, missing = svc:EstimateReagentCost(sid)
    local costLabel = T("RECIPE_MATCHER_REAGENT_COST_LABEL", "Reagent AH cost:")
    if cost then
        local txt = Wrap(RoleHex("Muted"), costLabel) .. " " .. (Money(cost) or "-")
        if missing > 0 then
            txt = txt .. " " .. Wrap(RoleHex("Dim"), string.format(T("RECIPE_MATCHER_UNPRICED_FMT", "(%d unpriced)"), missing))
        end
        local marginText = ""
        local out = svc:EstimateOutputValue(sid)
        if out and cost > 0 then
            local margin = out - cost
            local pct = math.floor((margin / cost) * 100 + 0.5)
            local hex = (margin >= 0) and GreenHex() or RedHex()
            marginText = Wrap(hex, ((margin >= 0) and "+" or "") .. SignedMoney(margin) .. string.format(" (%+d%%)", pct))
        end
        rowCounter = rowCounter + 1
        yOffset = AddDataRow(child, yOffset, rowCounter, 133784, txt, marginText, nil)
    else
        yOffset = AddTextLine(child, yOffset, Wrap(RoleHex("Dim"),
            T("RECIPE_MATCHER_REAGENT_COST_SCAN_HINT", "Sync AH prices to price reagents.")))
    end

    table.sort(rows, function(a, b) return (a.short > 0) and not (b.short > 0) end)
    local needFmt = T("RECIPE_MATCHER_NEED_FMT", "(need %d)")
    for i = 1, #rows do
        local r = rows[i]
        local priceTxt = ""
        if ns.AHPriceService and ns.AHPriceService.GetPrice then
            local p = ns.AHPriceService:GetPrice(r.itemID)
            if p then priceTxt = "  " .. Wrap(RoleHex("Dim"), Money(p * r.qty) or "") end
        end
        local value
        if r.short == 0 then
            value = Wrap(GreenHex(), r.have) .. Wrap(RoleHex("Bright"), " / " .. r.qty) .. priceTxt
        else
            value = Wrap(RedHex(), r.have) .. Wrap(RoleHex("Bright"), " / " .. r.qty)
                .. "  " .. Wrap(RedHex(), string.format(needFmt, r.short)) .. priceTxt
        end
        rowCounter = rowCounter + 1
        yOffset = AddDataRow(child, yOffset, rowCounter, ItemIcon(r.itemID, refreshCb),
            ItemName(r.itemID, refreshCb), value, r.itemID)
    end

    child:SetHeight(yOffset + DETAIL_PAD)
    Win().SyncScroll(vp)
end

--==========================================================================
-- Public API
--==========================================================================

local function SyncActionButtons(self, includeFiltered)
    SetButtonEnabled(self.btnShopSelected, self.selectedSpellID ~= nil)
    if includeFiltered then
        SetButtonEnabled(self.btnShopFiltered, #self:CollectFilteredSpellIDs() > 0)
    end
end

function RecipeMatcherUI:RefreshSelection()
    if not self.main or not self.main:IsShown() then return end
    local sid = self.selectedSpellID
    local rows = self.left and self.left.pool and self.left.pool.rows
    if rows then
        for i = 1, #rows do
            local row = rows[i]
            if row and row:IsShown() and row._anSpellID then
                PaintRowSelected(row, row._anSpellID == sid)
            end
        end
    end
    local svc = ns.RecipeService
    if svc then
        self._bagCounts = svc:GetBagCounts()
    end
    RefreshRight(self)
    SyncActionButtons(self, false)
end

function RecipeMatcherUI:Refresh(opts)
    opts = opts or {}
    if not self.main or not self.main:IsShown() then return end
    if opts.selectionOnly then
        self:RefreshSelection()
        return
    end

    local svc = ns.RecipeService
    if svc then
        self._bagCounts = svc:GetBagCounts(opts.forceBagScan)
    end

    if opts.rightOnly then
        RefreshRight(self)
        SyncActionButtons(self, false)
        return
    end

    UpdateStatus(self)
    if self.main.mode == "bag" then
        RefreshLeft_Bag(self)
    else
        RefreshLeft_Recipe(self)
    end
    if not opts.leftOnly then
        RefreshRight(self)
    end
    SyncActionButtons(self, true)
end

function RecipeMatcherUI:Hide()
    if self.main then
        self.main:Hide()
    end
end

function RecipeMatcherUI:Toggle()
    if self.main and self.main:IsShown() then
        self.main:Hide()
    else
        self:Show()
    end
end

--- Open the Recipe Matcher.
---@param opts table|nil `{ tileAfter = Frame }`: tile beside the window it was opened from.
function RecipeMatcherUI:Show(opts)
    self:Init()
    if not self.main then return end
    Win().Present(self.main, type(opts) == "table" and opts or nil)
end
