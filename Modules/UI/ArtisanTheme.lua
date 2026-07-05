--[[
    Artisan Nexus — theme surfaces (dark default + optional light mode).
    `profile.themeMode`: "dark" | "light" — call `ns.UI_RefreshColors()` after changes.
]]

local ADDON_NAME, ns = ...

local SURFACE_VARIANTS = {
    dark = {
        bg = { 0.065, 0.062, 0.076, 0.97 },
        bgLight = { 0.095, 0.092, 0.108, 1 },
        bgCard = { 0.078, 0.075, 0.089, 1 },
        border = { 0.26, 0.24, 0.30, 1 },
        borderLight = { 0.38, 0.35, 0.43, 1 },
        accent = { 0.44, 0.32, 0.58, 1 },
        accentDark = { 0.30, 0.22, 0.42, 1 },
        lootHeaderBg = { 0.125, 0.105, 0.155, 1 },
        lootHeaderBorder = { 0.58, 0.48, 0.72, 0.88 },
        tabActive = { 0.14, 0.11, 0.20, 1 },
        tabHover = { 0.18, 0.14, 0.25, 1 },
        tabInactive = { 0.074, 0.072, 0.084, 1 },
        textBright = { 0.96, 0.95, 0.97, 1 },
        textNormal = { 0.82, 0.80, 0.86, 1 },
        textDim = { 0.52, 0.50, 0.56, 1 },
        textMuted = { 0.72, 0.69, 0.78, 1 },
        lootQtyOn = { 0.93, 0.92, 0.96, 1 },
        lootQtyZero = { 0.48, 0.46, 0.54, 1 },
        lootCellBg = { 0.08, 0.077, 0.09, 0.92 },
        lootCellBorder = { 0.30, 0.28, 0.34, 0.40 },
        lootPickBorder = { 0.62, 0.54, 0.78 },
        --- Semantic tokens (dark values match the pre-token hardcoded literals).
        success = { 0.48, 0.80, 0.58, 1 },
        danger = { 0.60, 0.20, 0.20, 1 },
        warning = { 0.90, 0.76, 0.46, 1 },
        rowBg = { 0.05, 0.05, 0.07, 0.85 },
        sparkLine = { 0.85, 0.65, 1.0, 1 },
        sparkBar = { 0.30, 0.26, 0.36, 1 },
        sparkGrid = { 0.30, 0.26, 0.36, 1 },
    },
    light = {
        bg = { 0.88, 0.86, 0.91, 0.98 },
        bgLight = { 0.91, 0.89, 0.94, 1 },
        bgCard = { 0.90, 0.88, 0.93, 1 },
        border = { 0.72, 0.68, 0.78, 1 },
        borderLight = { 0.78, 0.74, 0.84, 1 },
        accent = { 0.48, 0.34, 0.62, 1 },
        accentDark = { 0.40, 0.28, 0.52, 1 },
        lootHeaderBg = { 0.86, 0.83, 0.90, 1 },
        lootHeaderBorder = { 0.58, 0.48, 0.72, 0.75 },
        tabActive = { 0.82, 0.76, 0.90, 1 },
        tabHover = { 0.86, 0.82, 0.92, 1 },
        tabInactive = { 0.90, 0.87, 0.93, 1 },
        textBright = { 0.08, 0.06, 0.10, 1 },
        textNormal = { 0.14, 0.12, 0.17, 1 },
        textDim = { 0.42, 0.38, 0.48, 1 },
        textMuted = { 0.32, 0.28, 0.38, 1 },
        lootQtyOn = { 0.10, 0.08, 0.12, 1 },
        lootQtyZero = { 0.55, 0.50, 0.60, 1 },
        lootCellBg = { 0.92, 0.90, 0.94, 0.98 },
        lootCellBorder = { 0.70, 0.66, 0.76, 0.65 },
        lootPickBorder = { 0.52, 0.40, 0.66 },
        --- Semantic tokens (readable counterparts on the warm broken-white ladder).
        success = { 0.12, 0.45, 0.24, 1 },
        danger = { 0.62, 0.14, 0.14, 1 },
        warning = { 0.58, 0.42, 0.10, 1 },
        rowBg = { 0.92, 0.90, 0.94, 0.90 },
        sparkLine = { 0.45, 0.28, 0.62, 1 },
        sparkBar = { 0.55, 0.48, 0.64, 1 },
        sparkGrid = { 0.66, 0.60, 0.74, 1 },
    },
}

--- Live palette (mutated in place by `UI_RefreshColors`).
local COLORS = {}

local function CopyPalette(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = { v[1], v[2], v[3], v[4] }
        end
    end
end

CopyPalette(COLORS, SURFACE_VARIANTS.dark)

local LAYOUT = {
    BASE_INDENT = 12,
    SECTION_GAP = 10,
    ROW_HEIGHT = 36,
    ICON_SIZE = 34,
    CATALOG_ICON = 44,
    CATALOG_COLS = 2,
    CATALOG_LABEL_HEIGHT = 40,
    WINDOW_WIDTH = 600,
    WINDOW_HEIGHT = 720,
    HEADER_HEIGHT = 52,
    SHELL_PAD = 12,
    SHELL_HEADER_HEIGHT = 44,
    SHELL_HEADER_HEIGHT_CLASSIC = 32,
    CLASSIC_DIALOG_INSET = 8,
    CLASSIC_TITLE_TOP_OFFSET = 12,
    CLASSIC_SHELL_TITLE_STRIP_HEIGHT = 40,
    CLASSIC_SHELL_TITLE_BODY_GAP = 4,
    CLASSIC_SHELL_CONTENT_TOP = 56,
    CLASSIC_SHELL_TITLE_WING = 28,
    CLASSIC_SHELL_TITLE_MIN_CENTER = 96,
    SHELL_LOGO_SIZE = 28,
    SHELL_TAB_HEIGHT = 30,
    LOOT_FRAME_MIN_WIDTH = 360,
    LOOT_FRAME_MIN_HEIGHT = 440,
    LOOT_FRAME_MAX_WIDTH = 960,
    LOOT_FRAME_MAX_HEIGHT = 920,
    HUB_WINDOW_WIDTH = 960,
    HUB_WINDOW_HEIGHT = 640,
    HUB_ROW_HEIGHT = 34,
    HUB_COL_HEADER_HEIGHT = 40,
    HUB_COL_HEADER_PAD = 4,
    HUB_STATUS_HEIGHT = 26,
    HUB_TAB_WIDTH = 128,
    HUB_ICON_SIZE = 24,
    MATCHER_WINDOW_WIDTH = 960,
    MATCHER_WINDOW_HEIGHT = 660,
    MATCHER_ROW_HEIGHT = 36,
    MATCHER_SECTION_HEIGHT = 28,
    MATCHER_TOOLBAR_HEIGHT = 32,
    MATCHER_ICON_SIZE = 28,
    MATCHER_TITLEBAR_HEIGHT = 52,
    MATCHER_LIST_EDGE_PAD = 4,
    MATCHER_PANE_GAP = 6,
    OVERLOAD_ROW_HEIGHT = 32,
    OVERLOAD_ICON_SIZE = 22,
    OVERLOAD_TRACKER_WIDTH = 248,
    OVERLOAD_BODY_PAD = 6,
    OVERLOAD_BODY_GAP = 6,
    OVERLOAD_ROW_GAP = 4,
    OVERLOAD_MODIFIER_HEIGHT = 16,
    OVERLOAD_DRAG_BAR_HEIGHT = 24,
    SIDECAR_WIDTH = 184,
    SIDECAR_MIN_HEIGHT = 108,
    POSTING_PANEL_WIDTH = 272,
    POSTING_PANEL_HEIGHT = 184,
    POSTING_BUTTON_HEIGHT = 26,
    LOOT_CATALOG_CELL_PAD = 8,
    SCROLL_BAR_WIDTH = 16,
    SCROLL_BAR_BUTTON_SIZE = 18,
    SCROLL_BAR_COLUMN_X_BIAS = 3,
    SCROLL_BAR_COLUMN_Y_BIAS = -1,
    SCROLLBAR_COLUMN_WIDTH = 26,
    SCROLL_GAP = 2,
    SCROLL_THUMB_MIN_HEIGHT = 24,
    SCROLL_THUMB_MAX_HEIGHT = 160,
    SCROLL_BASE_STEP = 28,
    SCROLL_SPEED_DEFAULT = 1.0,
}

--- Blizzard GameFont templates for window body text (Classic + Modern share names).
--- Primary list/body: WINDOW_BODY (not *Small*). Reserve META for status/secondary only.
local FONTS = {
    WINDOW_TITLE = "GameFontNormalLarge",
    WINDOW_SECTION = "GameFontHighlightMedium",
    WINDOW_BODY = "GameFontNormal",
    WINDOW_TOOLBAR = "GameFontNormal",
    WINDOW_META = "GameFontHighlightSmall",
    WINDOW_EMPHASIS = "GameFontNormalLarge",
}

---@param role string|nil e.g. "WINDOW_BODY", "WINDOW_META"
function ns.UI_GetWindowFont(role)
    if role and FONTS[role] then
        return FONTS[role]
    end
    return FONTS.WINDOW_BODY
end

local function ResolveThemeMode()
    local p = ns.db and ns.db.profile
    if p and p.themeMode == "light" then
        return "light"
    end
    return "dark"
end

function ns.UI_GetThemeMode()
    return ResolveThemeMode()
end

local function RefreshRegisteredBorderColors()
    local registry = ns.BORDER_REGISTRY
    if not registry then return end
    for i = 1, #registry do
        local fr = registry[i]
        if fr and fr.BorderTop then
            local br, bg
            if fr._borderType == "accent" then
                local ac = COLORS.accent or { 0.44, 0.32, 0.58, 1 }
                br = { ac[1], ac[2], ac[3], fr._borderAlpha or 0.6 }
            else
                local bd = COLORS.border or { 0.26, 0.24, 0.30, 1 }
                br = { bd[1], bd[2], bd[3], fr._borderAlpha or 0.6 }
            end
            if fr._bgType == "accentDark" then
                local ad = COLORS.accentDark or COLORS.lootHeaderBg or COLORS.bgCard
                bg = { ad[1], ad[2], ad[3], fr._bgAlpha or 1 }
            elseif fr._bgType == "bg" and fr.SetBackdropColor then
                local b = COLORS.bg or { 0.065, 0.062, 0.076, 0.97 }
                fr:SetBackdropColor(b[1], b[2], b[3], fr._bgAlpha or b[4] or 1)
            end
            if ns.UI_UpdateBorderColor and br then
                ns.UI_UpdateBorderColor(fr, br)
            end
            if bg and fr.SetBackdropColor then
                fr:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
            end
            if fr._iconTexture and COLORS.accent then
                local ac = COLORS.accent
                fr._iconTexture:SetVertexColor(ac[1], ac[2], ac[3], 1)
            end
            if fr._thumbTexture and COLORS.accent then
                local ac = COLORS.accent
                fr._thumbTexture:SetColorTexture(ac[1], ac[2], ac[3], 0.9)
            end
        end
    end
end

function ns.UI_GetControlChromeBackdrop()
    local mode = ResolveThemeMode()
    if mode == "light" then
        local c = COLORS.bgLight or { 0.91, 0.89, 0.94, 1 }
        return { c[1], c[2], c[3], 0.95 }
    end
    return { 0.08, 0.08, 0.10, 1 }
end

function ns.UI_GetControlChromeHoverBackdrop()
    local mode = ResolveThemeMode()
    local ac = COLORS.accent or { 0.44, 0.32, 0.58, 1 }
    if mode == "light" then
        return { ac[1] * 0.18 + 0.82, ac[2] * 0.18 + 0.80, ac[3] * 0.18 + 0.86, 0.92 }
    end
    return { 0.12, 0.11, 0.14, 0.95 }
end

--- Semantic action-button chrome resolved from the live palette at call time.
--- Dark values are derived so they match the pre-token hardcoded literals;
--- light values are pale washes with readable semantic borders.
---@param kind "danger"|"warning"|"neutral"
---@return table bg, table border
function ns.UI_GetSemanticButtonChrome(kind)
    local mode = ResolveThemeMode()
    if kind == "danger" then
        local d = COLORS.danger or { 0.60, 0.20, 0.20, 1 }
        if mode == "light" then
            local base = COLORS.bgLight or { 0.91, 0.89, 0.94, 1 }
            return {
                d[1] * 0.15 + base[1] * 0.85,
                d[2] * 0.15 + base[2] * 0.85,
                d[3] * 0.15 + base[3] * 0.85,
                0.95,
            }, { d[1], d[2], d[3], 0.80 }
        end
        return { d[1] * 0.33, d[2] * 0.5, d[3] * 0.5, 0.9 }, { d[1], d[2], d[3], 0.7 }
    end
    if kind == "warning" then
        local w = COLORS.warning or { 0.90, 0.76, 0.46, 1 }
        if mode == "light" then
            local base = COLORS.bgLight or { 0.91, 0.89, 0.94, 1 }
            return {
                w[1] * 0.15 + base[1] * 0.85,
                w[2] * 0.15 + base[2] * 0.85,
                w[3] * 0.12 + base[3] * 0.85,
                0.95,
            }, { w[1], w[2], w[3], 0.85 }
        end
        return { w[1] * 0.22, w[2] * 0.24, w[3] * 0.22, 1 }, { w[1], w[2], w[3], 0.85 }
    end
    -- neutral small action button
    local ac = COLORS.accent or { 0.44, 0.32, 0.58, 1 }
    if mode == "light" then
        local bg = (ns.UI_GetControlChromeBackdrop and ns.UI_GetControlChromeBackdrop())
            or { 0.91, 0.89, 0.94, 0.95 }
        return bg, { ac[1], ac[2], ac[3], 0.70 }
    end
    return { 0.15, 0.15, 0.18, 0.9 }, { ac[1], ac[2], ac[3], 1 }
end

--- `|cffRRGGBB` hex for a semantic role, resolved from the LIVE palette at call
--- time — paint code must not bake literal green/red escapes that ignore the
--- light theme (AN-UX GRAY BAN / banned-patterns table).
---@param kind "success"|"danger"|"warning"|"dim"|"muted"|"bright"
---@return string hex six lowercase hex digits (no |cff prefix)
function ns.UI_GetSemanticHex(kind)
    local c
    if kind == "success" then
        c = COLORS.success
    elseif kind == "danger" then
        c = COLORS.danger
    elseif kind == "warning" then
        c = COLORS.warning
    elseif kind == "dim" then
        c = COLORS.textDim
    elseif kind == "muted" then
        c = COLORS.textMuted
    elseif kind == "bright" then
        c = COLORS.textBright
    end
    c = c or COLORS.textNormal or { 0.82, 0.80, 0.86, 1 }
    return string.format("%02x%02x%02x",
        math.floor((c[1] or 0) * 255 + 0.5),
        math.floor((c[2] or 0) * 255 + 0.5),
        math.floor((c[3] or 0) * 255 + 0.5))
end

function ns.UI_RefreshColors()
    local mode = ResolveThemeMode()
    local src = SURFACE_VARIANTS[mode] or SURFACE_VARIANTS.dark
    CopyPalette(COLORS, src)
    RefreshRegisteredBorderColors()
    if ns.UI_RefreshScrollChrome then
        ns.UI_RefreshScrollChrome()
    end
end

---@param frame Frame
---@param width number|nil
---@param height number|nil
local function ApplyPanelBackdrop(frame, width, height)
    if width then frame:SetWidth(width) end
    if height then frame:SetHeight(height) end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_ApplyClassicDialogBackdrop then
            ns.UI_ApplyClassicDialogBackdrop(frame)
        end
        return
    end
    if ns.UI_ApplyVisuals then
        ns.UI_ApplyVisuals(frame, COLORS.bg, { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.62 })
    else
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        frame:SetBackdropColor(COLORS.bg[1], COLORS.bg[2], COLORS.bg[3], COLORS.bg[4])
        frame:SetBackdropBorderColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.6)
    end
end

ns.UI_COLORS = COLORS
ns.UI_LAYOUT = LAYOUT
ns.UI_FONTS = FONTS
ns.UI_ApplyPanelBackdrop = ApplyPanelBackdrop
ns.UI_SURFACE_VARIANTS = SURFACE_VARIANTS
