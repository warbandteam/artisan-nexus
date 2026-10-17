--[[
    Artisan Nexus - Settings UI: Artisan Nexus categories.
    Same hand-off as Warband Nexus SettingsUI_Modules.lua (ns.SettingsUI.AppendModulesPanel): the WN
    Settings tab (Modules/UI/SettingsUI.lua) calls in with its own row builders, and every row here is
    built with them (CreateSection / StackSettingsSubPanel / AppendSettingsSubSectionHeader /
    CreateCheckboxGrid / CreateSliderWidget / CreateDropdownWidget / CreateButtonGrid).

    Rows are data in Modules/UI/Settings/SettingsSchema.lua (ns.SettingsSchema); one schema section
    per WN category id (loot / crafting / auction / advanced), plus the "general" rows appended to the
    WN General category (AppendArtisanGeneralRows).
    Loaded after SettingsUI_Shell.lua, before Modules/UI/SettingsUI.lua.
]]

local _, ns = ...

ns.SettingsUI = ns.SettingsUI or {}

local function SchemaSection(id)
    local schema = ns.SettingsSchema or {}
    for i = 1, #schema do
        if schema[i].id == id then
            return schema[i]
        end
    end
    return nil
end

local function Resolve(v, ...)
    if type(v) == "function" then
        return v(...)
    end
    return v
end

local function RowVisible(row)
    return row.visible == nil or Resolve(row.visible) ~= false
end

local function RowEnabled(row)
    return row.enabled == nil or Resolve(row.enabled) ~= false
end

local function RowGet(row)
    if row.get then
        return row.get()
    end
    return ns.SettingsSchemaPath.Get(row.key)
end

--- Coalesced Settings tab repaint (WN UI_MAIN_REFRESH_REQUESTED path).
local function RepaintSettings()
    local addon = ns.ArtisanNexus
    local E = ns.Constants and ns.Constants.EVENTS
    if addon and E and E.UI_MAIN_REFRESH_REQUESTED then
        addon:SendMessage(E.UI_MAIN_REFRESH_REQUESTED, { tab = "settings", skipCooldown = true })
    end
end

--- Write + side effect, then repaint the Settings tab when other rows may depend on the value
--- (enabled / visible / button text read live values).
local function RowSet(row, value, repaint)
    if row.set then
        row.set(value)
    else
        ns.SettingsSchemaPath.Set(row.key, value)
    end
    if row.onChange then
        row.onChange(value)
    end
    if repaint ~= false then
        RepaintSettings()
    end
end

--- Danger-button confirmation: WN destructive-action StaticPopup (PlansUI.lua:994-1007,
--- "Yes, Reset" / Cancel) through ns.ArtisanWindow.Confirm (ArtisanWindow.lua).
local function Confirm(text, onAccept)
    local W = ns.ArtisanWindow
    if W and W.Confirm then
        W.Confirm(text, (ns.L and ns.L["YES_RESET"]) or "Yes, Reset", onAccept)
    end
end

local function DropdownValues(row)
    local list = Resolve(row.values) or {}
    local values, order = {}, {}
    for i = 1, #list do
        local o = list[i]
        values[o.value] = o.text
        order[i] = o.value
    end
    return values, order
end

--- Muted wrapped line (WN trFontHint pattern).
local function AppendMutedLine(inner, iw, cy, text, H)
    local FontManager = ns.FontManager
    local fs = FontManager:CreateFontString(inner, "body", "OVERLAY")
    fs:SetPoint("TOPLEFT", 0, cy)
    fs:SetWidth(iw)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    fs:SetText(text)
    ns.UI_SetTextColorRole(fs, "Muted")
    local gap = (H.GetHeaderToolbarGap and H.GetHeaderToolbarGap()) or 8
    return cy - math.max(18, fs:GetStringHeight()) - gap
end

--- One schema group: WN subsection header, then runs of toggles as one checkbox grid and every
--- other row with its WN builder. `widgets` is shared across grids so `parent` links resolve.
local function AppendGroup(inner, iw, cy, group, isFirst, H, widgets)
    if group.title then
        cy = H.AppendSettingsSubSectionHeader(inner, group.title, iw, cy, { skipGapBefore = isFirst })
    end
    local rows = group.rows or {}
    local toggles = {}
    local disabledToggles = {}
    local function FlushToggles()
        if #toggles == 0 then return end
        cy = H.CreateCheckboxGrid(inner, toggles, cy, iw, {
            maxColumns = group.columns,
            externalWidgets = widgets,
        })
        local SetCheckboxDisabled = ns.SettingsUI._H and ns.SettingsUI._H.SetCheckboxDisabled
        for key in pairs(disabledToggles) do
            local w = widgets[key]
            if w and SetCheckboxDisabled then
                SetCheckboxDisabled(w.checkbox, w.label, true)
            end
        end
        toggles, disabledToggles = {}, {}
    end
    for i = 1, #rows do
        local row = rows[i]
        if RowVisible(row) then
            if row.type == "toggle" then
                toggles[#toggles + 1] = {
                    key = row.key,
                    parentKey = row.parent,
                    label = row.label,
                    tooltip = row.desc,
                    get = function() return RowGet(row) and true or false end,
                    set = function(value) RowSet(row, value and true or false) end,
                }
                if not RowEnabled(row) then
                    disabledToggles[row.key] = true
                end
            else
                FlushToggles()
                if row.type == "slider" then
                    local slider
                    cy, slider = H.CreateSliderWidget(inner, {
                        name = row.label,
                        desc = row.desc,
                        min = row.min,
                        max = row.max,
                        step = row.step,
                        applyOnRelease = row.applyOnRelease,
                        valueFormat = row.format,
                        get = function() return tonumber(RowGet(row)) or row.min end,
                        set = function(_, value) RowSet(row, value, false) end,
                    }, cy, H.sliderElements)
                    if slider and not RowEnabled(row) then
                        if slider.Disable then slider:Disable() end
                        slider:SetAlpha(0.35)
                    end
                    local hint = Resolve(row.hint)
                    if type(hint) == "string" and hint ~= "" then
                        cy = AppendMutedLine(inner, iw, cy, hint, H)
                    end
                elseif row.type == "dropdown" or row.type == "radio" then
                    local values, order = DropdownValues(row)
                    if RowEnabled(row) then
                        cy = H.CreateDropdownWidget(inner, {
                            name = row.label,
                            desc = row.desc,
                            stackBelowLabel = true,
                            values = values,
                            valueOrder = order,
                            get = function() return RowGet(row) end,
                            set = function(_, value) RowSet(row, value) end,
                        }, cy)
                    else
                        local current = values[RowGet(row)] or ""
                        cy = AppendMutedLine(inner, iw, cy, (row.label or "") .. ": " .. tostring(current), H)
                    end
                elseif row.type == "button" then
                    local danger = row.variant == "danger"
                    cy = H.CreateButtonGrid(inner, { {
                        label = Resolve(row.text),
                        tooltip = row.desc,
                        color = danger and { 0.60, 0.22, 0.22 } or nil,
                        func = function()
                            if row.confirm then
                                Confirm(row.confirm, function()
                                    row.onClick()
                                    RepaintSettings()
                                end)
                            else
                                row.onClick()
                                RepaintSettings()
                            end
                        end,
                    } }, cy, iw, 160)
                elseif row.type == "note" then
                    cy = AppendMutedLine(inner, iw, cy, Resolve(row.text) or "", H)
                elseif row.type == "header" then
                    FlushToggles()
                    cy = H.AppendSettingsSubSectionHeader(inner, row.label, iw, cy, {})
                end
            end
        end
    end
    FlushToggles()
    return cy
end

---@param ctx table { panel, parent, effectiveWidth, yOffset, sideInset, skipPanelIntro, helpers }
function ns.SettingsUI.AppendArtisanPanel(ctx)
    if not ctx or not ctx.parent then return ctx and ctx.yOffset or 0 end
    local section = SchemaSection(ctx.panel)
    local H = ctx.helpers or {}
    local yOffset = ctx.yOffset or 0
    if not section or not (H.CreateSection and H.StackSettingsSubPanel and H.CreateCheckboxGrid) then
        return yOffset
    end
    local parent = ctx.parent
    local effectiveWidth = ctx.effectiveWidth
    if not ctx.skipPanelIntro and H.AppendSettingsPanelIntro then
        yOffset = H.AppendSettingsPanelIntro(parent, ctx.panel, effectiveWidth, yOffset, ctx.sideInset or 0, ctx.skipPanelIntro)
    end
    local card = H.CreateSection(parent, nil, effectiveWidth)
    H.AnchorSectionTop(card, yOffset)
    local contentW = H.GetSettingsSectionContentWidth and H.GetSettingsSectionContentWidth(effectiveWidth)
        or (effectiveWidth - 30)
    local widgets = {}
    local stackY = H.StackSettingsSubPanel(card.content, contentW, 0, function(inner, iw)
        local cy = 0
        local groups = section.groups or {}
        for gi = 1, #groups do
            cy = AppendGroup(inner, iw, cy, groups[gi], gi == 1, H, widgets)
        end
        return cy
    end, { flat = true, noTrailingGap = true })
    local contentH = H.SettingsMeasuredSectionContentHeight(stackY)
    H.FinalizeSettingsSectionHeight(card, contentH, false)
    return yOffset - card:GetHeight() - (H.SETTINGS_SECTION_GAP or 20)
end

--- AN rows inside the WN General card (after Controls & Scaling): schema section "general".
function ns.SettingsUI.AppendArtisanGeneralRows(inner, iw, cy, H)
    local section = SchemaSection("general")
    if not section or not H or not H.CreateCheckboxGrid then return cy end
    local widgets = {}
    local groups = section.groups or {}
    for gi = 1, #groups do
        cy = AppendGroup(inner, iw, cy, groups[gi], false, H, widgets)
    end
    return cy
end

--- Other windows call this after writing a key shown in Settings without a message of their own
--- (overlay / tracker toggles, floating button close).
ns.RefreshAddonSettings = RepaintSettings

-- ─────────────────────────────────────────────────────────────────
-- Leaving the Settings tab ends the overlay previews it started (pre-WN SettingsPage LeaveSettings:
-- clear the loot-toast scale preview, save an open toast-position edit, close dropdown flyouts).
-- WN's settings-hide hook is ArtisanNexus:StopSettingsKeybindCapture (SettingsUI_Keybind.lua): the
-- main window calls it when switching away from the Settings tab (UI_MainShell.lua SwitchTab, while
-- currentTab is still "settings") and from its OnHide (any tab), so the cleanup only runs when the
-- window is on Settings at that moment.
-- ─────────────────────────────────────────────────────────────────
local function LeaveSettings()
    local mf = _G.ArtisanNexusFrame
    if not mf or mf.currentTab ~= "settings" then
        return
    end
    local overlay = ns.SessionLootOverlayUI
    if overlay then
        if overlay.ClearScalePreview then
            overlay:ClearScalePreview()
        end
        if overlay.IsPositionEditing and overlay.SavePositionEdit and overlay:IsPositionEditing() then
            overlay:SavePositionEdit()
        end
    end
    if ns.UI_CloseOpenDropdownMenus then
        ns.UI_CloseOpenDropdownMenus()
    end
end

do
    local addon = ns.ArtisanNexus
    if addon and addon.StopSettingsKeybindCapture then
        hooksecurefunc(addon, "StopSettingsKeybindCapture", LeaveSettings)
    end
end

-- ─────────────────────────────────────────────────────────────────
-- Warband Nexus Config.lua color picker preview hook (verbatim; WN keeps it in Config.lua, AN's
-- Config.lua is the settings entry point only). The WN Settings theme color picker
-- (SettingsUI.lua) calls the guarded ns.InstallColorPickerPreviewHook() before every open.
-- ─────────────────────────────────────────────────────────────────
local WarbandNexus = ns.ArtisanNexus

-- Forward declarations for color picker state (used by options.set handlers).
local colorPickerOriginalColors = nil
local colorPickerHookInstalled = false
local colorPickerTicker = nil
local lastR, lastG, lastB = nil, nil, nil
local colorPickerConfirmed = false
-- True only between a WN theme-picker open and the next ColorPickerFrame hide; the global
-- ColorPickerFrame hooks no-op otherwise so other addons' / Blizzard pickers are untouched.
local colorPickerOwnedByWN = false

-- ===== COLOR PICKER REAL-TIME PREVIEW HOOK =====

-- TAINT FIX: ColorPickerFrame hooks are now installed LAZILY (on first color picker open)
-- instead of during OnInitialize. Hooking Blizzard frames during addon init can taint
-- the frame's script handler chain, causing ADDON_ACTION_FORBIDDEN on /reload in TWW.
local function InstallColorPickerPreviewHook()
    -- Called right before every WN theme picker open: arm ownership for this open.
    if colorPickerHookInstalled then
        colorPickerOwnedByWN = true
        return
    end
    -- Don't hook Blizzard frames during combat
    if InCombatLockdown() then return end
    if not ColorPickerFrame then return end
    colorPickerHookInstalled = true
    colorPickerOwnedByWN = true
    
    ColorPickerFrame:HookScript("OnShow", function()
        if not colorPickerOwnedByWN then return end
        colorPickerConfirmed = false
        
        if WarbandNexus and WarbandNexus.ShowMainWindow then
            WarbandNexus:ShowMainWindow()
        end
        
        local current = WarbandNexus.db.profile.themeColors
        colorPickerOriginalColors = {
            accent = {current.accent[1], current.accent[2], current.accent[3]},
            accentDark = {current.accentDark[1], current.accentDark[2], current.accentDark[3]},
            border = {current.border[1], current.border[2], current.border[3]},
            tabActive = {current.tabActive[1], current.tabActive[2], current.tabActive[3]},
            tabHover = {current.tabHover[1], current.tabHover[2], current.tabHover[3]},
        }
        
        lastR, lastG, lastB = ColorPickerFrame:GetColorRGB()
        
        if colorPickerTicker then
            colorPickerTicker:Cancel()
        end
        
        colorPickerTicker = C_Timer.NewTicker(0.05, function()
            if not colorPickerOwnedByWN or not ColorPickerFrame:IsShown() then
                return
            end
            
            local r, g, b = ColorPickerFrame:GetColorRGB()
            
            local tolerance = 0.001
            if math.abs(r - (lastR or 0)) > tolerance or 
               math.abs(g - (lastG or 0)) > tolerance or 
               math.abs(b - (lastB or 0)) > tolerance then
                
                lastR, lastG, lastB = r, g, b
                
                local previewColors = ns.UI_CalculateThemeColors(r, g, b)
                WarbandNexus.db.profile.themeColors = previewColors
                
                if ns.UI_RefreshColors then
                    ns.UI_RefreshColors()
                end
            end
        end)
    end)
    
    local okayButton = ColorPickerFrame.Footer and ColorPickerFrame.Footer.OkayButton or ColorPickerOkayButton
    local cancelButton = ColorPickerFrame.Footer and ColorPickerFrame.Footer.CancelButton or ColorPickerCancelButton
    
    if okayButton then
        okayButton:HookScript("OnClick", function()
            -- Unguarded on purpose: OK's own handler hides the picker (our OnHide clears
            -- ownership) before this post-hook runs; the delayed revert reads this flag.
            colorPickerConfirmed = true
        end)
    end
    
    if cancelButton then
        cancelButton:HookScript("OnClick", function()
            -- Unguarded on purpose (see OK hook): ownership is cleared by OnHide first.
            colorPickerConfirmed = false
        end)
    end
    
    ColorPickerFrame:HookScript("OnHide", function()
        if not colorPickerOwnedByWN then return end
        colorPickerOwnedByWN = false
        if colorPickerTicker then
            colorPickerTicker:Cancel()
            colorPickerTicker = nil
        end
        
        C_Timer.After(0.05, function()
            if not colorPickerConfirmed and colorPickerOriginalColors then
                WarbandNexus.db.profile.themeColors = colorPickerOriginalColors
                
                if ns.UI_RefreshColors then
                    ns.UI_RefreshColors()
                end
            end
            
            if not colorPickerConfirmed then
                colorPickerOriginalColors = nil
            end
            colorPickerConfirmed = false
            lastR, lastG, lastB = nil, nil, nil
        end)
    end)
end

-- Expose for lazy installation from SettingsUI color picker
ns.InstallColorPickerPreviewHook = InstallColorPickerPreviewHook
