--[[
    Artisan Nexus — balanced theme: cool charcoal + dusty violet accent (not neon steel, not loud gold).
    Loot highlights match accent hue so frames stay cohesive.
]]

local ADDON_NAME, ns = ...

---@class ArtisanTheme
local COLORS = {
    bg = { 0.065, 0.062, 0.076, 0.97 },
    bgLight = { 0.095, 0.092, 0.108, 1 },
    bgCard = { 0.078, 0.075, 0.089, 1 },
    border = { 0.26, 0.24, 0.30, 1 },
    borderLight = { 0.38, 0.35, 0.43, 1 },
    --- Dusty violet (closer to original identity, softer than pure saturation)
    accent = { 0.44, 0.32, 0.58, 1 },
    accentDark = { 0.30, 0.22, 0.42, 1 },
    tabActive = { 0.14, 0.11, 0.20, 1 },
    tabHover = { 0.18, 0.14, 0.25, 1 },
    tabInactive = { 0.074, 0.072, 0.084, 1 },
    textBright = { 0.96, 0.95, 0.97, 1 },
    textNormal = { 0.82, 0.80, 0.86, 1 },
    textDim = { 0.52, 0.50, 0.56, 1 },
    lootQtyOn = { 0.93, 0.92, 0.96, 1 },
    lootQtyZero = { 0.48, 0.46, 0.54, 1 },
    lootCellBg = { 0.08, 0.077, 0.09, 0.92 },
    lootCellBorder = { 0.30, 0.28, 0.34, 0.40 },
    --- Pick highlight: lilac-violet (matches accent; legible when border is thick + high-alpha)
    lootPickBorder = { 0.62, 0.54, 0.78 },
}

local LAYOUT = {
    BASE_INDENT = 12,
    SECTION_GAP = 10,
    ROW_HEIGHT = 36,
    ICON_SIZE = 34,
    CATALOG_ICON = 44,
    CATALOG_COLS = 2,
    CATALOG_LABEL_HEIGHT = 40,
    WINDOW_WIDTH = 520,
    WINDOW_HEIGHT = 700,
    HEADER_HEIGHT = 52,
    --- Loot history: min size + catalog grid targets (LootHistoryUI also clamps to UIParent).
    LOOT_FRAME_MIN_WIDTH = 340,
    LOOT_FRAME_MIN_HEIGHT = 420,
    LOOT_FRAME_MAX_WIDTH = 900,
    LOOT_FRAME_MAX_HEIGHT = 900,
    --- Catalog grid: inner padding (LootHistoryUI).
    LOOT_CATALOG_CELL_PAD = 8,
}

--- Same as Warband: flat fill + 1px accent border (SharedWidgets ApplyVisuals).
--- Load order: ArtisanTheme then ArtisanSharedWidgets; at runtime ns.UI_ApplyVisuals is set.
---@param frame Frame
---@param width number|nil
---@param height number|nil
local function ApplyPanelBackdrop(frame, width, height)
    if width then frame:SetWidth(width) end
    if height then frame:SetHeight(height) end
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
ns.UI_ApplyPanelBackdrop = ApplyPanelBackdrop
