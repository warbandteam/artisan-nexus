--[[
    Session loot overlay — compact on-screen toasts (icon, name, qty, price).
    No window chrome: appears on pickup, fades out. Position from Settings (X/Y).
    Classic / Modern row styling via uiMode + theme helpers.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants and ns.Constants.EVENTS
local L = ns.L
local COLORS = ns.UI_COLORS

local TOAST_SCALE = 1.15

local function Scaled(v)
    return math.floor(v * TOAST_SCALE + 0.5)
end

local TOAST_W = Scaled(340)
local TOAST_H = Scaled(38)
local TOAST_GAP = Scaled(6)
local ICON_SZ = Scaled(26)
local TOAST_PAD = Scaled(6)
local TOAST_ICON_GAP = Scaled(6)
local TOAST_COL_GAP = Scaled(6)
local TOAST_QTY_W = Scaled(34)
local TOAST_PRICE_W = Scaled(102)
local TOAST_COIN_H = Scaled(13)
local HOLD_SEC_DEFAULT = 4.0
local FADE_SEC = 0.85
local SLIDE_IN_SEC = 0.22
local SLIDE_OFFSET = Scaled(20)
local PULSE_SEC = 0.55
local STACK_MAX_DEFAULT = 3
local STACK_MAX_LIMIT = 6

---@class SessionLootOverlayUI
local SessionLootOverlayUI = {
    anchor = nil,
    _pool = {},
    _active = {},
    _lastShownRt = 0,
    _inited = false,
    _lootSeq = 0,
    _positionEdit = false,
    _editPreviewEntry = nil,
    _editHint = nil,
    _editGuard = nil,
}

local PREVIEW_ITEM_ID = 2770

local AcquireToast, PaintToast, StyleToastRow, LayoutToastRow, ReleaseToast

local function ToastFont()
    if ns.UI_GetWindowFont then
        return ns.UI_GetWindowFont("WINDOW_EMPHASIS")
    end
    local fonts = ns.UI_FONTS or {}
    return fonts.WINDOW_EMPHASIS or fonts.WINDOW_BODY or "GameFontNormalLarge"
end

local function SaveAnchorConfigFromFrame(frame)
    if not frame or not ns.db or not ns.db.profile then
        return
    end
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    if not point then
        return
    end
    ns.db.profile.sessionLootOverlayFrame = {
        point = point,
        relativePoint = relativePoint or point,
        x = math.floor((tonumber(x) or 0) + 0.5),
        y = math.floor((tonumber(y) or 0) + 0.5),
    }
end

local function EnsureEditGuard(self)
    if self._editGuard then
        return self._editGuard
    end
    local guardName = "ArtisanNexusSessionLootOverlayEditGuard"
    local g = CreateFrame("Frame", guardName, UIParent)
    g:SetSize(1, 1)
    g:Hide()
    g:SetScript("OnHide", function()
        if SessionLootOverlayUI._positionEdit and not SessionLootOverlayUI._editClosing then
            SessionLootOverlayUI:EndPositionEdit(false)
        end
    end)
    local listed = false
    for i = 1, #UISpecialFrames do
        if UISpecialFrames[i] == guardName then
            listed = true
            break
        end
    end
    if not listed then
        tinsert(UISpecialFrames, guardName)
    end
    self._editGuard = g
    return g
end

local function SetEditHintVisible(self, show)
    local hint = self._editHint
    if not hint then
        return
    end
    if show then
        hint:SetText((L and L["LOOT_OVERLAY_EDIT_HINT"]) or "Left-click drag to move — right-click to save")
        local tc = COLORS.textBright or COLORS.textNormal
        if tc then
            hint:SetTextColor(tc[1], tc[2], tc[3], 1)
        end
        hint:Show()
    else
        hint:Hide()
    end
end

local function EnsureEditHint(self)
    self:EnsureAnchor()
    local anchor = self.anchor
    if not anchor then
        return
    end
    if self._editHint then
        return
    end
    local hint = anchor:CreateFontString(nil, "OVERLAY", ToastFont())
    hint:SetPoint("BOTTOM", anchor, "TOP", 0, 6)
    hint:SetJustifyH("CENTER")
    hint:SetWidth(TOAST_W + 40)
    if hint.SetWordWrap then
        hint:SetWordWrap(true)
    end
    self._editHint = hint
end

local function ShowEditPreview(self)
    self:ClearToasts()
    self._editPreviewEntry = nil
    local anchor = self.anchor
    if not anchor then
        return
    end
    local row = AcquireToast(anchor)
    PaintToast(row, { itemID = PREVIEW_ITEM_ID, qty = 3, rt = GetTime() })
    StyleToastRow(row)
    local entry = { row = row, born = GetTime(), rt = GetTime(), _preview = true }
    self._active[1] = entry
    self._editPreviewEntry = entry
    self:LayoutStack()
    anchor:Show()
end

local function ClearEditPreview(self)
    if self._editPreviewEntry and self._editPreviewEntry.row then
        ReleaseToast(self._editPreviewEntry.row)
    end
    self._editPreviewEntry = nil
    self._active = {}
    if self.anchor then
        self.anchor:Hide()
    end
end

local function IsOverlayEnabled()
    local p = ns.db and ns.db.profile
    return p and p.sessionLootOverlayEnabled == true
end

local function EnsureInitialized()
    if not SessionLootOverlayUI._inited and SessionLootOverlayUI.Init then
        SessionLootOverlayUI:Init()
    end
end

local function GetAnchorConfig()
    local p = ns.db and ns.db.profile and ns.db.profile.sessionLootOverlayFrame
    if type(p) ~= "table" then
        return "TOPRIGHT", "TOPRIGHT", -24, -120
    end
    return p.point or "TOPRIGHT", p.relativePoint or p.point or "TOPRIGHT",
        tonumber(p.x) or -24, tonumber(p.y) or -120
end

local function GetHoldSec()
    local p = ns.db and ns.db.profile
    local n = p and tonumber(p.sessionLootOverlayHoldSec)
    if not n or n ~= n then
        return HOLD_SEC_DEFAULT
    end
    return math.max(1.5, math.min(12, n))
end

local function GetStackMax()
    local p = ns.db and ns.db.profile
    local n = p and tonumber(p.sessionLootOverlayStackMax)
    if not n or n ~= n then
        return STACK_MAX_DEFAULT
    end
    n = math.floor(n + 0.5)
    return math.max(1, math.min(STACK_MAX_LIMIT, n))
end

local function TexForItem(itemID)
    if not itemID or not C_Item or not C_Item.GetItemIconByID then
        return "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    local fileID = C_Item.GetItemIconByID(itemID)
    return (fileID and fileID > 0) and fileID or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function EaseOutQuad(t)
    if t <= 0 then
        return 0
    end
    if t >= 1 then
        return 1
    end
    return 1 - (1 - t) * (1 - t)
end

local function GetPriceColor()
    local w = COLORS.warning
    if w then
        return w[1], w[2], w[3], 1
    end
    local a = COLORS.accent
    if a then
        return a[1], a[2], a[3], 1
    end
    return 1, 0.82, 0.35, 1
end

LayoutToastRow = function(row)
    if not row then
        return
    end
    row:SetSize(TOAST_W, TOAST_H)
    local toastFont = ToastFont()
    local ic = row._icon
    if ic then
        ic:SetSize(ICON_SZ, ICON_SZ)
        ic:ClearAllPoints()
        ic:SetPoint("LEFT", row, "LEFT", TOAST_PAD, 0)
    end
    local textFields = { row._name, row._qty, row._price }
    for i = 1, 3 do
        local fs = textFields[i]
        if fs and fs.SetFontObject then
            fs:SetFontObject(toastFont)
        end
        if fs and fs.SetWordWrap then
            fs:SetWordWrap(false)
        end
    end
    local price = row._price
    local qty = row._qty
    local name = row._name
    if price then
        price:SetWidth(TOAST_PRICE_W)
        price:ClearAllPoints()
        price:SetPoint("RIGHT", row, "RIGHT", -TOAST_PAD, 0)
        if price.SetJustifyH then
            price:SetJustifyH("RIGHT")
        end
        if price.SetMaxLines then
            price:SetMaxLines(1)
        end
    end
    if qty and price then
        qty:SetWidth(TOAST_QTY_W)
        qty:ClearAllPoints()
        qty:SetPoint("RIGHT", price, "LEFT", -TOAST_COL_GAP, 0)
        if qty.SetJustifyH then
            qty:SetJustifyH("RIGHT")
        end
    end
    if name then
        name:ClearAllPoints()
        name:SetPoint("LEFT", ic or row, "RIGHT", TOAST_ICON_GAP, 0)
        if qty then
            name:SetPoint("RIGHT", qty, "LEFT", -TOAST_COL_GAP, 0)
        elseif price then
            name:SetPoint("RIGHT", price, "LEFT", -TOAST_COL_GAP, 0)
        else
            name:SetPoint("RIGHT", row, "RIGHT", -TOAST_PAD, 0)
        end
        if name.SetJustifyH then
            name:SetJustifyH("LEFT")
        end
    end
end

StyleToastRow = function(row)
    if not row then
        return
    end
    local classic = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    if classic and ns.UI_ApplyClassicInsetPanel then
        ns.UI_ApplyClassicInsetPanel(row)
    elseif ns.UI_ApplyVisuals and COLORS then
        local bg = COLORS.lootCellBg or COLORS.bgCard or COLORS.surfaceRowEven
        local bd = COLORS.lootCellBorder or COLORS.border
        ns.UI_ApplyVisuals(row, bg, bd)
    end
    if row._shadow then
        row._shadow:SetColorTexture(0, 0, 0, 0.28)
    end
    if row._pulseBg then
        local pick = COLORS.lootPickBorder or COLORS.accent
        if pick then
            row._pulseBg:SetVertexColor(pick[1], pick[2], pick[3])
        end
    end
end

AcquireToast = function(parent)
    local pool = SessionLootOverlayUI._pool
    local row = table.remove(pool)
    if row then
        row:SetParent(parent)
        row:Show()
        row:SetAlpha(1)
        row:SetScript("OnUpdate", nil)
        row._slideX = nil
        if row._pulseBg then
            row._pulseBg:SetAlpha(0)
        end
        if row._accent then
            row._accent:Hide()
        end
        LayoutToastRow(row)
        return row
    end

    local classic = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    local createIcon = ns.UI_CreateIcon
    local toastFont = ToastFont()

    row = CreateFrame("Frame", nil, parent, "BackdropTemplate")

    local shadow = row:CreateTexture(nil, "BACKGROUND", nil, -2)
    shadow:SetPoint("TOPLEFT", 2, -2)
    shadow:SetPoint("BOTTOMRIGHT", -2, 2)
    row._shadow = shadow

    local pulseBg = row:CreateTexture(nil, "BACKGROUND", nil, -1)
    pulseBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    pulseBg:SetAllPoints()
    pulseBg:SetAlpha(0)
    row._pulseBg = pulseBg

    StyleToastRow(row)

    local iconFrame
    if createIcon then
        local iconBr = COLORS.lootCellBorder
        iconFrame = createIcon(row, nil, ICON_SZ, false, iconBr, classic and true or false)
        if iconFrame and ns.UI_StyleLootIconFrame then
            ns.UI_StyleLootIconFrame(iconFrame, iconBr)
        end
    end
    row._icon = iconFrame

    local priceStr = row:CreateFontString(nil, "OVERLAY", toastFont)
    priceStr:SetJustifyH("RIGHT")
    row._price = priceStr

    local qtyStr = row:CreateFontString(nil, "OVERLAY", toastFont)
    qtyStr:SetJustifyH("RIGHT")
    row._qty = qtyStr

    local nameStr = row:CreateFontString(nil, "OVERLAY", toastFont)
    nameStr:SetJustifyH("LEFT")
    if nameStr.SetWordWrap then
        nameStr:SetWordWrap(false)
    end
    row._name = nameStr

    LayoutToastRow(row)
    return row
end

ReleaseToast = function(row)
    if not row then
        return
    end
    row:SetScript("OnUpdate", nil)
    row:Hide()
    row:SetParent(nil)
    row._anItemGen = (row._anItemGen or 0) + 1
    SessionLootOverlayUI._pool[#SessionLootOverlayUI._pool + 1] = row
end

PaintToast = function(row, event)
    local itemID = event and event.itemID
    if not itemID or not row then
        return
    end
    row._anLastEvent = event
    LayoutToastRow(row)
    local qty = event.qty or 1
    local ic = row._icon
    if ic then
        if ic.texture then
            ic.texture:SetTexture(TexForItem(itemID))
            ic.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        if ns.UI_StyleLootIconFrame then
            ns.UI_StyleLootIconFrame(ic, COLORS.lootCellBorder)
        end
        ic:Show()
    end

    row._qty:SetText(tostring(qty) .. "×")
    local qc = COLORS.lootQtyOn or COLORS.textBright
    if qc then
        row._qty:SetTextColor(qc[1], qc[2], qc[3], 1)
    end

    local unitFn = ns.GetLootUnitCopperWithFallback
    local formatCopper = ns.FormatCopper
    local priceStr = row._price
    local totalCopper = nil
    if unitFn then
        local unit = unitFn(itemID)
        if unit and unit > 0 and qty > 0 then
            totalCopper = unit * qty
        end
    end
    if totalCopper and totalCopper > 0 and formatCopper then
        priceStr:SetText(formatCopper(totalCopper, TOAST_COIN_H) or "")
        local pr, pg, pb = GetPriceColor()
        priceStr:SetTextColor(pr, pg, pb, 1)
        priceStr:Show()
    else
        priceStr:SetText((L and L["LOOT_CATALOG_AH_EMPTY"]) or "—")
        local zc = COLORS.lootQtyZero or COLORS.textDim
        if zc then
            priceStr:SetTextColor(zc[1], zc[2], zc[3], 1)
        end
        priceStr:Show()
    end

    row._anItemGen = (row._anItemGen or 0) + 1
    local itemGen = row._anItemGen
    local nameStr = row._name
    local getQuality = ns.GetQualityRGB

    local function ApplyName()
        local nm = GetItemInfo(itemID)
        local qIdx = select(3, GetItemInfo(itemID)) or 1
        if nm and not (issecretvalue and issecretvalue(nm)) then
            nameStr:SetText(nm)
        else
            nameStr:SetText("#" .. tostring(itemID))
        end
        if getQuality then
            local qr, qg, qb = getQuality(qIdx)
            nameStr:SetTextColor(qr, qg, qb)
        end
    end
    ApplyName()
    if not GetItemInfo(itemID) and Item and Item.CreateFromItemID then
        local item = Item:CreateFromItemID(itemID)
        item:ContinueOnItemLoad(function()
            if row._anItemGen == itemGen then
                ApplyName()
            end
        end)
    end
end

function SessionLootOverlayUI:ApplyAnchor()
    local anchor = self.anchor
    if not anchor then
        return
    end
    local point, relPoint, x, y = GetAnchorConfig()
    anchor:ClearAllPoints()
    anchor:SetPoint(point, UIParent, relPoint, x, y)
end

function SessionLootOverlayUI:EnsureAnchor()
    if self.anchor then
        self:ApplyAnchor()
        return
    end
    local anchor = CreateFrame("Frame", "ArtisanNexusSessionLootOverlayAnchor", UIParent)
    anchor:SetSize(TOAST_W, TOAST_H)
    anchor:SetFrameStrata("HIGH")
    anchor:SetFrameLevel(30)
    anchor:EnableMouse(false)
    self.anchor = anchor
    self:ApplyAnchor()
end

function SessionLootOverlayUI:IsPositionEditing()
    return self._positionEdit == true
end

function SessionLootOverlayUI:BeginPositionEdit()
    if self._positionEdit then
        return true
    end
    if InCombatLockdown and InCombatLockdown() then
        local addon = ns.ArtisanNexus
        if addon and addon.Print then
            addon:Print((L and L["LOOT_OVERLAY_EDIT_COMBAT"]) or "Cannot move the loot overlay during combat.")
        end
        return false
    end
    EnsureInitialized()
    self._positionEdit = true
    self:EnsureAnchor()
    local anchor = self.anchor
    if not anchor then
        self._positionEdit = false
        return false
    end
    anchor:SetFrameStrata("DIALOG")
    anchor:SetFrameLevel(40)
    anchor:SetMovable(true)
    anchor:EnableMouse(true)
    anchor:SetClampedToScreen(true)
    anchor:RegisterForDrag("LeftButton")
    anchor:SetScript("OnDragStart", function(_, button)
        if button == "LeftButton" then
            anchor:StartMoving()
        end
    end)
    anchor:SetScript("OnDragStop", function()
        anchor:StopMovingOrSizing()
    end)
    anchor:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            SessionLootOverlayUI:SavePositionEdit()
        end
    end)
    EnsureEditHint(self)
    SetEditHintVisible(self, true)
    ShowEditPreview(self)
    local guard = EnsureEditGuard(self)
    guard:Show()
    return true
end

function SessionLootOverlayUI:EndPositionEdit(save)
    if not self._positionEdit then
        return
    end
    self._editClosing = true
    local anchor = self.anchor
    if save and anchor then
        SaveAnchorConfigFromFrame(anchor)
    elseif anchor then
        self:ApplyAnchor()
    end
    if anchor then
        anchor:SetMovable(false)
        anchor:EnableMouse(false)
        anchor:RegisterForDrag()
        anchor:SetScript("OnDragStart", nil)
        anchor:SetScript("OnDragStop", nil)
        anchor:SetScript("OnMouseUp", nil)
        anchor:SetFrameStrata("HIGH")
        anchor:SetFrameLevel(30)
    end
    ClearEditPreview(self)
    SetEditHintVisible(self, false)
    self._positionEdit = false
    if self._editGuard and self._editGuard:IsShown() then
        self._editGuard:Hide()
    end
    self._editClosing = false
    if ns.ArtisanSettingsUI and ns.ArtisanSettingsUI.RefreshOverlayPositionButton then
        ns.ArtisanSettingsUI:RefreshOverlayPositionButton()
    end
end

function SessionLootOverlayUI:SavePositionEdit()
    if not self._positionEdit then
        return
    end
    self:EndPositionEdit(true)
    local addon = ns.ArtisanNexus
    if addon and addon.Print then
        addon:Print((L and L["SLASH_OVERLAY_MOVE_DONE"]) or "Loot overlay position saved.")
    end
end

function SessionLootOverlayUI:TogglePositionEdit()
    if self._positionEdit then
        self:SavePositionEdit()
        return false
    end
    local started = self:BeginPositionEdit()
    if started then
        local addon = ns.ArtisanNexus
        if addon and addon.Print then
            addon:Print((L and L["SLASH_OVERLAY_MOVE"]) or "Left-click drag the preview to move. Right-click to save.")
        end
    end
    return started
end

function SessionLootOverlayUI:LayoutStack()
    local anchor = self.anchor
    if not anchor then
        return
    end
    local active = self._active
    local n = #active
    if n < 1 then
        anchor:Hide()
        anchor:SetHeight(TOAST_H)
        return
    end
    local h = n * TOAST_H + math.max(0, n - 1) * TOAST_GAP
    anchor:SetSize(TOAST_W, h)
    local y = 0
    for i = 1, n do
        local entry = active[i]
        local row = entry and entry.row
        if row then
            local slideX = (entry and entry.slideX) or 0
            row:ClearAllPoints()
            row:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -slideX, -y)
            row:Show()
            y = y + TOAST_H + TOAST_GAP
        end
    end
    anchor:Show()
end

local function RemoveActiveEntry(self, entry)
    for i = 1, #self._active do
        if self._active[i] == entry then
            table.remove(self._active, i)
            ReleaseToast(entry.row)
            break
        end
    end
    self:LayoutStack()
end

function SessionLootOverlayUI:StartToastFade(entry)
    local row = entry and entry.row
    if not row then
        return
    end
    local holdSec = GetHoldSec()
    local fadeSec = FADE_SEC
    entry.born = entry.born or GetTime()
    entry.slideX = SLIDE_OFFSET
    row:SetAlpha(0)

    row:SetScript("OnUpdate", function()
        local age = GetTime() - entry.born
        local alphaMul = 1

        if age < SLIDE_IN_SEC then
            local ease = EaseOutQuad(age / SLIDE_IN_SEC)
            entry.slideX = SLIDE_OFFSET * (1 - ease)
            alphaMul = ease
            SessionLootOverlayUI:LayoutStack()
        elseif not entry._slideDone then
            entry._slideDone = true
            entry.slideX = 0
            SessionLootOverlayUI:LayoutStack()
        end

        if row._pulseBg then
            if age < PULSE_SEC then
                local env = 1 - (age / PULSE_SEC)
                local pulse = (math.sin(GetTime() * (math.pi * 2 * 2.4)) + 1) * 0.5
                local aLo, aHi = 0.05, 0.24
                row._pulseBg:SetAlpha(env * (aLo + (aHi - aLo) * pulse) * alphaMul)
                local pick = COLORS.lootPickBorder or COLORS.accent
                if pick then
                    local bright = 0.90 + 0.10 * pulse
                    row._pulseBg:SetVertexColor(pick[1] * bright, pick[2] * bright, pick[3] * bright)
                end
            else
                row._pulseBg:SetAlpha(0)
            end
        end

        if age < holdSec then
            row:SetAlpha(alphaMul)
            return
        end

        local fadeAge = age - holdSec
        if fadeAge >= fadeSec then
            row:SetScript("OnUpdate", nil)
            RemoveActiveEntry(SessionLootOverlayUI, entry)
            return
        end
        row:SetAlpha((1 - (fadeAge / fadeSec)) * alphaMul)
    end)
end

function SessionLootOverlayUI:PushToast(event)
    if not event or not event.itemID then
        return
    end
    self:EnsureAnchor()
    local stackMax = GetStackMax()
    while #self._active >= stackMax do
        local old = table.remove(self._active)
        if old and old.row then
            ReleaseToast(old.row)
        end
    end

    local row = AcquireToast(self.anchor)
    PaintToast(row, event)
    StyleToastRow(row)

    local entry = { row = row, born = GetTime(), rt = event.rt or GetTime(), _slideDone = false }
    table.insert(self._active, 1, entry)
    self:LayoutStack()
    self:StartToastFade(entry)
end

function SessionLootOverlayUI:ClearToasts()
    if self._positionEdit then
        ClearEditPreview(self)
        return
    end
    for i = #self._active, 1, -1 do
        ReleaseToast(self._active[i].row)
        self._active[i] = nil
    end
    if self.anchor then
        self.anchor:Hide()
    end
end

function SessionLootOverlayUI:OnLootUpdated()
    if not IsOverlayEnabled() or self._positionEdit then
        return
    end
    EnsureInitialized()
    local svc = ns.SessionLootService
    if not svc or not svc.GetMergedRecentSessionEvents then
        return
    end
    local events = svc:GetMergedRecentSessionEvents(8)
    if #events < 1 then
        return
    end
    local newestRt = events[1].rt or 0
    if newestRt <= self._lastShownRt then
        return
    end
    local cluster = 0.12
    local batch = {}
    for i = #events, 1, -1 do
        local e = events[i]
        local rt = e and e.rt
        if rt and rt >= newestRt - cluster and rt > self._lastShownRt then
            batch[#batch + 1] = e
        end
    end
    for i = #batch, 1, -1 do
        self:PushToast(batch[i])
    end
    if #batch > 0 then
        self._lastShownRt = newestRt
    end
end

function SessionLootOverlayUI:RefreshTheme()
    COLORS = ns.UI_COLORS
    for i = 1, #self._active do
        local entry = self._active[i]
        local row = entry and entry.row
        StyleToastRow(row)
        LayoutToastRow(row)
        if row and row._anLastEvent then
            PaintToast(row, row._anLastEvent)
        end
    end
end

function SessionLootOverlayUI:Hide()
    if self._positionEdit then
        self:EndPositionEdit(true)
    end
    self:ClearToasts()
end

function SessionLootOverlayUI:Show()
    EnsureInitialized()
end

function SessionLootOverlayUI:Toggle()
    EnsureInitialized()
    if not ns.db or not ns.db.profile then
        return false
    end
    local wasOn = IsOverlayEnabled()
    ns.db.profile.sessionLootOverlayEnabled = not wasOn
    if IsOverlayEnabled() then
        self._lastShownRt = GetTime()
    else
        self:Hide()
    end
    if ns.LootHistoryUI and ns.LootHistoryUI.UpdateLootOverlayToggle then
        ns.LootHistoryUI:UpdateLootOverlayToggle()
    end
    return IsOverlayEnabled()
end

function SessionLootOverlayUI:Open()
    EnsureInitialized()
    if not ns.db or not ns.db.profile then
        return false
    end
    ns.db.profile.sessionLootOverlayEnabled = true
    self._lastShownRt = GetTime()
    if ns.LootHistoryUI and ns.LootHistoryUI.UpdateLootOverlayToggle then
        ns.LootHistoryUI:UpdateLootOverlayToggle()
    end
    return true
end

function SessionLootOverlayUI:ResetForUiMode()
    if self._positionEdit then
        self:EndPositionEdit(true)
    end
    self:ClearToasts()
    if self.anchor and ns.UI_UnregisterVisuals then
        ns.UI_UnregisterVisuals(self.anchor)
    end
    self.anchor = nil
    self._pool = {}
end

local function ScheduleLootPulse()
    if not (C_Timer and C_Timer.After) then
        SessionLootOverlayUI:OnLootUpdated()
        return
    end
    SessionLootOverlayUI._lootSeq = (SessionLootOverlayUI._lootSeq or 0) + 1
    local token = SessionLootOverlayUI._lootSeq
    C_Timer.After(0.06, function()
        if token ~= SessionLootOverlayUI._lootSeq then
            return
        end
        SessionLootOverlayUI:OnLootUpdated()
    end)
end

function SessionLootOverlayUI:Init()
    if self._inited then
        return
    end
    self._inited = true
    self._lastShownRt = GetTime()

    local owner = ns.NewEventOwner("SessionLootOverlayUI")
    self._eventOwner = owner

    local function onLoot()
        if not IsOverlayEnabled() then
            return
        end
        ScheduleLootPulse()
    end

    if E and E.SESSION_LOOT_UPDATED then
        owner:RegisterMessage(E.SESSION_LOOT_UPDATED, onLoot)
    end
    if E and E.LOOT_HISTORY_UPDATED then
        owner:RegisterMessage(E.LOOT_HISTORY_UPDATED, onLoot)
    end
    if E and E.AH_PRICES_UPDATED then
        owner:RegisterMessage(E.AH_PRICES_UPDATED, function()
            if not IsOverlayEnabled() then
                return
            end
            for i = 1, #SessionLootOverlayUI._active do
                local entry = SessionLootOverlayUI._active[i]
                if entry and entry.row and entry.row._anLastEvent then
                    PaintToast(entry.row, entry.row._anLastEvent)
                end
            end
        end)
    end
    if E and E.THEME_CHANGED then
        owner:RegisterMessage(E.THEME_CHANGED, function()
            COLORS = ns.UI_COLORS
            SessionLootOverlayUI:RefreshTheme()
        end)
    end
end

--- Settings sliders call this after X/Y change.
function SessionLootOverlayUI:ApplySettingsAnchor()
    EnsureInitialized()
    self:ApplyAnchor()
    self:LayoutStack()
end

ns.SessionLootOverlayUI = SessionLootOverlayUI
