--[[
    Artisan Nexus — Hub UI (Profitability / Shopping List / Crafting Queue).

    Single themed window with three tabs powered by:
      * ProfitabilityService:ListRecipes
      * ShoppingListService:Aggregate
      * CraftingQueueService:GetQueue

    Each tab refreshes when its source SendMessage fires (see ns.Constants.EVENTS):
      AN_AH_PRICES_UPDATED       -> Profitability + Shopping
      AN_AH_SCAN_COMPLETE        -> Craft Briefing rebuild
      AN_CRAFT_BRIEFING_UPDATED  -> Hub briefing banner
      AN_SHOPPING_LIST_UPDATED   -> Shopping
      AN_CRAFT_QUEUE_UPDATED     -> Queue

    Slash: /an hub  (registered in Core after this file loads).
]]

local ADDON_NAME, ns = ...

local tinsert = table.insert

local L = ns.L

local E = ns.Constants and ns.Constants.EVENTS

local ArtisanHubUI = {}
local FRAME = nil
local CURRENT_TAB = "profit"

local function NormalizeHubTab(key)
    if key == "profit" or key == "shop" or key == "queue" then
        return key
    end
    return "profit"
end

local function RestoreHubTabFromProfile()
    local db = ns.db and ns.db.profile
    if db and db.hubActiveTab then
        CURRENT_TAB = NormalizeHubTab(db.hubActiveTab)
    end
end

--- SharedWidgets loads before this file per TOC; alias directly.
local Apply = ns.UI_ApplyVisuals

local function Colors() return ns.UI_COLORS or {} end

local FONTS = ns.UI_FONTS or {}
local function Font(role)
    return (role and FONTS[role]) or FONTS.WINDOW_BODY or "GameFontNormal"
end

--- Forward declare — EnsureHubColumnHeader (below) calls this before its definition line.
local SetFSRole

SetFSRole = function(fs, role)
    if not fs then
        return
    end
    local c = Colors()
    local rgb = c.textNormal or { 0.82, 0.78, 0.88 }
    if role == "bright" then
        rgb = c.textBright or rgb
    elseif role == "muted" then
        rgb = c.textMuted or rgb
    elseif role == "dim" then
        rgb = c.textDim or rgb
    end
    fs:SetTextColor(rgb[1], rgb[2], rgb[3])
end

local function HexDim(text)
    if ns.CoerceUiString then
        text = ns.CoerceUiString(text, "")
    elseif type(text) ~= "string" or text == "" or (issecretvalue and issecretvalue(text)) then
        return ""
    end
    if text == "" then
        return ""
    end
    local c = Colors().textDim or { 0.58, 0.54, 0.64 }
    return string.format("|cff%02x%02x%02x%s|r",
        math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255), text)
end

local HUB_COL_DIVIDER_W = 1

local function HubLayout()
    local layout = ns.UI_LAYOUT or {}
    return {
        windowW = layout.HUB_WINDOW_WIDTH or 960,
        windowH = layout.HUB_WINDOW_HEIGHT or 640,
        rowH = layout.HUB_ROW_HEIGHT or 34,
        statusH = layout.HUB_STATUS_HEIGHT or 26,
        tabW = layout.HUB_TAB_WIDTH or 128,
        colGap = 12,
        colCostW = 105,
        colValueW = 115,
        colProfitW = 145,
        iconSz = layout.HUB_ICON_SIZE or 24,
        colHeaderH = layout.HUB_COL_HEADER_HEIGHT or 40,
        colHeaderPad = layout.HUB_COL_HEADER_PAD or 4,
    }
end

--- Column anchors for the profitability / shopping tables (right-aligned numeric cols).
local function HubGrid()
    local h = HubLayout()
    local shellPad = (ns.UI_LAYOUT and ns.UI_LAYOUT.SHELL_PAD) or 12
    local sw = (FRAME and FRAME.scroll and FRAME.scroll:GetWidth()) or (h.windowW - shellPad * 2 - 12)
    local scrollPad = 12
    local cw = sw - scrollPad
    local rightPad = 10
    local profitX = cw - rightPad - h.colProfitW
    local valueX = profitX - h.colGap - h.colValueW
    local costX = valueX - h.colGap - h.colCostW
    local iconPad = 6 + h.iconSz + 8
    local recipeW = costX - h.colGap - iconPad
    return {
        cw = cw,
        rowH = h.rowH,
        recipeW = math.max(220, recipeW),
        costX = costX,
        costW = h.colCostW,
        valueX = valueX,
        valueW = h.colValueW,
        profitX = profitX,
        profitW = h.colProfitW,
        iconSz = h.iconSz,
    }
end

local function FinishHubScroll(y)
    local grid = HubGrid()
    local contentW = FRAME.scroll and FRAME.scroll:GetWidth() or grid.cw
    FRAME.content:SetSize(contentW, math.max(40, y + grid.rowH))
    if ns.UI_SyncScrollChildWidth and FRAME.scroll and FRAME.content then
        ns.UI_SyncScrollChildWidth(FRAME.scroll, FRAME.content, 0)
    end
    if ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(FRAME.scroll)
    end
    if ns.UI_RegisterViewportDebug and FRAME then
        ns.UI_RegisterViewportDebug(FRAME.bodyHost, "hub_body_host")
        ns.UI_RegisterViewportDebug(FRAME.body, "hub_body_vp")
        ns.UI_RegisterViewportDebug(FRAME.scrollHost, "hub_scroll")
        if FRAME.barChromeHost then
            ns.UI_RegisterViewportDebug(FRAME.barChromeHost, "hub_bar")
        end
        if FRAME.scroll then
            ns.UI_RegisterViewportDebug(FRAME.scroll, "hub_scroll")
            ns.UI_RegisterViewportDebug(FRAME.scroll._anScrollBarColumn, "hub_bar")
        end
    end
end

local function HubColHeaderHeight()
    return HubLayout().colHeaderH
end

local function HubDataStartY(headerTop)
    local h = HubLayout()
    return (headerTop or 4) + h.colHeaderH + h.colHeaderPad
end

local function HideHubColumnHeader()
    if FRAME and FRAME._hubColHeader then
        FRAME._hubColHeader:Hide()
    end
end

---@param columnDefs table[] { label, x, w?, justify?, dividerAfter? }
---@param headerTop number|nil y offset from scroll child top (default 4)
local function EnsureHubColumnHeader(columnDefs, headerTop)
    if not FRAME or not FRAME.content or not columnDefs or #columnDefs < 1 then
        HideHubColumnHeader()
        return
    end
    headerTop = headerTop or 4
    local grid = HubGrid()
    local hdrH = HubColHeaderHeight()
    local hdr = FRAME._hubColHeader
    if not hdr then
        hdr = CreateFrame("Frame", nil, FRAME.content)
        hdr._fs, hdr._dividers = {}, {}
        hdr._fsN, hdr._divN = 0, 0
        hdr._bottomRule = hdr:CreateTexture(nil, "ARTWORK")
        hdr._bottomRule:SetHeight(1)
        FRAME._hubColHeader = hdr
    end
    local chrome = Colors().surfaceHeaderChrome or Colors().bgCard or { 0.10, 0.09, 0.12, 1 }
    local bdr = Colors().border or { 0.26, 0.24, 0.30, 1 }
    Apply(hdr, chrome, { bdr[1], bdr[2], bdr[3], 0.42 })
    hdr:SetSize(grid.cw, hdrH)
    hdr:ClearAllPoints()
    hdr:SetPoint("TOPLEFT", 4, -headerTop)
    hdr:Show()

    for i = 1, hdr._fsN do
        hdr._fs[i]:Hide()
    end
    hdr._fsN = 0
    for i = 1, hdr._divN do
        hdr._dividers[i]:Hide()
    end
    hdr._divN = 0

    local dividerXs = {}
    for ci = 1, #columnDefs do
        local col = columnDefs[ci]
        local n = hdr._fsN + 1
        hdr._fsN = n
        local fs = hdr._fs[n]
        if not fs then
            fs = hdr:CreateFontString(nil, "OVERLAY", Font("WINDOW_SECTION"))
            hdr._fs[n] = fs
        end
        fs:ClearAllPoints()
        fs:SetJustifyH(col.justify or "LEFT")
        if col.w and col.w > 0 then
            fs:SetWidth(col.w)
        else
            fs:SetWidth(0)
        end
        fs:SetPoint("LEFT", col.x or 8, 0)
        fs:SetText(col.label or "")
        SetFSRole(fs, "muted")
        fs:Show()
        if col.dividerAfter and col.dividerAfter > 0 then
            dividerXs[#dividerXs + 1] = col.dividerAfter
        end
    end

    local ruleC = Colors().border or { 0.26, 0.24, 0.30, 1 }
    for di = 1, #dividerXs do
        local dn = hdr._divN + 1
        hdr._divN = dn
        local tex = hdr._dividers[dn]
        if not tex then
            tex = hdr:CreateTexture(nil, "ARTWORK")
            hdr._dividers[dn] = tex
        end
        tex:SetColorTexture(ruleC[1], ruleC[2], ruleC[3], 0.35)
        tex:SetWidth(HUB_COL_DIVIDER_W)
        tex:ClearAllPoints()
        tex:SetPoint("TOP", hdr, "TOP", 0, -6)
        tex:SetPoint("BOTTOM", hdr, "BOTTOM", 0, 2)
        tex:SetPoint("LEFT", hdr, "LEFT", dividerXs[di], 0)
        tex:Show()
    end

    if hdr._bottomRule then
        hdr._bottomRule:SetColorTexture(ruleC[1], ruleC[2], ruleC[3], 0.55)
        hdr._bottomRule:ClearAllPoints()
        hdr._bottomRule:SetPoint("BOTTOMLEFT", hdr, "BOTTOMLEFT", 0, 0)
        hdr._bottomRule:SetPoint("BOTTOMRIGHT", hdr, "BOTTOMRIGHT", 0, 0)
        hdr._bottomRule:Show()
    end
end

local function HubProfitColumnHeaderDefs(grid)
    return {
        { label = (L and L["HUB_COL_RECIPE"]) or "Recipe", x = 8, justify = "LEFT" },
        {
            label = (L and L["HUB_COL_COST"]) or "Cost",
            x = grid.costX, w = grid.costW, justify = "RIGHT",
            dividerAfter = grid.costX - 4,
        },
        {
            label = (L and L["HUB_COL_VALUE"]) or "Value",
            x = grid.valueX, w = grid.valueW, justify = "RIGHT",
            dividerAfter = grid.valueX - 4,
        },
        {
            label = (L and L["HUB_COL_PROFIT"]) or "Profit",
            x = grid.profitX, w = grid.profitW, justify = "RIGHT",
            dividerAfter = grid.profitX - 4,
        },
    }
end

local function HubQueueColumnHeaderDefs(grid)
    return {
        { label = (L and L["HUB_COL_RECIPE"]) or "Recipe", x = 8, justify = "LEFT" },
        {
            label = (L and L["HUB_COL_PROGRESS"]) or "Progress",
            x = grid.valueX, w = grid.valueW + grid.profitW, justify = "RIGHT",
            dividerAfter = grid.valueX - 4,
        },
    }
end

local function HubProfOrder()
    local c = ns.Constants
    return (c and c.CRAFT_PROFESSION_FILTERS) or {
        "All", "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering",
        "Inscription", "Jewelcrafting", "Leatherworking", "Tailoring",
    }
end

local function GetHubProfessionFilter()
    local p = ns.db and ns.db.profile
    local f = p and p.hubProfessionFilter
    if type(f) == "string" and f ~= "" then
        return f
    end
    return "All"
end

local function ProfessionListOpt(filter)
    if not filter or filter == "All" then
        return nil
    end
    return filter
end

local function RefreshProfFilterButton()
    if not FRAME or not FRAME.profFilterBtn then
        return
    end
    local profLabel = (L and L["RECIPE_MATCHER_PROF_SHORT"]) or "Profession"
    local filter = GetHubProfessionFilter()
    local filterText = filter
    local plain = filter
    if filter ~= "All" then
        filterText = HexDim(filter) or filter
    end
    local display = string.format("%s: %s", profLabel, filterText)
    local plainDisplay = string.format("%s: %s", profLabel, plain)
    if ns.UI_IsNativePanelButton and ns.UI_IsNativePanelButton(FRAME.profFilterBtn) then
        if ns.UI_SetToolbarButtonText then
            ns.UI_SetToolbarButtonText(FRAME.profFilterBtn, plainDisplay)
        end
    elseif ns.UI_SetToolbarButtonText then
        ns.UI_SetToolbarButtonText(FRAME.profFilterBtn, display)
    end
    local lbl = FRAME.profFilterBtn._lbl or (FRAME.profFilterBtn.GetFontString and FRAME.profFilterBtn:GetFontString())
    if lbl and lbl.SetText and not (ns.UI_IsNativePanelButton and ns.UI_IsNativePanelButton(FRAME.profFilterBtn)) then
        lbl:SetText(display)
        SetFSRole(lbl, "bright")
    end
    if ns.UI_StylePanelButton then
        ns.UI_StylePanelButton(FRAME.profFilterBtn, { pressed = false })
    end
end

local function CycleHubProfessionFilter()
    local order = HubProfOrder()
    local current = GetHubProfessionFilter()
    local idx = 1
    for i = 1, #order do
        if order[i] == current then
            idx = i
            break
        end
    end
    idx = idx % #order + 1
    local nextFilter = order[idx]
    local p = ns.db and ns.db.profile
    if p then
        p.hubProfessionFilter = nextFilter
    end
    RefreshProfFilterButton()
    ArtisanHubUI:Refresh()
end

local function ResolveHubSessionTab()
    local p = ns.db and ns.db.profile
    local tab = p and p.lootHistoryActiveTab
    if tab and tab ~= "" then
        return tab
    end
    return nil
end

local function RefreshSessionToggle()
    if not FRAME or not FRAME.sessionToggle then
        return
    end
    local p = ns.db and ns.db.profile
    local on = p and p.hubSessionOnly
    local text = on
        and ((L and L["HUB_SESSION_ONLY_ON"]) or "Session only")
        or ((L and L["HUB_SESSION_ONLY_OFF"]) or "Bags + session")
    if ns.UI_SetToolbarButtonText then
        ns.UI_SetToolbarButtonText(FRAME.sessionToggle, text)
    end
    local lbl = FRAME.sessionToggle._lbl or (FRAME.sessionToggle.GetFontString and FRAME.sessionToggle:GetFontString())
    if lbl and lbl.SetText and not (ns.UI_IsNativePanelButton and ns.UI_IsNativePanelButton(FRAME.sessionToggle)) then
        lbl:SetText(text)
    end
    ns.UI_StyleShellTabButton(FRAME.sessionToggle, on)
end

local function LayoutHubToolbar()
    if not FRAME then
        return
    end
    if FRAME.tabBar and FRAME.tabOrder and ns.UI_LayoutStretchRow then
        local tabRow = {}
        for i = 1, #FRAME.tabOrder do
            tabRow[i] = FRAME.tabs[FRAME.tabOrder[i]]
        end
        ns.UI_LayoutStretchRow(FRAME.tabBar, tabRow, 4)
    end
    if FRAME.filterBar and FRAME.profFilterBtn and FRAME.sessionToggle and ns.UI_LayoutStretchRow then
        ns.UI_LayoutStretchRow(FRAME.filterBar, { FRAME.profFilterBtn, FRAME.sessionToggle }, 6)
    end
end

--- Shared helpers (Modules/Utilities.lua; loads before this file per TOC).
local FormatCopper = ns.FormatCopper
local ItemName = ns.GetItemDisplayName
local ItemIcon = ns.GetItemIconFileID

--- Crafted item icon, else recipe spell UI icon (enchant / no-output recipes).
local function RecipeIconTexture(spellID, outputItemID)
    if outputItemID and outputItemID > 0 then
        local fid = ItemIcon(outputItemID)
        if type(fid) == "number" and fid > 0 then
            return fid
        end
    end
    if spellID and ns.RecipeService and ns.RecipeService.GetRecipeDisplayIconFileID then
        local fid = ns.RecipeService:GetRecipeDisplayIconFileID(spellID)
        if type(fid) == "number" and fid > 0 then
            return fid
        end
    end
    return 134400
end

local function SetHubStatus(msg)
    if FRAME and FRAME.status then
        FRAME.status:SetText(msg or "")
    end
end

local function ValidGatheringTab(cat)
    if ns.LootHistoryUI and ns.LootHistoryUI.IsValidTab then
        return ns.LootHistoryUI:IsValidTab(cat)
    end
    if ns.CoerceUiString then
        cat = ns.CoerceUiString(cat, "")
    elseif type(cat) ~= "string" or cat == "" or (issecretvalue and issecretvalue(cat)) then
        return false
    end
    return cat == "fishing" or cat == "herb" or cat == "mine" or cat == "leather"
        or cat == "disenchant" or cat == "others" or cat == "crafted"
end

local function FarmTabLabel(cat)
    if not ValidGatheringTab(cat) then
        return "?"
    end
    if ns.GetGatheringTabDisplayName then
        return ns.GetGatheringTabDisplayName(cat)
    end
    if ns.SafeLocaleString then
        local lk = ({
            fishing = "LOOT_TAB_FISHING",
            herb = "LOOT_GATHER_HERB",
            mine = "LOOT_GATHER_MINE",
            leather = "LOOT_GATHER_LEATHER",
            disenchant = "LOOT_GATHER_DE",
        })[cat]
        if lk then
            local s = ns.SafeLocaleString(lk, nil)
            if s then
                return s
            end
        end
    end
    local fallbacks = {
        fishing = "Fishing",
        herb = "Herbalism",
        mine = "Mining",
        leather = "Leatherworking",
        disenchant = "Enchanting",
    }
    return fallbacks[cat] or ns.CoerceUiString(cat, "?")
end

-- ─────────────────────────────────────────────────────────────────
-- Window chrome
-- ─────────────────────────────────────────────────────────────────
local function BuildChrome()
    local h = HubLayout()
    local shellPad = (ns.UI_LAYOUT and ns.UI_LAYOUT.SHELL_PAD) or 12
    local f = CreateFrame("Frame", "ArtisanNexusHub", UIParent, "BackdropTemplate")
    f:SetSize(h.windowW, h.windowH)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:Hide()
    ns.UI_ApplyMainWindowChrome(f)
    tinsert(UISpecialFrames, "ArtisanNexusHub")

    local shell = ns.UI_CreateWindowHeader(f, {
        title = (L and L["HUB_WINDOW_TITLE"]) or "Artisan Hub",
        dragFrame = f,
        showSettings = true,
        settingsTooltip = {
            title = (L and L["LOOT_SETTINGS_TOOLTIP"]) or "Artisan Nexus settings",
        },
        utilities = {
            {
                texture = "Interface\\Icons\\INV_Misc_Book_09",
                onClick = function()
                    if ns.RecipeMatcherUI and ns.RecipeMatcherUI.Show then
                        ns.RecipeMatcherUI:Show()
                    end
                end,
                title = (L and L["LOOT_OPEN_RECIPES"]) or "Recipes",
                desc = (L and L["LOOT_OPEN_RECIPES_DESC"]) or "",
            },
        },
    })
    f.headerBar = shell.bar
    f.shell = shell
    f.titleFs = shell.title

    -- Tabs
    local tabBar = CreateFrame("Frame", nil, f)
    tabBar:SetHeight(h.rowH)
    tabBar:SetPoint("TOPLEFT", shell.bar, "BOTTOMLEFT", shellPad, -8)
    tabBar:SetPoint("TOPRIGHT", shell.bar, "BOTTOMRIGHT", -shellPad, -8)
    f.tabBar = tabBar

    f.tabs = {}
    f.tabOrder = {}
    local tabDefs = {
        { key = "profit", label = (L and L["HUB_TAB_PROFIT"]) or "Profitability" },
        { key = "shop",   label = (L and L["HUB_TAB_SHOPPING"]) or "Shopping List" },
        { key = "queue",  label = (L and L["HUB_TAB_QUEUE"]) or "Crafting Queue" },
    }
    local rowH = h.rowH - 2
    for i = 1, #tabDefs do
        local td = tabDefs[i]
        local btn = ns.UI_CreateToolbarButton and ns.UI_CreateToolbarButton(tabBar, rowH)
            or CreateFrame("Button", nil, tabBar, "BackdropTemplate")
        if not ns.UI_CreateToolbarButton then
            btn:SetHeight(rowH)
        end
        if ns.UI_SetToolbarButtonText then
            ns.UI_SetToolbarButtonText(btn, td.label)
        end
        local lbl = btn._lbl or (btn.GetFontString and btn:GetFontString())
        if lbl and lbl.SetText then
            lbl:SetText(td.label)
            btn._lbl = lbl
            SetFSRole(lbl, "bright")
        end
        btn:SetScript("OnClick", function()
            CURRENT_TAB = td.key
            if ns.db and ns.db.profile then
                ns.db.profile.hubActiveTab = td.key
            end
            ArtisanHubUI:Refresh()
        end)
        f.tabs[td.key] = btn
        f.tabOrder[#f.tabOrder + 1] = td.key
    end

    local filterBar = CreateFrame("Frame", nil, f)
    filterBar:SetHeight(h.rowH)
    filterBar:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -6)
    filterBar:SetPoint("TOPRIGHT", tabBar, "BOTTOMRIGHT", 0, -6)
    f.filterBar = filterBar

    local sessionToggle = ns.UI_CreateToolbarButton and ns.UI_CreateToolbarButton(filterBar, rowH)
        or CreateFrame("Button", nil, filterBar, "BackdropTemplate")
    if not ns.UI_CreateToolbarButton then
        sessionToggle:SetHeight(rowH)
    end
    sessionToggle._lbl = sessionToggle._lbl or (sessionToggle.GetFontString and sessionToggle:GetFontString())
    sessionToggle:SetScript("OnClick", function()
        local p = ns.db and ns.db.profile
        if not p then return end
        p.hubSessionOnly = not p.hubSessionOnly
        RefreshSessionToggle()
        ArtisanHubUI:Refresh()
    end)
    sessionToggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText((L and L["HUB_SESSION_ONLY_TT"]) or "Filter Profitability to recipes craftable from session loot only.", 1, 1, 1)
        GameTooltip:Show()
    end)
    sessionToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.sessionToggle = sessionToggle

    local profFilterBtn = ns.UI_CreateToolbarButton and ns.UI_CreateToolbarButton(filterBar, rowH)
        or CreateFrame("Button", nil, filterBar, "BackdropTemplate")
    if not ns.UI_CreateToolbarButton then
        profFilterBtn:SetHeight(rowH)
    end
    profFilterBtn._lbl = profFilterBtn._lbl or (profFilterBtn.GetFontString and profFilterBtn:GetFontString())
    profFilterBtn:SetScript("OnClick", CycleHubProfessionFilter)
    profFilterBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText((L and L["HUB_PROF_FILTER_TT"]) or "Cycle craft profession filter for Profitability and Shopping.", 1, 1, 1)
        GameTooltip:Show()
    end)
    profFilterBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.profFilterBtn = profFilterBtn

    tabBar:SetScript("OnSizeChanged", LayoutHubToolbar)
    filterBar:SetScript("OnSizeChanged", LayoutHubToolbar)

    local harvestBanner = f:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    harvestBanner:SetHeight(18)
    harvestBanner:SetJustifyH("LEFT")
    harvestBanner:Hide()
    f.harvestBanner = harvestBanner

    local briefingBanner = f:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    briefingBanner:SetHeight(40)
    briefingBanner:SetJustifyH("LEFT")
    briefingBanner:SetJustifyV("TOP")
    briefingBanner:SetWordWrap(true)
    briefingBanner:Hide()
    f.briefingBanner = briefingBanner

    local bodyHost = CreateFrame("Frame", nil, f)
    bodyHost:SetPoint("TOPLEFT", filterBar, "BOTTOMLEFT", 0, -6)
    bodyHost:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -shellPad, shellPad)
    bodyHost:SetClipsChildren(true)
    f.bodyHost = bodyHost

    local body = CreateFrame("Frame", nil, bodyHost, "BackdropTemplate")
    if ns.UI_ApplyViewportInset then
        ns.UI_ApplyViewportInset(body, bodyHost)
    end
    if ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(body, Colors().bgCard, Colors().border)
    else
        Apply(body, Colors().bgCard or {0.125,0.118,0.138,1}, Colors().border or {0.40,0.36,0.48,1})
    end
    f.body = body

    local statusBar = CreateFrame("Frame", nil, body)
    statusBar:SetHeight(h.statusH)
    statusBar:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 4, 4)
    statusBar:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -4, 4)
    if ns.UI_CreateHorizontalRule then
        statusBar._rule = ns.UI_CreateHorizontalRule(statusBar)
        statusBar._rule:ClearAllPoints()
        statusBar._rule:SetPoint("TOPLEFT", statusBar, "TOPLEFT", 0, 0)
        statusBar._rule:SetPoint("TOPRIGHT", statusBar, "TOPRIGHT", 0, 0)
    end
    f.statusBar = statusBar

    local scrollHost = CreateFrame("Frame", nil, body)
    scrollHost:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    scrollHost:SetPoint("BOTTOMRIGHT", statusBar, "TOPRIGHT", 0, -2)
    scrollHost:SetClipsChildren(true)
    f.scrollHost = scrollHost

    local barChromeHost = (ns.UI_CreateScrollBarChromeHost and ns.UI_CreateScrollBarChromeHost(bodyHost, scrollHost))
        or bodyHost
    f.barChromeHost = barChromeHost

    local scroll, content = ns.UI_AttachThemedScroll(scrollHost, ns.UI_BuildExternalScrollOpts(barChromeHost, {
        padL = 6, padT = -6, padB = 6, topInset = 0, bottomInset = 0,
    }))
    f.scroll = scroll
    f.content = content
    f._rows = {}
    f._rowPool = {}

    if ns.UI_RegisterViewportDebug then
        ns.UI_RegisterViewportDebug(bodyHost, "hub_body_host")
        ns.UI_RegisterViewportDebug(body, "hub_body_vp")
        ns.UI_RegisterViewportDebug(scrollHost, "hub_scroll")
        ns.UI_RegisterViewportDebug(barChromeHost, "hub_bar")
        ns.UI_RegisterViewportDebug(scroll, "hub_scroll")
        ns.UI_RegisterViewportDebug(scroll._anScrollBarColumn, "hub_bar")
    end

    -- Status footer (dedicated bar — scroll content must not overlap)
    local status = statusBar:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    status:SetPoint("LEFT", 6, 0)
    status:SetPoint("RIGHT", -6, 0)
    status:SetJustifyH("RIGHT")
    status:SetMaxLines(2)
    status:SetWordWrap(true)
    f.status = status
    SetFSRole(status, "dim")

    RefreshProfFilterButton()
    RefreshSessionToggle()
    LayoutHubToolbar()
    return f
end

local function RefreshHubBanners()
    if not FRAME then
        return
    end
    local banner = FRAME.harvestBanner
    local briefingBanner = FRAME.briefingBanner
    local body = FRAME.body
    local filterBar = FRAME.filterBar
    local shellPad = (ns.UI_LAYOUT and ns.UI_LAYOUT.SHELL_PAD) or 12
    local anchor = filterBar
    if not anchor or not body then
        return
    end

    if banner then
        local rs = ns.RecipeService
        local show = false
        if rs and rs.GetStats then
            local stats = rs:GetStats()
            if stats.total > 0 and stats.harvested < stats.total then
                local pct = math.floor((stats.harvested / stats.total) * 100)
                local c = Colors().textMuted or { 0.72, 0.69, 0.78 }
                banner:SetTextColor(c[1], c[2], c[3])
                banner:SetText(string.format(
                    (L and L["HUB_HARVEST_BANNER_FMT"])
                        or "%d / %d recipe schematics cached (%d%%). Open any Midnight profession once.",
                    stats.harvested, stats.total, pct))
                banner:ClearAllPoints()
                banner:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -4)
                banner:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", -4, -4)
                banner:Show()
                anchor = banner
                show = true
            end
        end
        if not show then
            banner:Hide()
        end
    end

    if briefingBanner and CURRENT_TAB == "profit" then
        local briefing = ns.CraftBriefingService and ns.CraftBriefingService:GetBriefing()
        local top = briefing and briefing.top
        local equipHints = briefing and briefing.equipmentHints
        if type(top) == "table" and #top > 0 then
            local lines = { (L and L["HUB_BRIEFING_HEADER"]) or "Best crafts after last AH sync:" }
            for i = 1, math.min(3, #top) do
                local r = top[i]
                local profit = FormatCopper(r.margin) or "?"
                local line = string.format(
                    (L and L["HUB_BRIEFING_LINE_FMT"]) or "%s - %s (%s)",
                    r.name or ("Recipe " .. tostring(r.spellID)), profit, r.profession or "?")
                if r.recommendConcentration and r.concProfitDelta and r.concProfitDelta > 0 then
                    line = line .. " " .. string.format(
                        (L and L["HUB_BRIEFING_CONC_SUFFIX"]) or "(conc +%s)",
                        FormatCopper(r.concProfitDelta) or "?")
                end
                lines[#lines + 1] = line
            end
            if type(equipHints) == "table" and equipHints[1] and equipHints[1].message then
                lines[#lines + 1] = HexDim(equipHints[1].message) or equipHints[1].message
            end
            local c = Colors().textBright or { 0.95, 0.92, 0.98 }
            briefingBanner:SetTextColor(c[1], c[2], c[3])
            briefingBanner:SetText(table.concat(lines, "\n"))
            briefingBanner:ClearAllPoints()
            briefingBanner:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 4, -4)
            briefingBanner:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", -4, -4)
            briefingBanner:Show()
            anchor = briefingBanner
        else
            briefingBanner:Hide()
        end
    elseif briefingBanner then
        briefingBanner:Hide()
    end

    body:ClearAllPoints()
    body:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -6)
    body:SetPoint("BOTTOMRIGHT", FRAME, "BOTTOMRIGHT", -shellPad, shellPad)
end

local function ApplyTabState()
    if not FRAME then return end
    for key, btn in pairs(FRAME.tabs) do
        ns.UI_StyleShellTabButton(btn, key == CURRENT_TAB)
    end
end

-- ─────────────────────────────────────────────────────────────────
-- Row pool (frames are never GC'd in WoW: reuse instead of recreate).
-- Pool lives on FRAME (FRAME._rowPool / FRAME._rows) so a UI-mode reset
-- (ResetForUiMode nils FRAME) discards the whole pool with the window.
-- Rows keep generic sub-pools for their variable children:
--   row._fs  (FontStrings)  row._tex (Textures)  row._btn (Buttons)
-- Acquire helpers reconfigure and Show; release hides + clears scripts.
-- ─────────────────────────────────────────────────────────────────
local function ClearRows()
    if not FRAME then return end
    local rows = FRAME._rows
    local pool = FRAME._rowPool
    for i = #rows, 1, -1 do
        local row = rows[i]
        row:Hide()
        row:EnableMouse(false)
        row:SetScript("OnMouseUp", nil)
        row:SetScript("OnEnter", nil)
        row:SetScript("OnLeave", nil)
        row:SetScript("OnUpdate", nil)
        for j = 1, (row._fsN or 0) do
            row._fs[j]:Hide()
        end
        row._fsN = 0
        for j = 1, (row._texN or 0) do
            row._tex[j]:Hide()
        end
        row._texN = 0
        for j = 1, (row._btnN or 0) do
            local b = row._btn[j]
            b:Hide()
            b:SetScript("OnClick", nil)
        end
        row._btnN = 0
        pool[#pool + 1] = row
        rows[i] = nil
    end
end

local function NewRow(yOffset)
    local grid = HubGrid()
    local pool = FRAME._rowPool
    local row = pool[#pool]
    if row then
        pool[#pool] = nil
    else
        row = CreateFrame("Frame", nil, FRAME.content)
        row._fs, row._tex, row._btn = {}, {}, {}
        row._fsN, row._texN, row._btnN = 0, 0, 0
    end
    -- Re-style per acquire so pooled rows pick up theme changes; ApplyVisuals
    -- is idempotent and keeps the one-time BORDER_REGISTRY registration.
    local rowBg = Colors().rowBg or Colors().surfaceRowEven or { 0.05, 0.05, 0.07, 0.85 }
    local bdr = Colors().border or { 0.26, 0.24, 0.30, 1 }
    Apply(row, rowBg, { bdr[1], bdr[2], bdr[3], 0.38 })
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() and ns.UI_ApplyClassicInsetPanel then
        ns.UI_ApplyClassicInsetPanel(row)
    end
    row:SetSize(grid.cw, grid.rowH)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 4, -yOffset)
    row:Show()
    tinsert(FRAME._rows, row)
    return row
end

--- Acquire a pooled FontString on `row` (OVERLAY layer). Reused strings are
--- reset to template defaults (font object, color, anchors, width, justify).
local function RowFS(row, template)
    local n = row._fsN + 1
    row._fsN = n
    local fs = row._fs[n]
    if not fs then
        fs = row:CreateFontString(nil, "OVERLAY", template)
        fs._anTemplate = template
        row._fs[n] = fs
    else
        if fs._anTemplate ~= template then
            fs:SetFontObject(template)
            fs._anTemplate = template
        end
        fs:ClearAllPoints()
        fs:SetWidth(0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        local obj = _G[template]
        if obj and obj.GetTextColor then
            local r, g, b, a = obj:GetTextColor()
            fs:SetTextColor(r, g, b, a or 1)
        end
    end
    fs:SetText("")
    fs:Show()
    return fs
end

--- Acquire a pooled Texture on `row` (ARTWORK layer).
local function RowTex(row)
    local n = row._texN + 1
    row._texN = n
    local tex = row._tex[n]
    if not tex then
        tex = row:CreateTexture(nil, "ARTWORK")
        row._tex[n] = tex
    else
        tex:ClearAllPoints()
        tex:SetTexCoord(0, 1, 0, 1)
    end
    tex:Show()
    return tex
end

--- Acquire a pooled Button on `row` with a centered small label.
--- Caller sets size/point; colors are re-applied (ApplyVisuals is idempotent).
local function RowBtn(row, label, bg, bd, onClick)
    local n = row._btnN + 1
    row._btnN = n
    local b = row._btn[n]
    if not b then
        b = CreateFrame("Button", nil, row)
        local lbl = b:CreateFontString(nil, "OVERLAY", Font("WINDOW_TOOLBAR"))
        lbl:SetPoint("CENTER")
        b._lbl = lbl
        row._btn[n] = b
    else
        b:ClearAllPoints()
    end
    if ns.UI_StylePanelButton then
        ns.UI_StylePanelButton(b, { pressed = false })
    else
        Apply(b, bg, bd)
    end
    b._lbl:SetText(label)
    b:SetScript("OnClick", onClick)
    b:Show()
    return b
end

-- ─────────────────────────────────────────────────────────────────
-- Tab: Profitability
-- ─────────────────────────────────────────────────────────────────
local function RenderProfitability()
    ClearRows()
    local svc = ns.ProfitabilityService
    if not svc then
        SetHubStatus("ProfitabilityService not loaded")
        return
    end
    local profOpt = ProfessionListOpt(GetHubProfessionFilter())
    local listOpts = { useAverage = true, harvestedOnly = true, compareConcentration = true }
    if profOpt then
        listOpts.profession = profOpt
    end
    local rows = svc:ListRecipes(listOpts)
    local rs = ns.RecipeService
    local p = ns.db and ns.db.profile
    if p and p.hubSessionOnly and rs then
        local sessionCounts = rs:GetSessionCounts(ResolveHubSessionTab())
        local filtered = {}
        for ri = 1, #rows do
            local r = rows[ri]
            if rs:MaxCraftsForCounts(r.spellID, sessionCounts) >= 1 then
                filtered[#filtered + 1] = r
            end
        end
        rows = filtered
    end
    local grid = HubGrid()
    local headerTop = 4
    EnsureHubColumnHeader(HubProfitColumnHeaderDefs(grid), headerTop)
    local y = HubDataStartY(headerTop)

    local profitable, breakeven, losses, nodata = 0, 0, 0, 0
    local profitHoverToken = 0

    for ri = 1, #rows do
        local r = rows[ri]
        local row = NewRow(y); y = y + grid.rowH

        local icon = RowTex(row)
        icon:SetSize(grid.iconSz, grid.iconSz); icon:SetPoint("LEFT", 6, 0)
        icon:SetTexture(RecipeIconTexture(r.spellID, r.outputItem))
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        local name = RowFS(row, Font("WINDOW_BODY"))
        name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        name:SetWidth(grid.recipeW); name:SetJustifyH("LEFT"); name:SetWordWrap(false)
        name:SetText(r.name or ("Recipe " .. r.spellID))

        local costFS = RowFS(row, Font("WINDOW_BODY"))
        costFS:SetPoint("LEFT", grid.costX, 0); costFS:SetWidth(grid.costW); costFS:SetJustifyH("RIGHT")
        costFS:SetText(FormatCopper(r.cost) or HexDim("-"))

        local valFS = RowFS(row, Font("WINDOW_BODY"))
        valFS:SetPoint("LEFT", grid.valueX, 0); valFS:SetWidth(grid.valueW); valFS:SetJustifyH("RIGHT")
        local valTxt = FormatCopper(r.value) or HexDim("-")
        if r.hasHistory then valTxt = valTxt .. " " .. HexDim("~") end
        if r.fresh == false and r.outputItem then
            valTxt = valTxt .. " " .. HexDim((L and L["HUB_PRICE_STALE"]) or "*")
        end
        if r.qualityTier and r.qualityTier > 1 then
            valTxt = valTxt .. " " .. HexDim("Q" .. tostring(r.qualityTier))
        end
        valFS:SetText(valTxt)

        local pFS = RowFS(row, Font("WINDOW_BODY"))
        pFS:SetPoint("LEFT", grid.profitX, 0); pFS:SetWidth(grid.profitW); pFS:SetJustifyH("RIGHT")
        if (r.missingReagentPrices or 0) > 0 then
            --- Unpriced reagents contribute 0 to cost — the margin would be a
            --- fake fat profit. Show "no data" instead of a misleading number.
            pFS:SetText(HexDim("no data"))
            nodata = nodata + 1
        elseif r.margin and r.cost and r.cost > 0 then
            local color = (r.margin >= 0) and "|cff66ff66" or "|cffff6666"
            pFS:SetText(string.format("%s%s (%+d%%)|r",
                color, FormatCopper(r.margin) or "0", math.floor((r.marginPct or 0) + 0.5)))
            if r.margin > 0 then profitable = profitable + 1
            elseif r.margin == 0 then breakeven = breakeven + 1
            else losses = losses + 1 end
            if r.recommendConcentration and r.concProfitDelta and r.concProfitDelta > 0 then
                local pct = FormatCopper(r.concProfitDelta) or "?"
                pFS:SetText(pFS:GetText() .. " " .. HexDim(string.format(
                    (L and L["HUB_PROFIT_CONC_BADGE"]) or "conc +%s", pct)))
            end
        else
            pFS:SetText(HexDim("no data"))
            nodata = nodata + 1
        end

        -- Click → add to crafting queue +1
        row:EnableMouse(true)
        row:SetScript("OnMouseUp", function(_, btn)
            if btn == "LeftButton" and ns.CraftingQueueService then
                ns.CraftingQueueService:Add(r.spellID, 1)
                if ns.ArtisanNexus and ns.ArtisanNexus.Print then
                    ns.ArtisanNexus:Print(string.format("|cffd4af37+1 to queue:|r %s", r.name or ""))
                end
            elseif btn == "RightButton" and ns.ShoppingListService then
                ns.ShoppingListService:Add(r.spellID, 1)
                if ns.ArtisanNexus and ns.ArtisanNexus.Print then
                    ns.ArtisanNexus:Print(string.format("|cffd4af37+1 to shopping:|r %s", r.name or ""))
                end
            end
        end)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(r.name or ("Recipe " .. r.spellID), 1, 1, 1)
            if r.outputItem then GameTooltip:AddLine("Item: " .. ItemName(r.outputItem), 0.7, 0.7, 0.7) end
            if r.recommendConcentration and r.concProfitDelta and r.concProfitDelta > 0 then
                GameTooltip:AddLine(string.format(
                    (L and L["HUB_PROFIT_CONC_BADGE"]) or "conc +%s",
                    FormatCopper(r.concProfitDelta) or "?"), 0.82, 0.72, 0.35)
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffaaaaaaLeft-click: add to crafting queue|r")
            GameTooltip:AddLine("|cffaaaaaaRight-click: add to shopping list|r")
            GameTooltip:Show()
            profitHoverToken = profitHoverToken + 1
            local token = profitHoverToken
            if r.outputItem and ns.PriceHistoryUI then
                C_Timer.After(0.2, function()
                    if token ~= profitHoverToken or not self:IsMouseOver() then return end
                    ns.PriceHistoryUI:ShowPopup(r.outputItem, self, "TOPLEFT")
                end)
            end
        end)
        row:SetScript("OnLeave", function()
            profitHoverToken = profitHoverToken + 1
            GameTooltip:Hide()
            if ns.PriceHistoryUI then ns.PriceHistoryUI:HidePopup() end
        end)
    end

    local statusSuffix = ""
    if p and p.hubSessionOnly then
        statusSuffix = "  " .. HexDim((L and L["HUB_SESSION_FILTER_ACTIVE"]) or "(session materials only)")
    end
    local hubProf = GetHubProfessionFilter()
    if hubProf and hubProf ~= "All" then
        statusSuffix = statusSuffix .. "  " .. HexDim(string.format(
            (L and L["HUB_PROF_FILTER_ACTIVE"]) or "(%s only)", hubProf))
    end
    SetHubStatus(string.format(
        (L and L["HUB_STATUS_PROFIT_FMT"]) or "|cff66ff66%d profitable|r - |cffd4af37%d break-even|r - |cffff6666%d losses|r - %s%s",
        profitable, breakeven, losses,
        HexDim(string.format((L and L["HUB_STATUS_NODATA_FMT"]) or "%d no data", nodata)), statusSuffix))
    FinishHubScroll(y)
end

-- ─────────────────────────────────────────────────────────────────
-- Tab: Shopping List
-- ─────────────────────────────────────────────────────────────────
local function RenderShopping()
    ClearRows()
    HideHubColumnHeader()
    local svc = ns.ShoppingListService
    if not svc then SetHubStatus("ShoppingListService not loaded"); return end
    local profOpt = ProfessionListOpt(GetHubProfessionFilter())
    local aggOpts = { subtractBags = true }
    if profOpt then
        aggOpts.profession = profOpt
    end
    local entries = svc:GetEntries()
    if profOpt and ns.RecipeService then
        local rsFilter = ns.RecipeService
        local filtered = {}
        for i = 1, #entries do
            local e = entries[i]
            if rsFilter:GetProfession(e.spellID) == profOpt then
                filtered[#filtered + 1] = e
            end
        end
        entries = filtered
    end
    local agg = svc:Aggregate(aggOpts)

    local grid = HubGrid()
    local y = 4

    -- Section: queued recipes
    local hdr = NewRow(y); y = y + grid.rowH
    local h1 = RowFS(hdr, Font("WINDOW_SECTION"))
    h1:SetPoint("LEFT", 8, 0); h1:SetText((L and L["HUB_SHOPPING_RECIPES_HEADER"]) or "Recipes to craft")
    SetFSRole(h1, "muted")

    local rs = ns.RecipeService
    if #entries == 0 then
        local empty = NewRow(y); y = y + grid.rowH
        local fs = RowFS(empty, "GameFontNormal")
        fs:SetPoint("LEFT", 12, 0)
        fs:SetText(HexDim((L and L["HUB_SHOPPING_EMPTY_HINT"])
            or "List empty — Profitability tab (left-click / right-click) or Recipe Matcher (/an recipe)."))
    else
        for ei = 1, #entries do
            local e = entries[ei]
            local row = NewRow(y); y = y + grid.rowH
            local icon = RowTex(row)
            icon:SetSize(grid.iconSz, grid.iconSz); icon:SetPoint("LEFT", 6, 0)
            local outID = rs and rs:GetOutputItem(e.spellID) or nil
            icon:SetTexture(RecipeIconTexture(e.spellID, outID))
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local name = RowFS(row, Font("WINDOW_BODY"))
            name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
            name:SetWidth(math.max(240, grid.recipeW + grid.costW + 40))
            name:SetWordWrap(false); name:SetJustifyH("LEFT")
            name:SetText((rs and rs:GetRecipeName(e.spellID)) or ("Recipe " .. e.spellID))

            local count = RowFS(row, Font("WINDOW_BODY"))
            count:SetPoint("RIGHT", -80, 0); count:SetText("x" .. (e.count or 1))

            local dangerBg, dangerBd
            if ns.UI_GetSemanticButtonChrome then
                dangerBg, dangerBd = ns.UI_GetSemanticButtonChrome("danger")
            end
            local removeBtn = RowBtn(row, (L and L["HUB_REMOVE_BTN"]) or "Remove",
                dangerBg or { 0.20, 0.10, 0.10, 0.9 }, dangerBd or { 0.6, 0.2, 0.2, 0.7 },
                function() svc:Remove(e.spellID) end)
            removeBtn:SetSize(60, 18)
            removeBtn:SetPoint("RIGHT", -8, 0)
        end
    end

    -- Section: aggregated reagents
    y = y + 6
    local rhdr = NewRow(y); y = y + grid.rowH
    local rh = RowFS(rhdr, Font("WINDOW_SECTION"))
    rh:SetPoint("LEFT", 8, 0); rh:SetText((L and L["HUB_SHOPPING_REAGENTS_HEADER"]) or "Reagents to acquire (after bags)")
    SetFSRole(rh, "muted")

    local sortedAgg = {}
    for _, row in pairs(agg) do
        if (row.short or 0) > 0 then sortedAgg[#sortedAgg + 1] = row end
    end
    table.sort(sortedAgg, function(a, b)
        local ac, bc = a.cost or -1, b.cost or -1
        if ac ~= bc then return ac > bc end
        return (a.itemID or 0) < (b.itemID or 0)
    end)

    local total, missing = 0, 0
    for _, row in pairs(agg) do
        if row.cost then
            total = total + row.cost
        elseif (row.short or 0) > 0 then
            missing = missing + 1
        end
    end

    if #sortedAgg == 0 then
        local none = NewRow(y); y = y + grid.rowH
        local nfs = RowFS(none, "GameFontNormal")
        nfs:SetPoint("LEFT", 12, 0)
        nfs:SetText("|cff66ff66" .. ((L and L["HUB_SHOPPING_ALL_IN_BAGS"]) or "All reagents already in bags.") .. "|r")
    else
        for ai = 1, #sortedAgg do
            local aggRow = sortedAgg[ai]
            local r = NewRow(y); y = y + grid.rowH
            local icon = RowTex(r)
            icon:SetSize(grid.iconSz, grid.iconSz); icon:SetPoint("LEFT", 6, 0)
            icon:SetTexture(ItemIcon(aggRow.itemID))
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local name = RowFS(r, Font("WINDOW_BODY"))
            name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
            name:SetWidth(math.max(220, grid.recipeW))
            name:SetWordWrap(false); name:SetJustifyH("LEFT")
            name:SetText(ItemName(aggRow.itemID))
            local need = RowFS(r, Font("WINDOW_BODY"))
            need:SetPoint("LEFT", grid.costX, 0); need:SetWidth(grid.costW + grid.valueW)
            need:SetJustifyH("LEFT")
            need:SetText(string.format("|cffff8866need %d|r %s", aggRow.short, HexDim(string.format("(have %d)", aggRow.have or 0))))
            local cost = RowFS(r, Font("WINDOW_BODY"))
            cost:SetPoint("LEFT", grid.profitX, 0); cost:SetWidth(grid.profitW); cost:SetJustifyH("RIGHT")
            cost:SetText(FormatCopper(aggRow.cost) or HexDim("no price"))
        end
    end

    -- AH / vendor shorts (non-gatherable reagents)
    local purchaseOpts = {}
    if profOpt then
        purchaseOpts.profession = profOpt
    end
    local purchaseShorts = svc.GetPurchaseShorts and svc:GetPurchaseShorts(purchaseOpts) or {}
    if #purchaseShorts > 0 then
        y = y + 6
        local phdr = NewRow(y); y = y + grid.rowH
        local ph = RowFS(phdr, Font("WINDOW_SECTION"))
        ph:SetPoint("LEFT", 8, 0)
        ph:SetText((L and L["HUB_PURCHASE_SHORTS_HEADER"]) or "Buy on AH / vendor")
        SetFSRole(ph, "muted")

        for pi = 1, #purchaseShorts do
            local ps = purchaseShorts[pi]
            local row = NewRow(y); y = y + grid.rowH
            local icon = RowTex(row)
            icon:SetSize(grid.iconSz, grid.iconSz); icon:SetPoint("LEFT", 6, 0)
            icon:SetTexture(ItemIcon(ps.itemID))
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local name = RowFS(row, Font("WINDOW_BODY"))
            name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
            name:SetWidth(math.max(220, grid.recipeW))
            name:SetWordWrap(false); name:SetJustifyH("LEFT")
            name:SetText(ItemName(ps.itemID))
            local need = RowFS(row, Font("WINDOW_BODY"))
            need:SetPoint("LEFT", grid.costX, 0); need:SetWidth(grid.costW)
            need:SetJustifyH("LEFT")
            need:SetText(string.format("|cffff8866need %d|r", ps.short or 0))
            local cost = RowFS(row, Font("WINDOW_BODY"))
            cost:SetPoint("LEFT", grid.valueX, 0); cost:SetWidth(grid.valueW); cost:SetJustifyH("RIGHT")
            cost:SetText(FormatCopper(ps.cost) or HexDim("no price"))
            local srcLbl = RowFS(row, Font("WINDOW_BODY"))
            srcLbl:SetPoint("LEFT", grid.profitX, 0); srcLbl:SetWidth(grid.profitW); srcLbl:SetJustifyH("RIGHT")
            srcLbl:SetText(HexDim((L and L["HUB_PURCHASE_SHORTS_SOURCE"]) or "AH / vendor"))
        end
    end

    -- Farm targets: gatherable shorts linked to Session loot tabs
    local farmOpts = {}
    if profOpt then
        farmOpts.profession = profOpt
    end
    local farmTargets = svc.GetFarmTargets and svc:GetFarmTargets(farmOpts) or {}
    if #farmTargets > 0 then
        y = y + 6
        local fhdr = NewRow(y); y = y + grid.rowH
        local fh = RowFS(fhdr, Font("WINDOW_SECTION"))
        fh:SetPoint("LEFT", 8, 0)
        fh:SetText((L and L["HUB_FARM_TARGETS_HEADER"]) or "Gathering farm targets")
        SetFSRole(fh, "muted")

        for fi = 1, #farmTargets do
            local ft = farmTargets[fi]
            local row = NewRow(y); y = y + grid.rowH
            row:EnableMouse(true)
            local icon = RowTex(row)
            icon:SetSize(grid.iconSz, grid.iconSz); icon:SetPoint("LEFT", 6, 0)
            icon:SetTexture(ItemIcon(ft.itemID))
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local name = RowFS(row, Font("WINDOW_BODY"))
            name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
            name:SetWidth(math.max(220, grid.recipeW))
            name:SetWordWrap(false); name:SetJustifyH("LEFT")
            name:SetText(ItemName(ft.itemID))
            local need = RowFS(row, Font("WINDOW_BODY"))
            need:SetPoint("LEFT", grid.costX, 0); need:SetWidth(grid.costW + grid.valueW)
            need:SetJustifyH("LEFT")
            need:SetText(string.format("|cffff8866need %d|r", ft.short or 0))
            local tabLbl = RowFS(row, Font("WINDOW_BODY"))
            tabLbl:SetPoint("LEFT", grid.profitX, 0); tabLbl:SetWidth(grid.profitW); tabLbl:SetJustifyH("RIGHT")
            local lootTab = ValidGatheringTab(ft.category) and ft.category or nil
            tabLbl:SetText(HexDim(FarmTabLabel(lootTab)))
            row:SetScript("OnMouseUp", function(_, btn)
                if btn ~= "LeftButton" or not lootTab then
                    return
                end
                if ns.LootHistoryUI and ns.LootHistoryUI.Show then
                    ns.LootHistoryUI:Show(lootTab)
                end
            end)
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText((L and L["HUB_FARM_GOTO_TT"]) or "Click to open Session loot for this profession.")
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end

    FinishHubScroll(y)
    SetHubStatus(string.format((L and L["HUB_SHOPPING_TOTAL_FMT"]) or "Total: %s%s",
        FormatCopper(total) or "0",
        missing > 0 and (" " .. HexDim(string.format((L and L["HUB_SHOPPING_UNPRICED_FMT"]) or "(%d unpriced)", missing))) or ""))
end

-- ─────────────────────────────────────────────────────────────────
-- Tab: Crafting Queue
-- ─────────────────────────────────────────────────────────────────
local function RenderQueue()
    ClearRows()
    local svc = ns.CraftingQueueService
    if not svc then SetHubStatus("CraftingQueueService not loaded"); return end
    local q = svc:GetQueue()
    local rs = ns.RecipeService
    local grid = HubGrid()
    local y = 4
    local headerTop = 4

    local snapSvc = ns.ProfessionSnapshotService
    if snapSvc and snapSvc.GetChipText then
        local chip = snapSvc:GetChipText()
        if chip and chip ~= "" then
            local chipRow = NewRow(y)
            y = y + grid.rowH
            headerTop = y
            local fs = RowFS(chipRow, Font("WINDOW_META"))
            fs:SetPoint("LEFT", 10, 0)
            fs:SetPoint("RIGHT", -120, 0)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(true)
            fs:SetText(HexDim(chip))
        end
    end

    if #q > 0 then
        EnsureHubColumnHeader(HubQueueColumnHeaderDefs(grid), headerTop)
        y = math.max(y, HubDataStartY(headerTop))
    else
        HideHubColumnHeader()
    end

    if #q == 0 then
        local row = NewRow(y); y = y + grid.rowH
        local fs = RowFS(row, "GameFontNormal")
        fs:SetPoint("LEFT", 12, 0)
        fs:SetText(HexDim((L and L["HUB_QUEUE_EMPTY_HINT"])
            or "Queue empty — left-click recipes on Profitability tab to add."))
    else
        for qi = 1, #q do
            local e = q[qi]
            local row = NewRow(y); y = y + grid.rowH
            row:EnableMouse(true)
            local icon = RowTex(row)
            icon:SetSize(grid.iconSz, grid.iconSz); icon:SetPoint("LEFT", 6, 0)
            local outID = rs and rs:GetOutputItem(e.spellID) or nil
            icon:SetTexture(RecipeIconTexture(e.spellID, outID))
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local name = RowFS(row, Font("WINDOW_BODY"))
            name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
            name:SetWidth(math.max(260, grid.recipeW + grid.costW - 40))
            name:SetWordWrap(false); name:SetJustifyH("LEFT")
            name:SetText((rs and rs:GetRecipeName(e.spellID)) or ("Recipe " .. e.spellID))

            local progress = RowFS(row, Font("WINDOW_BODY"))
            progress:SetPoint("LEFT", grid.valueX, 0); progress:SetWidth(grid.valueW)
            local pColor = (e.progress >= e.target) and "|cff66ff66" or "|cffd4af37"
            progress:SetText(string.format("%s%d/%d|r", pColor, e.progress, e.target))

            -- Up / Down / Remove buttons (pooled on the row)
            local function SmallBtn(label, dx, fn, dangerous)
                local bg, bd
                if ns.UI_GetSemanticButtonChrome then
                    bg, bd = ns.UI_GetSemanticButtonChrome(dangerous and "danger" or "neutral")
                else
                    bg = dangerous and {0.20, 0.10, 0.10, 0.9} or {0.15, 0.15, 0.18, 0.9}
                    bd = dangerous and {0.6, 0.2, 0.2, 0.7} or (Colors().accent or {0.52,0.40,0.66,1})
                end
                local b = RowBtn(row, label, bg, bd, fn)
                b:SetSize(28, 18)
                b:SetPoint("RIGHT", dx, 0)
                return b
            end
            SmallBtn("X", -8, function() svc:Remove(e.spellID) end, true)
            SmallBtn("v", -40, function() svc:Move(e.spellID, 1) end)
            SmallBtn("^", -72, function() svc:Move(e.spellID, -1) end)
            SmallBtn("+1", -110, function() svc:Add(e.spellID, 1) end)
            row:SetScript("OnMouseUp", function(_, btn)
                if btn ~= "LeftButton" then
                    return
                end
                if ns.LootHistoryUI and ns.LootHistoryUI.Show then
                    ns.LootHistoryUI:Show("crafted")
                end
            end)
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText((L and L["HUB_QUEUE_GOTO_LOOT_TT"]) or "Click to open Crafted session loot.")
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end

    FinishHubScroll(y)
    local sum = svc:GetSummary()
    SetHubStatus(string.format((L and L["HUB_STATUS_QUEUE_FMT"]) or "%d recipes - %d / %d crafted (%d remaining)",
        sum.recipes, sum.completed, sum.total, sum.remaining))
end

-- ─────────────────────────────────────────────────────────────────
-- Refresh + lifecycle
-- ─────────────────────────────────────────────────────────────────
local pendingTabRefresh
local pendingTabKey

local function RenderHubTab(tabKey)
    if tabKey == "profit" then RenderProfitability()
    elseif tabKey == "shop" then RenderShopping()
    elseif tabKey == "queue" then RenderQueue() end
end

--- opts.tab: render only this tab body (defaults to CURRENT_TAB)
--- opts.skipChrome: skip session/filter/banner/tab chrome (tab body only)
function ArtisanHubUI:Refresh(opts)
    opts = opts or {}
    if not FRAME or not FRAME:IsShown() then return end
    local tabKey = opts.tab or CURRENT_TAB
    if not opts.skipChrome then
        LayoutHubToolbar()
        RefreshSessionToggle()
        RefreshProfFilterButton()
        RefreshHubBanners()
        ApplyTabState()
    end
    RenderHubTab(tabKey)
end

local function ScheduleTabRefresh(tabKey)
    if not FRAME or not FRAME:IsShown() then return end
    if tabKey and tabKey ~= CURRENT_TAB then
        return
    end
    pendingTabKey = tabKey or CURRENT_TAB
    if pendingTabRefresh then return end
    pendingTabRefresh = true
    C_Timer.After(0, function()
        pendingTabRefresh = false
        local tk = pendingTabKey
        pendingTabKey = nil
        if FRAME and FRAME:IsShown() and (not tk or tk == CURRENT_TAB) then
            ArtisanHubUI:Refresh({ tab = tk or CURRENT_TAB, skipChrome = true })
        end
    end)
end

function ArtisanHubUI:ResetForUiMode()
    if FRAME then
        FRAME:Hide()
        FRAME = nil
    end
end

function ArtisanHubUI:RefreshTheme()
    if not FRAME then
        return
    end
    if ns.UI_ApplyMainWindowChrome then
        ns.UI_ApplyMainWindowChrome(FRAME)
    end
    if ns.UI_RefreshWindowHeader then
        ns.UI_RefreshWindowHeader(FRAME.headerBar)
    end
    if FRAME:IsShown() then
        if FRAME.body and ns.UI_StylePanelInset then
            ns.UI_StylePanelInset(FRAME.body, Colors().bgCard, Colors().border)
        end
        if FRAME.statusBar and FRAME.statusBar._rule and FRAME.statusBar._rule.RefreshRuleColor then
            FRAME.statusBar._rule:RefreshRuleColor()
        end
        self:Refresh()
        if FRAME.scroll and ns.UI_FinishScrollLayout then
            ns.UI_FinishScrollLayout(FRAME.scroll)
        end
    end
end

function ArtisanHubUI:EnsureFrameSize()
    if not FRAME then
        return
    end
    local h = HubLayout()
    FRAME:SetSize(h.windowW, h.windowH)
end

function ArtisanHubUI:Hide()
    if FRAME then
        FRAME:Hide()
    end
end

function ArtisanHubUI:Toggle()
    if not FRAME then FRAME = BuildChrome(); RefreshSessionToggle() end
    self:EnsureFrameSize()
    if FRAME:IsShown() then
        FRAME:Hide()
    else
        RestoreHubTabFromProfile()
        if ns.UI_PresentCraftWindow then
            ns.UI_PresentCraftWindow(FRAME, "hub")
        else
            if ns.UI_CloseSiblingCraftWindows then
                ns.UI_CloseSiblingCraftWindows("hub")
            end
            FRAME:Show()
        end
        self:Refresh()
    end
end

function ArtisanHubUI:Show(tabKeyOrOpts)
    if not FRAME then FRAME = BuildChrome(); RefreshSessionToggle() end
    self:EnsureFrameSize()
    local tabKey, tileAfter
    if type(tabKeyOrOpts) == "table" then
        tabKey = tabKeyOrOpts.tabKey
        tileAfter = tabKeyOrOpts.tileAfter
    else
        tabKey = tabKeyOrOpts
    end
    if tabKey and tabKey ~= "" then
        CURRENT_TAB = NormalizeHubTab(tabKey)
        if ns.db and ns.db.profile then
            ns.db.profile.hubActiveTab = CURRENT_TAB
        end
    else
        RestoreHubTabFromProfile()
    end
    if ns.UI_PresentCraftWindow then
        ns.UI_PresentCraftWindow(FRAME, "hub", tileAfter and { tileAfter = tileAfter } or nil)
    else
        if ns.UI_CloseSiblingCraftWindows then
            ns.UI_CloseSiblingCraftWindows("hub")
        end
        FRAME:Show()
    end
    self:Refresh()
end

-- Subscribe to live updates
local listener = CreateFrame("Frame")
local function HookMessages()
    if ArtisanHubUI._eventOwner then return end
    local owner = ns.NewEventOwner("ArtisanHubUI")
    ArtisanHubUI._eventOwner = owner
    local function RefreshWhenShown()
        if FRAME and FRAME:IsShown() then ArtisanHubUI:Refresh() end
    end
    if E and E.AH_PRICES_UPDATED then
        owner:RegisterMessage(E.AH_PRICES_UPDATED, RefreshWhenShown)
    end
    if E and E.SHOPPING_LIST_UPDATED then
        owner:RegisterMessage(E.SHOPPING_LIST_UPDATED, function()
            ScheduleTabRefresh("shop")
        end)
    end
    if E and E.CRAFT_QUEUE_UPDATED then
        owner:RegisterMessage(E.CRAFT_QUEUE_UPDATED, function()
            ScheduleTabRefresh("queue")
        end)
    end
    if E and E.SESSION_LOOT_UPDATED then
        owner:RegisterMessage(E.SESSION_LOOT_UPDATED, function()
            if FRAME and FRAME:IsShown() and ns.db and ns.db.profile and ns.db.profile.hubSessionOnly then
                ArtisanHubUI:Refresh()
            end
        end)
    end
    if E and E.RECIPE_SCHEMATICS_UPDATED then
        owner:RegisterMessage(E.RECIPE_SCHEMATICS_UPDATED, RefreshWhenShown)
    end
    if E and E.THEME_CHANGED then
        owner:RegisterMessage(E.THEME_CHANGED, function() ArtisanHubUI:RefreshTheme() end)
    end
    if E and E.PROFESSION_SNAPSHOT_UPDATED then
        owner:RegisterMessage(E.PROFESSION_SNAPSHOT_UPDATED, RefreshWhenShown)
    end
    if E and E.CRAFT_BRIEFING_UPDATED then
        owner:RegisterMessage(E.CRAFT_BRIEFING_UPDATED, RefreshWhenShown)
    end
    if E and E.PROFESSION_EQUIPMENT_UPDATED then
        owner:RegisterMessage(E.PROFESSION_EQUIPMENT_UPDATED, RefreshWhenShown)
    end
end
listener:RegisterEvent("PLAYER_LOGIN")
listener:SetScript("OnEvent", function() C_Timer.After(2, HookMessages) end)

ns.ArtisanHubUI = ArtisanHubUI
