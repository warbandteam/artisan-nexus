--[[
    Artisan Nexus — theme tokens aligned with Warband Nexus (SharedWidgets COLORS / spacing).
    See warband-nexus Modules/UI/SharedWidgets.lua for the reference palette.
]]

local ADDON_NAME, ns = ...

---@class ArtisanTheme
local COLORS = {
    bg = { 0.06, 0.06, 0.08, 0.98 },
    bgLight = { 0.10, 0.10, 0.12, 1 },
    bgCard = { 0.08, 0.08, 0.10, 1 },
    border = { 0.20, 0.20, 0.25, 1 },
    borderLight = { 0.30, 0.30, 0.38, 1 },
    accent = { 0.40, 0.20, 0.58, 1 },
    accentDark = { 0.28, 0.14, 0.41, 1 },
    tabActive = { 0.20, 0.12, 0.30, 1 },
    tabHover = { 0.24, 0.14, 0.35, 1 },
    tabInactive = { 0.08, 0.08, 0.10, 1 },
    textBright = { 1, 1, 1, 1 },
    textNormal = { 0.85, 0.85, 0.85, 1 },
    textDim = { 0.55, 0.55, 0.55, 1 },
}

local LAYOUT = {
    BASE_INDENT = 12,
    SECTION_GAP = 10,
    ROW_HEIGHT = 30,
    ICON_SIZE = 28,
    CATALOG_ICON = 36,
    CATALOG_COLS = 2,
    CATALOG_LABEL_HEIGHT = 40,
    WINDOW_WIDTH = 460,
    WINDOW_HEIGHT = 640,
    HEADER_HEIGHT = 52,
    --- Loot history: min size + catalog grid targets (FishingHistoryUI also clamps to UIParent).
    LOOT_FRAME_MIN_WIDTH = 300,
    LOOT_FRAME_MIN_HEIGHT = 380,
    LOOT_FRAME_MAX_WIDTH = 900,
    LOOT_FRAME_MAX_HEIGHT = 900,
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
