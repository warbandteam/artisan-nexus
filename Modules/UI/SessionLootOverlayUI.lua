--[[
    Session loot overlay — compact on-screen toasts (icon, name, qty, price).
    No window chrome: appears on pickup, fades out. Position from Settings (X/Y).
    Classic / Modern row styling via uiMode + theme helpers.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants and ns.Constants.EVENTS
local L = ns.L
local COLORS = ns.UI_COLORS

local OVERLAY_SCALE_DEFAULT = 1.15
local OVERLAY_SCALE_MIN = 0.75
local OVERLAY_SCALE_MAX = 1.5

local OVERLAY_DIM_BASE = {
    toastW = 396,
    toastH = 38,
    toastGap = 6,
    iconSz = 26,
    toastPad = 6,
    toastIconGap = 6,
    toastColGap = 6,
    toastQtyW = 32,
    toastPriceW = 96,
    toastCoinH = 13,
    rankSz = 18,
    rankGap = 4,
    panelPad = 5,
    slideOffset = 20,
}

local function GetOverlayScale()
    local p = ns.db and ns.db.profile
    local n = p and tonumber(p.sessionLootOverlayScale)
    if not n or n ~= n then
        return OVERLAY_SCALE_DEFAULT
    end
    return math.max(OVERLAY_SCALE_MIN, math.min(OVERLAY_SCALE_MAX, n))
end

local function OverlayDim(key)
    local base = OVERLAY_DIM_BASE[key]
    if not base then
        return 0
    end
    return math.floor(base * GetOverlayScale() + 0.5)
end

local HOLD_SEC_DEFAULT = 4.0
local FADE_SEC = 0.85
local SLIDE_IN_SEC = 0.22
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

--- Resolve the toast font object plus its base metrics so text can scale with the
--- overlay size slider (font object alone stays a fixed size).
---@return string|table fontRef, string|nil file, number|nil size, string|nil flags
local function ToastFontSpec()
    local ref = ToastFont()
    local obj = ref
    if type(ref) == "string" then
        obj = _G[ref]
    end
    if obj and obj.GetFont then
        local file, size, flags = obj:GetFont()
        return ref, file, size, flags
    end
    return ref, nil, nil, nil
end

--- Catalog rows (fishing / gathering by category) give the authoritative reagent
--- tier for the quality badge; crafted / unknown tabs have none.
local function ResolveOverlayCatalogEntries(tabKey)
    if tabKey == "fishing" then
        return ns.GetFishingCatalogEntries and ns.GetFishingCatalogEntries() or nil
    end
    if not tabKey or tabKey == "crafted" then
        return nil
    end
    return ns.GetGatheringCatalogByCategory and ns.GetGatheringCatalogByCategory(tabKey) or nil
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
    hint:SetWidth(OverlayDim("toastW") + 40)
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
    row:SetSize(OverlayDim("toastW"), OverlayDim("toastH"))
    local toastFont, fontFile, fontSize, fontFlags = ToastFontSpec()
    local scale = GetOverlayScale()
    local ic = row._icon
    if ic then
        local iconSz = OverlayDim("iconSz")
        ic:SetSize(iconSz, iconSz)
        ic:ClearAllPoints()
        ic:SetPoint("LEFT", row, "LEFT", OverlayDim("toastPad"), 0)
    end
    local rank = row._rank
    if rank then
        local rsz = OverlayDim("rankSz")
        rank:SetSize(rsz, rsz)
        rank:ClearAllPoints()
        rank:SetPoint("LEFT", ic or row, "RIGHT", OverlayDim("toastIconGap"), 0)
    end
    local textFields = { row._name, row._qty, row._price }
    for i = 1, 3 do
        local fs = textFields[i]
        if fs and fs.SetFontObject then
            fs:SetFontObject(toastFont)
        end
        if fs and fontFile and fs.SetFont then
            fs:SetFont(fontFile, math.max(8, math.floor(fontSize * scale + 0.5)), fontFlags)
        end
        if fs and fs.SetWordWrap then
            fs:SetWordWrap(false)
        end
    end
    local price = row._price
    local qty = row._qty
    local name = row._name
    if price then
        price:SetWidth(OverlayDim("toastPriceW"))
        price:ClearAllPoints()
        price:SetPoint("RIGHT", row, "RIGHT", -OverlayDim("toastPad"), 0)
        if price.SetJustifyH then
            price:SetJustifyH("RIGHT")
        end
        if price.SetMaxLines then
            price:SetMaxLines(1)
        end
    end
    if qty and price then
        qty:SetWidth(OverlayDim("toastQtyW"))
        qty:ClearAllPoints()
        qty:SetPoint("RIGHT", price, "LEFT", -OverlayDim("toastColGap"), 0)
        if qty.SetJustifyH then
            qty:SetJustifyH("RIGHT")
        end
    end
    if name then
        name:ClearAllPoints()
        name:SetPoint("LEFT", ic or row, "RIGHT", OverlayDim("toastIconGap"), 0)
        if qty then
            name:SetPoint("RIGHT", qty, "LEFT", -OverlayDim("toastColGap"), 0)
        elseif price then
            name:SetPoint("RIGHT", price, "LEFT", -OverlayDim("toastColGap"), 0)
        else
            name:SetPoint("RIGHT", row, "RIGHT", -OverlayDim("toastPad"), 0)
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
        if row._rank then
            row._rank:Hide()
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
        iconFrame = createIcon(row, nil, OverlayDim("iconSz"), false, iconBr, classic and true or false)
        if iconFrame and ns.UI_StyleLootIconFrame then
            ns.UI_StyleLootIconFrame(iconFrame, iconBr)
        end
        if iconFrame and iconFrame.EnableMouse then
            --- Keep clicks falling through to the anchor panel (right-click dismiss).
            iconFrame:EnableMouse(false)
        end
    end
    row._icon = iconFrame

    local rankTex = row:CreateTexture(nil, "ARTWORK")
    rankTex:Hide()
    row._rank = rankTex

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
        priceStr:SetText(formatCopper(totalCopper, OverlayDim("toastCoinH")) or "")
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
    local rankTex = row._rank
    local getQuality = ns.GetQualityRGB
    local tabKey = event.tabKey or event.cat

    local function ApplyRank()
        if not nameStr then
            return
        end
        local shown = false
        if rankTex and ns.SetProfessionRankAtlasForItem then
            local tierFb
            local entries = ResolveOverlayCatalogEntries(tabKey)
            if entries and ns.GetCatalogRankIndexForItem then
                tierFb = ns.GetCatalogRankIndexForItem(itemID, entries)
            end
            local rsz = OverlayDim("rankSz")
            shown = ns.SetProfessionRankAtlasForItem(rankTex, itemID, rsz, rsz, tierFb) and true or false
        end
        row._rankShown = shown
        if rankTex and not shown then
            rankTex:Hide()
        end
        if shown and rankTex then
            nameStr:SetPoint("LEFT", rankTex, "RIGHT", OverlayDim("rankGap"), 0)
        else
            nameStr:SetPoint("LEFT", row._icon or row, "RIGHT", OverlayDim("toastIconGap"), 0)
        end
    end

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
    ApplyRank()
    if not GetItemInfo(itemID) and Item and Item.CreateFromItemID then
        local item = Item:CreateFromItemID(itemID)
        item:ContinueOnItemLoad(function()
            if row._anItemGen == itemGen then
                ApplyName()
                ApplyRank()
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

--- Themed border/backdrop around the whole overlay group (toasts sit inside with padding).
function SessionLootOverlayUI:StyleAnchorPanel()
    local anchor = self.anchor
    if not anchor then
        return
    end
    local classic = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    if classic and ns.UI_ApplyClassicInsetPanel then
        ns.UI_ApplyClassicInsetPanel(anchor)
    elseif ns.UI_ApplyVisuals and COLORS then
        local bg = COLORS.bgCard or COLORS.lootCellBg or COLORS.surfaceRowEven
        local bd = COLORS.border or COLORS.lootCellBorder
        ns.UI_ApplyVisuals(anchor, bg, bd)
    end
end

--- Normal (non-edit) mouse wiring: right-click anywhere on the panel dismisses toasts.
function SessionLootOverlayUI:ApplyOverlayMouse()
    local anchor = self.anchor
    if not anchor then
        return
    end
    anchor:EnableMouse(true)
    anchor:RegisterForDrag()
    anchor:SetScript("OnDragStart", nil)
    anchor:SetScript("OnDragStop", nil)
    anchor:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and not SessionLootOverlayUI._positionEdit then
            SessionLootOverlayUI:ClearToasts()
        end
    end)
end

function SessionLootOverlayUI:EnsureAnchor()
    if self.anchor then
        self:ApplyAnchor()
        return
    end
    local pad = OverlayDim("panelPad")
    local anchor = CreateFrame("Frame", "ArtisanNexusSessionLootOverlayAnchor", UIParent)
    anchor:SetSize(OverlayDim("toastW") + pad * 2, OverlayDim("toastH") + pad * 2)
    anchor:SetFrameStrata("HIGH")
    anchor:SetFrameLevel(30)
    self.anchor = anchor
    self:StyleAnchorPanel()
    self:ApplyOverlayMouse()
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
        anchor:SetFrameStrata("HIGH")
        anchor:SetFrameLevel(30)
        self:ApplyOverlayMouse()
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
    local pad = OverlayDim("panelPad")
    if n < 1 then
        anchor:Hide()
        anchor:SetHeight(OverlayDim("toastH") + pad * 2)
        return
    end
    local toastH = OverlayDim("toastH")
    local toastGap = OverlayDim("toastGap")
    local h = n * toastH + math.max(0, n - 1) * toastGap
    anchor:SetSize(OverlayDim("toastW") + pad * 2, h + pad * 2)
    local y = pad
    for i = 1, n do
        local entry = active[i]
        local row = entry and entry.row
        if row then
            local slideX = (entry and entry.slideX) or 0
            row:ClearAllPoints()
            row:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -(pad + slideX), -y)
            row:Show()
            y = y + toastH + toastGap
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
    entry.slideX = OverlayDim("slideOffset")
    row:SetAlpha(0)

    row:SetScript("OnUpdate", function()
        local age = GetTime() - entry.born
        local alphaMul = 1

        if age < SLIDE_IN_SEC then
            local ease = EaseOutQuad(age / SLIDE_IN_SEC)
            entry.slideX = OverlayDim("slideOffset") * (1 - ease)
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
    self:StyleAnchorPanel()
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

--- Settings overlay size slider — relayout pooled + active toasts.
function SessionLootOverlayUI:ApplySettingsScale()
    EnsureInitialized()
    if self._editHint then
        self._editHint:SetWidth(OverlayDim("toastW") + 40)
    end
    local pool = self._pool
    for i = 1, #pool do
        LayoutToastRow(pool[i])
    end
    for i = 1, #self._active do
        local entry = self._active[i]
        local row = entry and entry.row
        if row then
            LayoutToastRow(row)
            if row._anLastEvent then
                PaintToast(row, row._anLastEvent)
            end
        end
    end
    self:LayoutStack()
end

ns.SessionLootOverlayUI = SessionLootOverlayUI
