--[[
    Artisan Nexus — settings layout slice (ArtisanSettingsFrame.xml scroll grid).
    Positions XML-defined controls; typography + row geometry helpers live here.
]]

local _, ns = ...

local max = math.max
local min = math.min
local floor = math.floor
local ceil = math.ceil

local ArtisanSettingsUI = ns.ArtisanSettingsUI
assert(ArtisanSettingsUI, "ArtisanSettingsUI_Layout: load ArtisanSettingsUI.lua before this slice")

local UIDropDownMenu_SetWidth = UIDropDownMenu_SetWidth

--- Single layout budget for /an config scroll content (Warband Theme-tab parity).
local LAYOUT = {
    PAD = 16,
    GAP_X = 12,
    GAP_Y = 8,
    ROW_H = 30,
    TITLE_H = 34,
    TITLE_GAP = 10,
    SECTION_GAP = 20,
    SLIDER_BLOCK_H = 58,
    SLIDER_TRACK_H = 20,
    LABEL_H = 24,
    INLINE_ROW_H = 36,
    LABEL_COL_W = 152,
    DROP_MIN_W = 200,
    FULL_GAP = 12,
    SUBSECTION_PAD = 10,
}

ArtisanSettingsUI.SETTINGS_LAYOUT = LAYOUT

ArtisanSettingsUI.SETTINGS_SLIDER_NAMES = {
    "ArtisanNexusSettings_BagSlider",
    "ArtisanNexusSettings_AhFreshSlider",
    "ArtisanNexusSettings_LootOverlayScaleSlider",
    "ArtisanNexusSettings_SessionRecentSlider",
    "ArtisanNexusSettings_SessionOverallSlider",
    "ArtisanNexusSettings_CraftBriefingTopSlider",
    "ArtisanNexusSettings_CraftBriefingAlertMinSlider",
}

ArtisanSettingsUI.SETTINGS_CHECKBOX_NAMES = {
    "ArtisanNexusSettings_Minimap",
    "ArtisanNexusSettings_LoginChat",
    "ArtisanNexusSettings_LightTheme",
    "ArtisanNexusSettings_ClassColorAccent",
    "ArtisanNexusSettings_Gathering",
    "ArtisanNexusSettings_Fishing",
    "ArtisanNexusSettings_OverloadInd",
    "ArtisanNexusSettings_OverloadHud",
    "ArtisanNexusSettings_OverloadCastBtn",
    "ArtisanNexusSettings_BagGuard",
    "ArtisanNexusSettings_LootHistory",
    "ArtisanNexusSettings_LootAuto",
    "ArtisanNexusSettings_LootOverlay",
    "ArtisanNexusSettings_Debug",
    "ArtisanNexusSettings_CraftBriefing",
    "ArtisanNexusSettings_CraftBriefingChat",
    "ArtisanNexusSettings_CraftBriefingOwned",
    "ArtisanNexusSettings_CraftBriefingAlert",
    "ArtisanNexusSettings_CraftBriefingConc",
    "ArtisanNexusSettings_CraftBriefingEquip",
    "ArtisanNexusSettings_CraftBriefingPriceSpot",
    "ArtisanNexusSettings_CraftBriefingPriceAvg",
}

ArtisanSettingsUI.SETTINGS_SECTION_FRAMES = {
    "ArtisanNexusSettings_TitleGeneral",
    "ArtisanNexusSettings_TitleGathering",
    "ArtisanNexusSettings_TitleLoot",
    "ArtisanNexusSettings_TitleCraftBriefing",
    "ArtisanNexusSettings_TitleAdvanced",
}

ArtisanSettingsUI.SETTINGS_GRID_SECTIONS = {
    {
        title = "ArtisanNexusSettings_TitleGeneral",
        cols = 2,
        checks = {
            "ArtisanNexusSettings_Minimap",
            "ArtisanNexusSettings_LoginChat",
            "ArtisanNexusSettings_LightTheme",
            "ArtisanNexusSettings_ClassColorAccent",
        },
        dropdownFrames = {
            { frame = "ArtisanNexusSettings_UiModeFrame", label = "ArtisanNexusSettings_UiModeLabel", drop = "ArtisanNexusSettings_UiModeDropDown" },
            { frame = "ArtisanNexusSettings_AccentFrame", label = "ArtisanNexusSettings_AccentLabel", drop = "ArtisanNexusSettings_AccentDropDown" },
        },
    },
    {
        title = "ArtisanNexusSettings_TitleGathering",
        cols = 2,
        checks = {
            "ArtisanNexusSettings_Gathering",
            "ArtisanNexusSettings_Fishing",
            "ArtisanNexusSettings_OverloadInd",
            "ArtisanNexusSettings_OverloadHud",
            "ArtisanNexusSettings_OverloadCastBtn",
            "ArtisanNexusSettings_BagGuard",
        },
        sliders = { "ArtisanNexusSettings_BagSlider" },
    },
    {
        title = "ArtisanNexusSettings_TitleLoot",
        cols = 2,
        checks = {
            "ArtisanNexusSettings_LootHistory",
            "ArtisanNexusSettings_LootAuto",
            "ArtisanNexusSettings_LootOverlay",
        },
        sliders = {
            "ArtisanNexusSettings_LootOverlayScaleSlider",
            "ArtisanNexusSettings_SessionRecentSlider",
            "ArtisanNexusSettings_SessionOverallSlider",
        },
        actionButtons = { "ArtisanNexusSettings_LootOverlayPosition" },
    },
    {
        title = "ArtisanNexusSettings_TitleCraftBriefing",
        cols = 2,
        checks = {
            "ArtisanNexusSettings_CraftBriefing",
            "ArtisanNexusSettings_CraftBriefingChat",
            "ArtisanNexusSettings_CraftBriefingOwned",
            "ArtisanNexusSettings_CraftBriefingAlert",
            "ArtisanNexusSettings_CraftBriefingConc",
            "ArtisanNexusSettings_CraftBriefingEquip",
        },
        sliders = {
            "ArtisanNexusSettings_CraftBriefingAlertMinSlider",
            "ArtisanNexusSettings_CraftBriefingTopSlider",
        },
        labelFrames = { "ArtisanNexusSettings_CraftBriefingPriceFrame" },
        tailChecks = {
            "ArtisanNexusSettings_CraftBriefingPriceSpot",
            "ArtisanNexusSettings_CraftBriefingPriceAvg",
        },
        tailCols = 2,
    },
    {
        title = "ArtisanNexusSettings_TitleAdvanced",
        cols = 1,
        checks = { "ArtisanNexusSettings_Debug" },
        sliders = { "ArtisanNexusSettings_AhFreshSlider" },
        resetButtons = {
            "ArtisanNexusSettings_ResetSession",
            "ArtisanNexusSettings_ResetOverall",
        },
    },
}

local function RoleColor(role)
    local COL = ns.UI_COLORS or {}
    if role == "bright" then
        return COL.textBright or { 0.98, 0.97, 0.99, 1 }
    end
    if role == "normal" then
        return COL.textNormal or { 0.88, 0.84, 0.92, 1 }
    end
    if role == "muted" then
        return COL.textMuted or { 0.72, 0.68, 0.78, 1 }
    end
    return COL.textDim or { 0.58, 0.54, 0.64, 1 }
end

local function ApplyFontRole(fs, fontObj, role)
    if not fs then
        return
    end
    if fontObj and fs.SetFontObject then
        fs:SetFontObject(fontObj)
    end
    if fs.SetTextColor then
        local c = RoleColor(role)
        fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    end
end

function ArtisanSettingsUI:GetSettingsDropdownWidth()
    local scroll = _G.ArtisanNexusSettings_Scroll
    local layout = self.SETTINGS_LAYOUT or {}
    local pad = layout.PAD or 16
    local scrollW = (scroll and scroll:GetWidth()) or 556
    local usableW = max(320, scrollW - pad * 2)
    return max(layout.DROP_MIN_W or 200, usableW - (layout.LABEL_COL_W or 152) - (layout.GAP_X or 12)) - 24
end

--- Label-left / control-right inline row (interface style, accent color).
function ArtisanSettingsUI:LayoutSettingsDropdownRow(spec, usableW)
    if not spec then
        return
    end
    local fr = _G[spec.frame]
    if not fr then
        return
    end
    local label = _G[spec.label]
    local drop = _G[spec.drop]
    local labelW = LAYOUT.LABEL_COL_W
    local dropW = max(LAYOUT.DROP_MIN_W, usableW - labelW - LAYOUT.GAP_X)
    fr:SetHeight(LAYOUT.INLINE_ROW_H)
    if label then
        label:ClearAllPoints()
        label:SetPoint("LEFT", fr, "LEFT", 0, 0)
        label:SetWidth(labelW)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(false)
        label:SetMaxLines(1)
    end
    if drop then
        drop:ClearAllPoints()
        drop:SetPoint("RIGHT", fr, "RIGHT", 0, 0)
        drop:SetWidth(dropW)
        if UIDropDownMenu_SetWidth then
            UIDropDownMenu_SetWidth(drop, dropW - 24)
        end
    end
end

--- Label + value header row; track lives in a short child slider (see UI_BuildSettingsSliderBlock).
function ArtisanSettingsUI:LayoutSettingsSliderRow(slider, usableW)
    if not slider then
        return
    end
    local classic = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    if classic then
        slider:SetWidth(min(usableW, 420))
        return
    end
    if ns.UI_BuildSettingsSliderBlock then
        ns.UI_BuildSettingsSliderBlock(slider, usableW)
    end
    if slider.Text then
        ApplyFontRole(slider.Text, "GameFontHighlight", "normal")
    end
    if slider.Value then
        ApplyFontRole(slider.Value, "GameFontHighlightSmall", "muted")
    end
    if slider.Low then
        ApplyFontRole(slider.Low, "GameFontHighlightSmall", "dim")
    end
    if slider.High then
        ApplyFontRole(slider.High, "GameFontHighlightSmall", "dim")
    end
end

function ArtisanSettingsUI:LayoutSettingsSubsectionLabel(frame)
    if not frame then
        return
    end
    frame:SetHeight(LAYOUT.LABEL_H)
    local bname = frame.GetName and frame:GetName()
    if not bname then
        return
    end
    local fs = _G[bname .. "Label"] or frame.labelText
    if not fs then
        for i = 1, frame:GetNumRegions() or 0 do
            local r = select(i, frame:GetRegions())
            if r and r.IsObjectType and r:IsObjectType("FontString") then
                fs = r
                break
            end
        end
    end
    if fs then
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", frame, "LEFT", LAYOUT.SUBSECTION_PAD, 0)
        fs:SetJustifyH("LEFT")
        ApplyFontRole(fs, "GameFontHighlight", "normal")
    end
end

function ArtisanSettingsUI:ApplySettingsTypography()
    local classic = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    if classic then
        return
    end
    local titleIds = {
        "ArtisanNexusSettings_HeaderTitle",
        "ArtisanNexusSettings_TitleGeneralText",
        "ArtisanNexusSettings_TitleGatheringText",
        "ArtisanNexusSettings_TitleLootText",
        "ArtisanNexusSettings_TitleCraftBriefingText",
        "ArtisanNexusSettings_TitleAdvancedText",
    }
    for i = 1, #titleIds do
        ApplyFontRole(_G[titleIds[i]], "GameFontNormalLarge", "bright")
    end
    ApplyFontRole(_G.ArtisanNexusSettings_FooterHint, "GameFontHighlightSmall", "dim")
    ApplyFontRole(_G.ArtisanNexusSettings_UiModeLabel, "GameFontHighlight", "normal")
    ApplyFontRole(_G.ArtisanNexusSettings_AccentLabel, "GameFontHighlight", "normal")
    ApplyFontRole(_G.ArtisanNexusSettings_CraftBriefingPriceLabel, "GameFontHighlight", "normal")
    local sliders = self.SETTINGS_SLIDER_NAMES
    for i = 1, #sliders do
        local sl = _G[sliders[i]]
        if sl then
            self:LayoutSettingsSliderRow(sl, sl:GetWidth() or 420)
        end
    end
end

function ArtisanSettingsUI:LayoutContentGrid()
    local content = _G.ArtisanNexusSettings_ScrollContent
    local scroll = _G.ArtisanNexusSettings_Scroll
    if not content then
        return
    end
    local PAD = LAYOUT.PAD
    local GAP_X = LAYOUT.GAP_X
    local GAP_Y = LAYOUT.GAP_Y
    local ROW_H = LAYOUT.ROW_H
    local TITLE_H = LAYOUT.TITLE_H
    local SECTION_GAP = LAYOUT.SECTION_GAP
    local FULL_GAP = LAYOUT.FULL_GAP

    local scrollW = (scroll and scroll:GetWidth()) or 556
    local usableW = max(320, scrollW - PAD * 2)
    local sections = self.SETTINGS_GRID_SECTIONS

    local y = -12

    local function placeTitle(name)
        local fr = _G[name]
        if not fr then
            return
        end
        fr:ClearAllPoints()
        fr:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
        fr:SetWidth(usableW)
        fr:SetHeight(TITLE_H)
        local bname = fr.GetName and fr:GetName()
        local fs = bname and _G[bname .. "Text"]
        if fs then
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", fr, "LEFT", 0, 4)
            fs:SetJustifyH("LEFT")
        end
        y = y - TITLE_H - LAYOUT.TITLE_GAP
    end

    local function placeChecks(names, cols)
        if not names or #names < 1 then
            return
        end
        cols = cols or 2
        local colW = floor((usableW - (cols - 1) * GAP_X) / cols)
        local startY = y
        for i = 1, #names do
            local btn = _G[names[i]]
            if btn then
                local col = (i - 1) % cols
                local row = floor((i - 1) / cols)
                local x = PAD + col * (colW + GAP_X)
                local rowY = startY - row * (ROW_H + GAP_Y)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", content, "TOPLEFT", x, rowY)
                btn:SetHeight(ns.UI_SETTINGS_CHECK_ROW_HEIGHT or ROW_H)
                if btn.Text and btn.Text.SetWidth then
                    btn.Text:SetWidth(max(120, colW - 32))
                    btn.Text:SetWordWrap(true)
                    btn.Text:SetMaxLines(2)
                    btn.Text:SetJustifyH("LEFT")
                end
            end
        end
        local rows = ceil(#names / cols)
        y = startY - rows * ROW_H - max(0, rows - 1) * GAP_Y - SECTION_GAP
    end

    local function placeSliders(names)
        if not names then
            return
        end
        for i = 1, #names do
            local sl = _G[names[i]]
            if sl then
                if ns.UI_BuildSettingsSliderBlock then
                    ns.UI_BuildSettingsSliderBlock(sl, usableW)
                end
                local host = sl._anSliderBlock or sl
                host:ClearAllPoints()
                host:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
                self:LayoutSettingsSliderRow(sl, usableW)
                y = y - LAYOUT.SLIDER_BLOCK_H - FULL_GAP
            end
        end
    end

    local function placeLabelFrames(names)
        if not names then
            return
        end
        for i = 1, #names do
            local fr = _G[names[i]]
            if fr then
                fr:ClearAllPoints()
                fr:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
                fr:SetWidth(usableW)
                self:LayoutSettingsSubsectionLabel(fr)
                y = y - LAYOUT.LABEL_H - 8
            end
        end
    end

    local function placeDropdownFrames(specs)
        if not specs then
            return
        end
        for i = 1, #specs do
            local spec = specs[i]
            local fr = _G[spec.frame or spec]
            if fr then
                fr:ClearAllPoints()
                fr:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
                fr:SetWidth(usableW)
                if type(spec) == "table" and spec.label then
                    self:LayoutSettingsDropdownRow(spec, usableW)
                end
                y = y - LAYOUT.INLINE_ROW_H - 10
            end
        end
    end

    local function placeResetButtons(names)
        if not names then
            return
        end
        for i = 1, #names do
            local btn = _G[names[i]]
            if btn then
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
                btn:SetWidth(usableW)
                btn:SetHeight(30)
                y = y - 32 - 8
            end
        end
    end

    local function placeActionButtons(names)
        if not names then
            return
        end
        for i = 1, #names do
            local btn = _G[names[i]]
            if btn then
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 4, y)
                btn:SetWidth(min(usableW - 8, 280))
                btn:SetHeight(28)
                y = y - 30 - 10
            end
        end
    end

    for s = 1, #sections do
        local sec = sections[s]
        placeTitle(sec.title)
        placeChecks(sec.checks, sec.cols)
        placeDropdownFrames(sec.dropdownFrames)
        placeActionButtons(sec.actionButtons)
        placeSliders(sec.sliders)
        placeLabelFrames(sec.labelFrames)
        if sec.tailChecks then
            placeChecks(sec.tailChecks, sec.tailCols or 2)
        end
        placeResetButtons(sec.resetButtons)
    end

    content:SetHeight(max(480, -y + 56))
    self:ApplySettingsTypography()
end
