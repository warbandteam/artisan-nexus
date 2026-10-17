--[[
    Overload Tracker — floating Herbalism / Mining overload cooldown HUD + node modifier readout
    (hovered / targeted node, no click-to-cast).

    Window = ns.ArtisanWindow with cfg.hud (WN PlansTrackerWindow shell: title band, logo, close
    button, content area, FLOATING strata, combat hide), fixed size like the collapsed tracker. Not
    in the ESC stack.
    Rows = WN RecipeCompanionWindow.lua:438-560 data rows (Factory:CreateDataRow alternating bg,
    left icon + body name, right-aligned body value with semantic green / gold ink).
]]

local ADDON_NAME, ns = ...
-- Pixel-perfect frames (SharedWidgets_Pixel: SetPoint/SetSize snap to whole physical pixels).
local CreateFrame = function(...) return (ns.UI_CreateFrame or _G.CreateFrame)(...) end

local E = ns.Constants.EVENTS
local L = ns.L
local FontManager = ns.FontManager

-- Overload Tracker metrics (RecipeCompanionWindow.lua:83-103 row / icon / padding scale).
local TRACKER_W = 260
local ROW_H = 28
local ICON_SIZE = 20
local ROW_PAD = 8
local MODIFIER_GAP = 6
local TICK_SEC = 0.35
local TRACKER_DROP_FLASH_SEC = 1.75
local TRACKER_DROP_THRESHOLD = 0.85
local DEFAULT_POINT, DEFAULT_X, DEFAULT_Y = "BOTTOMRIGHT", -24, 120

---@class GatheringOverloadIndicator
local GatheringOverloadIndicator = {
    _inited = false,
    _lastPayload = nil,
    tracker = nil,
    trackerRows = {},
    modifierLabel = nil,
}

local function TrackerTitle()
    return (L and L["OVERLOAD_TRACKER_TITLE"]) or "Overload Tracker"
end

--- World hover / modifier hint — uses options + open world (not tied to tracker HUD toggle).
local function IsWorldOverloadFeatureEnabled()
    local db = ns.db and ns.db.profile
    if not db or db.overloadNodeIndicatorEnabled == false then
        return false
    end
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return false
    end
    return true
end

--- Floating tracker: Herbalism and/or Mining only + HUD toggle + open world.
local function ShouldShowOverloadTrackerHud()
    local db = ns.db and ns.db.profile
    if not db then
        return false
    end
    if db.overloadTrackerHudEnabled == false then
        return false
    end
    if ns.Utilities and not ns.Utilities.PlayerOwnsAnyOverloadTrackerProfession() then
        return false
    end
    if db.overloadNodeIndicatorEnabled == false then
        return false
    end
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return false
    end
    return true
end

--- Close button: turns the HUD setting off (Settings / Session Loot toggle turn it back on).
local function HideTrackerHud(tracker)
    if ns.db and ns.db.profile then
        ns.db.profile.overloadTrackerHudEnabled = false
    end
    if ns.LootHistoryUI and ns.LootHistoryUI.UpdateOverloadTrackerToggle then
        ns.LootHistoryUI:UpdateOverloadTrackerToggle()
    end
    if ns.RefreshAddonSettings then
        ns.RefreshAddonSettings()
    end
end

--- Tracker time: always hours + minutes (ceil to next minute; no seconds).
local function FormatOverloadTrackerTime(sec)
    sec = math.max(0, tonumber(sec) or 0)
    local totalMin = math.max(1, math.ceil(sec / 60))
    local h = math.floor(totalMin / 60)
    local m = totalMin % 60
    return string.format("%dh %02dm", h, m)
end

local function CategoryLabel(cat)
    if ns.GetGatheringTabDisplayName then
        local s = ns.GetGatheringTabDisplayName(cat)
        if type(s) == "string" and s ~= "" then
            return s
        end
    end
    if cat == "herb" then
        return (L and L["LOOT_GATHER_HERB"]) or "Herbalism"
    end
    return (L and L["LOOT_GATHER_MINE"]) or "Mining"
end

local function ModifierLabel(mod)
    if not mod then
        return nil
    end
    if mod == "wild" then
        return (L and L["OVERLOAD_MODIFIER_WILD"]) or "Wild"
    end
    if mod == "infused" then
        return (L and L["OVERLOAD_MODIFIER_INFUSED"]) or "Infused"
    end
    if mod == "empowered" then
        return (L and L["OVERLOAD_MODIFIER_EMPOWERED"]) or "Empowered"
    end
    if mod == "cursed" then
        return (L and L["OVERLOAD_MODIFIER_CURSED"]) or "Cursed"
    end
    return mod
end

--- Tracker icon: path, fileId, or C_Spell.GetSpellInfo iconID (Retail).
local function GetSpellTextureSafe(spellID)
    local id = tonumber(spellID)
    if not id then
        return nil
    end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, a = pcall(C_Spell.GetSpellTexture, id)
        if ok and ((type(a) == "string" and a ~= "") or (type(a) == "number" and a > 0)) then
            return a
        end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and type(info) == "table" then
            local iid = info.iconID or info.originalIconID
            if type(iid) == "number" and iid > 0 then
                return iid
            end
        end
    end
    return nil
end

-- ── Rows (RecipeCompanionWindow data row pattern) ──

local function CreateTrackerRow(parent, cat)
    local F = ns.UI.Factory
    local row = F:CreateDataRow(parent, 0, 1, ROW_H)
    local icon = ns.UI_CreateIcon(row, nil, ICON_SIZE, false)
    icon:SetPoint("LEFT", row, "LEFT", ROW_PAD, 0)
    icon:Show()
    local cd = CreateFrame("Cooldown", nil, icon, "CooldownFrameTemplate")
    cd:SetAllPoints(icon.texture)
    cd:SetDrawEdge(false)
    cd:Hide()
    local rem = FontManager:CreateFontString(row, "body", "OVERLAY")
    rem:SetPoint("RIGHT", row, "RIGHT", -ROW_PAD, 0)
    rem:SetJustifyH("RIGHT")
    rem:SetText("-")
    ns.UI_SetTextColorRole(rem, "Dim")
    local label = FontManager:CreateFontString(row, "body", "OVERLAY")
    label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    label:SetPoint("RIGHT", rem, "LEFT", -6, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetMaxLines(1)
    label:SetText(CategoryLabel(cat))
    ns.UI_SetTextColorRole(label, "Bright")
    row.icon = icon
    row.label = label
    row.remaining = rem
    row.cooldown = cd
    row.category = cat
    return row
end

--- Reposition rows / height when only one of herb / mine is known.
local function ApplyOverloadTrackerLayout(indicator)
    local tr = indicator.tracker
    local herb = indicator.trackerRows.herb
    local mine = indicator.trackerRows.mine
    if not tr or not herb or not mine then
        return
    end
    local body = tr.contentArea
    local F = ns.UI.Factory
    local shown = {}
    if ns.Utilities and ns.Utilities.PlayerOwnsHerbalism() then
        shown[#shown + 1] = herb
    else
        herb:Hide()
    end
    if ns.Utilities and ns.Utilities.PlayerOwnsMining() then
        shown[#shown + 1] = mine
    else
        mine:Hide()
    end
    local y = 0
    for i = 1, #shown do
        local row = shown[i]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
        row:SetPoint("RIGHT", body, "RIGHT", 0, 0)
        F:ApplyRowBackground(row, i)
        row.label:SetText(CategoryLabel(row.category))
        row:Show()
        y = y + ROW_H
    end

    local mod = indicator.modifierLabel
    local modText = mod and mod:GetText()
    if modText and modText ~= "" then
        mod:ClearAllPoints()
        mod:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(y + MODIFIER_GAP))
        mod:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -(y + MODIFIER_GAP))
        mod:Show()
        y = y + MODIFIER_GAP + math.ceil(mod:GetStringHeight() or 0)
    elseif mod then
        mod:Hide()
    end

    local W = ns.ArtisanWindow
    tr:SetHeight(W.HeaderHeight() + W.ROW_BELOW_CHROME + y + W.PADDING)
end

local function UpdateTrackerRow(row)
    --- Wild / Infused use different spell IDs; GetOverloadTrackerState picks the live cooldown.
    local displaySid, startT, dur, rem
    if ns.GetOverloadTrackerState then
        displaySid, startT, dur, rem = ns.GetOverloadTrackerState(row.category)
    end
    if displaySid then
        local tex = GetSpellTextureSafe(displaySid)
        if tex then
            row.icon.texture:SetTexture(tex)
        end
    end
    if not displaySid then
        row.remaining:SetText("-")
        ns.UI_SetTextColorRole(row.remaining, "Dim")
        row.cooldown:Hide()
        return
    end
    if startT and dur and dur > 0.001 then
        row.cooldown:Show()
        row.cooldown:SetCooldown(startT, dur)
    else
        row.cooldown:Hide()
    end
    if rem == nil then
        row._lastRem = nil
        row.remaining:SetText("-")
        ns.UI_SetTextColorRole(row.remaining, "Dim")
        return
    end
    local prevRem = row._lastRem
    if prevRem and rem < prevRem - TRACKER_DROP_THRESHOLD then
        row._flashGreenUntil = GetTime() + TRACKER_DROP_FLASH_SEC
    end
    row._lastRem = rem
    local flashGreen = row._flashGreenUntil and GetTime() < row._flashGreenUntil

    if rem <= 0.05 then
        row.remaining:SetText((L and L["OVERLOAD_READY"]) or "Ready")
        row.remaining:SetTextColor(ns.UI_GetSemanticGreenColor())
    else
        row.remaining:SetText(FormatOverloadTrackerTime(rem))
        if flashGreen then
            row.remaining:SetTextColor(ns.UI_GetSemanticGreenColor())
        else
            row.remaining:SetTextColor(ns.UI_GetSemanticGoldColor())
        end
    end
end

-- ── Window ──

local function PlaceTracker(tracker)
    if not ns.ArtisanWindow.RestorePosition(tracker) then
        tracker:ClearAllPoints()
        tracker:SetPoint(DEFAULT_POINT, UIParent, DEFAULT_POINT, DEFAULT_X, DEFAULT_Y)
    end
end

function GatheringOverloadIndicator:RefreshTrackerChrome()
    local tr = self.tracker
    if not tr then
        return
    end
    ns.ArtisanWindow.RefreshChrome(tr)
    tr._anTitleText:SetText(TrackerTitle())
    local F = ns.UI.Factory
    local i = 0
    for _, cat in ipairs({ "herb", "mine" }) do
        local row = self.trackerRows[cat]
        if row and row:IsShown() then
            i = i + 1
            F:ApplyRowBackground(row, i)
        end
        if row then
            ns.UI_SetTextColorRole(row.label, "Bright")
        end
    end
    if self.modifierLabel then
        ns.UI_SetTextColorRole(self.modifierLabel, "Muted")
    end
end

function GatheringOverloadIndicator:EnsureFrames()
    if self.tracker then
        return
    end
    local W = ns.ArtisanWindow
    local tracker = W.Create({
        name = "ArtisanNexusOverloadTrackerFrame",
        title = TrackerTitle(),
        posKey = "overloadTrackerFrame",
        width = TRACKER_W,
        height = W.HeaderHeight() + W.ROW_BELOW_CHROME + ROW_H * 2 + W.PADDING,
        resizable = false,
        --- HUD, not a window: FLOATING strata but out of the ESC stack (ESC closes the windows the
        --- user opened, never the always-on tracker); hidden in combat, RefreshTracker decides after.
        hud = true,
        combatHide = true,
        onCombatEnd = function()
            GatheringOverloadIndicator:RefreshTracker()
        end,
        onClose = HideTrackerHud,
    })
    if not tracker then
        return
    end
    PlaceTracker(tracker)

    local modifier = FontManager:CreateFontString(tracker.contentArea, "small", "OVERLAY")
    modifier:SetJustifyH("CENTER")
    modifier:SetWordWrap(false)
    modifier:SetText("")
    modifier:Hide()
    ns.UI_SetTextColorRole(modifier, "Muted")

    self.tracker = tracker
    self.modifierLabel = modifier
    self.trackerRows.herb = CreateTrackerRow(tracker.contentArea, "herb")
    self.trackerRows.mine = CreateTrackerRow(tracker.contentArea, "mine")
    ApplyOverloadTrackerLayout(self)

    --- Countdown ticker lives on the tracker (runs only while it is shown). Throttle first: the
    --- visibility check walks profession scans and must not run per frame.
    tracker:SetScript("OnUpdate", function(_, elapsed)
        local ind = GatheringOverloadIndicator
        ind._trackerElapsed = (ind._trackerElapsed or 0) + (elapsed or 0)
        if ind._trackerElapsed < TICK_SEC then
            return
        end
        ind._trackerElapsed = 0
        ind:RefreshTracker()
    end)
end

function GatheringOverloadIndicator:RefreshTracker()
    --- Enabled check first: don't build HUD frames for users who disabled it.
    if not ShouldShowOverloadTrackerHud() then
        if self.tracker then
            self.tracker:Hide()
        end
        return
    end
    local built = self.tracker ~= nil
    self:EnsureFrames()
    local tr = self.tracker
    if not tr then
        return
    end
    --- Layout only when something changed — not on every countdown tick.
    if not built or self._chromeDirty then
        self._chromeDirty = nil
        ApplyOverloadTrackerLayout(self)
        self:RefreshTrackerChrome()
    end
    --- Hidden in combat (ArtisanWindow cfg.combatHide; its onCombatEnd calls this again).
    if InCombatLockdown() then
        tr:Hide()
        return
    end
    tr:Show()
    if self.trackerRows.herb:IsShown() then
        UpdateTrackerRow(self.trackerRows.herb)
    end
    if self.trackerRows.mine:IsShown() then
        UpdateTrackerRow(self.trackerRows.mine)
    end
end

function GatheringOverloadIndicator:OnHint(_, payload)
    if not IsWorldOverloadFeatureEnabled() or not payload or not payload.active then
        --- Disable / clear path must not build frames for users with the feature off.
        self._lastPayload = nil
        if self.modifierLabel and (self.modifierLabel:GetText() or "") ~= "" then
            self.modifierLabel:SetText("")
            self._chromeDirty = true
        end
        self:RefreshTracker()
        return
    end
    self:EnsureFrames()
    --- Hints are sparse: refresh row layout (profession ownership) with them.
    self._chromeDirty = true
    self._lastPayload = payload

    local mod = ModifierLabel(payload.modifier)
    if self.modifierLabel then
        if mod then
            self.modifierLabel:SetText(string.format((L and L["OVERLOAD_NODE_FMT"]) or "Node: %s", mod))
        else
            self.modifierLabel:SetText("")
        end
    end
    self:RefreshTracker()
end

function GatheringOverloadIndicator:Init()
    if self._inited then
        return
    end
    self._inited = true
    --- Frames + OnUpdate ticker are owned by EnsureFrames (via RefreshTracker); Init wires messages.
    self:RefreshTracker()

    local owner = self._eventOwner or ns.NewEventOwner("GatheringOverloadIndicator")
    self._eventOwner = owner
    owner:RegisterMessage(E.GATHERING_OVERLOAD_HINT_UPDATED, function(_, payload)
        GatheringOverloadIndicator:OnHint(nil, payload)
    end)
    owner:RegisterMessage(E.THEME_CHANGED, function()
        GatheringOverloadIndicator._chromeDirty = true
        GatheringOverloadIndicator:RefreshTrackerChrome()
    end)
    owner:RegisterMessage(E.FONT_CHANGED, function()
        GatheringOverloadIndicator._chromeDirty = true
        if GatheringOverloadIndicator.tracker then
            ApplyOverloadTrackerLayout(GatheringOverloadIndicator)
        end
    end)
    owner:RegisterMessage(E.GATHERING_LOOT_RECORDED, function(_, itemID)
        if not ShouldShowOverloadTrackerHud() then
            return
        end
        local id = tonumber(itemID)
        local cat = id and ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(id)
        if cat ~= "herb" and cat ~= "mine" then
            return
        end
        GatheringOverloadIndicator:EnsureFrames()
        local row = GatheringOverloadIndicator.trackerRows[cat]
        if row then
            row._flashGreenUntil = GetTime() + TRACKER_DROP_FLASH_SEC
        end
        GatheringOverloadIndicator:RefreshTracker()
    end)
end

ns.GatheringOverloadIndicator = GatheringOverloadIndicator
