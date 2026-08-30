--[[
    Artisan Nexus — settings glue for FrameXML (ArtisanSettingsFrame.xml).
    Layout lives in XML; this file applies ArtisanTheme visuals, localization, AceDB bindings, and refresh logic.
]]

local _, ns = ...

local tinsert = table.insert
local max = math.max
local min = math.min
local floor = math.floor
local ceil = math.ceil

local ArtisanNexus = ns.ArtisanNexus
local L = ns.L
local COLORS = ns.UI_COLORS or {}
local ApplyVisuals = ns.UI_ApplyVisuals

local UIDropDownMenu_Initialize = UIDropDownMenu_Initialize
local UIDropDownMenu_CreateInfo = UIDropDownMenu_CreateInfo
local UIDropDownMenu_AddButton = UIDropDownMenu_AddButton
local UIDropDownMenu_SetWidth = UIDropDownMenu_SetWidth
local UIDropDownMenu_SetText = UIDropDownMenu_SetText

local UI_MODE_VALUES = { "modern", "classic" }

local AH_FRESH_DEFAULT_SEC = 60 * 60 * 6

--- Single source for the footer strip reserve (tip text + reset buttons zone)
--- and the modern scroll top inset — previously six scattered `38`s.
local SETTINGS_FOOTER_RESERVE = 38
local SETTINGS_SCROLL_TOP_MODERN = 54

--- Bar column band on shell — never anchor to `scroll` (scroll's right edge anchors to column).
local function PositionSettingsScrollBarColumn(barCol, shell, opts)
    if not barCol or not shell then
        return
    end
    opts = opts or {}
    local topFrame = opts.topFrame or shell
    local topPoint = opts.topPoint or "TOP"
    local topY = opts.topY or 0
    local bottomFrame = opts.bottomFrame or shell
    local bottomPoint = opts.bottomPoint or "BOTTOM"
    local bottomY = opts.bottomY or 0
    local rightInset = opts.rightInset or 0

    barCol:ClearAllPoints()
    barCol:SetPoint("TOP", topFrame, topPoint, 0, topY)
    barCol:SetPoint("BOTTOM", bottomFrame, bottomPoint, 0, bottomY)
    barCol:SetPoint("RIGHT", shell, "RIGHT", -rightInset, 0)
end

local function ReapplyModernSettingsWidgetChrome()
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        return
    end
    local settingsUI = ns.ArtisanSettingsUI
    if settingsUI and settingsUI.ApplyXmlThemedChrome then
        settingsUI:ApplyXmlThemedChrome()
    end
end

local function EnsureSliderValueText(sl)
    if not sl or sl.Value then
        return
    end
    local fs = sl:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    --- Blizzard options idiom: current value bottom-center, between Low/High.
    fs:SetPoint("TOP", sl, "BOTTOM", 0, 0)
    fs:SetJustifyH("CENTER")
    sl.Value = fs
end

--- Control name lists + grid layout: ArtisanSettingsUI_Layout.lua (loaded after this file).

local ArtisanSettingsUI = {
    frame = nil,
    wired = false,
}

local E = (ns.Constants and ns.Constants.EVENTS) or {}

local function ApplyFrame(frame, bg, border)
    if ApplyVisuals then
        ApplyVisuals(frame, bg, border)
    elseif frame.SetBackdrop then
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8" })
        if bg then
            frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
        end
    end
end

local function SetMinimapFromUi(show)
    ArtisanNexus.db.profile.minimap = ArtisanNexus.db.profile.minimap or {}
    ArtisanNexus:SetMinimapButtonVisible(show and true or false)
end

local function SetGatheringEnabled(v)
    local p = ArtisanNexus.db.profile
    p.modulesEnabled = p.modulesEnabled or {}
    local on = v and true or false
    p.modulesEnabled.gathering = on
    if E.MODULE_TOGGLED and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.MODULE_TOGGLED, "gathering", on)
    end
    if p.enabled == false then
        return
    end
    if on then
        if ns.GatheringLootService then
            ns.GatheringLootService:Enable()
        end
        if ns.GatheringOverloadService then
            ns.GatheringOverloadService:Enable()
        end
    else
        if ns.GatheringLootService then
            ns.GatheringLootService:Disable()
        end
        if ns.GatheringOverloadService then
            ns.GatheringOverloadService:Disable()
        end
    end
end

local function SetFishingEnabled(v)
    local p = ArtisanNexus.db.profile
    p.modulesEnabled = p.modulesEnabled or {}
    local on = v and true or false
    p.modulesEnabled.fishing = on
    if E.MODULE_TOGGLED and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.MODULE_TOGGLED, "fishing", on)
    end
    if p.enabled == false then
        return
    end
    if on then
        if ns.FishingService then
            ns.FishingService:Enable()
        end
        if ns.FishingLootService then
            ns.FishingLootService:Enable()
        end
    else
        if ns.FishingLootService then
            ns.FishingLootService:Disable()
        end
        if ns.FishingService then
            ns.FishingService:Disable()
        end
    end
end

local function SetOverloadIndicator(v)
    ArtisanNexus.db.profile.overloadNodeIndicatorEnabled = v and true or false
    if E.GATHERING_OVERLOAD_HINT_UPDATED and ns.ArtisanNexus then
        ns.ArtisanNexus:SendMessage(E.GATHERING_OVERLOAD_HINT_UPDATED, nil)
    end
end

local function SetOverloadTrackerHud(v)
    ArtisanNexus.db.profile.overloadTrackerHudEnabled = v and true or false
    if ns.GatheringOverloadIndicator and ns.GatheringOverloadIndicator.RefreshTracker then
        ns.GatheringOverloadIndicator:RefreshTracker()
    end
end

local function SetOverloadCastButtonVisible(v)
    local p = ArtisanNexus.db.profile
    p.overloadActionButton = p.overloadActionButton or {}
    p.overloadActionButton.hidden = not v
    if ns.GatheringOverloadActionButton then
        if v then
            ns.GatheringOverloadActionButton:Show()
        else
            ns.GatheringOverloadActionButton:Hide()
        end
    end
end

local function SetBagPressureGuard(v)
    ArtisanNexus.db.profile.bagPressureGuardEnabled = v and true or false
    if ns.BagPressureGuard then
        if v and ArtisanNexus.db.profile.enabled then
            ns.BagPressureGuard:Enable()
        else
            ns.BagPressureGuard:Disable()
        end
    end
end

local function SetLootHistoryEnabled(v)
    ArtisanNexus.db.profile.lootHistoryEnabled = v and true or false
    if not v and ns.LootHistoryUI and ns.LootHistoryUI.Hide then
        ns.LootHistoryUI:Hide()
    end
end

local function SetSessionLootOverlayEnabled(v)
    ArtisanNexus.db.profile.sessionLootOverlayEnabled = v and true or false
    if ns.SessionLootOverlayUI then
        if v and ns.SessionLootOverlayUI.Open then
            ns.SessionLootOverlayUI:Open()
        elseif ns.SessionLootOverlayUI.Hide then
            ns.SessionLootOverlayUI:Hide()
        end
    end
    if ns.LootHistoryUI and ns.LootHistoryUI.UpdateLootOverlayToggle then
        ns.LootHistoryUI:UpdateLootOverlayToggle()
    end
end

local function RefreshOverlayPositionButtonLabel()
    local btn = _G.ArtisanNexusSettings_LootOverlayPosition
    if not btn or not btn.SetText then
        return
    end
    local editing = ns.SessionLootOverlayUI and ns.SessionLootOverlayUI.IsPositionEditing
        and ns.SessionLootOverlayUI:IsPositionEditing()
    if editing then
        btn:SetText((L and L["CONFIG_LOOT_OVERLAY_POSITION_ACTIVE"]) or "Done positioning")
    else
        btn:SetText((L and L["CONFIG_LOOT_OVERLAY_POSITION"]) or "Position overlay")
    end
end

function ArtisanSettingsUI:RefreshOverlayPositionButton()
    RefreshOverlayPositionButtonLabel()
end

local function SetCraftBriefingPriceMode(mode)
    ArtisanNexus.db.profile.craftBriefingPriceMode = mode
end

local function RebuildBriefingIfCached()
    if ns.CraftBriefingService and ns.CraftBriefingService.Rebuild then
        local b = ns.CraftBriefingService:GetBriefing()
        if b and b.updatedAt then
            ns.CraftBriefingService:Rebuild("settings")
        end
    end
end

local function HookTooltip(widget, titleText, descText)
    if not widget then return end
    widget:SetScript("OnEnter", function(self)
        if self.IsEnabled and not self:IsEnabled() then return end
        if not descText or descText == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(titleText or "")
        if descText and descText ~= "" then
            GameTooltip:AddLine(descText, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", GameTooltip_Hide)
end

local function CheckText(btn, label)
    if not btn or not btn.Text then return end
    btn.Text:SetText(label or "")
end

local function NormalizeUiMode(mode)
    return mode == "classic" and "classic" or "modern"
end

local function UiModeDisplayText(mode)
    if mode == "classic" then
        return (L and L["CONFIG_UI_MODE_CLASSIC"]) or "Classic"
    end
    return (L and L["CONFIG_UI_MODE_MODERN"]) or "Modern"
end

local function ApplyUiModeSelection(mode)
    mode = NormalizeUiMode(mode)
    local cur = NormalizeUiMode(ArtisanNexus.db.profile.uiMode)
    if mode == cur then
        ArtisanSettingsUI:RefreshUiModeDropdown()
        return
    end
    ArtisanNexus.db.profile.uiMode = mode
    ReloadUI()
end

local function InitializeUiModeDropDown(self, level)
    local info = UIDropDownMenu_CreateInfo()
    for i = 1, #UI_MODE_VALUES do
        local mode = UI_MODE_VALUES[i]
        info.text = UiModeDisplayText(mode)
        info.value = mode
        info.checked = (NormalizeUiMode(ArtisanNexus.db.profile.uiMode) == mode)
        info.func = function()
            ApplyUiModeSelection(mode)
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)
    end
end

local ACCENT_PRESET_IDS = ns.UI_ACCENT_PRESET_IDS or {
    "default", "violet", "gold", "teal", "rose", "cobalt", "custom",
}

local ACCENT_LOCALE_KEYS = {
    default = "CONFIG_ACCENT_PRESET_DEFAULT",
    violet = "CONFIG_ACCENT_PRESET_VIOLET",
    gold = "CONFIG_ACCENT_PRESET_GOLD",
    teal = "CONFIG_ACCENT_PRESET_TEAL",
    rose = "CONFIG_ACCENT_PRESET_ROSE",
    cobalt = "CONFIG_ACCENT_PRESET_COBALT",
    custom = "CONFIG_ACCENT_PRESET_CUSTOM",
}

local function AccentPresetDisplayText(presetKey)
    local locKey = ACCENT_LOCALE_KEYS[presetKey]
    if locKey and L and L[locKey] then
        return L[locKey]
    end
    return presetKey or "Default"
end

local function NormalizeAccentPreset(preset)
    for i = 1, #ACCENT_PRESET_IDS do
        if ACCENT_PRESET_IDS[i] == preset then
            return preset
        end
    end
    return "default"
end

local function ApplyAccentPresetSelection(preset)
    preset = NormalizeAccentPreset(preset)
    ArtisanNexus.db.profile.accentPreset = preset
    ArtisanNexus:RefreshTheme()
    ArtisanSettingsUI:RefreshAccentControls()
    if preset == "custom" then
        ArtisanSettingsUI:OpenAccentColorPicker()
    end
end

local function InitializeAccentDropDown(self, level)
    local info = UIDropDownMenu_CreateInfo()
    local cur = NormalizeAccentPreset(ArtisanNexus.db.profile.accentPreset)
    for i = 1, #ACCENT_PRESET_IDS do
        local preset = ACCENT_PRESET_IDS[i]
        info.text = AccentPresetDisplayText(preset)
        info.value = preset
        info.checked = (cur == preset)
        info.func = function()
            ApplyAccentPresetSelection(preset)
            CloseDropDownMenus()
        end
        UIDropDownMenu_AddButton(info)
    end
end

function ArtisanSettingsUI:OpenAccentColorPicker()
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        return
    end
    if ArtisanNexus.db.profile.useClassColorAccent then
        return
    end
    local p = ArtisanNexus.db.profile
    p.accentCustom = p.accentCustom or { 0.44, 0.32, 0.58 }
    local r, g, b = p.accentCustom[1], p.accentCustom[2], p.accentCustom[3]
    if ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow then
        local prevR, prevG, prevB = r, g, b
        local pendingR, pendingG, pendingB = r, g, b
        local cancelled = false
        local function ApplyPending()
            p.accentCustom = { pendingR, pendingG, pendingB }
            p.accentPreset = "custom"
            ArtisanNexus:RefreshTheme()
            ArtisanSettingsUI:RefreshAccentControls()
        end
        local info = {
            r = r,
            g = g,
            b = b,
            hasOpacity = false,
            swatchFunc = function()
                if ColorPickerFrame then
                    pendingR, pendingG, pendingB = ColorPickerFrame:GetColorRGB()
                end
            end,
            cancelFunc = function()
                cancelled = true
                pendingR, pendingG, pendingB = prevR, prevG, prevB
                ApplyPending()
            end,
        }
        ColorPickerFrame:SetupColorPickerAndShow(info)
        if C_Timer and C_Timer.NewTicker then
            local ticker
            ticker = C_Timer.NewTicker(0.15, function()
                if cancelled then
                    ticker:Cancel()
                    return
                end
                if not ColorPickerFrame or not ColorPickerFrame.IsShown or not ColorPickerFrame:IsShown() then
                    ticker:Cancel()
                    ApplyPending()
                end
            end)
        end
        return
    end
    if ColorPickerFrame then
        ColorPickerFrame.func = function()
            local nr, ng, nb = ColorPickerFrame:GetColorRGB()
            p.accentCustom = { nr, ng, nb }
            p.accentPreset = "custom"
            ArtisanNexus:RefreshTheme()
            ArtisanSettingsUI:RefreshAccentControls()
        end
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Show()
    end
end

function ArtisanSettingsUI:RefreshAccentDropdown()
    local dd = _G.ArtisanNexusSettings_AccentDropDown
    if not dd then
        return
    end
    UIDropDownMenu_SetWidth(dd, self.GetSettingsDropdownWidth and self:GetSettingsDropdownWidth() or 180)
    UIDropDownMenu_SetText(dd, AccentPresetDisplayText(NormalizeAccentPreset(ArtisanNexus.db.profile.accentPreset)))
    if ns.UI_StyleSettingsDropDown then
        ns.UI_StyleSettingsDropDown(dd)
    end
end

function ArtisanSettingsUI:RefreshAccentSwatch()
    local btn = _G.ArtisanNexusSettings_AccentSwatch
    if not btn then
        return
    end
    if not btn._anSwatchTex then
        btn._anSwatchTex = btn:CreateTexture(nil, "ARTWORK")
        btn._anSwatchTex:SetPoint("TOPLEFT", 3, -3)
        btn._anSwatchTex:SetPoint("BOTTOMRIGHT", -3, 3)
        if btn.SetText then
            btn:SetText("")
        end
    end
    local classic = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    local preset = NormalizeAccentPreset(ArtisanNexus.db.profile.accentPreset)
    local show = (preset == "custom") and not classic
    btn:SetShown(show)
    if not show then
        return
    end
    local r, g, b = ns.UI_GetAccentPresetRgb("custom")
    btn._anSwatchTex:SetColorTexture(r, g, b, 1)
end

function ArtisanSettingsUI:SyncAccentAvailability()
    local classic = ArtisanNexus.db.profile.uiMode == "classic"
    local classAccent = ArtisanNexus.db.profile.useClassColorAccent and true or false
    local disabled = classic or classAccent
    local frame = _G.ArtisanNexusSettings_AccentFrame
    local dd = _G.ArtisanNexusSettings_AccentDropDown
    local label = _G.ArtisanNexusSettings_AccentLabel
    local swatch = _G.ArtisanNexusSettings_AccentSwatch
    if dd and dd.SetEnabled then
        dd:SetEnabled(not disabled)
    end
    if frame and frame.SetEnabled then
        frame:SetEnabled(not classic)
    end
    if swatch and swatch.SetEnabled then
        swatch:SetEnabled(not disabled)
    end
    if label and label.SetTextColor then
        if classic or classAccent then
            label:SetTextColor(0.5, 0.5, 0.5)
        else
            local tn = COLORS.textNormal or { 0.82, 0.80, 0.86, 1 }
            label:SetTextColor(tn[1], tn[2], tn[3], tn[4] or 1)
        end
    end
    local classCb = _G.ArtisanNexusSettings_ClassColorAccent
    if classCb and classCb.SetEnabled then
        classCb:SetEnabled(not classic)
    end
    if classCb and classCb.Text and classCb.Text.SetTextColor then
        if classic then
            classCb.Text:SetTextColor(0.5, 0.5, 0.5)
        else
            local tn = COLORS.textNormal or { 0.82, 0.80, 0.86, 1 }
            classCb.Text:SetTextColor(tn[1], tn[2], tn[3], tn[4] or 1)
        end
    end
    self:RefreshAccentSwatch()
end

function ArtisanSettingsUI:RefreshAccentControls()
    self:RefreshAccentDropdown()
    self:RefreshAccentSwatch()
    self:SyncAccentAvailability()
end

function ArtisanSettingsUI:GetRoot()
    if self.frame then
        return self.frame
    end
    local f = _G.ArtisanNexusSettingsFrame
    if not f then
        return nil
    end
    self.frame = f
    return f
end

--- Two/three-column settings layout; scroll child height derived from placed widgets.
function ArtisanSettingsUI:ApplySettingsHeaderClip()
    local header = _G.ArtisanNexusSettings_Header
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if header and ns.UI_RefreshClassicWindowHeader then
            ns.UI_RefreshClassicWindowHeader(header)
        end
        return
    end
    local logo = _G.ArtisanNexusSettings_HeaderLogo
    local title = _G.ArtisanNexusSettings_HeaderTitle
    local close = _G.ArtisanNexusSettings_Close
    if not title or not close then
        return
    end
    title:ClearAllPoints()
    if logo then
        title:SetPoint("LEFT", logo, "RIGHT", 8, 0)
    else
        title:SetPoint("LEFT", header, "LEFT", 12, 0)
    end
    title:SetPoint("RIGHT", close, "LEFT", -10, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetMaxLines(1)
end

function ArtisanSettingsUI:ApplyLocalizedStaticText()
    local function T(fs, key, fallback)
        if not fs then return end
        local text = fallback or ""
        if ns.SafeLocaleString then
            text = ns.SafeLocaleString(key, fallback) or fallback or ""
        elseif L and type(key) == "string" then
            text = L[key] or fallback or ""
        end
        fs:SetText(text)
    end

    T(_G.ArtisanNexusSettings_TitleGeneralText, "SETTINGS_SECTION_GENERAL", "General")
    T(_G.ArtisanNexusSettings_TitleGatheringText, "SETTINGS_SECTION_GATHERING", "Gathering, overload & routes")
    T(_G.ArtisanNexusSettings_TitleLootText, "SETTINGS_SECTION_LOOT", "Loot & session")
    T(_G.ArtisanNexusSettings_TitleCraftBriefingText, "SETTINGS_SECTION_CRAFT_BRIEFING", "Craft briefing")
    T(_G.ArtisanNexusSettings_TitleAdvancedText, "SETTINGS_SECTION_ADVANCED", "Advanced & data")

    T(_G.ArtisanNexusSettings_HeaderTitle, "CONFIG_HEADER", "Artisan Nexus")
    T(_G.ArtisanNexusSettings_FooterHint, "SETTINGS_FOOTER_HINT", "/an config")

    CheckText(_G.ArtisanNexusSettings_Minimap, (L and L["CONFIG_MINIMAP_BUTTON"]) or "")
    CheckText(_G.ArtisanNexusSettings_LoginChat, (L and L["CONFIG_SHOW_LOGIN_CHAT"]) or "")
    CheckText(_G.ArtisanNexusSettings_LightTheme, (L and L["CONFIG_LIGHT_THEME"]) or "Light theme")
    CheckText(_G.ArtisanNexusSettings_ClassColorAccent, (L and L["CONFIG_USE_CLASS_COLOR_ACCENT"]) or "Use class color as accent")

    local uiModeLabel = _G.ArtisanNexusSettings_UiModeLabel
    if uiModeLabel then
        uiModeLabel:SetText((L and L["CONFIG_UI_MODE"]) or "Interface style")
    end

    local accentLabel = _G.ArtisanNexusSettings_AccentLabel
    if accentLabel then
        accentLabel:SetText((L and L["CONFIG_ACCENT_COLOR"]) or "Accent color")
    end

    CheckText(_G.ArtisanNexusSettings_Gathering, (L and L["CONFIG_GATHERING_LOOT"]) or "")
    CheckText(_G.ArtisanNexusSettings_Fishing, (L and L["CONFIG_FISHING_MODULE"]) or "Fishing module")
    CheckText(_G.ArtisanNexusSettings_OverloadInd, (L and L["CONFIG_OVERLOAD_NODE_INDICATOR"]) or "")
    CheckText(_G.ArtisanNexusSettings_OverloadHud, (L and L["CONFIG_OVERLOAD_TRACKER_HUD"]) or "")
    CheckText(_G.ArtisanNexusSettings_OverloadCastBtn, (L and L["CONFIG_OVERLOAD_CAST_BUTTON"]) or "")
    CheckText(_G.ArtisanNexusSettings_BagGuard, (L and L["CONFIG_BAG_PRESSURE_GUARD"]) or "")

    CheckText(_G.ArtisanNexusSettings_LootHistory, (L and L["CONFIG_LOOT_HISTORY_ENABLED"]) or "")
    CheckText(_G.ArtisanNexusSettings_LootAuto, (L and L["CONFIG_LOOT_HISTORY_AUTO_OPEN"]) or "")
    CheckText(_G.ArtisanNexusSettings_LootOverlay, (L and L["CONFIG_LOOT_OVERLAY"]) or "")

    CheckText(_G.ArtisanNexusSettings_Debug, (L and L["CONFIG_DEBUG"]) or "")

    CheckText(_G.ArtisanNexusSettings_CraftBriefing, (L and L["CONFIG_CRAFT_BRIEFING"]) or "Craft briefing after AH sync")
    CheckText(_G.ArtisanNexusSettings_CraftBriefingChat, (L and L["CONFIG_CRAFT_BRIEFING_CHAT"]) or "")
    CheckText(_G.ArtisanNexusSettings_CraftBriefingOwned, (L and L["CONFIG_CRAFT_BRIEFING_OWNED"]) or "")
    CheckText(_G.ArtisanNexusSettings_CraftBriefingAlert, (L and L["CONFIG_CRAFT_BRIEFING_ALERT"]) or "")
    CheckText(_G.ArtisanNexusSettings_CraftBriefingConc, (L and L["CONFIG_CRAFT_BRIEFING_CONC"]) or "")
    CheckText(_G.ArtisanNexusSettings_CraftBriefingEquip, (L and L["CONFIG_CRAFT_BRIEFING_EQUIP"]) or "")
    CheckText(_G.ArtisanNexusSettings_CraftBriefingPriceSpot, (L and L["CONFIG_CRAFT_BRIEFING_PRICE_SPOT"]) or "")
    CheckText(_G.ArtisanNexusSettings_CraftBriefingPriceAvg, (L and L["CONFIG_CRAFT_BRIEFING_PRICE_AVG"]) or "")
    T(_G.ArtisanNexusSettings_CraftBriefingPriceLabel, "CONFIG_CRAFT_BRIEFING_PRICE_LABEL", "Briefing price source")

    local cbTop = _G.ArtisanNexusSettings_CraftBriefingTopSlider
    if cbTop and cbTop.Text then
        cbTop.Text:SetText((L and L["CONFIG_CRAFT_BRIEFING_TOP_N"]) or "")
    end
    local cbAlertMin = _G.ArtisanNexusSettings_CraftBriefingAlertMinSlider
    if cbAlertMin and cbAlertMin.Text then
        cbAlertMin.Text:SetText((L and L["CONFIG_CRAFT_BRIEFING_ALERT_MIN"]) or "")
    end

    local rs = _G.ArtisanNexusSettings_ResetSession
    if rs then rs:SetText((L and L["CONFIG_RESET_ALL_SESSION"]) or "") end
    local ro = _G.ArtisanNexusSettings_ResetOverall
    if ro then ro:SetText((L and L["CONFIG_RESET_ALL_OVERALL"]) or "") end

    local bag = _G.ArtisanNexusSettings_BagSlider
    if bag and bag.Text then
        bag.Text:SetText((L and L["CONFIG_BAG_PRESSURE_THRESHOLD"]) or "")
    end
    local ah = _G.ArtisanNexusSettings_AhFreshSlider
    if ah and ah.Text then
        ah.Text:SetText((L and L["CONFIG_AH_FRESHNESS_HOURS"]) or "")
    end
    local sRecent = _G.ArtisanNexusSettings_SessionRecentSlider
    if sRecent and sRecent.Text then
        sRecent.Text:SetText((L and L["CONFIG_SESSION_LOOT_MAX_RECENT"]) or "")
    end
    local sOverlayScale = _G.ArtisanNexusSettings_LootOverlayScaleSlider
    if sOverlayScale and sOverlayScale.Text then
        sOverlayScale.Text:SetText((L and L["CONFIG_LOOT_OVERLAY_SIZE"]) or "")
    end
    local sOverall = _G.ArtisanNexusSettings_SessionOverallSlider
    if sOverall and sOverall.Text then
        sOverall.Text:SetText((L and L["CONFIG_SESSION_LOOT_OVERALL_CAP"]) or "")
    end
end

--- Warband-style themed toggles + section strips on FrameXML controls.
--- Runs in BOTH skins: the style helpers carry their own classic-reversal
--- branches, so skipping them in Classic would leave Modern chrome behind
--- after a live mode switch (the "Classic UI" toggle lives in this panel).
function ArtisanSettingsUI:ApplyXmlThemedChrome()
    local classic = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    local StyleCb = ns.UI_StyleSettingsCheckButton
    local StyleSec = ns.UI_StyleSettingsSectionTitle
    if not StyleCb or not StyleSec then
        return
    end
    local sectionFrames = ArtisanSettingsUI.SETTINGS_SECTION_FRAMES or {}
    local checkboxNames = ArtisanSettingsUI.SETTINGS_CHECKBOX_NAMES or {}
    local sliderNames = ArtisanSettingsUI.SETTINGS_SLIDER_NAMES or {}
    for i = 1, #sectionFrames do
        StyleSec(_G[sectionFrames[i]])
    end
    for i = 1, #checkboxNames do
        StyleCb(_G[checkboxNames[i]])
    end

    --- Radio-group cards for multi-option rows only; dropdown rows stay inline (WN Theme tab parity).
    local function StyleRadioCard(fr)
        if not fr then
            return
        end
        if ns.UI_StylePanelInset then
            local b = COLORS.border or { 0.40, 0.36, 0.48, 1 }
            ns.UI_StylePanelInset(fr,
                COLORS.bgCard or { 0.125, 0.118, 0.138, 0.92 },
                { b[1], b[2], b[3], 0.45 })
        elseif ApplyVisuals then
            local b = COLORS.border or { 0.40, 0.36, 0.48, 1 }
            ApplyVisuals(fr, COLORS.bgCard or { 0.125, 0.118, 0.138, 0.92 },
                { b[1], b[2], b[3], 0.45 })
        end
    end
    local function ClearInlineRowFrame(fr)
        if not fr then
            return
        end
        if ns.UI_SuppressArtisanChrome then
            ns.UI_SuppressArtisanChrome(fr)
        end
        if fr.SetBackdropColor then
            pcall(function()
                fr:SetBackdropColor(0, 0, 0, 0)
            end)
        end
    end
    StyleRadioCard(_G.ArtisanNexusSettings_CraftBriefingPriceFrame)
    ClearInlineRowFrame(_G.ArtisanNexusSettings_UiModeFrame)
    ClearInlineRowFrame(_G.ArtisanNexusSettings_AccentFrame)

    if ns.UI_StyleSettingsDropDown then
        ns.UI_StyleSettingsDropDown(_G.ArtisanNexusSettings_UiModeDropDown)
        ns.UI_StyleSettingsDropDown(_G.ArtisanNexusSettings_AccentDropDown)
    end

    local function tintInlineLabel(fs)
        if not fs or not fs.SetTextColor then
            return
        end
        if classic then
            fs:SetTextColor(1, 0.82, 0, 1)
            return
        end
        local role = (fs == _G.ArtisanNexusSettings_UiModeLabel or fs == _G.ArtisanNexusSettings_AccentLabel) and "normal" or "bright"
        local c = role == "normal" and (COLORS.textNormal or { 0.88, 0.84, 0.92, 1 }) or (COLORS.textBright or { 0.98, 0.97, 0.99, 1 })
        fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    end
    tintInlineLabel(_G.ArtisanNexusSettings_UiModeLabel)
    tintInlineLabel(_G.ArtisanNexusSettings_AccentLabel)
    tintInlineLabel(_G.ArtisanNexusSettings_CraftBriefingPriceLabel)

    local function tintSliderFonts(sl)
        if not sl then return end
        if classic then
            --- Native template colors (gold label, white min/max/value) so
            --- Modern tints never linger on classic slider art.
            if sl.Text then sl.Text:SetTextColor(1, 0.82, 0, 1) end
            if sl.Low then sl.Low:SetTextColor(1, 1, 1, 1) end
            if sl.High then sl.High:SetTextColor(1, 1, 1, 1) end
            if sl.Value then sl.Value:SetTextColor(1, 1, 1, 1) end
            return
        end
        local tb = COLORS.textNormal or { 0.88, 0.84, 0.92, 1 }
        local dim = COLORS.textDim or { 0.58, 0.54, 0.64, 1 }
        local muted = COLORS.textMuted or { 0.72, 0.68, 0.78, 1 }
        if sl.Text then sl.Text:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1) end
        if sl.Low then sl.Low:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1) end
        if sl.High then sl.High:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1) end
        if sl.Value then sl.Value:SetTextColor(muted[1], muted[2], muted[3], muted[4] or 1) end
    end
    for i = 1, #sliderNames do
        local sl = _G[sliderNames[i]]
        if ns.UI_StyleSettingsSlider then
            ns.UI_StyleSettingsSlider(sl)
        end
        tintSliderFonts(sl)
        if self.LayoutSettingsSliderRow and sl then
            local scroll = _G.ArtisanNexusSettings_Scroll
            local scrollW = (scroll and scroll:GetWidth()) or 556
            local layout = self.SETTINGS_LAYOUT or {}
            local usableW = max(320, scrollW - (layout.PAD or 16) * 2)
            self:LayoutSettingsSliderRow(sl, usableW)
        end
    end
    if ns.UI_StyleSettingsPanelButton then
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_LootOverlayPosition)
    end
    if not classic and self.ApplySettingsTypography then
        self:ApplySettingsTypography()
    end
end

function ArtisanSettingsUI:RefreshUiModeDropdown()
    local dd = _G.ArtisanNexusSettings_UiModeDropDown
    if not dd then
        return
    end
    UIDropDownMenu_SetWidth(dd, self.GetSettingsDropdownWidth and self:GetSettingsDropdownWidth() or 180)
    UIDropDownMenu_SetText(dd, UiModeDisplayText(NormalizeUiMode(ArtisanNexus.db.profile.uiMode)))
    if ns.UI_StyleSettingsDropDown then
        ns.UI_StyleSettingsDropDown(dd)
    end
end

function ArtisanSettingsUI:SyncThemedToggleDots()
    for i = 1, #ArtisanSettingsUI.SETTINGS_CHECKBOX_NAMES do
        local b = _G[ArtisanSettingsUI.SETTINGS_CHECKBOX_NAMES[i]]
        if b and b.anThemedDot then
            b.anThemedDot:SetShown(b:GetChecked())
        end
        if b and b.anThemedHost then
            local en = (b.IsEnabled and b:IsEnabled()) ~= false
            b.anThemedHost:SetAlpha(en and 1 or 0.38)
            if b.Text then
                b.Text:SetAlpha(en and 1 or 0.45)
            end
        end
    end
end

function ArtisanSettingsUI:SyncLightThemeAvailability()
    local classic = ArtisanNexus.db.profile.uiMode == "classic"
    local lt = _G.ArtisanNexusSettings_LightTheme
    if lt then
        if lt.SetEnabled then
            lt:SetEnabled(not classic)
        end
        if lt.Text and lt.Text.SetTextColor then
            if classic then
                lt.Text:SetTextColor(0.5, 0.5, 0.5)
            else
                local tn = COLORS.textNormal or { 0.82, 0.80, 0.86, 1 }
                lt.Text:SetTextColor(tn[1], tn[2], tn[3], tn[4] or 1)
            end
        end
    end
    if ArtisanSettingsUI.SyncAccentAvailability then
        ArtisanSettingsUI:SyncAccentAvailability()
    end
end

function ArtisanSettingsUI:ApplyChrome()
    local f = self:GetRoot()
    if not f then return end
    f._anPosKey = "settingsFrame"

    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_ApplyClassicDialogBackdrop then
            ns.UI_ApplyClassicDialogBackdrop(f)
        end
        f._anClassicDialogRoot = true
        if f.SetClipsChildren then
            f:SetClipsChildren(false)
        end
    else
        ApplyFrame(f, COLORS.bg or { 0.11, 0.105, 0.125, 0.98 }, {
            (COLORS.accent or { 0.52, 0.40, 0.66, 1 })[1],
            (COLORS.accent or { 0.52, 0.40, 0.66, 1 })[2],
            (COLORS.accent or { 0.52, 0.40, 0.66, 1 })[3],
            0.85,
        })
    end

    local listed = false
    for i = 1, #UISpecialFrames do
        if UISpecialFrames[i] == "ArtisanNexusSettingsFrame" then
            listed = true
            break
        end
    end
    if not listed then
        tinsert(UISpecialFrames, "ArtisanNexusSettingsFrame")
    end

    local header = _G.ArtisanNexusSettings_Header
    if header then
        header:RegisterForDrag("LeftButton")
        header:SetScript("OnDragStart", function()
            f:StartMoving()
        end)
        header:SetScript("OnDragStop", function()
            f:StopMovingOrSizing()
            if ns.UI_SaveWindowPosition then
                ns.UI_SaveWindowPosition(f)
            end
        end)
        if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
            if ns.UI_SuppressArtisanChrome then
                ns.UI_SuppressArtisanChrome(header)
            end
            header._anShellParent = f
            header._anShellTitle = _G.ArtisanNexusSettings_HeaderTitle
            header._anShellLogo = _G.ArtisanNexusSettings_HeaderLogo
            header._anShellClose = _G.ArtisanNexusSettings_Close
            if ns.UI_LayoutClassicShellHeader then
                ns.UI_LayoutClassicShellHeader(header)
            elseif ns.UI_RefreshClassicWindowHeader then
                ns.UI_RefreshClassicWindowHeader(header)
            end
        else
            local hb = COLORS.lootHeaderBg or COLORS.accentDark or { 0.125, 0.105, 0.155, 1 }
            local hbr = COLORS.lootHeaderBorder or {
                (COLORS.accent or { 0.52, 0.40, 0.66, 1 })[1],
                (COLORS.accent or { 0.52, 0.40, 0.66, 1 })[2],
                (COLORS.accent or { 0.52, 0.40, 0.66, 1 })[3],
                0.85,
            }
            ApplyFrame(header, hb, hbr)
        end
    end

    local logo = _G.ArtisanNexusSettings_HeaderLogo
    if logo then
        logo:SetTexture("Interface\\AddOns\\ArtisanNexus\\Media\\anlogo")
    end

    local ht = _G.ArtisanNexusSettings_HeaderTitle
    if ht then
        local tb = COLORS.textBright or { 0.96, 0.95, 0.97, 1 }
        ht:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1)
    end

    local fh = _G.ArtisanNexusSettings_FooterHint
    if fh then
        local dim = COLORS.textDim or { 0.58, 0.54, 0.64, 1 }
        fh:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1)
    end

    local close = _G.ArtisanNexusSettings_Close
    if close then
        --- Strict skin separation: Modern gets our glyph control, Classic keeps the
        --- native Blizzard look (the XML button no longer inherits UIPanelCloseButton,
        --- so Classic restores that art here).
        if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
            close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
            close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
            close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
        elseif ns.UI_AdoptShellGlyphButton then
            ns.UI_AdoptShellGlyphButton(close, "\195\151", "danger")
        end
        close:SetScript("OnClick", function()
            f:Hide()
        end)
    end

    self:InstallSettingsScroll()
    self:SyncScrollSkin()
    self:LayoutContentGrid()
    self:ApplySettingsHeaderClip()

    --- Reset buttons: reversible mode-aware skin (Modern pixel chrome vs
    --- native UIPanelButtonTemplate art) — see UI_StyleSettingsPanelButton.
    if ns.UI_StyleSettingsPanelButton then
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_ResetSession)
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_ResetOverall)
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_LootOverlayPosition)
    end
    if ns.UI_StyleSettingsDropDown then
        ns.UI_StyleSettingsDropDown(_G.ArtisanNexusSettings_UiModeDropDown)
        ns.UI_StyleSettingsDropDown(_G.ArtisanNexusSettings_AccentDropDown)
    end
    if ns.UI_StyleSettingsPanelButton then
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_AccentSwatch)
    end
end

--- Warband-style scroll column for FrameXML settings scroll host.
--- Guarded by its own flag: a Classic-first session must still be able to run
--- this on the first switch to Modern (the classic path used to share the flag
--- and permanently blocked the Factory install).
function ArtisanSettingsUI:InstallSettingsScroll()
    local scroll = _G.ArtisanNexusSettings_Scroll
    local f = self:GetRoot()
    local header = _G.ArtisanNexusSettings_Header
    if not scroll or not f or not header then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        return
    end

    local Factory = ns.UI and ns.UI.Factory
    if not Factory or not Factory.InstallScrollBarStyle then
        return
    end

    if scroll._anModernScrollInstalled then
        Factory:InstallScrollBarStyle(scroll)
        local barCol = scroll._anScrollBarColumn
        if not barCol then
            barCol = Factory:CreateScrollBarColumn(f, nil, SETTINGS_SCROLL_TOP_MODERN, SETTINGS_FOOTER_RESERVE)
            scroll._anScrollBarColumn = barCol
        elseif Factory.EnsureScrollBarColumnChrome then
            Factory:EnsureScrollBarColumnChrome(barCol)
        end
        scroll._anExternalBarColumn = true
        if scroll.ScrollBar and barCol then
            Factory:PositionScrollBarInContainer(scroll.ScrollBar, barCol, 0, scroll)
        end
        PositionSettingsScrollBarColumn(barCol, f, {
            topFrame = header,
            topPoint = "BOTTOM",
            topY = -8,
            bottomFrame = f,
            bottomPoint = "BOTTOM",
            bottomY = SETTINGS_FOOTER_RESERVE,
        })
        if ns.UI_FinishScrollLayout then
            ns.UI_FinishScrollLayout(scroll)
        end
        self:LayoutContentGrid()
        return
    end
    scroll._anModernScrollInstalled = true

    Factory:InstallScrollBarStyle(scroll)
    local barCol = scroll._anScrollBarColumn
    if not barCol then
        barCol = Factory:CreateScrollBarColumn(f, nil, SETTINGS_SCROLL_TOP_MODERN, SETTINGS_FOOTER_RESERVE)
        scroll._anScrollBarColumn = barCol
    elseif Factory.EnsureScrollBarColumnChrome then
        Factory:EnsureScrollBarColumnChrome(barCol)
    end
    PositionSettingsScrollBarColumn(barCol, f, {
        topFrame = header,
        topPoint = "BOTTOM",
        topY = -8,
        bottomFrame = f,
        bottomPoint = "BOTTOM",
        bottomY = SETTINGS_FOOTER_RESERVE,
    })
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -8)
    scroll:SetPoint("BOTTOMRIGHT", barCol, "BOTTOMLEFT", -2, 0)
    scroll._anScrollBarColumn = barCol
    scroll._anExternalBarColumn = true
    scroll._anScrollAnchorTL = { a1 = "TOPLEFT", frame = header, a2 = "BOTTOMLEFT", x = 4, y = -8 }
    scroll._anScrollAnchorBRHidden = { a1 = "BOTTOMRIGHT", frame = f, a2 = "BOTTOMRIGHT", x = -4, y = SETTINGS_FOOTER_RESERVE }
    scroll._anScrollAnchorBRShown = { a1 = "BOTTOMRIGHT", frame = barCol, a2 = "BOTTOMLEFT", x = -2, y = 0 }
    Factory:PositionScrollBarInContainer(scroll.ScrollBar, barCol, 0, scroll)
    if ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(scroll)
    end
    if ns.UI_RegisterViewportDebug then
        ns.UI_RegisterViewportDebug(scroll, "settings_scroll")
        ns.UI_RegisterViewportDebug(scroll._anScrollBarColumn, "settings_bar")
    end
    self:LayoutContentGrid()
end

--- Native template scrollbar in external column (FrameXML settings; Classic UI).
function ArtisanSettingsUI:ApplyClassicSettingsScroll(scroll, f, header)
    if not scroll or not f or not header then
        return
    end
    local Factory = ns.UI and ns.UI.Factory
    local layout = ns.UI_LAYOUT or {}
    local gap = layout.SCROLL_GAP or 2
    local footerReserve = SETTINGS_FOOTER_RESERVE
    local contentTop = (ns.UI_GetClassicShellContentTop and ns.UI_GetClassicShellContentTop()) or 56
    local scrollTopInset = contentTop + 4
    local classicInset = (ns.UI_GetClassicDialogInset and ns.UI_GetClassicDialogInset()) or 8

    local col = scroll._anScrollBarColumn
    if not col and Factory and Factory.CreateScrollBarColumn then
        col = Factory:CreateScrollBarColumn(f, nil, scrollTopInset, footerReserve, classicInset)
        scroll._anScrollBarColumn = col
    elseif col then
        if Factory and Factory.EnsureScrollBarColumnChrome then
            Factory:EnsureScrollBarColumnChrome(col)
        end
    end
    scroll._anExternalBarColumn = col ~= nil

    if not scroll._anSavedUpdateVis and scroll.UpdateScrollBarVisibility then
        scroll._anSavedUpdateVis = scroll.UpdateScrollBarVisibility
    end
    scroll.UpdateScrollBarVisibility = nil

    if col and col.Show then
        PositionSettingsScrollBarColumn(col, f, {
            topFrame = f,
            topPoint = "TOP",
            topY = -scrollTopInset,
            bottomFrame = f,
            bottomPoint = "BOTTOM",
            bottomY = footerReserve,
            rightInset = classicInset,
        })
        col:Show()
    end
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -scrollTopInset)
    scroll:SetClipsChildren(true)
    if col then
        scroll:SetPoint("BOTTOMRIGHT", col, "BOTTOMLEFT", -gap, 0)
    else
        scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, footerReserve)
    end
    scroll._anClassicScroll = true
    scroll._anModernScrollInstalled = nil
    scroll._anScrollAnchorTL = { a1 = "TOPLEFT", frame = f, a2 = "TOPLEFT", x = 4, y = -scrollTopInset }
    scroll._anScrollAnchorBRShown = col and { a1 = "BOTTOMRIGHT", frame = col, a2 = "BOTTOMLEFT", x = -gap, y = 0 } or nil
    scroll._anScrollAnchorBRHidden = { a1 = "BOTTOMRIGHT", frame = f, a2 = "BOTTOMRIGHT", x = -4, y = footerReserve }

    if Factory and col and scroll.ScrollBar then
        Factory:PositionNativeScrollBarInContainer(scroll.ScrollBar, col, scroll)
    end
    if col and ns.UI_HookClassicScrollBarColumnLayout then
        ns.UI_HookClassicScrollBarColumnLayout(scroll, col)
    end
    if ns.UI_ApplyClassicScrollBarLayout then
        ns.UI_ApplyClassicScrollBarLayout(scroll)
    end
    if ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(scroll)
    end
    if ns.UI_RegisterViewportDebug then
        ns.UI_RegisterViewportDebug(scroll, "settings_scroll")
        ns.UI_RegisterViewportDebug(scroll._anScrollBarColumn, "settings_bar")
    end
    self:LayoutContentGrid()
end

--- Classic <-> Modern scrollbar. The Factory install re-skins and reparents the
--- template scrollbar into a custom right column; Classic hides that column and
--- restores the native template scrollbar, Modern re-applies the column.
function ArtisanSettingsUI:SyncScrollSkin()
    local scroll = _G.ArtisanNexusSettings_Scroll
    local f = self:GetRoot()
    local header = _G.ArtisanNexusSettings_Header
    if not scroll or not f or not header then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        self:ApplyClassicSettingsScroll(scroll, f, header)
        return
    end
    -- Modern: install once (works for Classic-first sessions too), then
    -- reverse any classic leftovers and re-anchor to the modern layout.
    local firstInstall = not scroll._anModernScrollInstalled
    if firstInstall then
        self:InstallSettingsScroll()
    end
    if not scroll._anClassicScroll and not firstInstall then
        if ns.UI_ApplyModernScrollBarLayout then
            ns.UI_ApplyModernScrollBarLayout(scroll)
        end
        return
    end
    scroll._anClassicScroll = nil
    if scroll._anSavedUpdateVis then
        scroll.UpdateScrollBarVisibility = scroll._anSavedUpdateVis
        scroll._anSavedUpdateVis = nil
    end
    if ns.UI_ApplyModernScrollBarLayout then
        ns.UI_ApplyModernScrollBarLayout(scroll)
    end
    local col = scroll._anScrollBarColumn
    if col then
        col:Show()
        PositionSettingsScrollBarColumn(col, f, {
            topFrame = header,
            topPoint = "BOTTOM",
            topY = -8,
            bottomFrame = f,
            bottomPoint = "BOTTOM",
            bottomY = SETTINGS_FOOTER_RESERVE,
        })
    end
    scroll:ClearAllPoints()
    local tl = scroll._anScrollAnchorTL
    if tl then
        scroll:SetPoint(tl.a1, tl.frame, tl.a2, tl.x, tl.y)
    else
        scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -8)
    end
    local brShown = scroll._anScrollAnchorBRShown
    if brShown then
        scroll:SetPoint(brShown.a1, brShown.frame, brShown.a2, brShown.x, brShown.y)
    else
        scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, SETTINGS_FOOTER_RESERVE)
    end
    if ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(scroll)
    end
    self:LayoutContentGrid()
    self:ApplySettingsHeaderClip()
end

function ArtisanSettingsUI:RefreshThemeChrome()
    --- Mode-reversible chrome first: themed toggles / section strips / radio
    --- cards flip between skins, and the scroll column swaps with the template
    --- scrollbar. Both are idempotent, so re-running on theme refresh is safe.
    self:ApplyXmlThemedChrome()
    self:SyncScrollSkin()
    --- Reset buttons flip between template art (Classic) and pixel chrome (Modern).
    if ns.UI_StyleSettingsPanelButton then
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_ResetSession)
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_ResetOverall)
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_LootOverlayPosition)
    end
    if ns.UI_StyleSettingsDropDown then
        ns.UI_StyleSettingsDropDown(_G.ArtisanNexusSettings_UiModeDropDown)
        ns.UI_StyleSettingsDropDown(_G.ArtisanNexusSettings_AccentDropDown)
    end
    if ns.UI_StyleSettingsPanelButton then
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_AccentSwatch)
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        local f = self:GetRoot()
        if f and ns.UI_ApplyClassicDialogBackdrop then
            ns.UI_ApplyClassicDialogBackdrop(f)
        end
        local header = _G.ArtisanNexusSettings_Header
        if header and ns.UI_RefreshClassicWindowHeader then
            ns.UI_RefreshClassicWindowHeader(header)
        end
        local ht = _G.ArtisanNexusSettings_HeaderTitle
        if ht then
            ht:SetTextColor(1, 0.82, 0)
        end
        local fh = _G.ArtisanNexusSettings_FooterHint
        if fh then
            fh:SetTextColor(0.8, 0.8, 0.8)
        end
        for i = 1, #ArtisanSettingsUI.SETTINGS_CHECKBOX_NAMES do
            local b = _G[ArtisanSettingsUI.SETTINGS_CHECKBOX_NAMES[i]]
            if b and b.Text then
                b.Text:SetTextColor(1, 1, 1)
            end
        end
        self:SyncLightThemeAvailability()
        self:LayoutContentGrid()
        self:ApplySettingsHeaderClip()
        return
    end
    local tb = COLORS.textBright or { 0.96, 0.95, 0.97, 1 }
    local dim = COLORS.textDim or { 0.52, 0.50, 0.56, 1 }
    local tn = COLORS.textNormal or { 0.82, 0.80, 0.86, 1 }
    local titleNames = {
        "ArtisanNexusSettings_HeaderTitle",
        "ArtisanNexusSettings_TitleGeneralText",
        "ArtisanNexusSettings_TitleGatheringText",
        "ArtisanNexusSettings_TitleLootText",
        "ArtisanNexusSettings_TitleCraftBriefingText",
        "ArtisanNexusSettings_TitleAdvancedText",
    }
    for i = 1, #titleNames do
        local fs = _G[titleNames[i]]
        if fs and fs.SetTextColor then
            fs:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1)
        end
    end
    for i = 1, #ArtisanSettingsUI.SETTINGS_SECTION_FRAMES do
        local sec = _G[ArtisanSettingsUI.SETTINGS_SECTION_FRAMES[i]]
        if sec and sec._anTitleText and sec._anTitleText.SetTextColor then
            sec._anTitleText:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1)
        end
        if sec and sec._anSectionUnderline then
            local ac = COLORS.accent or { 0.52, 0.40, 0.66, 1 }
            sec._anSectionUnderline:SetColorTexture(ac[1], ac[2], ac[3], 0.55)
        elseif sec and sec.BorderTop and ns.UI_UpdateBorderColor then
            local sr, sg, sb, sa = 0.52, 0.40, 0.66, 0.35
            if ns.UI_GetSectionHeaderBorderRGBA then
                sr, sg, sb, sa = ns.UI_GetSectionHeaderBorderRGBA()
            else
                local ac = COLORS.accent or { 0.44, 0.32, 0.58, 1 }
                sr, sg, sb, sa = ac[1], ac[2], ac[3], 0.35
            end
            ns.UI_UpdateBorderColor(sec, { sr, sg, sb, sa })
            if sec.SetBackdropColor then
                local bg = COLORS.bgCard or { 0.125, 0.118, 0.138, 0.92 }
                sec:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
            end
        end
    end
    local fh = _G.ArtisanNexusSettings_FooterHint
    if fh then
        fh:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1)
    end
    for i = 1, #ArtisanSettingsUI.SETTINGS_CHECKBOX_NAMES do
        local b = _G[ArtisanSettingsUI.SETTINGS_CHECKBOX_NAMES[i]]
        if b and ns.UI_StyleSettingsCheckButton then
            ns.UI_StyleSettingsCheckButton(b)
        end
    end
    local ac = COLORS.accent or { 0.52, 0.40, 0.66, 1 }
    local f = self:GetRoot()
    if f then
        ApplyFrame(f, COLORS.bg or { 0.11, 0.105, 0.125, 0.98 }, {
            ac[1], ac[2], ac[3], 0.85,
        })
        local header = _G.ArtisanNexusSettings_Header
        if header then
            local hb = COLORS.lootHeaderBg or COLORS.accentDark or { 0.125, 0.105, 0.155, 1 }
            local hbr = COLORS.lootHeaderBorder or { ac[1], ac[2], ac[3], 0.85 }
            ApplyFrame(header, hb, hbr)
        end
    end
    local function tintSliderFonts(sl)
        if not sl then return end
        if sl.Text then sl.Text:SetTextColor(tn[1], tn[2], tn[3], tn[4] or 1) end
        if sl.Low then sl.Low:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1) end
        if sl.High then sl.High:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1) end
        local muted = COLORS.textMuted or { 0.72, 0.68, 0.78, 1 }
        if sl.Value then sl.Value:SetTextColor(muted[1], muted[2], muted[3], muted[4] or 1) end
    end
    tintSliderFonts(_G.ArtisanNexusSettings_BagSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_AhFreshSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_LootOverlayScaleSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_SessionRecentSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_SessionOverallSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_CraftBriefingTopSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_CraftBriefingAlertMinSlider)
    if ns.UI_StyleSettingsSlider then
        for i = 1, #ArtisanSettingsUI.SETTINGS_SLIDER_NAMES do
            ns.UI_StyleSettingsSlider(_G[ArtisanSettingsUI.SETTINGS_SLIDER_NAMES[i]])
        end
    end
    local scroll = _G.ArtisanNexusSettings_Scroll
    if scroll and ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(scroll)
    end
    self:SyncLightThemeAvailability()
    self:LayoutContentGrid()
    self:ApplySettingsHeaderClip()
end

function ArtisanSettingsUI:WireControls()
    if self.wired then return end
    if not _G.ArtisanNexusSettings_Minimap then return end

    self:ApplyChrome()
    self:ApplyLocalizedStaticText()

    --- Current-value readouts: template has none; every handler and
    --- RefreshControls writes into `slider.Value` guarded, so create them once.
    for i = 1, #ArtisanSettingsUI.SETTINGS_SLIDER_NAMES do
        EnsureSliderValueText(_G[ArtisanSettingsUI.SETTINGS_SLIDER_NAMES[i]])
    end

    local bag = _G.ArtisanNexusSettings_BagSlider
    if bag then
        bag:SetMinMaxValues(1, 40)
        bag:SetValueStep(1)
        bag.Low:SetText("1")
        bag.High:SetText("40")
        bag:SetScript("OnValueChanged", function(self, value)
            value = max(1, min(40, floor(value + 0.5)))
            self:SetValue(value)
            ArtisanNexus.db.profile.bagPressureThreshold = value
            if self.Value then
                self.Value:SetText(tostring(value))
            end
        end)
    end

    local ah = _G.ArtisanNexusSettings_AhFreshSlider
    if ah then
        ah:SetMinMaxValues(1, 72)
        ah:SetValueStep(1)
        ah.Low:SetText("1h")
        ah.High:SetText("72h")
        ah:SetScript("OnValueChanged", function(self, value)
            value = max(1, min(72, floor(value + 0.5)))
            self:SetValue(value)
            ArtisanNexus.db.profile.ahFreshTTL = value * 3600
            if self.Value then
                self.Value:SetText(tostring(value) .. "h")
            end
        end)
    end

    local SLS = ns.SessionLootService

    local overlayPosBtn = _G.ArtisanNexusSettings_LootOverlayPosition
    if overlayPosBtn then
        if ns.UI_StyleSettingsPanelButton then
            ns.UI_StyleSettingsPanelButton(overlayPosBtn)
        end
        overlayPosBtn:SetScript("OnClick", function()
            if not (ns.SessionLootOverlayUI and ns.SessionLootOverlayUI.TogglePositionEdit) then
                return
            end
            local editing = ns.SessionLootOverlayUI:TogglePositionEdit()
            RefreshOverlayPositionButtonLabel()
            if editing then
                local root = ArtisanSettingsUI:GetRoot()
                if root and root:IsShown() then
                    root:Hide()
                end
            end
        end)
        RefreshOverlayPositionButtonLabel()
    end

    local overlayScale = _G.ArtisanNexusSettings_LootOverlayScaleSlider
    if overlayScale then
        local SCALE_MIN_PCT = 75
        local SCALE_MAX_PCT = 150
        local SCALE_STEP = 5
        overlayScale:SetMinMaxValues(SCALE_MIN_PCT, SCALE_MAX_PCT)
        overlayScale:SetValueStep(SCALE_STEP)
        overlayScale.Low:SetText("75%")
        overlayScale.High:SetText("150%")
        overlayScale:SetScript("OnValueChanged", function(self, value)
            value = max(SCALE_MIN_PCT, min(SCALE_MAX_PCT, floor(value / SCALE_STEP + 0.5) * SCALE_STEP))
            self:SetValue(value)
            ArtisanNexus.db.profile.sessionLootOverlayScale = value / 100
            if self.Value then
                self.Value:SetText(tostring(value) .. "%")
            end
            if ns.SessionLootOverlayUI and ns.SessionLootOverlayUI.ApplySettingsScale then
                ns.SessionLootOverlayUI:ApplySettingsScale()
            end
        end)
    end

    local sessRecent = _G.ArtisanNexusSettings_SessionRecentSlider
    if sessRecent and SLS and SLS.GetSessionRecentHardLimits and SLS.GetMaxRecentLoot then
        local rMin, rMax = SLS:GetSessionRecentHardLimits()
        sessRecent:SetMinMaxValues(rMin, rMax)
        sessRecent:SetValueStep(1)
        sessRecent.Low:SetText(tostring(rMin))
        sessRecent.High:SetText(tostring(rMax))
        sessRecent:SetScript("OnValueChanged", function(self, value)
            value = max(rMin, min(rMax, floor(value + 0.5)))
            self:SetValue(value)
            ArtisanNexus.db.profile.sessionLootMaxRecent = value
            if self.Value then
                self.Value:SetText(tostring(value))
            end
            if E.SESSION_LOOT_UPDATED and ns.ArtisanNexus then
                ns.ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED)
            end
        end)
    end

    local sessOverall = _G.ArtisanNexusSettings_SessionOverallSlider
    if sessOverall and SLS and SLS.GetSessionOverallHardLimits and SLS.GetOverallEventsCap then
        local oMin, oMax = SLS:GetSessionOverallHardLimits()
        sessOverall:SetMinMaxValues(oMin, oMax)
        sessOverall:SetValueStep(1)
        sessOverall.Low:SetText(tostring(oMin))
        sessOverall.High:SetText(tostring(oMax))
        sessOverall:SetScript("OnValueChanged", function(self, value)
            value = max(oMin, min(oMax, floor(value + 0.5)))
            self:SetValue(value)
            ArtisanNexus.db.profile.sessionLootOverallCap = value
            if self.Value then
                self.Value:SetText(tostring(value))
            end
            if E.SESSION_LOOT_UPDATED and ns.ArtisanNexus then
                ns.ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED)
            end
        end)
    end

    _G.ArtisanNexusSettings_Minimap:SetScript("OnClick", function(self)
        SetMinimapFromUi(self:GetChecked())
    end)
    _G.ArtisanNexusSettings_LoginChat:SetScript("OnClick", function(self)
        ArtisanNexus.db.profile.showLoginChat = self:GetChecked()
    end)
    if _G.ArtisanNexusSettings_LightTheme then
        _G.ArtisanNexusSettings_LightTheme:SetScript("OnClick", function(self)
            ArtisanNexus.db.profile.themeMode = self:GetChecked() and "light" or "dark"
            ArtisanNexus:RefreshTheme()
            ArtisanSettingsUI:RefreshIfShown()
        end)
    end
    if _G.ArtisanNexusSettings_ClassColorAccent then
        _G.ArtisanNexusSettings_ClassColorAccent:SetScript("OnClick", function(self)
            ArtisanNexus.db.profile.useClassColorAccent = self:GetChecked() and true or false
            ArtisanNexus:RefreshTheme()
            ArtisanSettingsUI:RefreshAccentControls()
            ArtisanSettingsUI:RefreshIfShown()
        end)
    end

    local uiModeDd = _G.ArtisanNexusSettings_UiModeDropDown
    if uiModeDd then
        UIDropDownMenu_Initialize(uiModeDd, InitializeUiModeDropDown)
        ArtisanSettingsUI:RefreshUiModeDropdown()
    end

    local accentDd = _G.ArtisanNexusSettings_AccentDropDown
    if accentDd then
        UIDropDownMenu_Initialize(accentDd, InitializeAccentDropDown)
        if ArtisanSettingsUI.RefreshAccentDropdown then
            ArtisanSettingsUI:RefreshAccentDropdown()
        end
    end
    local accentSwatch = _G.ArtisanNexusSettings_AccentSwatch
    if accentSwatch then
        if ns.UI_StyleSettingsPanelButton then
            ns.UI_StyleSettingsPanelButton(accentSwatch)
        end
        accentSwatch:SetScript("OnClick", function()
            ArtisanNexus.db.profile.accentPreset = "custom"
            ArtisanSettingsUI:OpenAccentColorPicker()
        end)
        HookTooltip(accentSwatch,
            (L and L["CONFIG_ACCENT_PRESET_CUSTOM"]) or "Custom",
            (L and L["CONFIG_ACCENT_PICK_CUSTOM"]) or "")
    end
    ArtisanSettingsUI:RefreshAccentControls()

    _G.ArtisanNexusSettings_Gathering:SetScript("OnClick", function(self)
        SetGatheringEnabled(self:GetChecked())
        ArtisanSettingsUI:RefreshControls()
    end)

    _G.ArtisanNexusSettings_Fishing:SetScript("OnClick", function(self)
        SetFishingEnabled(self:GetChecked())
        ArtisanSettingsUI:RefreshControls()
    end)
    _G.ArtisanNexusSettings_OverloadInd:SetScript("OnClick", function(self)
        SetOverloadIndicator(self:GetChecked())
        ArtisanSettingsUI:RefreshControls()
    end)
    _G.ArtisanNexusSettings_OverloadHud:SetScript("OnClick", function(self)
        SetOverloadTrackerHud(self:GetChecked())
    end)
    _G.ArtisanNexusSettings_OverloadCastBtn:SetScript("OnClick", function(self)
        SetOverloadCastButtonVisible(self:GetChecked())
    end)
    _G.ArtisanNexusSettings_BagGuard:SetScript("OnClick", function(self)
        SetBagPressureGuard(self:GetChecked())
        ArtisanSettingsUI:RefreshControls()
    end)

    _G.ArtisanNexusSettings_LootHistory:SetScript("OnClick", function(self)
        SetLootHistoryEnabled(self:GetChecked())
        ArtisanSettingsUI:RefreshControls()
    end)
    _G.ArtisanNexusSettings_LootAuto:SetScript("OnClick", function(self)
        ArtisanNexus.db.profile.lootHistoryAutoOpen = self:GetChecked()
    end)
    _G.ArtisanNexusSettings_LootOverlay:SetScript("OnClick", function(self)
        SetSessionLootOverlayEnabled(self:GetChecked())
    end)

    _G.ArtisanNexusSettings_Debug:SetScript("OnClick", function(self)
        ArtisanNexus.db.profile.debugMode = self:GetChecked()
        --- QA viewport tints must follow the toggle live, same as `/an debug`.
        if ns.UI_RefreshAllViewportDebugChrome then
            ns.UI_RefreshAllViewportDebugChrome()
        end
    end)

    local function bindBriefingPrice(btn, mode)
        if not btn then return end
        btn:SetScript("OnClick", function()
            SetCraftBriefingPriceMode(mode)
            ArtisanSettingsUI:RefreshCraftBriefingPriceRadio()
            RebuildBriefingIfCached()
        end)
    end
    bindBriefingPrice(_G.ArtisanNexusSettings_CraftBriefingPriceSpot, "spot")
    bindBriefingPrice(_G.ArtisanNexusSettings_CraftBriefingPriceAvg, "avg")

    local cbBrief = _G.ArtisanNexusSettings_CraftBriefing
    if cbBrief then
        cbBrief:SetScript("OnClick", function(self)
            ArtisanNexus.db.profile.craftBriefingEnabled = self:GetChecked()
            RebuildBriefingIfCached()
            ArtisanSettingsUI:RefreshControls()
        end)
    end
    local cbChat = _G.ArtisanNexusSettings_CraftBriefingChat
    if cbChat then
        cbChat:SetScript("OnClick", function(self)
            ArtisanNexus.db.profile.craftBriefingChatNotify = self:GetChecked()
        end)
    end
    local cbOwned = _G.ArtisanNexusSettings_CraftBriefingOwned
    if cbOwned then
        cbOwned:SetScript("OnClick", function(self)
            ArtisanNexus.db.profile.craftBriefingOwnedOnly = self:GetChecked()
            RebuildBriefingIfCached()
        end)
    end
    local cbAlert = _G.ArtisanNexusSettings_CraftBriefingAlert
    if cbAlert then
        cbAlert:SetScript("OnClick", function(self)
            ArtisanNexus.db.profile.craftBriefingProactiveAlert = self:GetChecked()
            ArtisanSettingsUI:RefreshControls()
        end)
    end
    local cbConc = _G.ArtisanNexusSettings_CraftBriefingConc
    if cbConc then
        cbConc:SetScript("OnClick", function(self)
            ArtisanNexus.db.profile.craftBriefingConcentrationHints = self:GetChecked()
            RebuildBriefingIfCached()
        end)
    end
    local cbEquip = _G.ArtisanNexusSettings_CraftBriefingEquip
    if cbEquip then
        cbEquip:SetScript("OnClick", function(self)
            ArtisanNexus.db.profile.craftBriefingEquipmentHints = self:GetChecked()
            RebuildBriefingIfCached()
        end)
    end

    local cbTop = _G.ArtisanNexusSettings_CraftBriefingTopSlider
    if cbTop then
        cbTop:SetMinMaxValues(3, 15)
        cbTop:SetValueStep(1)
        cbTop.Low:SetText("3")
        cbTop.High:SetText("15")
        cbTop:SetScript("OnValueChanged", function(self, value)
            value = max(3, min(15, floor(value + 0.5)))
            self:SetValue(value)
            ArtisanNexus.db.profile.craftBriefingTopN = value
            if self.Value then
                self.Value:SetText(tostring(value))
            end
            RebuildBriefingIfCached()
        end)
    end

    local cbAlertMin = _G.ArtisanNexusSettings_CraftBriefingAlertMinSlider
    if cbAlertMin then
        cbAlertMin:SetMinMaxValues(0, 100)
        cbAlertMin:SetValueStep(1)
        cbAlertMin.Low:SetText("0g")
        cbAlertMin.High:SetText("100g")
        cbAlertMin:SetScript("OnValueChanged", function(self, value)
            value = max(0, min(100, floor(value + 0.5)))
            self:SetValue(value)
            ArtisanNexus.db.profile.craftBriefingAlertMinProfit = value * 10000
            if self.Value then
                self.Value:SetText(tostring(value) .. "g")
            end
        end)
    end

    _G.ArtisanNexusSettings_ResetSession:SetScript("OnClick", function()
        if ns.SessionLootService and ns.SessionLootService.ResetSession then
            ns.SessionLootService:ResetSession()
        end
    end)
    _G.ArtisanNexusSettings_ResetOverall:SetScript("OnClick", function()
        if ns.SessionLootService and ns.SessionLootService.ResetAllOverallData then
            ns.SessionLootService:ResetAllOverallData()
        end
    end)

    -- Tooltips
    HookTooltip(_G.ArtisanNexusSettings_Minimap, (L and L["CONFIG_MINIMAP_BUTTON"]) or "", (L and L["CONFIG_MINIMAP_BUTTON_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_LoginChat, (L and L["CONFIG_SHOW_LOGIN_CHAT"]) or "", (L and L["CONFIG_SHOW_LOGIN_CHAT_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_LightTheme,
        (L and L["CONFIG_LIGHT_THEME"]) or "Light theme",
        (L and L["CONFIG_LIGHT_THEME_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_ClassColorAccent,
        (L and L["CONFIG_USE_CLASS_COLOR_ACCENT"]) or "Use class color as accent",
        (L and L["CONFIG_USE_CLASS_COLOR_ACCENT_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_UiModeFrame,
        (L and L["CONFIG_UI_MODE"]) or "Interface style",
        (L and L["CONFIG_UI_MODE_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_AccentFrame,
        (L and L["CONFIG_ACCENT_COLOR"]) or "Accent color",
        (L and L["CONFIG_ACCENT_COLOR_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_Gathering, (L and L["CONFIG_GATHERING_LOOT"]) or "", (L and L["CONFIG_GATHERING_LOOT_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_Fishing, (L and L["CONFIG_FISHING_MODULE"]) or "Fishing module", (L and L["CONFIG_FISHING_MODULE_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_OverloadInd, (L and L["CONFIG_OVERLOAD_NODE_INDICATOR"]) or "", (L and L["CONFIG_OVERLOAD_NODE_INDICATOR_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_OverloadHud, (L and L["CONFIG_OVERLOAD_TRACKER_HUD"]) or "", (L and L["CONFIG_OVERLOAD_TRACKER_HUD_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_OverloadCastBtn, (L and L["CONFIG_OVERLOAD_CAST_BUTTON"]) or "", (L and L["CONFIG_OVERLOAD_CAST_BUTTON_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_BagGuard, (L and L["CONFIG_BAG_PRESSURE_GUARD"]) or "", (L and L["CONFIG_BAG_PRESSURE_GUARD_DESC"]) or "")
    HookTooltip(bag, (L and L["CONFIG_BAG_PRESSURE_THRESHOLD"]) or "", (L and L["CONFIG_BAG_PRESSURE_THRESHOLD_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_LootHistory, (L and L["CONFIG_LOOT_HISTORY_ENABLED"]) or "", (L and L["CONFIG_LOOT_HISTORY_ENABLED_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_LootAuto, (L and L["CONFIG_LOOT_HISTORY_AUTO_OPEN"]) or "", (L and L["CONFIG_LOOT_HISTORY_AUTO_OPEN_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_LootOverlay, (L and L["CONFIG_LOOT_OVERLAY"]) or "", (L and L["CONFIG_LOOT_OVERLAY_DESC"]) or "")
    if _G.ArtisanNexusSettings_LootOverlayPosition then
        HookTooltip(_G.ArtisanNexusSettings_LootOverlayPosition, (L and L["CONFIG_LOOT_OVERLAY_POSITION"]) or "",
            (L and L["CONFIG_LOOT_OVERLAY_POSITION_DESC"]) or "")
    end
    if _G.ArtisanNexusSettings_LootOverlayScaleSlider then
        HookTooltip(_G.ArtisanNexusSettings_LootOverlayScaleSlider, (L and L["CONFIG_LOOT_OVERLAY_SIZE"]) or "",
            (L and L["CONFIG_LOOT_OVERLAY_SIZE_DESC"]) or "")
    end
    if _G.ArtisanNexusSettings_SessionRecentSlider then
        HookTooltip(_G.ArtisanNexusSettings_SessionRecentSlider, (L and L["CONFIG_SESSION_LOOT_MAX_RECENT"]) or "",
            (L and L["CONFIG_SESSION_LOOT_MAX_RECENT_DESC"]) or "")
    end
    if _G.ArtisanNexusSettings_SessionOverallSlider then
        HookTooltip(_G.ArtisanNexusSettings_SessionOverallSlider, (L and L["CONFIG_SESSION_LOOT_OVERALL_CAP"]) or "",
            (L and L["CONFIG_SESSION_LOOT_OVERALL_CAP_DESC"]) or "")
    end
    HookTooltip(_G.ArtisanNexusSettings_Debug, (L and L["CONFIG_DEBUG"]) or "", (L and L["CONFIG_DEBUG_DESC"]) or "")
    HookTooltip(ah, (L and L["CONFIG_AH_FRESHNESS_HOURS"]) or "", (L and L["CONFIG_AH_FRESHNESS_HOURS_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_ResetSession, (L and L["CONFIG_RESET_ALL_SESSION"]) or "", (L and L["CONFIG_RESET_ALL_SESSION_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_ResetOverall, (L and L["CONFIG_RESET_ALL_OVERALL"]) or "", (L and L["CONFIG_RESET_ALL_OVERALL_DESC"]) or "")

    HookTooltip(_G.ArtisanNexusSettings_CraftBriefing, (L and L["CONFIG_CRAFT_BRIEFING"]) or "", (L and L["CONFIG_CRAFT_BRIEFING_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_CraftBriefingChat, (L and L["CONFIG_CRAFT_BRIEFING_CHAT"]) or "", (L and L["CONFIG_CRAFT_BRIEFING_CHAT_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_CraftBriefingOwned, (L and L["CONFIG_CRAFT_BRIEFING_OWNED"]) or "", (L and L["CONFIG_CRAFT_BRIEFING_OWNED_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_CraftBriefingAlert, (L and L["CONFIG_CRAFT_BRIEFING_ALERT"]) or "", (L and L["CONFIG_CRAFT_BRIEFING_ALERT_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_CraftBriefingAlertMinSlider,
        (L and L["CONFIG_CRAFT_BRIEFING_ALERT_MIN"]) or "",
        (L and L["CONFIG_CRAFT_BRIEFING_ALERT_MIN_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_CraftBriefingConc, (L and L["CONFIG_CRAFT_BRIEFING_CONC"]) or "", (L and L["CONFIG_CRAFT_BRIEFING_CONC_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_CraftBriefingEquip, (L and L["CONFIG_CRAFT_BRIEFING_EQUIP"]) or "", (L and L["CONFIG_CRAFT_BRIEFING_EQUIP_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_CraftBriefingTopSlider, (L and L["CONFIG_CRAFT_BRIEFING_TOP_N"]) or "", (L and L["CONFIG_CRAFT_BRIEFING_TOP_N_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_CraftBriefingPriceFrame, (L and L["CONFIG_CRAFT_BRIEFING_PRICE_LABEL"]) or "", (L and L["CONFIG_CRAFT_BRIEFING_PRICE_LABEL_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_CraftBriefingPriceSpot, (L and L["CONFIG_CRAFT_BRIEFING_PRICE_SPOT"]) or "", (L and L["CONFIG_CRAFT_BRIEFING_PRICE_SPOT_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_CraftBriefingPriceAvg, (L and L["CONFIG_CRAFT_BRIEFING_PRICE_AVG"]) or "", (L and L["CONFIG_CRAFT_BRIEFING_PRICE_AVG_DESC"]) or "")

    self:ApplyXmlThemedChrome()
    self:RefreshThemeChrome()

    self.wired = true
end

function ArtisanSettingsUI:RefreshCraftBriefingPriceRadio()
    local mode = ArtisanNexus.db.profile.craftBriefingPriceMode or "spot"
    local s = _G.ArtisanNexusSettings_CraftBriefingPriceSpot
    local a = _G.ArtisanNexusSettings_CraftBriefingPriceAvg
    if s then s:SetChecked(mode ~= "avg") end
    if a then a:SetChecked(mode == "avg") end
    self:SyncThemedToggleDots()
end

function ArtisanSettingsUI:RefreshControls()
    if not self.wired then
        return
    end
    local p = ArtisanNexus.db.profile

    _G.ArtisanNexusSettings_Minimap:SetChecked(not (p.minimap and p.minimap.hide))
    _G.ArtisanNexusSettings_LoginChat:SetChecked(p.showLoginChat and true or false)
    if _G.ArtisanNexusSettings_LightTheme then
        _G.ArtisanNexusSettings_LightTheme:SetChecked(p.themeMode == "light")
    end
    if _G.ArtisanNexusSettings_ClassColorAccent then
        _G.ArtisanNexusSettings_ClassColorAccent:SetChecked(p.useClassColorAccent and true or false)
    end
    self:RefreshUiModeDropdown()
    self:SyncLightThemeAvailability()
    self:RefreshAccentControls()

    local m = p.modulesEnabled
    _G.ArtisanNexusSettings_Gathering:SetChecked(m and m.gathering ~= false)
    _G.ArtisanNexusSettings_Fishing:SetChecked(not m or m.fishing ~= false)
    _G.ArtisanNexusSettings_OverloadInd:SetChecked(p.overloadNodeIndicatorEnabled ~= false)
    _G.ArtisanNexusSettings_OverloadHud:SetChecked(p.overloadTrackerHudEnabled ~= false)

    do
        local ob = p.overloadActionButton or {}
        local vis = ob.hidden ~= true
        _G.ArtisanNexusSettings_OverloadCastBtn:SetChecked(vis)
    end

    _G.ArtisanNexusSettings_BagGuard:SetChecked(p.bagPressureGuardEnabled ~= false)
    _G.ArtisanNexusSettings_LootHistory:SetChecked(p.lootHistoryEnabled ~= false)
    _G.ArtisanNexusSettings_LootAuto:SetChecked(p.lootHistoryAutoOpen and true or false)
    _G.ArtisanNexusSettings_LootOverlay:SetChecked(p.sessionLootOverlayEnabled == true)
    RefreshOverlayPositionButtonLabel()
    _G.ArtisanNexusSettings_Debug:SetChecked(p.debugMode and true or false)

    local thresh = p.bagPressureThreshold or 8
    local bag = _G.ArtisanNexusSettings_BagSlider
    if bag then
        bag:SetValue(thresh)
        if bag.Value then bag.Value:SetText(tostring(thresh)) end
    end

    local ttlSec = (type(p.ahFreshTTL) == "number" and p.ahFreshTTL > 0) and p.ahFreshTTL or AH_FRESH_DEFAULT_SEC
    local hrs = max(1, min(72, floor((ttlSec / 3600) + 0.5)))
    local ah = _G.ArtisanNexusSettings_AhFreshSlider
    if ah then
        ah:SetValue(hrs)
        if ah.Value then ah.Value:SetText(tostring(hrs) .. "h") end
    end

    do
        local SLS = ns.SessionLootService
        local oScale = _G.ArtisanNexusSettings_LootOverlayScaleSlider
        if oScale then
            local scale = tonumber(p.sessionLootOverlayScale)
            if not scale or scale ~= scale then
                scale = 1.15
            end
            scale = max(0.75, min(1.5, scale))
            local pct = floor(scale * 100 + 0.5)
            oScale:SetValue(pct)
            if oScale.Value then
                oScale.Value:SetText(tostring(pct) .. "%")
            end
        end
        local sr = _G.ArtisanNexusSettings_SessionRecentSlider
        if sr and SLS and SLS.GetMaxRecentLoot then
            local eff = SLS:GetMaxRecentLoot()
            sr:SetValue(eff)
            if sr.Value then
                sr.Value:SetText(tostring(eff))
            end
        end
        local so = _G.ArtisanNexusSettings_SessionOverallSlider
        if so and SLS and SLS.GetOverallEventsCap then
            local effO = SLS:GetOverallEventsCap()
            so:SetValue(effO)
            if so.Value then
                so.Value:SetText(tostring(effO))
            end
        end
    end

    self:RefreshCraftBriefingPriceRadio()

    local pBrief = p.craftBriefingEnabled ~= false
    if _G.ArtisanNexusSettings_CraftBriefing then
        _G.ArtisanNexusSettings_CraftBriefing:SetChecked(pBrief)
    end
    if _G.ArtisanNexusSettings_CraftBriefingChat then
        _G.ArtisanNexusSettings_CraftBriefingChat:SetChecked(p.craftBriefingChatNotify ~= false)
    end
    if _G.ArtisanNexusSettings_CraftBriefingOwned then
        _G.ArtisanNexusSettings_CraftBriefingOwned:SetChecked(p.craftBriefingOwnedOnly ~= false)
    end
    if _G.ArtisanNexusSettings_CraftBriefingAlert then
        _G.ArtisanNexusSettings_CraftBriefingAlert:SetChecked(p.craftBriefingProactiveAlert ~= false)
    end
    if _G.ArtisanNexusSettings_CraftBriefingConc then
        _G.ArtisanNexusSettings_CraftBriefingConc:SetChecked(p.craftBriefingConcentrationHints ~= false)
    end
    if _G.ArtisanNexusSettings_CraftBriefingEquip then
        _G.ArtisanNexusSettings_CraftBriefingEquip:SetChecked(p.craftBriefingEquipmentHints ~= false)
    end
    local topN = tonumber(p.craftBriefingTopN) or 5
    topN = max(3, min(15, floor(topN + 0.5)))
    local cbTop = _G.ArtisanNexusSettings_CraftBriefingTopSlider
    if cbTop then
        cbTop:SetValue(topN)
        if cbTop.Value then cbTop.Value:SetText(tostring(topN)) end
    end
    local alertGold = tonumber(p.craftBriefingAlertMinProfit) or 10000
    alertGold = max(0, min(100, floor((alertGold / 10000) + 0.5)))
    local cbAlertMin = _G.ArtisanNexusSettings_CraftBriefingAlertMinSlider
    if cbAlertMin then
        cbAlertMin:SetValue(alertGold)
        if cbAlertMin.Value then cbAlertMin.Value:SetText(tostring(alertGold) .. "g") end
    end
    local briefOn = pBrief and p.enabled ~= false
    local briefChildren = {
        "ArtisanNexusSettings_CraftBriefingChat",
        "ArtisanNexusSettings_CraftBriefingOwned",
        "ArtisanNexusSettings_CraftBriefingAlert",
        "ArtisanNexusSettings_CraftBriefingAlertMinSlider",
        "ArtisanNexusSettings_CraftBriefingConc",
        "ArtisanNexusSettings_CraftBriefingEquip",
        "ArtisanNexusSettings_CraftBriefingTopSlider",
        "ArtisanNexusSettings_CraftBriefingPriceFrame",
        "ArtisanNexusSettings_CraftBriefingPriceSpot",
        "ArtisanNexusSettings_CraftBriefingPriceAvg",
    }
    for i = 1, #briefChildren do
        local w = _G[briefChildren[i]]
        if w and w.SetEnabled then
            w:SetEnabled(briefOn)
        end
    end
    if cbAlertMin and cbAlertMin.SetEnabled then
        cbAlertMin:SetEnabled(briefOn and p.craftBriefingProactiveAlert ~= false)
    end

    local guardOff = p.bagPressureGuardEnabled == false
    if bag then
        bag:SetEnabled(not guardOff and (p.enabled ~= false))
    end
    _G.ArtisanNexusSettings_LootAuto:SetEnabled(not (p.lootHistoryEnabled == false) and (p.enabled ~= false))
    _G.ArtisanNexusSettings_OverloadHud:SetEnabled(p.overloadNodeIndicatorEnabled ~= false and (p.enabled ~= false))
    local overlayExtrasOn = p.enabled ~= false and p.sessionLootOverlayEnabled == true
    if _G.ArtisanNexusSettings_LootOverlayPosition then
        _G.ArtisanNexusSettings_LootOverlayPosition:SetEnabled(overlayExtrasOn)
    end
    if _G.ArtisanNexusSettings_LootOverlayScaleSlider then
        _G.ArtisanNexusSettings_LootOverlayScaleSlider:SetEnabled(overlayExtrasOn)
    end

    local addonOn = p.enabled ~= false
    local names = {
        "ArtisanNexusSettings_Minimap", "ArtisanNexusSettings_LoginChat", "ArtisanNexusSettings_LightTheme",
        "ArtisanNexusSettings_ClassColorAccent",
        "ArtisanNexusSettings_UiModeDropDown",
        "ArtisanNexusSettings_AccentDropDown",
        "ArtisanNexusSettings_Gathering", "ArtisanNexusSettings_Fishing", "ArtisanNexusSettings_OverloadInd", "ArtisanNexusSettings_OverloadHud",
        "ArtisanNexusSettings_OverloadCastBtn", "ArtisanNexusSettings_BagGuard",
        "ArtisanNexusSettings_LootHistory", "ArtisanNexusSettings_LootAuto", "ArtisanNexusSettings_LootOverlay",
        "ArtisanNexusSettings_SessionRecentSlider", "ArtisanNexusSettings_SessionOverallSlider",
        "ArtisanNexusSettings_Debug",
        "ArtisanNexusSettings_ResetSession", "ArtisanNexusSettings_ResetOverall",
    }
    for i = 1, #names do
        local w = _G[names[i]]
        if w and w.SetEnabled then
            w:SetEnabled(addonOn)
        end
    end
    if ah and ah.SetEnabled then
        ah:SetEnabled(addonOn)
    end

    if ns.UI_UpdateSettingsSliderFill and ArtisanSettingsUI.SETTINGS_SLIDER_NAMES then
        for i = 1, #ArtisanSettingsUI.SETTINGS_SLIDER_NAMES do
            ns.UI_UpdateSettingsSliderFill(_G[ArtisanSettingsUI.SETTINGS_SLIDER_NAMES[i]])
        end
    end

    self:SyncThemedToggleDots()
end

function ArtisanSettingsUI:RefreshIfShown()
    local f = self:GetRoot()
    if f and f:IsShown() then
        self:RefreshThemeChrome()
        self:RefreshControls()
    end
end

function ArtisanSettingsUI:Toggle()
    local fr = self:GetRoot()
    if not fr then
        return
    end
    if fr:IsShown() then
        fr:Hide()
    else
        self:ShowPanel()
    end
end

function ArtisanSettingsUI:ShowPanel()
    if InCombatLockdown() then
        ArtisanNexus:Print((L and L["SETTINGS_COMBAT_LOCK"]) or "Settings cannot be opened during combat lockdown.")
        return
    end
    local fr = self:GetRoot()
    if not fr then
        ArtisanNexus:Print((L and L["SETTINGS_UI_UNAVAILABLE"]) or "Settings UI is not available.")
        return
    end
    self:WireControls()
    self:ApplyLocalizedStaticText()
    --- Skin may have been switched while the panel was hidden (slash / options);
    --- WireControls is one-shot, so re-sync chrome on every open.
    self:RefreshThemeChrome()
    self:RefreshControls()
    self:LayoutContentGrid()
    --- Bar visibility/thumb must be computed AFTER the grid set the final
    --- content height, not against the previous panel's height.
    local scroll = _G.ArtisanNexusSettings_Scroll
    if scroll and ns.UI_FinishScrollLayout then
        ns.UI_FinishScrollLayout(scroll)
    end
    self:ApplySettingsHeaderClip()
    --- XML anchors this frame at CENTER on load; restore the last-left position
    --- so it reopens where the user dropped it.
    fr._anPosKey = "settingsFrame"
    if ns.UI_RestoreWindowPosition then
        ns.UI_RestoreWindowPosition(fr)
    end
    fr:Show()
    fr:Raise()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if fr:IsShown() then
                ArtisanSettingsUI:RefreshThemeChrome()
                ArtisanSettingsUI:SyncThemedToggleDots()
            end
        end)
    end
end

function ArtisanSettingsUI:HidePanel()
    local fr = self:GetRoot()
    if fr then
        fr:Hide()
    end
end

function ArtisanSettingsUI:Init()
    self:GetRoot()
    self:InstallSettingsScroll()
    if E.THEME_CHANGED and not self._eventOwner then
        self._eventOwner = ns.NewEventOwner("ArtisanSettingsUI")
        self._eventOwner:RegisterMessage(E.THEME_CHANGED, function()
            ArtisanSettingsUI:RefreshIfShown()
        end)
    end
end

ns.ArtisanSettingsUI = ArtisanSettingsUI
