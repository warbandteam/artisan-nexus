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

local AH_FRESH_DEFAULT_SEC = 60 * 60 * 6

--- XML `UICheckButton` global names — themed like Warband `CreateThemedCheckbox`.
local SETTINGS_CHECKBOX_NAMES = {
    "ArtisanNexusSettings_Minimap",
    "ArtisanNexusSettings_LoginChat",
    "ArtisanNexusSettings_LightTheme",
    "ArtisanNexusSettings_ClassicUi",
    "ArtisanNexusSettings_Gathering",
    "ArtisanNexusSettings_Fishing",
    "ArtisanNexusSettings_OverloadInd",
    "ArtisanNexusSettings_OverloadHud",
    "ArtisanNexusSettings_OverloadCastBtn",
    "ArtisanNexusSettings_BagGuard",
    "ArtisanNexusSettings_LootHistory",
    "ArtisanNexusSettings_LootAuto",
    "ArtisanNexusSettings_Debug",
    "ArtisanNexusSettings_PostingUndercut",
    "ArtisanNexusSettings_PostingAverage",
    "ArtisanNexusSettings_PostingMax",
    "ArtisanNexusSettings_CraftBriefing",
    "ArtisanNexusSettings_CraftBriefingChat",
    "ArtisanNexusSettings_CraftBriefingOwned",
    "ArtisanNexusSettings_CraftBriefingAlert",
    "ArtisanNexusSettings_CraftBriefingConc",
    "ArtisanNexusSettings_CraftBriefingEquip",
    "ArtisanNexusSettings_CraftBriefingPriceSpot",
    "ArtisanNexusSettings_CraftBriefingPriceAvg",
}

local SETTINGS_SECTION_FRAMES = {
    "ArtisanNexusSettings_TitleGeneral",
    "ArtisanNexusSettings_TitleGathering",
    "ArtisanNexusSettings_TitleLoot",
    "ArtisanNexusSettings_TitleCraftBriefing",
    "ArtisanNexusSettings_TitleAdvanced",
}

--- Checkbox groups laid out in 2–3 columns (positions computed in Lua; XML keeps widget defs only).
local SETTINGS_GRID_SECTIONS = {
    {
        title = "ArtisanNexusSettings_TitleGeneral",
        cols = 2,
        checks = {
            "ArtisanNexusSettings_Minimap",
            "ArtisanNexusSettings_LoginChat",
            "ArtisanNexusSettings_LightTheme",
            "ArtisanNexusSettings_ClassicUi",
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
        },
        sliders = {
            "ArtisanNexusSettings_SessionRecentSlider",
            "ArtisanNexusSettings_SessionOverallSlider",
        },
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
        labelFrames = { "ArtisanNexusSettings_PostingLabelFrame" },
        tailChecks = {
            "ArtisanNexusSettings_PostingUndercut",
            "ArtisanNexusSettings_PostingAverage",
            "ArtisanNexusSettings_PostingMax",
        },
        tailCols = 2,
        sliders = { "ArtisanNexusSettings_AhFreshSlider" },
        resetButtons = {
            "ArtisanNexusSettings_ResetSession",
            "ArtisanNexusSettings_ResetOverall",
        },
    },
}

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

local function SetPostingStrategy(strat)
    local p = ArtisanNexus.db.profile
    p.posting = p.posting or {}
    p.posting.strategy = strat
    if ns.PostingHelperService and ns.PostingHelperService.SetConfig then
        ns.PostingHelperService:SetConfig({ strategy = strat })
    end
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
function ArtisanSettingsUI:LayoutContentGrid()
    local content = _G.ArtisanNexusSettings_ScrollContent
    local scroll = _G.ArtisanNexusSettings_Scroll
    if not content then
        return
    end
    local PAD = 16
    local GAP_X = 12
    local GAP_Y = 10
    local ROW_H = 32
    local TITLE_H = 26
    local SECTION_GAP = 18
    local SLIDER_H = 34
    local LABEL_H = 22
    local FULL_GAP = 12

    local scrollW = (scroll and scroll:GetWidth()) or 556
    local usableW = max(320, scrollW - PAD * 2)

    local y = -12

    local function placeTitle(name)
        local fr = _G[name]
        if not fr then
            return
        end
        fr:ClearAllPoints()
        fr:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
        fr:SetWidth(usableW)
        y = y - TITLE_H - 8
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
                if btn.Text and btn.Text.SetWidth then
                    btn.Text:SetWidth(max(120, colW - 28))
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
                sl:ClearAllPoints()
                sl:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, y)
                sl:SetWidth(min(usableW, 420))
                y = y - SLIDER_H - FULL_GAP
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
                y = y - LABEL_H - 8
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
                y = y - 30 - 8
            end
        end
    end

    for s = 1, #SETTINGS_GRID_SECTIONS do
        local sec = SETTINGS_GRID_SECTIONS[s]
        placeTitle(sec.title)
        placeChecks(sec.checks, sec.cols)
        placeSliders(sec.sliders)
        placeLabelFrames(sec.labelFrames)
        if sec.tailChecks then
            placeChecks(sec.tailChecks, sec.tailCols or 2)
        end
        placeResetButtons(sec.resetButtons)
    end

    content:SetHeight(max(420, -y + 48))
end

function ArtisanSettingsUI:ApplySettingsHeaderClip()
    local header = _G.ArtisanNexusSettings_Header
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
        fs:SetText((L and L[key]) or fallback or "")
    end

    T(_G.ArtisanNexusSettings_TitleGeneralText, "SETTINGS_SECTION_GENERAL", "General")
    T(_G.ArtisanNexusSettings_TitleGatheringText, "SETTINGS_SECTION_GATHERING", "Gathering, overload & routes")
    T(_G.ArtisanNexusSettings_TitleLootText, "SETTINGS_SECTION_LOOT", "Loot & session")
    T(_G.ArtisanNexusSettings_TitleCraftBriefingText, "SETTINGS_SECTION_CRAFT_BRIEFING", "Craft briefing")
    T(_G.ArtisanNexusSettings_TitleAdvancedText, "SETTINGS_SECTION_ADVANCED", "Advanced & data")

    T(_G.ArtisanNexusSettings_HeaderTitle, "CONFIG_HEADER", "Artisan Nexus")
    T(_G.ArtisanNexusSettings_FooterHint, "SETTINGS_FOOTER_HINT", "/an config")
    T(_G.ArtisanNexusSettings_PostingLabel, "CONFIG_POSTING_STRATEGY", "AH posting suggestion")

    CheckText(_G.ArtisanNexusSettings_Minimap, (L and L["CONFIG_MINIMAP_BUTTON"]) or "")
    CheckText(_G.ArtisanNexusSettings_LoginChat, (L and L["CONFIG_SHOW_LOGIN_CHAT"]) or "")
    CheckText(_G.ArtisanNexusSettings_LightTheme, (L and L["CONFIG_LIGHT_THEME"]) or "Light theme")
    CheckText(_G.ArtisanNexusSettings_ClassicUi, (L and L["CONFIG_CLASSIC_UI"]) or "Classic UI")

    CheckText(_G.ArtisanNexusSettings_Gathering, (L and L["CONFIG_GATHERING_LOOT"]) or "")
    CheckText(_G.ArtisanNexusSettings_Fishing, (L and L["CONFIG_FISHING_MODULE"]) or "Fishing module")
    CheckText(_G.ArtisanNexusSettings_OverloadInd, (L and L["CONFIG_OVERLOAD_NODE_INDICATOR"]) or "")
    CheckText(_G.ArtisanNexusSettings_OverloadHud, (L and L["CONFIG_OVERLOAD_TRACKER_HUD"]) or "")
    CheckText(_G.ArtisanNexusSettings_OverloadCastBtn, (L and L["CONFIG_OVERLOAD_CAST_BUTTON"]) or "")
    CheckText(_G.ArtisanNexusSettings_BagGuard, (L and L["CONFIG_BAG_PRESSURE_GUARD"]) or "")

    CheckText(_G.ArtisanNexusSettings_LootHistory, (L and L["CONFIG_LOOT_HISTORY_ENABLED"]) or "")
    CheckText(_G.ArtisanNexusSettings_LootAuto, (L and L["CONFIG_LOOT_HISTORY_AUTO_OPEN"]) or "")

    CheckText(_G.ArtisanNexusSettings_Debug, (L and L["CONFIG_DEBUG"]) or "")

    CheckText(_G.ArtisanNexusSettings_PostingUndercut, (L and L["CONFIG_POSTING_UNDERCUT"]) or "")
    CheckText(_G.ArtisanNexusSettings_PostingAverage, (L and L["CONFIG_POSTING_AVERAGE"]) or "")
    CheckText(_G.ArtisanNexusSettings_PostingMax, (L and L["CONFIG_POSTING_MAX"]) or "")

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
    local sOverall = _G.ArtisanNexusSettings_SessionOverallSlider
    if sOverall and sOverall.Text then
        sOverall.Text:SetText((L and L["CONFIG_SESSION_LOOT_OVERALL_CAP"]) or "")
    end
end

--- Warband-style themed toggles + section strips on FrameXML controls (once per session).
function ArtisanSettingsUI:ApplyXmlThemedChrome()
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        return
    end
    local StyleCb = ns.UI_StyleSettingsCheckButton
    local StyleSec = ns.UI_StyleSettingsSectionTitle
    if not StyleCb or not StyleSec then
        return
    end
    for i = 1, #SETTINGS_SECTION_FRAMES do
        StyleSec(_G[SETTINGS_SECTION_FRAMES[i]])
    end
    for i = 1, #SETTINGS_CHECKBOX_NAMES do
        StyleCb(_G[SETTINGS_CHECKBOX_NAMES[i]])
    end

    --- Radio-group cards: mode-aware and re-runnable (classic inset <-> pixel chrome).
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
    StyleRadioCard(_G.ArtisanNexusSettings_PostingLabelFrame)
    StyleRadioCard(_G.ArtisanNexusSettings_CraftBriefingPriceFrame)

    local function tintSliderFonts(sl)
        if not sl then return end
        local tb = COLORS.textBright or { 0.98, 0.97, 0.99, 1 }
        local dim = COLORS.textDim or { 0.58, 0.54, 0.64, 1 }
        if sl.Text then sl.Text:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1) end
        if sl.Low then sl.Low:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1) end
        if sl.High then sl.High:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1) end
        if sl.Value then sl.Value:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1) end
    end
    tintSliderFonts(_G.ArtisanNexusSettings_BagSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_AhFreshSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_SessionRecentSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_SessionOverallSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_CraftBriefingTopSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_CraftBriefingAlertMinSlider)
end

function ArtisanSettingsUI:SyncThemedToggleDots()
    for i = 1, #SETTINGS_CHECKBOX_NAMES do
        local b = _G[SETTINGS_CHECKBOX_NAMES[i]]
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
end

function ArtisanSettingsUI:ApplyChrome()
    local f = self:GetRoot()
    if not f then return end

    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_ApplyClassicDialogBackdrop then
            ns.UI_ApplyClassicDialogBackdrop(f)
        end
        f._anClassicDialogRoot = true
        if f.SetClipsChildren then
            f:SetClipsChildren(true)
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
    end
end

--- Warband-style scroll column for FrameXML settings scroll host.
function ArtisanSettingsUI:InstallSettingsScroll()
    local scroll = _G.ArtisanNexusSettings_Scroll
    local f = self:GetRoot()
    local header = _G.ArtisanNexusSettings_Header
    if not scroll or not f or not header or scroll._anScrollInstalled then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        return
    end
    scroll._anScrollInstalled = true

    local Factory = ns.UI and ns.UI.Factory
    if not Factory or not Factory.InstallScrollBarStyle then
        return
    end

    Factory:InstallScrollBarStyle(scroll)
    local barCol = scroll._anScrollBarColumn
    if not barCol then
        barCol = Factory:CreateScrollBarColumn(f, nil, 54, 38)
        scroll._anScrollBarColumn = barCol
    elseif Factory.EnsureScrollBarColumnChrome then
        Factory:EnsureScrollBarColumnChrome(barCol)
    end
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -8)
    scroll:SetPoint("BOTTOMRIGHT", barCol, "BOTTOMLEFT", -2, 0)
    scroll._anScrollBarColumn = barCol
    scroll._anExternalBarColumn = true
    scroll._anScrollAnchorTL = { a1 = "TOPLEFT", frame = header, a2 = "BOTTOMLEFT", x = 4, y = -8 }
    scroll._anScrollAnchorBRHidden = { a1 = "BOTTOMRIGHT", frame = f, a2 = "BOTTOMRIGHT", x = -4, y = 38 }
    scroll._anScrollAnchorBRShown = { a1 = "BOTTOMRIGHT", frame = barCol, a2 = "BOTTOMLEFT", x = -2, y = 0 }
    Factory:PositionScrollBarInContainer(scroll.ScrollBar, barCol, 0)
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
    local footerReserve = 38
    local headerBottomY = -54

    local col = scroll._anScrollBarColumn
    if not col and Factory and Factory.CreateScrollBarColumn then
        col = Factory:CreateScrollBarColumn(f, nil, math.abs(headerBottomY), footerReserve)
        scroll._anScrollBarColumn = col
    elseif col and Factory and Factory.EnsureScrollBarColumnChrome then
        Factory:EnsureScrollBarColumnChrome(col)
    end
    if col and col.Show then
        col:Show()
    end
    scroll._anExternalBarColumn = col ~= nil
    scroll._anScrollInstalled = true

    if not scroll._anSavedUpdateVis and scroll.UpdateScrollBarVisibility then
        scroll._anSavedUpdateVis = scroll.UpdateScrollBarVisibility
    end
    scroll.UpdateScrollBarVisibility = nil

    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 4, -8)
    scroll:SetClipsChildren(true)
    if col then
        scroll:SetPoint("BOTTOMRIGHT", col, "BOTTOMLEFT", -gap, 0)
    else
        scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, footerReserve)
    end
    scroll._anClassicScroll = true
    scroll._anScrollAnchorTL = { a1 = "TOPLEFT", frame = header, a2 = "BOTTOMLEFT", x = 4, y = -8 }
    scroll._anScrollAnchorBRShown = col and { a1 = "BOTTOMRIGHT", frame = col, a2 = "BOTTOMLEFT", x = -gap, y = 0 } or nil
    scroll._anScrollAnchorBRHidden = { a1 = "BOTTOMRIGHT", frame = f, a2 = "BOTTOMRIGHT", x = -4, y = 38 }

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
    -- Modern: first entry installs; returning from classic re-applies.
    if not scroll._anScrollInstalled then
        self:InstallSettingsScroll()
        return
    end
    if not scroll._anClassicScroll then
        return
    end
    scroll._anClassicScroll = nil
    if scroll._anSavedUpdateVis then
        scroll.UpdateScrollBarVisibility = scroll._anSavedUpdateVis
        scroll._anSavedUpdateVis = nil
    end
    local bar = scroll.ScrollBar
    local col = scroll._anScrollBarColumn
    if col then
        col:Show()
    end
    if bar then
        if bar.ScrollUpButton then
            bar.ScrollUpButton:Hide()
            bar.ScrollUpButton:SetSize(0.1, 0.1)
        end
        if bar.ScrollDownButton then
            bar.ScrollDownButton:Hide()
            bar.ScrollDownButton:SetSize(0.1, 0.1)
        end
        if bar.CustomTrack then
            bar.CustomTrack:Show()
        end
        if ns.UI_RestoreArtisanChrome then
            ns.UI_RestoreArtisanChrome(bar)
        end
        if bar.ThumbTexture then
            local ac = COLORS.accent or { 0.44, 0.32, 0.58, 1 }
            bar.ThumbTexture:SetColorTexture(ac[1], ac[2], ac[3], 0.9)
            bar.ThumbTexture:SetSize(14, 60)
        end
        bar:SetScript("OnEnter", function(s)
            if s.ThumbTexture then
                local a = COLORS.accent or { 0.44, 0.32, 0.58, 1 }
                s.ThumbTexture:SetColorTexture(min(1, a[1] * 1.2), min(1, a[2] * 1.2), min(1, a[3] * 1.2), 1)
            end
        end)
        bar:SetScript("OnLeave", function(s)
            if s.ThumbTexture then
                local a = COLORS.accent or { 0.44, 0.32, 0.58, 1 }
                s.ThumbTexture:SetColorTexture(a[1], a[2], a[3], 0.9)
            end
        end)
        local Factory = ns.UI and ns.UI.Factory
        if Factory and col then
            Factory:PositionScrollBarInContainer(bar, col, 0)
        end
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
        scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 38)
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
    if self.wired then
        self:ApplyXmlThemedChrome()
    end
    self:SyncScrollSkin()
    --- Reset buttons flip between template art (Classic) and pixel chrome (Modern).
    if ns.UI_StyleSettingsPanelButton then
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_ResetSession)
        ns.UI_StyleSettingsPanelButton(_G.ArtisanNexusSettings_ResetOverall)
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
        for i = 1, #SETTINGS_CHECKBOX_NAMES do
            local b = _G[SETTINGS_CHECKBOX_NAMES[i]]
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
    for i = 1, #SETTINGS_SECTION_FRAMES do
        local sec = _G[SETTINGS_SECTION_FRAMES[i]]
        if sec and sec._anTitleText and sec._anTitleText.SetTextColor then
            sec._anTitleText:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1)
        end
        if sec and sec.BorderTop and ns.UI_UpdateBorderColor then
            local ac = COLORS.accent or { 0.44, 0.32, 0.58, 1 }
            local brBase = COLORS.lootHeaderBorder or { ac[1], ac[2], ac[3], 0.88 }
            local br = { brBase[1], brBase[2], brBase[3], math.min(brBase[4] or 0.88, 0.55) }
            ns.UI_UpdateBorderColor(sec, br)
            if sec.SetBackdropColor then
                local bg = COLORS.lootHeaderBg or COLORS.accentDark or { 0.125, 0.105, 0.155, 1 }
                sec:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
            end
        end
    end
    local fh = _G.ArtisanNexusSettings_FooterHint
    if fh then
        fh:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1)
    end
    local chromeBg = ns.UI_GetControlChromeBackdrop and ns.UI_GetControlChromeBackdrop()
    local ac = COLORS.accent or { 0.52, 0.40, 0.66, 1 }
    local borderCol = { ac[1], ac[2], ac[3], 0.82 }
    for i = 1, #SETTINGS_CHECKBOX_NAMES do
        local b = _G[SETTINGS_CHECKBOX_NAMES[i]]
        if b and b.anThemedHost then
            if chromeBg and b.anThemedHost.SetBackdropColor then
                b.anThemedHost:SetBackdropColor(chromeBg[1], chromeBg[2], chromeBg[3], chromeBg[4] or 1)
            end
            if b.anThemedHost.BorderTop and ns.UI_UpdateBorderColor then
                ns.UI_UpdateBorderColor(b.anThemedHost, borderCol)
            end
        end
        if b and b.Text then
            b.Text:SetTextColor(tn[1], tn[2], tn[3], tn[4] or 1)
        end
    end
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
        if sl.Text then sl.Text:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1) end
        if sl.Low then sl.Low:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1) end
        if sl.High then sl.High:SetTextColor(dim[1], dim[2], dim[3], dim[4] or 1) end
        if sl.Value then sl.Value:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1) end
    end
    tintSliderFonts(_G.ArtisanNexusSettings_BagSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_AhFreshSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_SessionRecentSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_SessionOverallSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_CraftBriefingTopSlider)
    tintSliderFonts(_G.ArtisanNexusSettings_CraftBriefingAlertMinSlider)
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
    if _G.ArtisanNexusSettings_ClassicUi then
        _G.ArtisanNexusSettings_ClassicUi:SetScript("OnClick", function(self)
            ArtisanNexus.db.profile.uiMode = self:GetChecked() and "classic" or "modern"
            if ArtisanNexus.RefreshUiMode then
                ArtisanNexus:RefreshUiMode()
            end
            ArtisanSettingsUI:RefreshIfShown()
        end)
    end

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

    _G.ArtisanNexusSettings_Debug:SetScript("OnClick", function(self)
        ArtisanNexus.db.profile.debugMode = self:GetChecked()
    end)

    local function bindPosting(btn, strat)
        if not btn then return end
        btn:SetScript("OnClick", function()
            SetPostingStrategy(strat)
            ArtisanSettingsUI:RefreshPostingRadio()
        end)
    end
    bindPosting(_G.ArtisanNexusSettings_PostingUndercut, "undercut")
    bindPosting(_G.ArtisanNexusSettings_PostingAverage, "average")
    bindPosting(_G.ArtisanNexusSettings_PostingMax, "max")

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
    HookTooltip(_G.ArtisanNexusSettings_ClassicUi,
        (L and L["CONFIG_CLASSIC_UI"]) or "Classic UI",
        (L and L["CONFIG_CLASSIC_UI_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_Gathering, (L and L["CONFIG_GATHERING_LOOT"]) or "", (L and L["CONFIG_GATHERING_LOOT_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_Fishing, (L and L["CONFIG_FISHING_MODULE"]) or "Fishing module", (L and L["CONFIG_FISHING_MODULE_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_OverloadInd, (L and L["CONFIG_OVERLOAD_NODE_INDICATOR"]) or "", (L and L["CONFIG_OVERLOAD_NODE_INDICATOR_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_OverloadHud, (L and L["CONFIG_OVERLOAD_TRACKER_HUD"]) or "", (L and L["CONFIG_OVERLOAD_TRACKER_HUD_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_OverloadCastBtn, (L and L["CONFIG_OVERLOAD_CAST_BUTTON"]) or "", (L and L["CONFIG_OVERLOAD_CAST_BUTTON_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_BagGuard, (L and L["CONFIG_BAG_PRESSURE_GUARD"]) or "", (L and L["CONFIG_BAG_PRESSURE_GUARD_DESC"]) or "")
    HookTooltip(bag, (L and L["CONFIG_BAG_PRESSURE_THRESHOLD"]) or "", (L and L["CONFIG_BAG_PRESSURE_THRESHOLD_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_LootHistory, (L and L["CONFIG_LOOT_HISTORY_ENABLED"]) or "", (L and L["CONFIG_LOOT_HISTORY_ENABLED_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_LootAuto, (L and L["CONFIG_LOOT_HISTORY_AUTO_OPEN"]) or "", (L and L["CONFIG_LOOT_HISTORY_AUTO_OPEN_DESC"]) or "")
    if _G.ArtisanNexusSettings_SessionRecentSlider then
        HookTooltip(_G.ArtisanNexusSettings_SessionRecentSlider, (L and L["CONFIG_SESSION_LOOT_MAX_RECENT"]) or "",
            (L and L["CONFIG_SESSION_LOOT_MAX_RECENT_DESC"]) or "")
    end
    if _G.ArtisanNexusSettings_SessionOverallSlider then
        HookTooltip(_G.ArtisanNexusSettings_SessionOverallSlider, (L and L["CONFIG_SESSION_LOOT_OVERALL_CAP"]) or "",
            (L and L["CONFIG_SESSION_LOOT_OVERALL_CAP_DESC"]) or "")
    end
    HookTooltip(_G.ArtisanNexusSettings_Debug, (L and L["CONFIG_DEBUG"]) or "", (L and L["CONFIG_DEBUG_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_PostingLabelFrame, (L and L["CONFIG_POSTING_STRATEGY"]) or "", (L and L["CONFIG_POSTING_STRATEGY_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_PostingUndercut, (L and L["CONFIG_POSTING_UNDERCUT"]) or "", (L and L["CONFIG_POSTING_UNDERCUT_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_PostingAverage, (L and L["CONFIG_POSTING_AVERAGE"]) or "", (L and L["CONFIG_POSTING_AVERAGE_DESC"]) or "")
    HookTooltip(_G.ArtisanNexusSettings_PostingMax, (L and L["CONFIG_POSTING_MAX"]) or "", (L and L["CONFIG_POSTING_MAX_DESC"]) or "")
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

function ArtisanSettingsUI:RefreshPostingRadio()
    local p = ArtisanNexus.db.profile.posting or {}
    local strat = p.strategy or "undercut"
    local u = _G.ArtisanNexusSettings_PostingUndercut
    local a = _G.ArtisanNexusSettings_PostingAverage
    local m = _G.ArtisanNexusSettings_PostingMax
    if u then u:SetChecked(strat == "undercut") end
    if a then a:SetChecked(strat == "average") end
    if m then m:SetChecked(strat == "max") end
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
    if _G.ArtisanNexusSettings_ClassicUi then
        _G.ArtisanNexusSettings_ClassicUi:SetChecked(p.uiMode == "classic")
    end
    self:SyncLightThemeAvailability()

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

    self:RefreshPostingRadio()
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

    local addonOn = p.enabled ~= false
    local names = {
        "ArtisanNexusSettings_Minimap", "ArtisanNexusSettings_LoginChat", "ArtisanNexusSettings_LightTheme", "ArtisanNexusSettings_ClassicUi",
        "ArtisanNexusSettings_Gathering", "ArtisanNexusSettings_Fishing", "ArtisanNexusSettings_OverloadInd", "ArtisanNexusSettings_OverloadHud",
        "ArtisanNexusSettings_OverloadCastBtn", "ArtisanNexusSettings_BagGuard",
        "ArtisanNexusSettings_LootHistory", "ArtisanNexusSettings_LootAuto",
        "ArtisanNexusSettings_SessionRecentSlider", "ArtisanNexusSettings_SessionOverallSlider",
        "ArtisanNexusSettings_Debug",
        "ArtisanNexusSettings_PostingUndercut", "ArtisanNexusSettings_PostingAverage", "ArtisanNexusSettings_PostingMax",
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
    self:ApplySettingsHeaderClip()
    fr:Show()
    fr:Raise()
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
