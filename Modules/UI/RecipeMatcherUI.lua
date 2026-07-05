--[[
    Artisan Nexus - Recipe Matcher window.

    Two questions, one window:
      1. "From bag"   - scan bags, list Midnight recipes whose reagents I hold.
      2. "Recipe"     - pick any cached recipe, see what you still need to farm.

    Reagent data only exists for recipes whose profession window has been
    opened at least once (see RecipeService:HarvestOpenProfession). Until
    then the list is empty - open the profession, browse once, done.
]]

local ADDON_NAME, ns = ...

local L = ns.L
local COLORS = ns.UI_COLORS
local ApplyVisuals = ns.UI_ApplyVisuals
local E = ns.Constants.EVENTS

local function Colors()
    return COLORS or ns.UI_COLORS or {}
end

---@class RecipeMatcherUI
local RecipeMatcherUI = {}
ns.RecipeMatcherUI = RecipeMatcherUI

local WINDOW_W = (ns.UI_LAYOUT and ns.UI_LAYOUT.MATCHER_WINDOW_WIDTH) or 960
local WINDOW_H = (ns.UI_LAYOUT and ns.UI_LAYOUT.MATCHER_WINDOW_HEIGHT) or 660
local PAD = 12
local LAYOUT = ns.UI_LAYOUT or {}
local LIST_EDGE_PAD = LAYOUT.MATCHER_LIST_EDGE_PAD or 4
local PANE_GAP = LAYOUT.MATCHER_PANE_GAP or 6
local FONTS = ns.UI_FONTS or {}
local function Font(role)
    return (role and FONTS[role]) or FONTS.WINDOW_BODY or "GameFontNormal"
end

--- Bottom pane anchors touch the window edge directly. Classic's ornate border
--- art needs more clearance than the plain PAD used by the modern skin — see
--- AN-UI-theme.mdc border footprint.
local function BodySafeInset(basePad)
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() and ns.UI_GetClassicShellHorizontalInset then
        return ns.UI_GetClassicShellHorizontalInset()
    end
    return basePad
end
local ROW_H = LAYOUT.MATCHER_ROW_HEIGHT or 36
local ICON_SZ = LAYOUT.MATCHER_ICON_SIZE or 28
local SECTION_H = LAYOUT.MATCHER_SECTION_HEIGHT or 28
local SECTION_GAP = 6
local TOOLBAR_H = LAYOUT.MATCHER_TOOLBAR_HEIGHT or 32
local TITLEBAR_H = LAYOUT.MATCHER_TITLEBAR_HEIGHT or 52
local LEFT_PANE_FRAC = 0.46

--- Semantic role markup resolved from the LIVE palette (light/dark safe).
local function HexRole(text, kind)
    if type(text) ~= "string" or text == "" then
        return text or ""
    end
    local hex = ns.UI_GetSemanticHex and ns.UI_GetSemanticHex(kind)
    if not hex then
        return text
    end
    return "|cff" .. hex .. text .. "|r"
end

local function HexDim(a)
    local c = COLORS and COLORS.textDim or { 0.58, 0.54, 0.64 }
    return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255)) .. (a or "") .. "|r"
end

--- SharedWidgets shell stylers load before this file per TOC; alias directly.
---@param btn Frame
---@param selected boolean
local function StyleModeTab(btn, selected)
    ns.UI_StyleShellTabButton(btn, selected)
end

--- Neutral toolbar control (profession filter / secondary actions).
---@param btn Frame
---@param highlight boolean hovered
---@param skipTextColor boolean|nil keep embedded |c...|r in label (e.g. profession picker)
local function StyleToolbarBtn(btn, highlight, skipTextColor)
    if ns.UI_StylePanelButton then
        ns.UI_StylePanelButton(btn, { pressed = highlight and true or false })
        return
    end
    ns.UI_StyleShellToolButton(btn, highlight, skipTextColor)
end

--- Row overlay fills resolved from the live palette at call time.
--- Dark keeps the white ADD-style glow values; light uses an accent wash
--- (AN-UX-readability: no white overlays / dark accent fills on light surfaces).
---@param state string "none"|"hover"|"hoverSelected"|"selected"
local function SetRowOverlay(row, state)
    if state == "none" then
        row.bg:SetColorTexture(0, 0, 0, 0)
        return
    end
    local light = ns.UI_GetThemeMode and ns.UI_GetThemeMode() == "light"
    local ac = Colors().accent or { 0.44, 0.32, 0.58, 1 }
    if state == "selected" then
        if light then
            row.bg:SetColorTexture(ac[1], ac[2], ac[3], 0.20)
        else
            row.bg:SetColorTexture(ac[1] * 0.22, ac[2] * 0.18, ac[3] * 0.28, 0.35)
        end
        return
    end
    local sel = (state == "hoverSelected")
    if light then
        row.bg:SetColorTexture(ac[1], ac[2], ac[3], sel and 0.26 or 0.14)
    else
        row.bg:SetColorTexture(1, 1, 1, sel and 0.12 or 0.06)
    end
end

local function RowSetSelected(row, on)
    row._selected = on and true or false
    if row:IsMouseOver() then
        SetRowOverlay(row, on and "hoverSelected" or "hover")
    elseif on then
        SetRowOverlay(row, "selected")
    else
        SetRowOverlay(row, "none")
    end
end

--- Async item name + icon: triggers a ContinueOnItemLoad that refreshes UI.
---@type table<number, string>
local ITEM_NAME_CACHE = {}
---@type table<number, number>
local ITEM_ICON_CACHE = {}
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
            rightPaintCache.spellID = nil
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
        ITEM_NAME_CACHE[itemID] = item:GetItemName() or ""
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

local function SetItemVisual(iconFrame, itemID, onLoad)
    if not itemID then
        iconFrame:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        return
    end
    local tex = ITEM_ICON_CACHE[itemID]
    if not tex then
        local live = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
        if live and live > 0 then
            tex = live
            ITEM_ICON_CACHE[itemID] = live
        end
    end
    if tex and tex > 0 then
        iconFrame:SetTexture(tex)
    else
        iconFrame:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        RequestItemLoad(itemID, onLoad)
    end
end

--- Prefer crafted item icon; else recipe UI icon (fileID) from harvest or live GetRecipeInfo.
--- (Must be defined after SetItemVisual: Lua 5.1 cannot forward-reference locals.)
local function SetRecipeRowIcon(rowIcon, spellID, outputItemID, recipeIconFile, onRefresh)
    local oid = outputItemID
    if oid and oid > 0 then
        SetItemVisual(rowIcon, oid, onRefresh)
        return
    end
    local fid = recipeIconFile
    if (not fid or fid <= 0) and ns.RecipeService and ns.RecipeService.GetRecipeDisplayIconFileID then
        fid = ns.RecipeService:GetRecipeDisplayIconFileID(spellID)
    end
    if type(fid) == "number" and fid > 0 then
        rowIcon:SetTexture(fid)
        return
    end
    rowIcon:SetTexture(136243)
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
    return HexDim("item:" .. tostring(itemID))
end

--- Shared money formatter (Modules/Utilities.lua; loads before this file per TOC).
local FormatCopper = ns.FormatCopper

local function CreateRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)
    row:EnableMouse(true)
    row._selected = false

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(0, 0, 0, 0)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SZ, ICON_SZ)
    row.icon:SetPoint("LEFT", row, "LEFT", LIST_EDGE_PAD + 4, 0)

    row.right = row:CreateFontString(nil, "OVERLAY", Font("WINDOW_BODY"))
    row.right:SetPoint("RIGHT", row, "RIGHT", -(LIST_EDGE_PAD + 6), 0)
    row.right:SetJustifyH("RIGHT")

    row.label = row:CreateFontString(nil, "OVERLAY", Font("WINDOW_BODY"))
    row.label:SetPoint("LEFT", row.icon, "RIGHT", 10, 0)
    row.label:SetPoint("RIGHT", row.right, "LEFT", -8, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        SetRowOverlay(self, self._selected and "hoverSelected" or "hover")
        if self.tooltipItemID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.tooltipItemID)
            GameTooltip:Show()
        elseif self.tooltipSpellID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(self.tooltipSpellID)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function(self)
        RowSetSelected(self, self._selected)
        GameTooltip:Hide()
    end)
    return row
end

local function CreateScrollList(parent)
    local host = CreateFrame("Frame", nil, parent)
    host:SetClipsChildren(true)
    local viewport = CreateFrame("Frame", nil, host, "BackdropTemplate")
    if ns.UI_ApplyViewportInset then
        ns.UI_ApplyViewportInset(viewport, host)
    end
    if ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(viewport, COLORS.bgLight, COLORS.border)
    elseif ApplyVisuals then
        ApplyVisuals(viewport, COLORS.bgLight, { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.42 })
    end

    local barChromeHost = (ns.UI_CreateScrollBarChromeHost and ns.UI_CreateScrollBarChromeHost(host, viewport))
        or host
    host.barChromeHost = barChromeHost

    local scroll, content = ns.UI_AttachThemedScroll(viewport, ns.UI_BuildExternalScrollOpts(barChromeHost, {
        padL = 6, padT = -6, padB = 6, topInset = 0, bottomInset = 0,
    }))
    scroll:SetClipsChildren(true)

    local function syncScrollWidth()
        if ns.UI_SyncScrollChildWidth then
            ns.UI_SyncScrollChildWidth(scroll, content, 0)
        else
            local w = scroll:GetWidth()
            if w and w > 8 then
                content:SetWidth(w)
            end
        end
    end
    host.syncWidth = syncScrollWidth
    scroll:SetScript("OnSizeChanged", syncScrollWidth)
    host:SetScript("OnSizeChanged", syncScrollWidth)

    host.scroll = scroll
    host.content = content
    host.viewport = viewport
    host.rows = {}
    host.sectionHeaders = {}
    if ns.UI_RegisterViewportDebug then
        ns.UI_RegisterViewportDebug(host, "recipe_host")
        ns.UI_RegisterViewportDebug(viewport, "recipe_vp")
        ns.UI_RegisterViewportDebug(barChromeHost, "recipe_bar")
        ns.UI_RegisterViewportDebug(scroll, "recipe_scroll")
        ns.UI_RegisterViewportDebug(scroll._anScrollBarColumn, "recipe_bar")
    end
    return host
end

--- Section headers double as collapse toggles. Created lazily, recycled per refresh.
local function ApplySectionHeaderChrome(hdr)
    if not hdr or not hdr.bg then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_ApplyClassicInsetPanel then
            ns.UI_ApplyClassicInsetPanel(hdr)
        end
        return
    end
    local ac = Colors().accent or { 0.44, 0.32, 0.58, 1 }
    local light = ns.UI_GetThemeMode and ns.UI_GetThemeMode() == "light"
    if light then
        hdr.bg:SetColorTexture(ac[1], ac[2], ac[3], 0.14)
    else
        hdr.bg:SetColorTexture(ac[1] * 0.12, ac[2] * 0.10, ac[3] * 0.16, 0.55)
    end
end

local function CreateSectionHeader(parent)
    local h = CreateFrame("Button", nil, parent)
    h:SetHeight(SECTION_H)
    h:EnableMouse(true)

    h.bg = h:CreateTexture(nil, "BACKGROUND")
    h.bg:SetAllPoints()
    ApplySectionHeaderChrome(h)

    h.caret = h:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    h.caret:SetPoint("LEFT", h, "LEFT", LIST_EDGE_PAD + 6, 0)
    h.caret:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3], 1)

    h.label = h:CreateFontString(nil, "OVERLAY", Font("WINDOW_SECTION"))
    h.label:SetPoint("LEFT", h.caret, "RIGHT", 6, 0)
    h.label:SetJustifyH("LEFT")
    h.label:SetWordWrap(false)

    h.right = h:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    h.right:SetPoint("RIGHT", h, "RIGHT", -(LIST_EDGE_PAD + 6), 0)
    h.right:SetJustifyH("RIGHT")
    h.right:SetWordWrap(false)

    h.label:SetPoint("RIGHT", h.right, "LEFT", -8, 0)

    h:SetScript("OnEnter", function(self)
        if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
            return
        end
        local ac = Colors().accent or { 0.44, 0.32, 0.58, 1 }
        local light = ns.UI_GetThemeMode and ns.UI_GetThemeMode() == "light"
        if light then
            self.bg:SetColorTexture(ac[1], ac[2], ac[3], 0.22)
        else
            self.bg:SetColorTexture(ac[1] * 0.18, ac[2] * 0.15, ac[3] * 0.24, 0.65)
        end
    end)
    h:SetScript("OnLeave", function(self)
        ApplySectionHeaderChrome(self)
    end)
    return h
end

local function AcquireSectionHeader(list, index, y)
    local h = list.sectionHeaders[index]
    if not h then
        h = CreateSectionHeader(list.content)
        list.sectionHeaders[index] = h
    end
    h:ClearAllPoints()
    h:SetPoint("TOPLEFT", list.content, "TOPLEFT", LIST_EDGE_PAD, y)
    h:SetPoint("RIGHT", list.content, "RIGHT", -LIST_EDGE_PAD, 0)
    h:Show()
    return h
end

local function ReleaseSectionHeaders(list)
    local sh = list.sectionHeaders
    for i = 1, #sh do
        local h = sh[i]
        if h then
            h:Hide()
            h:SetScript("OnClick", nil)
        end
    end
end

local function ReleaseRows(list)
    local rows = list.rows
    for i = 1, #rows do
        local r = rows[i]
        if r then
            r:Hide()
            r.tooltipItemID = nil
            r.tooltipSpellID = nil
            r:SetScript("OnClick", nil)
            RowSetSelected(r, false)
        end
    end
end

local function AcquireRow(list, index, y)
    local row = list.rows[index]
    if not row then
        row = CreateRow(list.content)
        list.rows[index] = row
    end
    row:ClearAllPoints()
    local yOff = y or (-(index - 1) * ROW_H)
    -- TOPLEFT + TOPRIGHT only: mixing RIGHT stretch with SetWidth causes anchor-family errors.
    row:SetPoint("TOPLEFT", list.content, "TOPLEFT", 0, yOff)
    row:SetPoint("TOPRIGHT", list.content, "TOPRIGHT", 0, yOff)
    row:Show()
    return row
end

--==========================================================================
-- Forward declarations (pane renderers are defined after Init)
--==========================================================================

local RefreshLeft_Bag, RefreshLeft_Recipe, RefreshRight
local UpdateStatus

--==========================================================================
-- Layout
--==========================================================================

function RecipeMatcherUI:Init()
    if self.main then return end

    local f = CreateFrame("Frame", "ArtisanNexusRecipeMatcher", UIParent, "BackdropTemplate")
    f:SetSize(WINDOW_W, WINDOW_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:Hide()
    --- Init re-runs after every ResetForUiMode; a duplicate UISpecialFrames
    --- entry would make one Esc press run the hide handler twice.
    local alreadySpecial = false
    for i = 1, #UISpecialFrames do
        if UISpecialFrames[i] == "ArtisanNexusRecipeMatcher" then
            alreadySpecial = true
            break
        end
    end
    if not alreadySpecial then
        tinsert(UISpecialFrames, "ArtisanNexusRecipeMatcher")
    end

    if ns.UI_ApplyMainWindowChrome then
        ns.UI_ApplyMainWindowChrome(f)
    else
        ApplyVisuals(f, COLORS.bg, { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.62 })
    end

    local shell = ns.UI_CreateWindowHeader(f, {
        title = (L and L["RECIPE_MATCHER_TITLE"]) or "Recipes",
        dragFrame = f,
        showSettings = true,
        settingsTooltip = {
            title = (L and L["LOOT_SETTINGS_TOOLTIP"]) or "Artisan Nexus settings",
        },
        utilities = {
            {
                texture = "Interface\\Icons\\INV_Misc_Coin_01",
                onClick = function()
                    if ns.ArtisanHubUI and ns.ArtisanHubUI.Show then
                        ns.ArtisanHubUI:Show()
                    end
                end,
                title = (L and L["LOOT_OPEN_HUB"]) or "Hub",
                desc = (L and L["LOOT_OPEN_HUB_DESC"]) or "",
            },
        },
    })
    self.shell = shell
    f.headerBar = shell.bar
    f.title = shell.title

    f.status = f:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    f.status:SetPoint("TOPLEFT", shell.bar, "BOTTOMLEFT", PAD + 4, -4)
    f.status:SetPoint("TOPRIGHT", shell.bar, "BOTTOMRIGHT", -(PAD + 4), -4)
    f.status:SetHeight(22)
    f.status:SetJustifyH("LEFT")
    f.status:SetMaxLines(1)
    f.status:SetWordWrap(false)

    --- Toolbar row 1: mode tabs + scan (no profession cram on same line).
    local toolRow1 = CreateFrame("Frame", nil, f)
    toolRow1:SetHeight(TOOLBAR_H)
    toolRow1:SetPoint("TOPLEFT", f.status, "BOTTOMLEFT", 0, -6)
    toolRow1:SetPoint("TOPRIGHT", f.status, "BOTTOMRIGHT", 0, -6)

    --- Toolbar row 2: profession filter full width.
    local toolRow2 = CreateFrame("Frame", nil, f)
    toolRow2:SetHeight(TOOLBAR_H)
    toolRow2:SetPoint("TOPLEFT", toolRow1, "BOTTOMLEFT", 0, -6)
    toolRow2:SetPoint("TOPRIGHT", toolRow1, "BOTTOMRIGHT", 0, -6)

    local function makeToolbarBtn(parent)
        local b = ns.UI_CreateToolbarButton and ns.UI_CreateToolbarButton(parent, TOOLBAR_H - 2)
            or CreateFrame("Button", nil, parent, "BackdropTemplate")
        if not ns.UI_CreateToolbarButton then
            b:SetHeight(TOOLBAR_H - 2)
            local fs = b:CreateFontString(nil, "OVERLAY", Font("WINDOW_TOOLBAR"))
            fs:SetPoint("CENTER", 0, 0)
            b:SetFontString(fs)
            b._lbl = fs
        end
        return b
    end

    local tabFromBag = makeToolbarBtn(toolRow1)
    if ns.UI_SetToolbarButtonText then
        ns.UI_SetToolbarButtonText(tabFromBag, (L and L["RECIPE_MATCHER_TAB_BAG"]) or "From bag")
    end

    local tabRecipe = makeToolbarBtn(toolRow1)
    local tabRecipeLabel = (L and L["RECIPE_MATCHER_TAB_RECIPE"]) or "By recipe"
    if ns.UI_SetToolbarButtonText then
        ns.UI_SetToolbarButtonText(tabRecipe, tabRecipeLabel)
    end

    f.profFilter = "All"
    local profBtn = makeToolbarBtn(toolRow2)
    local function profBtnUpdate()
        local pl = (L and L["RECIPE_MATCHER_PROF_SHORT"]) or "Profession"
        local text = string.format("%s: %s", pl, HexDim(f.profFilter))
        local plain = string.format("%s: %s", pl, f.profFilter)
        if ns.UI_IsNativePanelButton and ns.UI_IsNativePanelButton(profBtn) then
            if ns.UI_SetToolbarButtonText then
                ns.UI_SetToolbarButtonText(profBtn, plain)
            end
        elseif ns.UI_SetToolbarButtonText then
            ns.UI_SetToolbarButtonText(profBtn, text)
        else
            local fs = profBtn:GetFontString()
            if fs then fs:SetText(text) end
        end
    end
    profBtnUpdate()

    local PROF_ORDER = (ns.Constants and ns.Constants.CRAFT_PROFESSION_FILTERS) or {
        "All",
        "Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering",
        "Inscription", "Jewelcrafting", "Leatherworking", "Tailoring",
    }
    profBtn:SetScript("OnClick", function()
        local idx = 1
        for i = 1, #PROF_ORDER do if PROF_ORDER[i] == f.profFilter then idx = i; break end end
        idx = idx % #PROF_ORDER + 1
        f.profFilter = PROF_ORDER[idx]
        profBtnUpdate()
        RecipeMatcherUI:Refresh()
    end)
    profBtn:SetScript("OnEnter", function()
        StyleToolbarBtn(profBtn, true, true)
    end)
    profBtn:SetScript("OnLeave", function()
        StyleToolbarBtn(profBtn, false, true)
    end)

    local harvestBtn = makeToolbarBtn(toolRow1)
    if ns.UI_SetToolbarButtonText then
        ns.UI_SetToolbarButtonText(harvestBtn, (L and L["RECIPE_MATCHER_HARVEST"]) or "Scan")
    end
    harvestBtn:SetScript("OnClick", function()
        local svc = ns.RecipeService
        if not svc then return end
        if svc.IsHarvestChunkActive and svc:IsHarvestChunkActive() then
            return
        end
        local function onDone(n)
            if n == 0 and ns.ArtisanNexus then
                ns.ArtisanNexus:Print((L and L["RECIPE_MATCHER_NO_PROF_OPEN"])
                    or "Open a profession window first, then click Scan Now.")
            end
            InvalidateListCaches()
            RecipeMatcherUI:Refresh()
        end
        local started = svc.HarvestOpenProfessionChunked and svc:HarvestOpenProfessionChunked(onDone)
        if not started then
            onDone(0)
        end
    end)
    harvestBtn:SetScript("OnEnter", function()
        StyleToolbarBtn(harvestBtn, true)
    end)
    harvestBtn:SetScript("OnLeave", function()
        StyleToolbarBtn(harvestBtn, false)
    end)

    local function layoutToolbar()
        local w1 = toolRow1:GetWidth() or (WINDOW_W - PAD * 2)
        if w1 < 200 then return end
        if ns.UI_LayoutStretchRow then
            ns.UI_LayoutStretchRow(toolRow1, { tabFromBag, tabRecipe, harvestBtn }, 6)
            ns.UI_LayoutStretchRow(toolRow2, { profBtn }, 0)
        end
    end

    --- Left: recipe list. Bottom x matches the toolbar chain's left edge
    --- (PAD + 4) — a mismatched second left anchor skews the pane rect.
    local left = CreateScrollList(f)
    local bottomSafePad = BodySafeInset(PAD)
    left:SetPoint("TOPLEFT", toolRow2, "BOTTOMLEFT", 0, -PAD)
    left:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", bottomSafePad + 4, bottomSafePad)
    left:SetWidth(math.floor(WINDOW_W * LEFT_PANE_FRAC))

    local divider
    if ns.UI_CreatePaneDivider then
        divider = ns.UI_CreatePaneDivider(f)
    else
        divider = CreateFrame("Frame", nil, f)
        divider:SetWidth(1)
        local divTex = divider:CreateTexture(nil, "ARTWORK")
        divTex:SetAllPoints()
        divTex:SetColorTexture(COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.55)
        divider._dividerTex = divTex
        divider.RefreshDividerColor = function() end
    end
    divider:SetPoint("TOPLEFT", left, "TOPRIGHT", PANE_GAP, 0)
    divider:SetPoint("BOTTOMLEFT", left, "BOTTOMRIGHT", PANE_GAP, 0)
    f.paneDivider = divider

    --- Right: sticky title + scroll
    local rightOuter = CreateFrame("Frame", nil, f, "BackdropTemplate")
    rightOuter:SetPoint("TOPLEFT", divider, "TOPRIGHT", PANE_GAP, 0)
    --- Mirror the toolbar right edge (PAD + 4) so both panes sit symmetric
    --- under the rows above.
    rightOuter:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(bottomSafePad + 4), bottomSafePad)
    rightOuter:SetClipsChildren(true)
    if ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(rightOuter, COLORS.bgCard, COLORS.border)
    end
    f.rightOuter = rightOuter

    local rightTitleBar = CreateFrame("Frame", nil, rightOuter, "BackdropTemplate")
    rightTitleBar:SetHeight(TITLEBAR_H)
    rightTitleBar:SetPoint("TOPLEFT", LIST_EDGE_PAD, -LIST_EDGE_PAD)
    rightTitleBar:SetPoint("TOPRIGHT", -LIST_EDGE_PAD, -LIST_EDGE_PAD)
    if ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(rightTitleBar, COLORS.bgLight, COLORS.border)
    elseif ApplyVisuals then
        ApplyVisuals(rightTitleBar, COLORS.bgCard, { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.45 })
    end

    local rightDetailTitle = rightTitleBar:CreateFontString(nil, "OVERLAY", Font("WINDOW_SECTION"))
    rightDetailTitle:SetPoint("TOPLEFT", rightTitleBar, "TOPLEFT", 12, -8)
    rightDetailTitle:SetPoint("RIGHT", rightTitleBar, "RIGHT", -12, 0)
    rightDetailTitle:SetJustifyH("LEFT")
    rightDetailTitle:SetWordWrap(false)
    rightDetailTitle:SetMaxLines(1)

    local rightDetailSub = rightTitleBar:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    rightDetailSub:SetPoint("TOPLEFT", rightDetailTitle, "BOTTOMLEFT", 0, -1)
    rightDetailSub:SetPoint("RIGHT", rightTitleBar, "RIGHT", -10, 0)
    rightDetailSub:SetJustifyH("LEFT")
    rightDetailSub:SetMaxLines(1)
    rightDetailSub:SetWordWrap(false)

    --- Shopping list actions (service layer only; no secure macro).
    local shopBar = CreateFrame("Frame", nil, rightOuter)
    shopBar:SetHeight(TOOLBAR_H)
    shopBar:SetPoint("TOPLEFT", rightTitleBar, "BOTTOMLEFT", LIST_EDGE_PAD, -6)
    shopBar:SetPoint("TOPRIGHT", rightTitleBar, "BOTTOMRIGHT", -LIST_EDGE_PAD, -6)
    if ns.UI_CreateHorizontalRule then
        shopBar._rule = ns.UI_CreateHorizontalRule(shopBar)
        shopBar._rule:SetPoint("BOTTOMLEFT", shopBar, "BOTTOMLEFT", 0, 0)
        shopBar._rule:SetPoint("BOTTOMRIGHT", shopBar, "BOTTOMRIGHT", 0, 0)
    end

    local function makeShopBtn()
        return makeToolbarBtn(shopBar)
    end

    local btnShopSelected = makeShopBtn()
    local btnShopFiltered = makeShopBtn()

    --- Modern skin has no template disabled art: without this, a dead
    --- "Add selected" looks fully clickable (Classic grays out natively).
    for _, sb in ipairs({ btnShopSelected, btnShopFiltered }) do
        sb:SetScript("OnDisable", function(self) self:SetAlpha(0.45) end)
        sb:SetScript("OnEnable", function(self) self:SetAlpha(1) end)
    end

    local function layoutShopBar()
        if ns.UI_LayoutStretchRow then
            ns.UI_LayoutStretchRow(shopBar, { btnShopSelected, btnShopFiltered }, 6)
        end
    end
    shopBar:SetScript("OnSizeChanged", layoutShopBar)

    local function shopBarTip(btn, title, body)
        btn:SetScript("OnEnter", function(self)
            StyleToolbarBtn(self, true)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(title, 1, 1, 1)
            if body and body ~= "" then
                GameTooltip:AddLine(body, 0.75, 0.75, 0.8, true)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            StyleToolbarBtn(self, false)
            GameTooltip:Hide()
        end)
    end

    local shopSelLabel = (L and L["RECIPE_MATCHER_SHOP_ADD_SELECTED"]) or "Add selected"
    local shopFilLabel = (L and L["RECIPE_MATCHER_SHOP_ADD_FILTERED"]) or "Add all filtered"
    if ns.UI_SetToolbarButtonText then
        ns.UI_SetToolbarButtonText(btnShopSelected, shopSelLabel)
        ns.UI_SetToolbarButtonText(btnShopFiltered, shopFilLabel)
    end
    StyleToolbarBtn(btnShopSelected, false)
    StyleToolbarBtn(btnShopFiltered, false)

    shopBarTip(btnShopSelected, shopSelLabel,
        (L and L["RECIPE_MATCHER_SHOP_TT_SELECTED"]) or "Adds the highlighted recipe on the left (count +1).")
    shopBarTip(btnShopFiltered, shopFilLabel,
        (L and L["RECIPE_MATCHER_SHOP_TT_FILTERED"]) or "Adds every recipe in the current list (profession filter; both tabs).")

    btnShopSelected:SetScript("OnClick", function()
        local sid = RecipeMatcherUI.selectedSpellID
        if not sid or not ns.ShoppingListService then return end
        ns.ShoppingListService:Add(sid, 1)
        if ns.ArtisanNexus and ns.ArtisanNexus.Print then
            local nm = (ns.RecipeService and ns.RecipeService.GetRecipeName and ns.RecipeService:GetRecipeName(sid)) or ("#" .. tostring(sid))
            if not nm or (issecretvalue and issecretvalue(nm)) then nm = "#" .. tostring(sid) end
            ns.ArtisanNexus:Print(string.format((L and L["RECIPE_MATCHER_SHOP_ONE_FMT"]) or "|cffd4af37+1 shopping:|r %s", nm))
        end
    end)
    btnShopFiltered:SetScript("OnClick", function()
        if not ns.ShoppingListService or not ns.ShoppingListService.AddMany then return end
        local ids = RecipeMatcherUI:CollectFilteredSpellIDs()
        if #ids == 0 then
            if ns.ArtisanNexus and ns.ArtisanNexus.Print then
                ns.ArtisanNexus:Print((L and L["RECIPE_MATCHER_SHOP_NONE"]) or "Nothing to add for the current filter.")
            end
            return
        end
        local n = ns.ShoppingListService:AddMany(ids, 1)
        if ns.ArtisanNexus and ns.ArtisanNexus.Print and n > 0 then
            ns.ArtisanNexus:Print(string.format((L and L["RECIPE_MATCHER_SHOP_BATCH_FMT"]) or "|cffd4af37Shopping list:|r merged %d recipe(s).", n))
        end
    end)

    local right = CreateScrollList(rightOuter)
    right:SetPoint("TOPLEFT", shopBar, "BOTTOMLEFT", 0, -6)
    right:SetPoint("BOTTOMRIGHT", rightOuter, "BOTTOMRIGHT", -LIST_EDGE_PAD, LIST_EDGE_PAD)

    --- Tab state
    f.mode = "bag"
    local function refreshModeTabs()
        local bagSel = f.mode == "bag"
        StyleModeTab(tabFromBag, bagSel)
        StyleModeTab(tabRecipe, not bagSel)
    end
    RecipeMatcherUI.refreshModeTabs = refreshModeTabs

    local function setMode(m)
        if f.mode == m then return end
        f.mode = m
        RecipeMatcherUI.selectedSpellID = nil
        refreshModeTabs()
        RecipeMatcherUI:Refresh()
    end
    tabFromBag:SetScript("OnClick", function() setMode("bag") end)
    tabRecipe:SetScript("OnClick", function() setMode("recipe") end)
    refreshModeTabs()
    StyleToolbarBtn(profBtn, false, true)
    StyleToolbarBtn(harvestBtn, false)

    toolRow1:SetScript("OnSizeChanged", layoutToolbar)
    toolRow2:SetScript("OnSizeChanged", layoutToolbar)
    f:HookScript("OnShow", function()
        layoutToolbar()
        layoutShopBar()
        if left.syncWidth then left.syncWidth() end
        if right.syncWidth then right.syncWidth() end
        RecipeMatcherUI:Refresh()
    end)
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            layoutToolbar()
            layoutShopBar()
        end)
    end

    self.main = f
    self.left = left
    self.right = right
    self.rightTitleBar = rightTitleBar
    self.rightDetailTitle = rightDetailTitle
    self.rightDetailSub = rightDetailSub
    self.toolbarTabBar = toolRow1
    self.toolRow2 = toolRow2
    self.tabFromBag = tabFromBag
    self.tabRecipe = tabRecipe
    self.profBtn = profBtn
    self.harvestBtn = harvestBtn
    self.layoutToolbar = layoutToolbar
    self.layoutShopBar = layoutShopBar
    self.shopBar = shopBar
    self.btnShopSelected = btnShopSelected
    self.btnShopFiltered = btnShopFiltered
    self.selectedSpellID = nil

    if not RecipeMatcherUI._eventOwner then
        RecipeMatcherUI._eventOwner = ns.NewEventOwner("RecipeMatcherUI")
    end
    local owner = RecipeMatcherUI._eventOwner
    owner:RegisterMessage(E.RECIPE_SCHEMATICS_UPDATED, function()
        InvalidateListCaches()
        local main = RecipeMatcherUI.main
        if main and main:IsShown() then RecipeMatcherUI:Refresh() end
    end)
    if E.PROFESSION_SNAPSHOT_UPDATED then
        owner:RegisterMessage(E.PROFESSION_SNAPSHOT_UPDATED, function()
            local main = RecipeMatcherUI.main
            if main and main:IsShown() then RecipeMatcherUI:Refresh() end
        end)
    end
    if E.THEME_CHANGED then
        owner:RegisterMessage(E.THEME_CHANGED, function()
            RecipeMatcherUI:RefreshTheme()
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

    self:LayoutClassicShellChrome()
end

function RecipeMatcherUI:LayoutClassicShellChrome()
    local f = self.main
    if not f then
        return
    end
    if ns.UI_RefreshClassicMainWindowShell then
        ns.UI_RefreshClassicMainWindowShell(f)
    elseif f.headerBar and ns.UI_RefreshWindowHeader then
        ns.UI_RefreshWindowHeader(f.headerBar)
    end
    if f.status and ns.UI_AnchorClassicShellBodyRow then
        ns.UI_AnchorClassicShellBodyRow(f.status, f, f.headerBar, PAD + 4, 4)
    end
end

function RecipeMatcherUI:ResetForUiMode()
    if self.main then
        self.main:Hide()
        --- Discarded chrome must leave BORDER_REGISTRY (infra MUST).
        if ns.UI_UnregisterVisuals then
            ns.UI_UnregisterVisuals(self.main)
        end
        self.main = nil
    end
end

function RecipeMatcherUI:RefreshTheme()
    if not self.main then return end
    --- Painted strings carry palette-resolved hex — force both panes to
    --- repaint with the new theme's colors.
    rightPaintCache.spellID = nil
    rightPaintCache.bagGen = -1
    if ns.UI_ApplyMainWindowChrome then
        ns.UI_ApplyMainWindowChrome(self.main)
    end
    if ns.UI_RefreshWindowHeader then
        ns.UI_RefreshWindowHeader(self.main.headerBar)
    end
    self:LayoutClassicShellChrome()
    if self.main.title then
        if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
            self.main.title:SetTextColor(1, 0.82, 0)
        else
            local c = Colors()
            self.main.title:SetTextColor(c.textBright[1], c.textBright[2], c.textBright[3])
        end
    end
    if self.refreshModeTabs then
        self.refreshModeTabs()
    end
    if self.profBtn then
        StyleToolbarBtn(self.profBtn, false, true)
    end
    if self.harvestBtn then
        StyleToolbarBtn(self.harvestBtn, false)
    end
    if self.main.paneDivider and self.main.paneDivider.RefreshDividerColor then
        self.main.paneDivider:RefreshDividerColor()
    end
    if self.main.rightOuter and ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(self.main.rightOuter, Colors().bgCard, Colors().border)
    end
    if self.rightTitleBar and ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(self.rightTitleBar, Colors().bgLight, Colors().border)
    end
    if self.left and self.left.viewport and ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(self.left.viewport, Colors().bgLight, Colors().border)
    end
    if self.right and self.right.viewport and ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(self.right.viewport, Colors().bgLight, Colors().border)
    end
    if self.shopBar and self.shopBar._rule and self.shopBar._rule.RefreshRuleColor then
        self.shopBar._rule:RefreshRuleColor()
    end
    if self.left and self.left.scroll and ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(self.left.scroll)
    end
    if self.right and self.right.scroll and ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(self.right.scroll)
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
        statusFs:SetText((L and L["RECIPE_MATCHER_HARVEST_ONBOARDING"])
            or "Open any Midnight profession window once, then click Scan to cache recipes.")
        local warn = Colors().textMuted or { 0.85, 0.75, 0.45 }
        statusFs:SetTextColor(warn[1], warn[2], warn[3])
        return
    end
    local pct = (stats.total > 0) and math.floor((stats.harvested / stats.total) * 100) or 100
    if stats.total > 0 and stats.harvested < stats.total then
        statusFs:SetText(string.format(
            (L and L["RECIPE_MATCHER_STATUS_PARTIAL"]) or "%d / %d recipes cached (%d%%) - open professions to learn more.",
            stats.harvested, stats.total, pct))
    else
        statusFs:SetText(string.format(
            (L and L["RECIPE_MATCHER_STATUS_LINE"]) or "%d / %d recipes cached - open a profession to learn more.",
            stats.harvested, stats.total))
    end
    local dim = Colors().textDim or { 0.58, 0.54, 0.64 }
    statusFs:SetTextColor(dim[1], dim[2], dim[3])
    local snapSvc = ns.ProfessionSnapshotService
    if snapSvc and snapSvc.GetChipText then
        local chip = snapSvc:GetChipText()
        if chip and chip ~= "" then
            statusFs:SetText(statusFs:GetText() .. "  |  " .. chip)
        end
    end
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

local function ToggleCollapse(prof)
    RecipeMatcherUI.collapsed[prof] = not RecipeMatcherUI.collapsed[prof]
end

local function ConfigureSectionHeader(hdr, prof, label, right)
    ApplySectionHeaderChrome(hdr)
    local collapsed = IsCollapsed(prof)
    hdr.caret:SetText(collapsed and ">" or "v")
    hdr.caret:SetTextColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.9)
    hdr.label:SetText(label)
    hdr.label:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3], 1)
    hdr.right:SetText(right or "")
    hdr.right:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3], 0.95)
    hdr:SetScript("OnClick", function()
        ToggleCollapse(prof)
        RecipeMatcherUI:Refresh({ leftOnly = true })
    end)
end

local function OnRecipeRowClick(spellID)
    if RecipeMatcherUI.selectedSpellID == spellID then
        return
    end
    RecipeMatcherUI.selectedSpellID = spellID
    RecipeMatcherUI:RefreshSelection()
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

local function PaintBagRow(self, list, entry, rowIndex, y)
    local row = AcquireRow(list, rowIndex, y)
    SetRecipeRowIcon(row.icon, entry.spellID, entry.outputItemID, entry.recipeIcon, RequestFullRefresh)
    local label = entry.name ~= "" and entry.name or ("spell:" .. entry.spellID)
    local suc = Colors().success or { 0.48, 0.80, 0.58, 1 }
    if entry.craftable then
        row.label:SetText(string.format("|cff%02x%02x%02x%s|r",
            math.floor(suc[1] * 255), math.floor(suc[2] * 255), math.floor(suc[3] * 255), label))
    else
        row.label:SetText(label)
    end
    row.right:SetText(string.format("%d/%d", entry.matched, entry.total))
    if entry.craftable then
        row.right:SetTextColor(suc[1], suc[2], suc[3])
    else
        row.right:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3])
    end
    row.tooltipSpellID = entry.spellID
    local sid = entry.spellID
    row:SetScript("OnClick", function() OnRecipeRowClick(sid) end)
    RowSetSelected(row, RecipeMatcherUI.selectedSpellID == sid)
end

local function PaintRecipeRow(self, list, entry, rowIndex, y)
    local row = AcquireRow(list, rowIndex, y)
    SetRecipeRowIcon(row.icon, entry.spellID, entry.outputItemID, entry.recipeIcon, RequestFullRefresh)
    if entry.cached then
        row.label:SetText(entry.name)
        row.right:SetText("")
    else
        row.label:SetText(HexDim(entry.name))
        row.right:SetText(HexDim("?"))
    end
    row.tooltipSpellID = entry.spellID
    local sid = entry.spellID
    row:SetScript("OnClick", function() OnRecipeRowClick(sid) end)
    RowSetSelected(row, RecipeMatcherUI.selectedSpellID == sid)
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
            rightText = string.format(
                (L and L["RECIPE_MATCHER_READY_TOTAL_FMT"]) or "%d ready / %d total",
                craftableCount, #g)
        else
            rightText = string.format(
                (L and L["RECIPE_MATCHER_CACHED_FMT"]) or "%d / %d cached",
                cachedCount, #g)
        end
        queue[#queue + 1] = { kind = "header", prof = prof, label = prof, right = rightText }
        if not IsCollapsed(prof) then
            for ei = 1, #g do
                queue[#queue + 1] = { kind = "row", entry = g[ei], mode = mode }
            end
        end
        queue[#queue + 1] = { kind = "gap" }
    end
    return queue
end

local function PaintLeftQueue(self, queue, gen, qi, y, rowIndex, sectionIndex)
    if gen ~= leftDrawGen then
        return
    end
    local list = self.left
    local limit = math.min(qi + LEFT_DRAW_CHUNK - 1, #queue)
    for i = qi, limit do
        local item = queue[i]
        if item.kind == "header" then
            sectionIndex = sectionIndex + 1
            local hdr = AcquireSectionHeader(list, sectionIndex, y)
            ConfigureSectionHeader(hdr, item.prof, item.label, item.right)
            y = y - SECTION_H - 2
        elseif item.kind == "row" then
            rowIndex = rowIndex + 1
            if item.mode == "bag" then
                PaintBagRow(self, list, item.entry, rowIndex, y)
            else
                PaintRecipeRow(self, list, item.entry, rowIndex, y)
            end
            y = y - ROW_H
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
    list.content:SetHeight(-y + 8)
    --- Chunked paint finishes async: bar visibility/thumb were computed against
    --- the PREVIOUS content height in RefreshLeft_*; re-run on the final chunk
    --- (modern scroll has no OnScrollRangeChanged hook — classic does).
    if ns.UI_FinishScrollLayout and list.scroll then
        ns.UI_FinishScrollLayout(list.scroll)
    end
end

local function StartLeftPaint(self, queue)
    local gen = BumpLeftDraw()
    local list = self.left
    ReleaseRows(list)
    ReleaseSectionHeaders(list)
    PaintLeftQueue(self, queue, gen, 1, -4, 0, 0)
end

--- Spell IDs for the current mode + profession filter (deduped), for shopping list batch add.
function RecipeMatcherUI:CollectFilteredSpellIDs()
    local svc = ns.RecipeService
    if not svc or not self.main then return {} end
    local filter = self.main.profFilter
    if filter == "All" then filter = nil end
    local out = {}
    local seen = {}
    if self.main.mode == "bag" then
        local bagCounts = self._bagCounts or svc:GetBagCounts()
        local results = GetBagResultsCached(svc, filter, bagCounts)
        for i = 1, #results do
            local sid = results[i].spellID
            if sid and not seen[sid] then
                seen[sid] = true
                out[#out + 1] = sid
            end
        end
    else
        local entries = GetRecipeEntriesCached(svc, filter)
        for i = 1, #entries do
            local sid = entries[i].spellID
            if sid and not seen[sid] then
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
    local list = self.left

    local filter = self.main.profFilter
    if filter == "All" then filter = nil end
    local bagCounts = self._bagCounts or svc:GetBagCounts()
    local results = GetBagResultsCached(svc, filter, bagCounts)

    if #results == 0 then
        BumpLeftDraw()
        ReleaseRows(list)
        ReleaseSectionHeaders(list)
        local row = AcquireRow(list, 1, -4)
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
        local stats = svc:GetStats()
        if stats.harvested < 1 then
            row.label:SetText(HexDim((L and L["RECIPE_MATCHER_HARVEST_ONBOARDING"])
                or "Open any Midnight profession window once, then click Scan to cache recipes."))
        else
            row.label:SetText(HexDim((L and L["RECIPE_MATCHER_EMPTY_BAG"])
                or "No bag reagents match any harvested Midnight recipe yet."))
        end
        row.right:SetText("")
        list.content:SetHeight(ROW_H + 8)
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
    local entries = GetRecipeEntriesCached(svc, filter)

    if #entries == 0 then
        --- Mirror the bag-mode empty state: a fully blank pane with no message
        --- reads as broken when the catalog is empty/unavailable.
        BumpLeftDraw()
        local list = self.left
        ReleaseRows(list)
        ReleaseSectionHeaders(list)
        local row = AcquireRow(list, 1, -4)
        row.icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
        row.label:SetText(HexDim((L and L["RECIPE_MATCHER_EMPTY_RECIPE"])
            or "No recipes for this filter yet - open a Midnight profession, then Scan."))
        row.right:SetText("")
        list.content:SetHeight(ROW_H + 8)
        if ns.UI_FinishScrollLayout and list.scroll then
            ns.UI_FinishScrollLayout(list.scroll)
        end
        return
    end

    local order, groups = GroupByProfession(entries)
    for _, g in pairs(groups) do
        table.sort(g, function(a, b) return (a.name or "") < (b.name or "") end)
    end

    StartLeftPaint(self, BuildLeftPaintQueue(order, groups, "recipe"))
end

RefreshRight = function(self)
    local svc = ns.RecipeService
    if not svc then return end
    local list = self.right
    local detailTitle = self.rightDetailTitle
    local detailSub = self.rightDetailSub

    local sid = self.selectedSpellID
    local bagGen = svc.GetBagCacheGeneration and svc:GetBagCacheGeneration() or 0
    if sid and rightPaintCache.spellID == sid and rightPaintCache.bagGen == bagGen
        and list and list.rows and #list.rows > 0 then
        return
    end

    ReleaseRows(list)

    if not sid then
        rightPaintCache.spellID = nil
        rightPaintCache.bagGen = bagGen
        if detailTitle then
            detailTitle:SetText((L and L["RECIPE_MATCHER_SELECT_HINT"]) or "Select a recipe")
        end
        if detailSub then
            detailSub:SetText("")
            detailSub:Hide()
        end
        if self.rightTitleBar then
            self.rightTitleBar:SetHeight(36)
        end
        --- In-viewport empty state: title-bar text alone leaves a large blank
        --- pane that reads as broken (and tints as a void under /an debug).
        local hintRow = AcquireRow(list, 1)
        hintRow.icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")
        hintRow.label:SetText(HexDim((L and L["RECIPE_MATCHER_EMPTY_DETAIL_HINT"])
            or "Select a recipe on the left to see reagents, cost and value."))
        hintRow.right:SetText("")
        hintRow.tooltipItemID = nil
        hintRow:SetScript("OnClick", nil)
        list.content:SetHeight(ROW_H + 8)
        return
    end

    if detailSub then
        detailSub:Show()
    end
    if self.rightTitleBar then
        self.rightTitleBar:SetHeight(TITLEBAR_H)
    end

    local name = svc:GetRecipeName(sid) or ("spell:" .. sid)
    local bagCounts = self._bagCounts or svc:GetBagCounts()
    local rows, craftable = svc:MatchReagents(sid, bagCounts)
    local prof = svc:GetProfession(sid) or ""
    if detailTitle then
        local line = name
        if craftable then
            line = line .. "  " .. HexRole("+ " .. ((L and L["RECIPE_MATCHER_READY"]) or "Ready"), "success")
        end
        detailTitle:SetText(line)
    end
    if detailSub then
        detailSub:SetText(prof ~= "" and prof or " ")
    end

    if #rows == 0 then
        local row = AcquireRow(list, 1)
        row.label:SetText((L and L["RECIPE_MATCHER_NO_SCHEMATIC"])
            or "No reagent data yet - open this profession window once to harvest.")
        row.right:SetText("")
        list.content:SetHeight(ROW_H + 8)
        return
    end

    table.sort(rows, function(a, b) return (a.short > 0) and not (b.short > 0) end)

    --- +2 leading rows reserved for output summary + separator
    local leadRows = 2
    local outputID = svc:GetOutputItem(sid)
    list.content:SetHeight((#rows + leadRows) * ROW_H + 8)

    --- Output row
    local outRow = AcquireRow(list, 1)
    outRow:ClearAllPoints()
    outRow:SetPoint("TOPLEFT", list.content, "TOPLEFT", LIST_EDGE_PAD, -4)
    outRow:SetPoint("RIGHT", list.content, "RIGHT", -LIST_EDGE_PAD, 0)
    local refreshCb = RequestRightRefresh
    if outputID then
        SetItemVisual(outRow.icon, outputID)
        local outPrice = svc:EstimateOutputValue(sid)
        outRow.label:SetText(
            HexRole((L and L["RECIPE_MATCHER_PRODUCES_LABEL"]) or "Produces:", "warning")
            .. " " .. ItemName(outputID, refreshCb))
        outRow.right:SetText(FormatCopper(outPrice)
            or HexDim((L and L["RECIPE_MATCHER_NO_AH_PRICE"]) or "no AH price"))
        outRow.tooltipItemID = outputID
    else
        local schOut = svc.GetSchematic and svc:GetSchematic(sid)
        SetRecipeRowIcon(outRow.icon, sid, nil, schOut and schOut.recipeIcon, refreshCb)
        outRow.label:SetText(HexDim((L and L["RECIPE_MATCHER_PRODUCES_UNKNOWN"])
            or "Produces: (unknown - open profession to harvest)"))
        outRow.right:SetText("")
        outRow.tooltipItemID = nil
    end
    outRow:SetScript("OnClick", nil)

    --- Reagent cost summary row
    local costRow = AcquireRow(list, 2)
    costRow:ClearAllPoints()
    costRow:SetPoint("TOPLEFT", list.content, "TOPLEFT", LIST_EDGE_PAD, -ROW_H - 4)
    costRow:SetPoint("RIGHT", list.content, "RIGHT", -LIST_EDGE_PAD, 0)
    costRow.icon:SetTexture(133784) -- coin
    local cost, missing = svc:EstimateReagentCost(sid)
    local costLabel = (L and L["RECIPE_MATCHER_REAGENT_COST_LABEL"]) or "Reagent AH cost:"
    if cost then
        local txt = HexRole(costLabel, "muted") .. " " .. (FormatCopper(cost) or "-")
        if missing > 0 then
            txt = txt .. HexDim(string.format(
                " " .. ((L and L["RECIPE_MATCHER_UNPRICED_FMT"]) or "(%d unpriced)"), missing))
        end
        costRow.label:SetText(txt)
        local out = svc:EstimateOutputValue(sid)
        if out and cost > 0 then
            local margin = out - cost
            local pct = math.floor((margin / cost) * 100 + 0.5)
            costRow.right:SetText(HexRole(string.format(
                (margin >= 0) and "+%s (%+d%%)" or "%s (%+d%%)",
                FormatCopper(margin) or "", pct),
                (margin >= 0) and "success" or "danger"))
        else
            costRow.right:SetText("")
        end
    else
        costRow.label:SetText(HexDim((L and L["RECIPE_MATCHER_REAGENT_COST_SCAN_HINT"])
            or "Reagent AH cost: run /an ah to scan prices"))
        costRow.right:SetText("")
    end
    costRow.tooltipItemID = nil
    costRow:SetScript("OnClick", nil)

    for i = 1, #rows do
        local r = rows[i]
        local row = AcquireRow(list, i + leadRows)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", list.content, "TOPLEFT", LIST_EDGE_PAD, -((i + leadRows - 1) * ROW_H) - 4)
        row:SetPoint("RIGHT", list.content, "RIGHT", -LIST_EDGE_PAD, 0)

        SetItemVisual(row.icon, r.itemID)
        row.label:SetText(ItemName(r.itemID, refreshCb))
        local priceTxt = ""
        if ns.AHPriceService and ns.AHPriceService.GetPrice then
            local p = ns.AHPriceService:GetPrice(r.itemID)
            if p then priceTxt = "  |cff888888" .. (FormatCopper(p * r.qty) or "") .. "|r" end
        end
        if r.short == 0 then
            row.right:SetText(string.format("|cff55ff55%d|r / %d%s", r.have, r.qty, priceTxt))
        else
            row.right:SetText(string.format("|cffff6666%d|r / %d  (need %d)%s", r.have, r.qty, r.short, priceTxt))
        end
        row.tooltipItemID = r.itemID
        row:SetScript("OnClick", nil)
    end

    rightPaintCache.spellID = sid
    rightPaintCache.bagGen = bagGen
end

function RecipeMatcherUI:EnsureFrameSize()
    if not self.main then
        return
    end
    self.main:SetSize(WINDOW_W, WINDOW_H)
end

function RecipeMatcherUI:RefreshSelection()
    if not self.main or not self.main:IsShown() then return end
    local sid = self.selectedSpellID
    local rows = self.left and self.left.rows
    if rows then
        for i = 1, #rows do
            local row = rows[i]
            if row and row.tooltipSpellID then
                RowSetSelected(row, row.tooltipSpellID == sid)
            end
        end
    end
    local svc = ns.RecipeService
    if svc then
        self._bagCounts = svc:GetBagCounts()
    end
    RefreshRight(self)
    if self.btnShopSelected then
        self.btnShopSelected:SetEnabled(sid ~= nil)
    end
    if self.right and self.right.scroll and ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(self.right.scroll)
    end
end

function RecipeMatcherUI:Refresh(opts)
    opts = opts or {}
    if not self.main or not self.main:IsShown() then return end
    if opts.selectionOnly then
        self:RefreshSelection()
        return
    end
    if self.left and self.left.syncWidth then self.left.syncWidth() end
    if self.right and self.right.syncWidth then self.right.syncWidth() end

    local svc = ns.RecipeService
    if svc then
        self._bagCounts = svc:GetBagCounts(opts.forceBagScan)
    end

    if opts.rightOnly then
        RefreshRight(self)
        if self.btnShopSelected then
            self.btnShopSelected:SetEnabled(self.selectedSpellID ~= nil)
        end
        if self.right and self.right.scroll and ns.UI_FinishScrollLayout then
            ns.UI_FinishScrollLayout(self.right.scroll)
        end
        return
    end

    if opts.leftOnly then
        UpdateStatus(self)
        if self.main.mode == "bag" then
            RefreshLeft_Bag(self)
        else
            RefreshLeft_Recipe(self)
        end
        if self.btnShopFiltered then
            local ids = self:CollectFilteredSpellIDs()
            self.btnShopFiltered:SetEnabled(#ids > 0)
        end
        if self.left and self.left.scroll and ns.UI_FinishScrollLayout then
            ns.UI_FinishScrollLayout(self.left.scroll)
        end
        return
    end

    UpdateStatus(self)
    if self.main.mode == "bag" then
        RefreshLeft_Bag(self)
    else
        RefreshLeft_Recipe(self)
    end
    RefreshRight(self)
    if self.btnShopSelected and self.btnShopFiltered then
        local ids = self:CollectFilteredSpellIDs()
        self.btnShopFiltered:SetEnabled(#ids > 0)
        self.btnShopSelected:SetEnabled(self.selectedSpellID ~= nil)
    end
    if self.layoutShopBar then self.layoutShopBar() end
    if ns.UI_FinishScrollLayout then
        if self.left and self.left.scroll then ns.UI_FinishScrollLayout(self.left.scroll) end
        if self.right and self.right.scroll then ns.UI_FinishScrollLayout(self.right.scroll) end
    end
end

function RecipeMatcherUI:Hide()
    if self.main then
        self.main:Hide()
    end
end

function RecipeMatcherUI:Toggle()
    self:Init()
    self:EnsureFrameSize()
    if self.layoutToolbar then self.layoutToolbar() end
    if self.main:IsShown() then
        self.main:Hide()
    else
        if ns.UI_PresentCraftWindow then
            ns.UI_PresentCraftWindow(self.main, "recipes")
        else
            if ns.UI_CloseSiblingCraftWindows then
                ns.UI_CloseSiblingCraftWindows("recipes")
            end
            self.main:Show()
        end
    end
end

function RecipeMatcherUI:Show(arg)
    self:Init()
    self:EnsureFrameSize()
    if self.layoutToolbar then self.layoutToolbar() end
    self:LayoutClassicShellChrome()
    local opts = type(arg) == "table" and arg or nil
    if ns.UI_PresentCraftWindow then
        ns.UI_PresentCraftWindow(self.main, "recipes", opts)
    else
        if ns.UI_CloseSiblingCraftWindows then
            ns.UI_CloseSiblingCraftWindows("recipes")
        end
        self.main:Show()
    end
end

function RecipeMatcherUI:SelectRecipe(spellID)
    self:Init()
    self:EnsureFrameSize()
    if self.layoutToolbar then self.layoutToolbar() end
    if ns.UI_PresentCraftWindow then
        ns.UI_PresentCraftWindow(self.main, "recipes")
    elseif ns.UI_CloseSiblingCraftWindows then
        ns.UI_CloseSiblingCraftWindows("recipes")
        self.main:Show()
    else
        self.main:Show()
    end
    self.main.mode = "recipe"
    if self.refreshModeTabs then self.refreshModeTabs() end
    self.selectedSpellID = spellID
    self:Refresh()
end
