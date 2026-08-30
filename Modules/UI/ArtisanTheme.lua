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
        lootQtyOn = { 1, 1, 1, 1 }, -- pure white for obtained counts — GRAY BAN (AN-UX-readability.mdc)
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
    SHELL_HEADER_HEIGHT_CLASSIC = 36,
    --- Shell header control glyph buttons (close / settings); classic uses CLASSIC_SHELL_TITLE_CONTROL_SIZE.
    SHELL_CONTROL_SIZE = 22,
    CLASSIC_DIALOG_INSET = 8,
    CLASSIC_DIALOG_INSET_LEFT = 11,
    CLASSIC_DIALOG_INSET_RIGHT = 12,
    CLASSIC_DIALOG_INSET_TOP = 12,
    CLASSIC_DIALOG_INSET_BOTTOM = 11,
    CLASSIC_TITLE_TOP_OFFSET = 12,
    CLASSIC_SHELL_TITLE_TOP_OFFSET = 0,
    CLASSIC_SHELL_TITLE_STRIP_HEIGHT = 52,
    CLASSIC_SHELL_TITLE_BODY_GAP = 4,
    CLASSIC_SHELL_CONTENT_TOP = 56,
    CLASSIC_SHELL_TITLE_H_INSET = 0, -- 0 = full bleed to shell.main left/right edges
    CLASSIC_SHELL_TITLE_LEFT_PAD = 16, -- from headerBar's true left edge; clears the ornate corner accent
    CLASSIC_SHELL_TITLE_TEXT_GAP = 8,
    CLASSIC_SHELL_TITLE_LOGO_SIZE = 28,
    CLASSIC_SHELL_TITLE_CONTROL_SIZE = 24,
    CLASSIC_SHELL_TITLE_PAD_V = 5,
    CLASSIC_SHELL_TITLE_ICON_GAP = 4,
    CLASSIC_SHELL_HEADER_UTILITY_RIGHT = 18,
    CLASSIC_SHELL_TITLE_WING = 32, -- >= backdrop edgeSize (32) so the corner border art is fully covered
    --- Body content (tabs, catalog/session hosts, rows, scrollbars) must clear
    --- the ornate dialog border art. The border backdrop uses edgeSize = 32
    --- (see UI_ApplyClassicDialogBackdrop) but only insets its background fill
    --- by 11/12 — the decorative corner art itself occupies the full 32px band,
    --- so body content needs >= edgeSize clearance, not just SHELL_PAD (12) or
    --- the background fill inset, or scrollbars/rows visually cross the border
    --- (worst near corners, e.g. the bottom-right session list scrollbar cap).
    CLASSIC_SHELL_BODY_SAFE_INSET = 32,
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
    --- The tracker is a compact HUD, so it runs a shorter header than the
    --- shared SHELL_HEADER_HEIGHT full windows use.
    OVERLOAD_HEADER_HEIGHT = 32,
    OVERLOAD_ROW_HEIGHT = 28,
    OVERLOAD_ICON_SIZE = 20,
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
    LOOT_CATALOG_CELL_PAD = 8, -- interior cell padding (icon offset, rank block sizing) — keep roomy so text never clips
    LOOT_CATALOG_GRID_GAP = 5, -- gap between catalog cards (and between rows) — tighter than CELL_PAD
    LOOT_CATALOG_SIDE_PAD = 10, -- fixed left/right margin for the whole catalog grid, independent of the inter-card gap
    --- Minimum catalog card width: icon + rank block must fit atlas + count + money
    --- (embedded coin icons). PopulateCatalog drops to 1 column when 2-up would
    --- squeeze below this — prevents truncation at narrow window widths.
    LOOT_CATALOG_MIN_VALUE_W = 72,
    LOOT_CATALOG_MAX_COLS = 2,
    SCROLL_BAR_WIDTH = 16,
    SCROLL_BAR_BUTTON_SIZE = 18,
    SCROLL_BAR_COLUMN_X_BIAS = 3,
    SCROLL_BAR_COLUMN_Y_BIAS = -1,
    SCROLLBAR_COLUMN_WIDTH = 22,
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

--- Named accent presets (RGB). "default" uses the active dark/light palette accent.
local ACCENT_PRESET_RGB = {
    violet = { 0.44, 0.32, 0.58 },
    gold = { 0.78, 0.62, 0.22 },
    teal = { 0.22, 0.58, 0.54 },
    rose = { 0.72, 0.28, 0.42 },
    cobalt = { 0.28, 0.42, 0.78 },
}

ns.UI_ACCENT_PRESET_IDS = { "default", "violet", "gold", "teal", "rose", "cobalt", "custom" }

local DEFAULT_THEME_ACCENT = { 0.44, 0.32, 0.58 }

--- Derive accent ladder from a master RGB (Warband SharedWidgets_Theme parity).
function ns.UI_CalculateThemeColors(masterR, masterG, masterB)
    local function Desaturate(r, g, b, amount)
        local gray = (r + g + b) / 3
        return r + (gray - r) * amount,
            g + (gray - g) * amount,
            b + (gray - b) * amount
    end
    local function AdjustBrightness(r, g, b, factor)
        return math.min(1, r * factor),
            math.min(1, g * factor),
            math.min(1, b * factor)
    end
    local darkR, darkG, darkB = AdjustBrightness(masterR, masterG, masterB, 0.7)
    local borderR, borderG, borderB = Desaturate(masterR * 0.5, masterG * 0.5, masterB * 0.5, 0.6)
    local activeR, activeG, activeB = AdjustBrightness(masterR, masterG, masterB, 0.5)
    local hoverR, hoverG, hoverB = AdjustBrightness(masterR, masterG, masterB, 0.6)
    return {
        accent = { masterR, masterG, masterB },
        accentDark = { darkR, darkG, darkB },
        border = { borderR, borderG, borderB },
        tabActive = { activeR, activeG, activeB },
        tabHover = { hoverR, hoverG, hoverB },
    }
end

--- Class color when available; else fallback accent triple.
function ns.ResolveAccentColor(fallbackAccent)
    local fr = fallbackAccent and fallbackAccent[1]
    local fg = fallbackAccent and fallbackAccent[2]
    local fb = fallbackAccent and fallbackAccent[3]
    if type(fr) ~= "number" or type(fg) ~= "number" or type(fb) ~= "number" then
        fr, fg, fb = DEFAULT_THEME_ACCENT[1], DEFAULT_THEME_ACCENT[2], DEFAULT_THEME_ACCENT[3]
    end
    local _, classFile = UnitClass("player")
    if not classFile or classFile == "" then
        return fr, fg, fb
    end
    if C_ClassColor and C_ClassColor.GetClassColor then
        local ok, cc = pcall(C_ClassColor.GetClassColor, classFile)
        if ok and cc then
            if cc.GetRGB then
                local r, g, b = cc:GetRGB()
                if type(r) == "number" and type(g) == "number" and type(b) == "number" then
                    return r, g, b
                end
            elseif type(cc.r) == "number" and type(cc.g) == "number" and type(cc.b) == "number" then
                return cc.r, cc.g, cc.b
            end
        end
    end
    local rc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if rc and type(rc.r) == "number" and type(rc.g) == "number" and type(rc.b) == "number" then
        return rc.r, rc.g, rc.b
    end
    return fr, fg, fb
end

--- Section / settings card header accent border (subtle, not full chroma wash).
function ns.UI_GetSectionHeaderBorderRGBA()
    local ac = COLORS.accent or DEFAULT_THEME_ACCENT
    return ac[1], ac[2], ac[3], 0.45
end

local function ResolvePaletteFallbackAccent()
    local mode = ResolveThemeMode()
    local src = SURFACE_VARIANTS[mode] or SURFACE_VARIANTS.dark
    local ac = src.accent or { DEFAULT_THEME_ACCENT[1], DEFAULT_THEME_ACCENT[2], DEFAULT_THEME_ACCENT[3], 1 }
    return ac[1], ac[2], ac[3]
end

local function ResolveMasterAccentRgb()
    local p = ns.db and ns.db.profile
    if not p then
        return ResolvePaletteFallbackAccent()
    end
    local fr, fg, fb = ResolvePaletteFallbackAccent()
    if p.useClassColorAccent then
        return ns.ResolveAccentColor({ fr, fg, fb })
    end
    local preset = p.accentPreset or "default"
    if preset == "custom" and type(p.accentCustom) == "table" then
        return p.accentCustom[1] or fr, p.accentCustom[2] or fg, p.accentCustom[3] or fb
    end
    if preset ~= "default" and ACCENT_PRESET_RGB[preset] then
        local rgb = ACCENT_PRESET_RGB[preset]
        return rgb[1], rgb[2], rgb[3]
    end
    return fr, fg, fb
end

local function ApplyDerivedThemeColors(theme, masterR, masterG, masterB)
    COLORS.accent[1], COLORS.accent[2], COLORS.accent[3] = theme.accent[1], theme.accent[2], theme.accent[3]
    COLORS.accentDark[1], COLORS.accentDark[2], COLORS.accentDark[3] = theme.accentDark[1], theme.accentDark[2], theme.accentDark[3]
    COLORS.border[1], COLORS.border[2], COLORS.border[3] = theme.border[1], theme.border[2], theme.border[3]
    COLORS.tabActive[1], COLORS.tabActive[2], COLORS.tabActive[3] = theme.tabActive[1], theme.tabActive[2], theme.tabActive[3]
    COLORS.tabHover[1], COLORS.tabHover[2], COLORS.tabHover[3] = theme.tabHover[1], theme.tabHover[2], theme.tabHover[3]
    local ad = theme.accentDark
    COLORS.lootHeaderBg = {
        ad[1] * 0.85 + 0.02,
        ad[2] * 0.85 + 0.02,
        ad[3] * 0.85 + 0.02,
        1,
    }
    COLORS.lootHeaderBorder = {
        math.min(1, masterR * 1.12),
        math.min(1, masterG * 1.12),
        math.min(1, masterB * 1.12),
        0.88,
    }
    if COLORS.lootPickBorder then
        COLORS.lootPickBorder[1] = masterR
        COLORS.lootPickBorder[2] = masterG
        COLORS.lootPickBorder[3] = masterB
    end
    if ResolveThemeMode() == "light" then
        local bgL = COLORS.bgLight or COLORS.bg
        for _, key in ipairs({ "tabActive", "tabHover" }) do
            local c = COLORS[key]
            local mix = (key == "tabActive") and 0.18 or 0.14
            local surf = 1 - mix
            c[1] = c[1] * mix + bgL[1] * surf
            c[2] = c[2] * mix + bgL[2] * surf
            c[3] = c[3] * mix + bgL[3] * surf
        end
    end
end

local function ApplyAccentOverrides()
    local p = ns.db and ns.db.profile
    if not p then
        return
    end
    local preset = p.accentPreset or "default"
    if not p.useClassColorAccent and preset == "default" then
        return
    end
    local r, g, b = ResolveMasterAccentRgb()
    local theme = ns.UI_CalculateThemeColors(r, g, b)
    ApplyDerivedThemeColors(theme, r, g, b)
    p.themeColors = p.themeColors or {}
    for k, v in pairs(theme) do
        p.themeColors[k] = { v[1], v[2], v[3] }
    end
end

function ns.UI_GetAccentPresetRgb(presetKey)
    if presetKey == "custom" then
        local p = ns.db and ns.db.profile
        if p and type(p.accentCustom) == "table" then
            return p.accentCustom[1], p.accentCustom[2], p.accentCustom[3]
        end
        return 0.44, 0.32, 0.58
    end
    if presetKey == "default" then
        local mode = ResolveThemeMode()
        local src = SURFACE_VARIANTS[mode] or SURFACE_VARIANTS.dark
        local ac = src.accent or { 0.44, 0.32, 0.58, 1 }
        return ac[1], ac[2], ac[3]
    end
    local rgb = ACCENT_PRESET_RGB[presetKey]
    if rgb then
        return rgb[1], rgb[2], rgb[3]
    end
    return 0.44, 0.32, 0.58
end

local function ResolveRegistryBackdrop(frame, accentDarkColor, bgColor)
    local bgType = frame._bgType
    local bgAlpha = frame._bgAlpha or 1
    if bgType == "searchChrome" then
        return 0, 0, 0, 0
    elseif bgType == "controlChrome" then
        local c = ns.UI_GetControlChromeBackdrop()
        return c[1], c[2], c[3], c[4] or bgAlpha
    elseif bgType == "controlChromeHover" then
        local c = ns.UI_GetControlChromeHoverBackdrop()
        return c[1], c[2], c[3], c[4] or bgAlpha
    elseif bgType == "bgCard" then
        local c = COLORS.bgCard or bgColor
        return c[1], c[2], c[3], c[4] or bgAlpha
    elseif bgType == "lootHeader" then
        local c = COLORS.lootHeaderBg or accentDarkColor
        return c[1], c[2], c[3], c[4] or bgAlpha
    elseif bgType == "accentDark" then
        return accentDarkColor[1], accentDarkColor[2], accentDarkColor[3], bgAlpha
    end
    return bgColor[1], bgColor[2], bgColor[3], bgAlpha
end

local function RefreshRegisteredBorderColors()
    local registry = ns.BORDER_REGISTRY
    if not registry then return end
    local accentColor = COLORS.accent or { 0.44, 0.32, 0.58, 1 }
    local accentDarkColor = COLORS.accentDark or accentColor
    local borderColor = COLORS.border or { 0.26, 0.24, 0.30, 1 }
    local bgColor = COLORS.bg or { 0.065, 0.062, 0.076, 0.97 }
    for i = #registry, 1, -1 do
        local fr = registry[i]
        if not fr then
            table.remove(registry, i)
        elseif fr.BorderTop then
            local br
            local alpha = fr._borderAlpha or 0.6
            if fr._borderType == "sectionHeader" then
                local sr, sg, sb, sa = ns.UI_GetSectionHeaderBorderRGBA()
                br = { sr, sg, sb, sa or alpha }
            elseif fr._borderType == "accent" then
                br = { accentColor[1], accentColor[2], accentColor[3], alpha }
            else
                br = { borderColor[1], borderColor[2], borderColor[3], alpha }
            end
            if ns.UI_UpdateBorderColor and br then
                ns.UI_UpdateBorderColor(fr, br)
            end
            if fr.SetBackdropColor and fr._bgType then
                local brgb, bgg, bb, ba = ResolveRegistryBackdrop(fr, accentDarkColor, bgColor)
                fr:SetBackdropColor(brgb, bgg, bb, ba)
            end
            if fr._iconTexture then
                fr._iconTexture:SetVertexColor(accentColor[1], accentColor[2], accentColor[3], 1)
            end
            if fr._thumbTexture then
                fr._thumbTexture:SetColorTexture(accentColor[1], accentColor[2], accentColor[3], 0.9)
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
    ApplyAccentOverrides()
    ns.UI_COLORS = COLORS
    RefreshRegisteredBorderColors()
    if ns.FontManager and ns.FontManager.RefreshThemeTypography then
        ns.FontManager.RefreshThemeTypography()
    end
    if ns.UI_RefreshScrollBarColumns then
        ns.UI_RefreshScrollBarColumns()
    end
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
