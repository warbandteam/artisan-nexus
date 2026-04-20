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
        return "TOP", "TOP", 0, -140
    end
    local point = p.point or "TOP"
    local relativePoint = p.relativePoint or point
    local x = tonumber(p.x) or 0
    local y = tonumber(p.y) or -140
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

local function IsEnabled()
    local db = ns.db and ns.db.profile
    if not db then
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

--- Tracker: long overload CDs as hours + minutes; under 1h as minutes + seconds; last minute as seconds.
local function FormatOverloadTrackerTime(sec)
    sec = math.max(0, tonumber(sec) or 0)
    if sec >= 3600 then
        local h = math.floor(sec / 3600)
        local m = math.floor((sec % 3600) / 60)
        if m == 0 then
            return string.format("%dh", h)
        end
        return string.format("%dh %dm", h, m)
    end
    if sec >= 60 then
        local m = math.floor(sec / 60)
        local s = math.floor(sec % 60)
        return string.format("%dm %02ds", m, s)
    end
    return string.format("%ds", math.floor(sec + 0.5))
end

local TRACKER_DROP_FLASH_SEC = 1.75
local TRACKER_DROP_THRESHOLD = 0.85

local function CategoryLabel(cat)
    if cat == "herb" then
        return (L and L["LOOT_GATHER_HERB"]) or "Herbalism"
    end
    if cat == "mine" then
        return (L and L["LOOT_GATHER_MINE"]) or "Mining"
    end
    return "Gathering"
end

local function ModifierLabel(mod)
    if not mod then
        return nil
    end
    if mod == "wild" then
        return "Wild"
    end
    if mod == "infused" then
        return "Infused"
    end
    if mod == "empowered" then
        return "Empowered"
    end
    return mod
end

local function CreateTrackerRow(parent, yOffset, cat)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetSize(168, 28)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, yOffset)
    if ns.UI_ApplyVisuals and ns.UI_COLORS then
        ns.UI_ApplyVisuals(row, ns.UI_COLORS.bgLight, { ns.UI_COLORS.border[1], ns.UI_COLORS.border[2], ns.UI_COLORS.border[3], 0.28 })
    end
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    label:SetJustifyH("LEFT")
    label:SetText(CategoryLabel(cat))
    local rem = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rem:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    rem:SetJustifyH("RIGHT")
    rem:SetText("-")
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
    tracker:SetSize(184, 118)
    do
        local point, relativePoint, x, y = GetTrackerAnchor()
        tracker:SetPoint(point, UIParent, relativePoint, x, y)
    end
    tracker:SetFrameStrata("MEDIUM")
    tracker:SetMovable(true)
    tracker:EnableMouse(true)
    tracker:RegisterForDrag("LeftButton")
    local ApplyVisuals = ns.UI_ApplyVisuals
    local C = ns.UI_COLORS
    if ApplyVisuals and C then
        ApplyVisuals(tracker, C.bgCard, { C.accent[1], C.accent[2], C.accent[3], 0.52 })
    else
        tracker:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            edgeSize = 1,
        })
        tracker:SetBackdropColor(0.08, 0.08, 0.1, 0.78)
        tracker:SetBackdropBorderColor(0.44, 0.32, 0.58, 0.52)
    end

    local dragBar = CreateFrame("Frame", nil, tracker, "BackdropTemplate")
    dragBar:SetPoint("TOPLEFT", tracker, "TOPLEFT", 2, -2)
    dragBar:SetPoint("TOPRIGHT", tracker, "TOPRIGHT", -2, -2)
    dragBar:SetHeight(20)
    if ApplyVisuals and C then
        ApplyVisuals(dragBar, C.bgLight, { C.accent[1], C.accent[2], C.accent[3], 0.38 })
    end
    dragBar:EnableMouse(true)
    dragBar:RegisterForDrag("LeftButton")
    dragBar:SetScript("OnDragStart", function()
        tracker:StartMoving()
    end)
    dragBar:SetScript("OnDragStop", function()
        tracker:StopMovingOrSizing()
        SaveTrackerAnchor(tracker)
    end)

    local title = dragBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("CENTER", dragBar, "CENTER", 0, 0)
    title:SetText("Overload Tracker")
    if C and C.textBright then
        title:SetTextColor(C.textBright[1], C.textBright[2], C.textBright[3], 1)
    else
        title:SetTextColor(0.95, 0.95, 0.96, 1)
    end

    local modifier = tracker:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    modifier:SetPoint("BOTTOM", tracker, "BOTTOM", 0, 7)
    modifier:SetText("")
    if C and C.textNormal then
        modifier:SetTextColor(C.textNormal[1], C.textNormal[2], C.textNormal[3], 1)
    else
        modifier:SetTextColor(0.80, 0.81, 0.84, 1)
    end

    self.tracker = tracker
    self.modifierLabel = modifier
    self.trackerRows.herb = CreateTrackerRow(tracker, -28, "herb")
    self.trackerRows.mine = CreateTrackerRow(tracker, -60, "mine")
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

    --- Semantic timer colors (soft green / amber; still readable at a glance)
    if rem <= 0.05 then
        row.remaining:SetText("Ready")
        row.remaining:SetTextColor(0.48, 0.80, 0.58, 1)
    else
        row.remaining:SetText(FormatOverloadTrackerTime(rem))
        if flashGreen then
            row.remaining:SetTextColor(0.42, 0.86, 0.54, 1)
        else
            row.remaining:SetTextColor(0.90, 0.76, 0.46, 1)
        end
    end
end

function GatheringOverloadIndicator:RefreshTracker()
    self:EnsureFrames()
    if not IsEnabled() then
        if self.tracker then self.tracker:Hide() end
        return
    end
    if self.tracker then
        self.tracker:Show()
    end
    UpdateTrackerRow(self.trackerRows.herb)
    UpdateTrackerRow(self.trackerRows.mine)
end

function GatheringOverloadIndicator:OnHint(_, payload)
    self:EnsureFrames()
    if not IsEnabled() or not payload or not payload.active then
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
            self.modifierLabel:SetText("Node: " .. mod)
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
            GatheringOverloadIndicator._trackerElapsed = (GatheringOverloadIndicator._trackerElapsed or 0) + (elapsed or 0)
            if GatheringOverloadIndicator._trackerElapsed < 0.2 then
                return
            end
            GatheringOverloadIndicator._trackerElapsed = 0
            GatheringOverloadIndicator:RefreshTracker()
        end)
    end

    if ArtisanNexus and ArtisanNexus.RegisterMessage and E and E.GATHERING_OVERLOAD_HINT_UPDATED then
        ArtisanNexus:RegisterMessage(E.GATHERING_OVERLOAD_HINT_UPDATED, function(_, payload)
            GatheringOverloadIndicator:OnHint(nil, payload)
        end)
    end
    if ArtisanNexus and ArtisanNexus.RegisterMessage and E and E.GATHERING_LOOT_RECORDED then
        ArtisanNexus:RegisterMessage(E.GATHERING_LOOT_RECORDED, function(_, itemID)
            if not IsEnabled() then
                return
            end
            if ns.IsOpenWorld and not ns.IsOpenWorld() then
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
