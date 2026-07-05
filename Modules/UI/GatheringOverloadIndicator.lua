--[[
    Gathering overload QoL HUD:
      1) Always-on herb/mining overload cooldown tracker
      2) Node modifier readout from hover/target (no click-to-cast)
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants and ns.Constants.EVENTS
local L = ns.L

---@class GatheringOverloadIndicator
local GatheringOverloadIndicator = {
    _inited = false,
    _lastPayload = nil,
    tracker = nil,
    trackerRows = {},
    modifierLabel = nil,
}

local function GetTrackerAnchor()
    local p = ns.db and ns.db.profile and ns.db.profile.overloadTrackerFrame
    if type(p) ~= "table" then
        return "BOTTOMRIGHT", "BOTTOMRIGHT", -24, 120
    end
    local point = p.point or "BOTTOMRIGHT"
    local relativePoint = p.relativePoint or point
    local x = tonumber(p.x) or -24
    local y = tonumber(p.y) or 120
    return point, relativePoint, x, y
end

local function SaveTrackerAnchor(frame)
    if not frame or not frame.GetPoint then
        return
    end
    if not (ns.db and ns.db.profile) then
        return
    end
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    ns.db.profile.overloadTrackerFrame = ns.db.profile.overloadTrackerFrame or {}
    local t = ns.db.profile.overloadTrackerFrame
    t.point = point or "TOP"
    t.relativePoint = relativePoint or t.point
    t.x = math.floor((tonumber(x) or 0) + 0.5)
    t.y = math.floor((tonumber(y) or 0) + 0.5)
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

local function GetTrackerChromeMetrics()
    local layout = ns.UI_LAYOUT or {}
    local classic = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    local inset = classic and (ns.UI_GetClassicDialogInset and ns.UI_GetClassicDialogInset() or 8) or 0
    local headerH = classic and (layout.CLASSIC_SHELL_TITLE_STRIP_HEIGHT or layout.SHELL_HEADER_HEIGHT_CLASSIC or 36)
        or (layout.OVERLOAD_DRAG_BAR_HEIGHT or 24)
    local contentTop = classic and (ns.UI_GetClassicShellContentTop and ns.UI_GetClassicShellContentTop())
        or (headerH + (layout.OVERLOAD_BODY_GAP or 6))
    return {
        classic = classic,
        inset = inset,
        headerH = headerH,
        contentTop = contentTop,
        rowH = layout.OVERLOAD_ROW_HEIGHT or 32,
        rowGap = layout.OVERLOAD_ROW_GAP or 4,
        bodyPad = layout.OVERLOAD_BODY_PAD or 6,
        bodyGap = layout.OVERLOAD_BODY_GAP or 6,
        modifierH = layout.OVERLOAD_MODIFIER_HEIGHT or 16,
        trackerW = layout.OVERLOAD_TRACKER_WIDTH or 220,
    }
end

--- Reposition rows / height when only one of herb/mine is known.
local function ApplyOverloadTrackerLayout(indicator)
    local tr = indicator.tracker
    local body = tr and tr._anBody
    local herb = indicator.trackerRows.herb
    local mine = indicator.trackerRows.mine
    if not tr or not body or not herb or not mine then
        return
    end
    local hasH = ns.Utilities and ns.Utilities.PlayerOwnsHerbalism()
    local hasM = ns.Utilities and ns.Utilities.PlayerOwnsMining()
    local m = GetTrackerChromeMetrics()
    local n = 0
    local y = -m.bodyPad
    if hasH then
        herb:Show()
        herb:ClearAllPoints()
        herb:SetPoint("TOPLEFT", body, "TOPLEFT", m.bodyPad, y)
        y = y - m.rowH - m.rowGap
        n = n + 1
    else
        herb:Hide()
    end
    if hasM then
        mine:Show()
        mine:ClearAllPoints()
        mine:SetPoint("TOPLEFT", body, "TOPLEFT", m.bodyPad, y)
        n = n + 1
    else
        mine:Hide()
    end
    if n == 0 then
        return
    end

    local rowW = m.trackerW - (m.inset * 2) - (m.bodyPad * 2)
    herb:SetWidth(rowW)
    mine:SetWidth(rowW)

    local modifierH = 0
    local mod = indicator.modifierLabel
    if mod then
        local modText = mod:GetText()
        if modText and modText ~= "" then
            modifierH = m.modifierH + 4
            mod:Show()
            mod:ClearAllPoints()
            mod:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", m.bodyPad, m.bodyPad)
            mod:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -m.bodyPad, m.bodyPad)
        else
            mod:Hide()
        end
    end

    local rowsH = n * m.rowH + math.max(0, n - 1) * m.rowGap
    local bodyH = m.bodyPad + rowsH + modifierH + m.bodyPad
    body:SetHeight(bodyH)
    tr:SetHeight(m.contentTop + bodyH + m.inset)
end

--- Tracker: always **Saat Dakika** (ceil to next minute; no seconds, no em dash for long CDs).
local function FormatOverloadTrackerTime(sec)
    sec = math.max(0, tonumber(sec) or 0)
    local totalMin = math.max(1, math.ceil(sec / 60))
    local h = math.floor(totalMin / 60)
    local m = totalMin % 60
    return string.format("%dh %02dm", h, m)
end

local TRACKER_DROP_FLASH_SEC = 1.75
local TRACKER_DROP_THRESHOLD = 0.85

local function CategoryLabel(cat)
    if cat == "herb" or cat == "mine" then
        if ns.GetGatheringTabDisplayName then
            local s = ns.GetGatheringTabDisplayName(cat)
            if type(s) == "string" and s ~= "" then
                return s
            end
        end
    end
    if cat == "herb" then
        return (L and L["LOOT_GATHER_HERB"]) or "Herbalism"
    end
    if cat == "mine" then
        return (L and L["LOOT_GATHER_MINE"]) or "Mining"
    end
    return (L and L["OVERLOAD_GATHERING"]) or "Gathering"
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
    return mod
end

local function CreateTrackerRow(parent, cat)
    local layout = ns.UI_LAYOUT or {}
    local fonts = ns.UI_FONTS or {}
    local rowH = layout.OVERLOAD_ROW_HEIGHT or 32
    local iconSz = layout.OVERLOAD_ICON_SIZE or 22
    local chrome = GetTrackerChromeMetrics()
    local rowW = chrome.trackerW - (chrome.inset * 2) - (chrome.bodyPad * 2)
    local bodyFont = fonts.WINDOW_BODY or "GameFontNormal"
    local metaFont = fonts.WINDOW_META or "GameFontHighlightSmall"
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetSize(rowW, rowH)
    if ns.UI_StylePanelInset and ns.UI_COLORS then
        ns.UI_StylePanelInset(row, ns.UI_COLORS.bgLight, ns.UI_COLORS.border)
    elseif ns.UI_ApplyVisuals and ns.UI_COLORS then
        ns.UI_ApplyVisuals(row, ns.UI_COLORS.bgLight, { ns.UI_COLORS.border[1], ns.UI_COLORS.border[2], ns.UI_COLORS.border[3], 0.44 })
    end
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(iconSz, iconSz)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local rem = row:CreateFontString(nil, "OVERLAY", metaFont)
    rem:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    rem:SetJustifyH("RIGHT")
    rem:SetText("-")
    local label = row:CreateFontString(nil, "OVERLAY", bodyFont)
    label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    label:SetPoint("RIGHT", rem, "LEFT", -4, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetMaxLines(1)
    label:SetText(CategoryLabel(cat))
    local cd = CreateFrame("Cooldown", nil, row, "CooldownFrameTemplate")
    cd:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
    cd:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
    cd:SetDrawEdge(false)
    cd:Hide()
    row.icon = icon
    row.label = label
    row.remaining = rem
    row.cooldown = cd
    row.category = cat
    return row
end

function GatheringOverloadIndicator:EnsureFrames()
    if self.tracker then
        return
    end

    local tracker = CreateFrame("Frame", "ArtisanNexusOverloadTrackerFrame", UIParent, "BackdropTemplate")
    local fonts = ns.UI_FONTS or {}
    local m = GetTrackerChromeMetrics()
    tracker:SetSize(m.trackerW, 96)
    do
        local point, relativePoint, x, y = GetTrackerAnchor()
        tracker:SetPoint(point, UIParent, relativePoint, x, y)
    end
    tracker:SetFrameStrata("MEDIUM")
    tracker:SetMovable(true)
    tracker:EnableMouse(true)
    if tracker.SetClipsChildren then
        tracker:SetClipsChildren(false)
    end
    local C = ns.UI_COLORS
    if m.classic and ns.UI_ApplyClassicDialogBackdrop then
        ns.UI_ApplyClassicDialogBackdrop(tracker)
    elseif ns.UI_StylePanelInset and C then
        ns.UI_StylePanelInset(tracker, C.bgCard, C.border)
    elseif ns.UI_ApplyVisuals and C then
        ns.UI_ApplyVisuals(tracker, C.bgCard, { C.accent[1], C.accent[2], C.accent[3], 0.64 })
    else
        tracker:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        tracker:SetBackdropColor(0.12, 0.11, 0.14, 0.82)
        tracker:SetBackdropBorderColor(0.52, 0.40, 0.66, 0.62)
    end

    -- Shell header flush on window top (classic DialogBox-Header strip).
    local headerBar = CreateFrame("Frame", nil, tracker, "BackdropTemplate")
    headerBar._anShellParent = tracker
    headerBar:SetPoint("TOPLEFT", tracker, "TOPLEFT", 0, 0)
    headerBar:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", 0, 0)
    headerBar:SetHeight(m.classic and m.contentTop or m.headerH)
    headerBar:EnableMouse(true)
    headerBar:RegisterForDrag("LeftButton")
    headerBar:SetScript("OnDragStart", function()
        tracker:StartMoving()
    end)
    headerBar:SetScript("OnDragStop", function()
        tracker:StopMovingOrSizing()
        SaveTrackerAnchor(tracker)
    end)
    tracker._anHeader = headerBar
    tracker._anDragBar = headerBar

    local title = headerBar:CreateFontString(nil, "OVERLAY", fonts.WINDOW_SECTION or "GameFontHighlightMedium")
    title:SetJustifyH("CENTER")
    title:SetWordWrap(false)
    title:SetMaxLines(1)
    title:SetText((L and L["OVERLOAD_TRACKER_TITLE"]) or "Overload Tracker")
    headerBar._anShellTitle = title
    if m.classic and ns.UI_ApplyClassicDialogTitleBar then
        ns.UI_ApplyClassicDialogTitleBar(tracker, title)
    elseif ns.UI_RefreshWindowHeader then
        ns.UI_RefreshWindowHeader(headerBar)
        title:SetPoint("CENTER", headerBar, "CENTER", 0, 0)
    elseif C and C.textBright then
        title:SetPoint("CENTER", headerBar, "CENTER", 0, 0)
        title:SetTextColor(C.textBright[1], C.textBright[2], C.textBright[3], 1)
    else
        title:SetPoint("CENTER", headerBar, "CENTER", 0, 0)
        title:SetTextColor(0.95, 0.95, 0.96, 1)
    end

    local body = CreateFrame("Frame", nil, tracker, "BackdropTemplate")
    if m.classic then
        body:SetPoint("TOPLEFT", tracker, "TOPLEFT", m.inset, -m.contentTop)
        body:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", -m.inset, -m.contentTop)
    else
        body:SetPoint("TOPLEFT", headerBar, "BOTTOMLEFT", 0, -m.bodyGap)
        body:SetPoint("TOPRIGHT", headerBar, "BOTTOMRIGHT", 0, -m.bodyGap)
    end
    if ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(body)
    end
    tracker._anBody = body

    local modifier = body:CreateFontString(nil, "OVERLAY", fonts.WINDOW_META or "GameFontHighlightSmall")
    modifier:SetJustifyH("CENTER")
    modifier:SetText("")
    modifier:Hide()
    if C and C.textNormal then
        modifier:SetTextColor(C.textNormal[1], C.textNormal[2], C.textNormal[3], 1)
    else
        modifier:SetTextColor(0.80, 0.81, 0.84, 1)
    end

    self.tracker = tracker
    self.modifierLabel = modifier
    self.trackerRows.herb = CreateTrackerRow(body, "herb")
    self.trackerRows.mine = CreateTrackerRow(body, "mine")
    ApplyOverloadTrackerLayout(self)
end

--- UI-mode switch: drop cached HUD frames, then Init rebuilds with the active
--- skin and rewires the OnUpdate ticker (message owner re-registration is a
--- same-owner replace, so no duplicate handlers).
function GatheringOverloadIndicator:ResetForUiMode()
    if not self.tracker then
        return
    end
    self.tracker:Hide()
    self.tracker = nil
    self.modifierLabel = nil
    if self.trackerRows then
        self.trackerRows.herb = nil
        self.trackerRows.mine = nil
    end
    self:Init()
end

--- Tracker icon: path, fileId, or C_Spell.GetSpellInfo iconID (Retail).
local function GetSpellTextureSafe(spellID)
    if not spellID then
        return nil
    end
    local id = tonumber(spellID)
    if not id then
        return nil
    end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, a = pcall(C_Spell.GetSpellTexture, id)
        if ok then
            if type(a) == "string" and a ~= "" then
                return a
            end
            if type(a) == "number" and a > 0 then
                return a
            end
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
    if GetSpellTexture then
        local tex = GetSpellTexture(id)
        if tex and tex ~= "" then
            return tex
        end
    end
    return nil
end

local function DimTextColor()
    local C = ns.UI_COLORS
    if C and C.textDim then
        return C.textDim[1], C.textDim[2], C.textDim[3]
    end
    return 0.52, 0.53, 0.56
end

local function UpdateTrackerRow(row)
    local dr, dg, db = DimTextColor()
    --- Wild / Infused farklı spell ID — bar gerçek ID’yi gösterir; tracker `GetOverloadTrackerState` ile aynı CD’yi seçer.
    local getState = ns.GetOverloadTrackerState
    local displaySid, startT, dur, rem
    if getState then
        displaySid, startT, dur, rem = getState(row.category)
    end
    if displaySid then
        local tex = GetSpellTextureSafe(displaySid)
        if tex then
            row.icon:SetTexture(tex)
        end
    end
    if not displaySid then
        row.remaining:SetText("-")
        row.remaining:SetTextColor(dr, dg, db, 1)
        if row.cooldown then
            row.cooldown:Hide()
        end
        return
    end
    if row.cooldown and row.cooldown.SetCooldown then
        if startT and dur and dur > 0.001 then
            row.cooldown:Show()
            row.cooldown:SetCooldown(startT, dur)
        else
            row.cooldown:Hide()
        end
    end
    if rem == nil then
        row._lastRem = nil
        row.remaining:SetText("-")
        row.remaining:SetTextColor(dr, dg, db, 1)
        return
    end
    local prevRem = row._lastRem
    if prevRem and rem < prevRem - TRACKER_DROP_THRESHOLD then
        row._flashGreenUntil = GetTime() + TRACKER_DROP_FLASH_SEC
    end
    row._lastRem = rem

    local now = GetTime()
    local flashGreen = row._flashGreenUntil and now < row._flashGreenUntil

    --- Semantic timer colors from the live palette (success green / warning amber)
    local pal = ns.UI_COLORS or {}
    local suc = pal.success or { 0.48, 0.80, 0.58, 1 }
    local warn = pal.warning or { 0.90, 0.76, 0.46, 1 }
    if rem <= 0.05 then
        row.remaining:SetText((L and L["OVERLOAD_READY"]) or "Ready")
        row.remaining:SetTextColor(suc[1], suc[2], suc[3], 1)
    else
        row.remaining:SetText(FormatOverloadTrackerTime(rem))
        if flashGreen then
            row.remaining:SetTextColor(suc[1], suc[2], suc[3], 1)
        else
            row.remaining:SetTextColor(warn[1], warn[2], warn[3], 1)
        end
    end
end

function GatheringOverloadIndicator:RefreshTracker()
    --- Enabled check FIRST: don't build HUD frames for users who disabled it.
    if not ShouldShowOverloadTrackerHud() then
        if self.tracker then
            self.tracker:Hide()
        end
        return
    end
    self:EnsureFrames()
    ApplyOverloadTrackerLayout(self)
    if self.tracker then
        self.tracker:Show()
    end
    if self.trackerRows.herb and self.trackerRows.herb:IsShown() then
        UpdateTrackerRow(self.trackerRows.herb)
    end
    if self.trackerRows.mine and self.trackerRows.mine:IsShown() then
        UpdateTrackerRow(self.trackerRows.mine)
    end
end

function GatheringOverloadIndicator:OnHint(_, payload)
    self:EnsureFrames()
    if not IsWorldOverloadFeatureEnabled() or not payload or not payload.active then
        self._lastPayload = nil
        self:RefreshTracker()
        if self.modifierLabel then
            self.modifierLabel:SetText("")
        end
        return
    end

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
    self:EnsureFrames()
    self:RefreshTracker()
    if self.tracker then
        self.tracker:SetScript("OnUpdate", function(_, elapsed)
            if not ShouldShowOverloadTrackerHud() then
                return
            end
            GatheringOverloadIndicator._trackerElapsed = (GatheringOverloadIndicator._trackerElapsed or 0) + (elapsed or 0)
            if GatheringOverloadIndicator._trackerElapsed < 0.35 then
                return
            end
            GatheringOverloadIndicator._trackerElapsed = 0
            GatheringOverloadIndicator:RefreshTracker()
        end)
    end

    local owner = self._eventOwner or ns.NewEventOwner("GatheringOverloadIndicator")
    self._eventOwner = owner
    if E and E.GATHERING_OVERLOAD_HINT_UPDATED then
        owner:RegisterMessage(E.GATHERING_OVERLOAD_HINT_UPDATED, function(_, payload)
            GatheringOverloadIndicator:OnHint(nil, payload)
        end)
    end
    if E and E.GATHERING_LOOT_RECORDED then
        owner:RegisterMessage(E.GATHERING_LOOT_RECORDED, function(_, itemID)
            if not IsWorldOverloadFeatureEnabled() then
                return
            end
            if ns.IsOpenWorld and not ns.IsOpenWorld() then
                return
            end
            if not ShouldShowOverloadTrackerHud() then
                return
            end
            local id = tonumber(itemID)
            if not id then
                return
            end
            local cat = ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(id)
            if cat ~= "herb" and cat ~= "mine" then
                return
            end
            GatheringOverloadIndicator:EnsureFrames()
            local row = cat == "herb" and GatheringOverloadIndicator.trackerRows.herb or GatheringOverloadIndicator.trackerRows.mine
            if row then
                row._flashGreenUntil = GetTime() + TRACKER_DROP_FLASH_SEC
            end
            GatheringOverloadIndicator:RefreshTracker()
        end)
    end
end

ns.GatheringOverloadIndicator = GatheringOverloadIndicator
