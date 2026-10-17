--[[
    Session loot overlay — one Warband Nexus compact toast per pickup (icon, name, qty, price).

    Every toast is built exactly like the WN compact collectible toast
    (NotificationManager.lua:1167-1418 ShowModalNotification `config.compact` branch):
      host / layers            -> ns.NotificationToastFactory:CreateToastHost / CreateToastLayer
      backdrop + accent border -> NotificationManager.lua:1189-1201 + ToastChrome.ApplyCompactBackdropChrome
      icon slot + icon border  -> NotificationManager.lua:1203-1231 + ToastChrome.ApplyCompactIconBorder
      badge / title / detail   -> NotificationManager.lua:1287-1416 + NotificationToastFactory:ApplyCompactTextLayout
      geometry + fonts         -> NotificationManager_AlertStack.lua:85-186 (collectible tier)
      entrance / fade / stack  -> NotificationManager.lua:1435-1455, AlertStack.lua:767-796 (fade out)
    The WN layout scale (1.15) is the overlay size slider here (default 1.15 = WN look).

    The stack hangs from a movable, invisible anchor (position edit: drag preview, right-click saves).
]]

local ADDON_NAME, ns = ...
-- Pixel-perfect frames (SharedWidgets_Pixel: SetPoint/SetSize snap to whole physical pixels).
local CreateFrame = function(...) return (ns.UI_CreateFrame or _G.CreateFrame)(...) end

-- 12.1.5 removed the global item/coin fallbacks; bind the namespaced APIs.
local GetItemInfo = C_Item.GetItemInfo

local E = ns.Constants.EVENTS
local L = ns.L
local FontManager = ns.FontManager

local OVERLAY_SCALE_DEFAULT = 1.15
local OVERLAY_SCALE_MIN = 0.75
local OVERLAY_SCALE_MAX = 1.5

-- NotificationManager_AlertStack.lua:150-186 (collectible compact tier, unscaled px).
local ALERT_WIDTH = 320
local ALERT_HEIGHT = 58
local ALERT_GAP = 6
local ALERT_ICON_SIZE = 36
local ALERT_ICON_SLOT = 50
local ALERT_PAD_LEFT = 8
local ALERT_PAD_RIGHT = 10
local ALERT_PAD_TEXT = 6
local ALERT_TEXT_LINE_GAP = 2
local WN_TOAST_LAYOUT_SCALE = 1.15
-- AlertStack.lua:85-90 typography scales.
local TOAST_FONT_SCALE_META = 1.0
local TOAST_FONT_SCALE_PRIMARY = 0.96

-- NotificationManager.lua:49-53 / AlertStack.lua:13-15 timings.
local TOAST_FADE_OUT_SEC = 0.32
local TOAST_COLLAPSE_DELAY_SEC = 0.14
local TOAST_REPOSITION_SEC = 0.38
local TOAST_ENTRANCE_SEC = 0.3
local TOAST_ENTRANCE_OFFSET = 50

local HOLD_SEC_DEFAULT = 4.0
local STACK_MAX_DEFAULT = 3
local STACK_MAX_LIMIT = 6
local PREVIEW_ITEM_ID = 2770
local PREVIEW_COPPER = 1845000
local SCALE_PREVIEW_SEC = 2.5
local EDIT_HINT_GAP = 6
local COIN_ICON_SIZE = 11

---@class SessionLootOverlayUI
local SessionLootOverlayUI = {
    anchor = nil,
    _pool = {},
    _active = {},
    _lastShownRt = 0,
    _inited = false,
    _lootPulsePending = false,
    _positionEdit = false,
    _editPreviewEntry = nil,
    _editHint = nil,
    _editGuard = nil,
    _scalePreview = false,
    _scalePreviewEntry = nil,
    _scalePreviewSeq = 0,
}

local function GetOverlayScale()
    local p = ns.db and ns.db.profile
    local n = p and tonumber(p.sessionLootOverlayScale)
    if not n or n ~= n then
        return OVERLAY_SCALE_DEFAULT
    end
    return math.max(OVERLAY_SCALE_MIN, math.min(OVERLAY_SCALE_MAX, n))
end

--- AlertStack.lua:92-94 ToastPx with the overlay size slider as the layout scale.
local function ToastPx(value)
    return math.max(1, math.floor((tonumber(value) or 0) * GetOverlayScale() + 0.5))
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

-- ── WN toast helpers (NotificationManager.lua:75-143, ToastChrome.lua:117-181) ──

--- Toast accent when the item quality is unknown (NotificationManager.lua:75 GetThemeAccentColor).
local function GetThemeAccentColor()
    local c = ns.UI_COLORS
    if c and c.accent then
        return { c.accent[1], c.accent[2], c.accent[3] }
    end
    return { 0.40, 0.20, 0.58 }
end

--- NotificationManager.lua:111-120 NM_GetElevatedBackdropFillRGBA.
local function GetElevatedBackdropFillRGBA()
    local c = ns.UI_COLORS or {}
    local s = c.surfaceElevated or c.bgLight or c.bg
    if s then
        local a = s[4]
        if type(a) ~= "number" or a ~= a or a <= 0 or a > 1 then a = 0.94 end
        return s[1], s[2], s[3], a
    end
    return 0.03, 0.03, 0.05, 0.98
end

--- NotificationManager.lua:122-129 NM_ThemeTextHex.
local function ThemeTextHex(role)
    if ns.UI_GetTextRoleHex then
        return ns.UI_GetTextRoleHex(role)
    end
    if role == "Dim" then return "|cff888888" end
    if role == "Muted" then return "|cffaaaaaa" end
    return "|cffeeeeee"
end

--- NotificationManager.lua:131-143 NM_ApplyTextShadow.
local function ApplyTextShadow(fs, strength)
    if not fs or not fs.SetShadowColor then return end
    local sr, sg, sb, sa
    if ns.UI_GetTextShadowRGBA then
        sr, sg, sb, sa = ns.UI_GetTextShadowRGBA(strength)
    else
        sr, sg, sb, sa = 0, 0, 0, 0.9 * (strength or 1)
    end
    fs:SetShadowColor(sr, sg, sb, sa)
    fs:SetShadowOffset(1, -1)
end

--- ToastChrome.lua:166-177 AccentHex / TitleHex.
local function AccentHex(accentRGB, boost)
    if not accentRGB then return "|cffffffff" end
    boost = boost or 1.06
    local tr = math.floor(math.min(255, accentRGB[1] * 255 * boost))
    local tg = math.floor(math.min(255, accentRGB[2] * 255 * boost))
    local tb = math.floor(math.min(255, accentRGB[3] * 255 * boost))
    return string.format("|cff%02x%02x%02x", tr, tg, tb)
end

--- AlertStack.lua:112-139 NM_ToastFontSize + NM_ApplyToastFont (size follows the overlay scale).
local function ApplyToastFont(fs, category)
    if not fs or not FontManager then return end
    local base = (FontManager.GetFontSize and FontManager:GetFontSize(category)) or 12
    local catScale = (category == "small") and TOAST_FONT_SCALE_META or TOAST_FONT_SCALE_PRIMARY
    local size = base * catScale * (GetOverlayScale() / WN_TOAST_LAYOUT_SCALE)
    size = math.max(6, math.min(72, math.floor(size + 0.5)))
    local flags = FontManager:GetAAFlags(category, {})
    local face = FontManager:GetFontFace()
    pcall(function()
        fs:SetFont(face, size, flags)
    end)
    if FontManager.ApplyReadableEdge then
        FontManager:ApplyReadableEdge(fs, category, {})
    end
end

--- AlertStack.lua:141-147 NM_CreateToastFontString.
local function CreateToastFontString(parent, category)
    local fs = FontManager:CreateFontString(parent, category, "OVERLAY")
    ApplyToastFont(fs, category)
    return fs
end

local function ToastHost(parent, width, height, options)
    return ns.NotificationToastFactory:CreateToastHost(parent, width, height, options)
end

local function ToastLayer(parent, width, height)
    return ns.NotificationToastFactory:CreateToastLayer(parent, width, height)
end

--- ToastChrome.ApplyCompactIconBorder (border frame created once per pooled toast, recolored on reuse).
local function ApplyCompactIconBorder(iconSlot, iconTex, iconSize, accentRGB)
    iconTex:SetVertexColor(1, 1, 1, 1)
    iconTex:SetAlpha(1)
    local edgeSize = (ns.UI_GetBorderThickness and ns.UI_GetBorderThickness(iconSlot)) or 1
    local border = iconSlot._anIconBorder
    if not border then
        border = CreateFrame("Frame", nil, iconSlot, "BackdropTemplate")
        border:EnableMouse(false)
        iconSlot._anIconBorder = border
    end
    border:SetFrameLevel(iconSlot:GetFrameLevel() + 2)
    border:SetSize(iconSize + edgeSize * 2, iconSize + edgeSize * 2)
    border:ClearAllPoints()
    border:SetPoint("CENTER", iconTex, "CENTER", 0, 0)
    border:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        tile = false,
        edgeSize = edgeSize,
        insets = { left = edgeSize, right = edgeSize, top = edgeSize, bottom = edgeSize },
    })
    border:SetBackdropColor(0, 0, 0, 0)
    local r, g, b = 0.42, 0.42, 0.46
    if accentRGB then r, g, b = accentRGB[1], accentRGB[2], accentRGB[3] end
    border:SetBackdropBorderColor(r, g, b, 0.88)
end

--- NotificationManager.lua:1189-1201 backdrop layer + ToastChrome.ApplyCompactBackdropChrome.
local function ApplyBackdropChrome(backdrop, accentRGB)
    backdrop:SetBackdrop({
        bgFile = "Interface\\BUTTONS\\WHITE8X8",
        edgeFile = "Interface\\BUTTONS\\WHITE8X8",
        tile = false,
        edgeSize = (ns.UI_GetBorderThickness and ns.UI_GetBorderThickness(backdrop)) or 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    backdrop:SetBackdropColor(GetElevatedBackdropFillRGBA())
    if accentRGB then
        backdrop:SetBackdropBorderColor(accentRGB[1], accentRGB[2], accentRGB[3], 0.38)
    end
end

-- ── Toast build / layout / paint ──

local function ToastWidth()
    return ToastPx(ALERT_WIDTH)
end

local function ToastHeight()
    return ToastPx(ALERT_HEIGHT)
end

--- Geometry + fonts for the current overlay scale (NotificationManager.lua:1171-1231).
local function LayoutToast(toast)
    local w, h = ToastWidth(), ToastHeight()
    local slotW, iconSz = ToastPx(ALERT_ICON_SLOT), ToastPx(ALERT_ICON_SIZE)
    local padLeft, padRight = ToastPx(ALERT_PAD_LEFT), ToastPx(ALERT_PAD_RIGHT)
    toast:SetSize(w, h)
    toast._backdrop:SetAllPoints(toast)
    toast._iconSlot:SetSize(slotW, h)
    toast._iconSlot:ClearAllPoints()
    toast._iconSlot:SetPoint("LEFT", toast, "LEFT", padLeft, 0)
    toast._icon:SetSize(iconSz, iconSz)
    toast._iconSz = iconSz
    local rankSz = math.floor(iconSz * 0.5 + 0.5)
    toast._rank:SetSize(rankSz, rankSz)
    toast._rankSz = rankSz
    toast._content:ClearAllPoints()
    toast._content:SetPoint("TOP", toast, "TOP", 0, 0)
    toast._content:SetPoint("BOTTOM", toast, "BOTTOM", 0, 0)
    toast._content:SetPoint("LEFT", toast, "LEFT", padLeft + slotW, 0)
    toast._content:SetPoint("RIGHT", toast, "RIGHT", -padRight, 0)
    toast._textUseW = math.max(48, w - padLeft - slotW - padRight - ToastPx(ALERT_PAD_TEXT) * 2)
    ApplyToastFont(toast._title, "title")
    ApplyToastFont(toast._badge, "small")
    ApplyToastFont(toast._detail, "small")
end

local function CreateToast(parent)
    local w, h = ToastWidth(), ToastHeight()
    local toast = ToastHost(parent, w, h, {
        strata = parent:GetFrameStrata(),
        frameLevel = parent:GetFrameLevel() + 2,
        clampToScreen = false,
    })
    -- Layer 1: backdrop (fill + accent border).
    local backdrop = ToastLayer(toast, w, h)
    backdrop:SetFrameLevel(toast:GetFrameLevel() + 1)
    backdrop:EnableMouse(false)
    toast._backdrop = backdrop
    -- Layer 2: icon slot (shared left gutter) + item icon + crafting-quality rank.
    local iconSlot = ToastLayer(toast, ToastPx(ALERT_ICON_SLOT), h)
    iconSlot:SetFrameLevel(toast:GetFrameLevel() + 2)
    iconSlot:EnableMouse(false)
    toast._iconSlot = iconSlot
    local icon = iconSlot:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER", iconSlot, "CENTER", 0, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    toast._icon = icon
    local rank = iconSlot:CreateTexture(nil, "OVERLAY", nil, 2)
    rank:SetPoint("TOPLEFT", icon, "TOPLEFT", -2, 2)
    rank:Hide()
    toast._rank = rank
    -- Content frame (right): badge / title / detail.
    local content = ToastLayer(toast, 1, h)
    content:SetFrameLevel(toast:GetFrameLevel() + 2)
    content:EnableMouse(false)
    content:SetClipsChildren(true)
    toast._content = content
    local textGroup = ToastLayer(content)
    textGroup:SetFrameLevel(content:GetFrameLevel() + 1)
    textGroup:EnableMouse(false)
    toast._textGroup = textGroup
    local title = CreateToastFontString(textGroup, "title")
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetMaxLines(1)
    toast._title = title
    local badge = CreateToastFontString(textGroup, "small")
    badge:SetJustifyH("LEFT")
    badge:SetWordWrap(false)
    badge:SetMaxLines(1)
    toast._badge = badge
    local detail = CreateToastFontString(textGroup, "small")
    detail:SetJustifyH("LEFT")
    detail:SetWordWrap(false)
    detail:SetMaxLines(1)
    toast._detail = detail
    -- Left-click dismisses this toast, right-click every toast (NotificationManager.lua:1420-1426).
    toast:SetScript("OnMouseDown", function(self, button)
        local entry = self._anEntry
        if not entry or SessionLootOverlayUI._positionEdit then
            return
        end
        if button == "RightButton" then
            SessionLootOverlayUI:ClearToasts()
        else
            SessionLootOverlayUI:DismissEntry(entry)
        end
    end)
    LayoutToast(toast)
    return toast
end

local function AcquireToast(parent)
    local toast = table.remove(SessionLootOverlayUI._pool)
    if toast then
        toast:SetParent(parent)
        toast:SetFrameStrata(parent:GetFrameStrata())
        LayoutToast(toast)
    else
        toast = CreateToast(parent)
    end
    toast:SetAlpha(0)
    toast:EnableMouse(not SessionLootOverlayUI._positionEdit)
    toast:Show()
    return toast
end

local function ReleaseToast(toast)
    if not toast then
        return
    end
    toast:Hide()
    toast:ClearAllPoints()
    toast._anEntry = nil
    toast._anLastEvent = nil
    toast._anItemGen = (toast._anItemGen or 0) + 1
    SessionLootOverlayUI._pool[#SessionLootOverlayUI._pool + 1] = toast
end

--- Badge / title / detail lines + compact text layout (NotificationManager.lua:1287-1416).
local function LayoutToastText(toast)
    local textUseW = toast._textUseW
    local title, badge, detail = toast._title, toast._badge, toast._detail
    title:SetWidth(textUseW)
    badge:SetWidth(textUseW)
    local hasDetail = (detail:GetText() or "") ~= ""
    if hasDetail then
        detail:SetWidth(textUseW)
        detail:Show()
    else
        detail:Hide()
    end
    local gapTitle = ToastPx(ALERT_TEXT_LINE_GAP)
    local hTitle = title:GetStringHeight() or 0
    local hHeader = badge:GetStringHeight() or 0
    local hDetail = hasDetail and (detail:GetStringHeight() or 0) or 0
    local stackH = hTitle + (hasDetail and (gapTitle + hDetail) or 0)
    local params = {
        mode = "standard",
        contentFrame = toast._content,
        textGroup = toast._textGroup,
        headerLine = badge,
        titleLine = title,
        detailLine = hasDetail and detail or nil,
        textUseW = textUseW,
        stackH = stackH,
        hHeader = hHeader,
        gapTitle = gapTitle,
        textLeftPad = ToastPx(ALERT_PAD_TEXT),
        headerTopInset = ToastPx(2),
    }
    ns.NotificationToastFactory:ApplyCompactTextLayout(params)
end

local function PaintToast(toast, event)
    local itemID = event and event.itemID
    if not itemID or not toast then
        return
    end
    toast._anLastEvent = event
    local qty = event.qty or 1

    toast._icon:SetTexture(TexForItem(itemID))
    toast._icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local badge = toast._badge
    badge:SetText(ThemeTextHex("Bright") .. tostring(qty) .. "×|r")
    ApplyTextShadow(badge, 0.8)

    local totalCopper
    local unitFn = ns.GetLootUnitCopperWithFallback
    if unitFn then
        local unit = unitFn(itemID)
        if unit and unit > 0 and qty > 0 then
            totalCopper = unit * qty
        end
    end
    if (not totalCopper or totalCopper <= 0) and event._preview then
        totalCopper = PREVIEW_COPPER
    end
    local detail = toast._detail
    local money = totalCopper and totalCopper > 0 and ns.FormatCopper
        and ns.FormatCopper(totalCopper, ToastPx(COIN_ICON_SIZE))
    if money and money ~= "" then
        detail:SetText(money)
    else
        detail:SetText(ThemeTextHex("Muted") .. ((L and L["LOOT_CATALOG_AH_EMPTY"]) or "—") .. "|r")
    end
    ApplyTextShadow(detail, 0.6)

    toast._anItemGen = (toast._anItemGen or 0) + 1
    local itemGen = toast._anItemGen
    local title = toast._title
    local tabKey = event.tabKey or event.cat

    local function ApplyRank()
        local shown = false
        if ns.SetProfessionRankAtlasForItem then
            local tierFb
            local entries = ResolveOverlayCatalogEntries(tabKey)
            if entries and ns.GetCatalogRankIndexForItem then
                tierFb = ns.GetCatalogRankIndexForItem(itemID, entries)
            end
            local rsz = toast._rankSz
            shown = ns.SetProfessionRankAtlasForItem(toast._rank, itemID, rsz, rsz, tierFb) and true or false
        end
        if shown then
            toast._rank:Show()
        else
            toast._rank:Hide()
        end
    end

    local function ApplyName()
        local nm, _, quality = GetItemInfo(itemID)
        local accent
        if quality and ns.GetQualityRGB then
            local qr, qg, qb = ns.GetQualityRGB(quality)
            accent = { qr, qg, qb }
        end
        accent = accent or GetThemeAccentColor()
        local nameStr = (nm and not (issecretvalue and issecretvalue(nm))) and nm or ("#" .. tostring(itemID))
        title:SetText(AccentHex(accent, 1.14) .. nameStr .. "|r")
        ApplyTextShadow(title, 0.85)
        ApplyBackdropChrome(toast._backdrop, accent)
        ApplyCompactIconBorder(toast._iconSlot, toast._icon, toast._iconSz, accent)
        LayoutToastText(toast)
    end

    ApplyName()
    ApplyRank()
    if not GetItemInfo(itemID) and Item and Item.CreateFromItemID then
        local item = Item:CreateFromItemID(itemID)
        item:ContinueOnItemLoad(function()
            if toast._anItemGen == itemGen then
                ApplyName()
                ApplyRank()
            end
        end)
    end
end

-- ── Stack driver (entrance -> hold -> fade out -> collapse; one OnUpdate on the anchor) ──

local function StackStep()
    return ToastHeight() + ToastPx(ALERT_GAP)
end

local function RemoveEntry(self, entry)
    for i = 1, #self._active do
        if self._active[i] == entry then
            table.remove(self._active, i)
            break
        end
    end
    ReleaseToast(entry.toast)
    entry.toast = nil
    if self._editPreviewEntry == entry then self._editPreviewEntry = nil end
    if self._scalePreviewEntry == entry then self._scalePreviewEntry = nil end
    self:LayoutStack()
end

local function AnchorOnUpdate(anchor, elapsed)
    local self = SessionLootOverlayUI
    local now = GetTime()
    local holdSec = GetHoldSec()
    local repoStep = math.min(1, (elapsed or 0) / TOAST_REPOSITION_SEC * 3)
    local removed
    for i = 1, #self._active do
        local entry = self._active[i]
        local toast = entry and entry.toast
        if toast then
            local age = now - entry.born
            local alpha, entranceY = 1, 0
            if age < TOAST_ENTRANCE_SEC then
                local p = age / TOAST_ENTRANCE_SEC
                local ease = 1 - (1 - p) * (1 - p)
                alpha = math.min(1, p * 1.2)
                entranceY = TOAST_ENTRANCE_OFFSET * (1 - ease)
            end
            if not entry.keep then
                if entry.closingAt then
                    local p = (now - entry.closingAt) / TOAST_FADE_OUT_SEC
                    alpha = math.max(0, 1 - p)
                    if p >= 1 then
                        alpha = 0
                        if now - entry.closingAt >= TOAST_FADE_OUT_SEC + TOAST_COLLAPSE_DELAY_SEC then
                            removed = removed or {}
                            removed[#removed + 1] = entry
                        end
                    end
                elseif age >= holdSec then
                    entry.closingAt = now
                    toast:EnableMouse(false)
                end
            end
            local cy = entry.y or entry.targetY or 0
            cy = cy + ((entry.targetY or 0) - cy) * repoStep
            if math.abs((entry.targetY or 0) - cy) < 0.5 then cy = entry.targetY or 0 end
            entry.y = cy
            toast:SetAlpha(alpha)
            toast:ClearAllPoints()
            toast:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, -cy + entranceY)
        end
    end
    if removed then
        for i = 1, #removed do
            RemoveEntry(self, removed[i])
        end
    end
end

-- ── Position edit (anchor drag) ──

local function EnsureEditGuard(self)
    if self._editGuard then
        return self._editGuard
    end
    local g = CreateFrame("Frame", "ArtisanNexusSessionLootOverlayEditGuard", UIParent)
    g:SetSize(1, 1)
    g:Hide()
    g:SetScript("OnHide", function()
        if SessionLootOverlayUI._positionEdit and not SessionLootOverlayUI._editClosing then
            SessionLootOverlayUI:EndPositionEdit(false)
        end
    end)
    --- Esc cancels the position edit: the guard is a WN WindowManager POPUP entry (top of the
    --- Esc stack while shown).
    ns.WindowManager:Register(g, ns.WindowManager.PRIORITY.POPUP, function() g:Hide() end)
    self._editGuard = g
    return g
end

local function EnsureEditHint(self)
    self:EnsureAnchor()
    local anchor = self.anchor
    if self._editHint or not anchor then
        return
    end
    local hint = FontManager:CreateFontString(anchor, "body", "OVERLAY")
    hint:SetPoint("BOTTOM", anchor, "TOP", 0, EDIT_HINT_GAP)
    hint:SetJustifyH("CENTER")
    hint:SetWordWrap(true)
    hint:Hide()
    self._editHint = hint
end

local function SetEditHintVisible(self, show)
    local hint = self._editHint
    if not hint then
        return
    end
    if show then
        hint:SetWidth(ToastWidth() + 40)
        hint:SetText((L and L["LOOT_OVERLAY_EDIT_HINT"]) or "Drag to move, right-click to save")
        ns.UI_SetTextColorRole(hint, "Bright")
        ApplyTextShadow(hint, 0.85)
        hint:Show()
    else
        hint:Hide()
    end
end

local function PushPreviewEntry(self)
    local anchor = self.anchor
    local toast = AcquireToast(anchor)
    local entry = { toast = toast, born = GetTime() - TOAST_ENTRANCE_SEC, keep = true, _preview = true }
    toast._anEntry = entry
    PaintToast(toast, { itemID = PREVIEW_ITEM_ID, qty = 3, rt = GetTime(), _preview = true })
    table.insert(self._active, 1, entry)
    self:LayoutStack()
    return entry
end

local function ReleaseAllEntries(self)
    for i = #self._active, 1, -1 do
        ReleaseToast(self._active[i].toast)
        self._active[i] = nil
    end
    self._editPreviewEntry = nil
    self._scalePreviewEntry = nil
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

--- Normal (non-edit) mouse wiring: the anchor itself is click-through; toasts take the clicks.
function SessionLootOverlayUI:ApplyOverlayMouse()
    local anchor = self.anchor
    if not anchor then
        return
    end
    anchor:EnableMouse(false)
    anchor:RegisterForDrag()
    anchor:SetScript("OnDragStart", nil)
    anchor:SetScript("OnDragStop", nil)
    anchor:SetScript("OnMouseUp", nil)
end

function SessionLootOverlayUI:EnsureAnchor()
    if self.anchor then
        self:ApplyAnchor()
        return
    end
    local anchor = ns.UI.Factory:CreateContainer(UIParent, ToastWidth(), ToastHeight(), false,
        "ArtisanNexusSessionLootOverlayAnchor")
    anchor:Hide()
    --- Toast HUD: WN FLOATING tier strata (not ESC / combat registered: toasts outlive both).
    ns.WindowManager:ApplyStrata(anchor, ns.WindowManager.PRIORITY.FLOATING)
    anchor:SetClampedToScreen(true)
    anchor:SetScript("OnUpdate", AnchorOnUpdate)
    self.anchor = anchor
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
    if self._scalePreview then
        self:ClearScalePreview()
    end
    self._positionEdit = true
    self:EnsureAnchor()
    local anchor = self.anchor
    ReleaseAllEntries(self)
    ns.WindowManager:ApplyStrata(anchor, ns.WindowManager.PRIORITY.POPUP)
    anchor:SetMovable(true)
    anchor:EnableMouse(true)
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
    self._editPreviewEntry = PushPreviewEntry(self)
    EnsureEditGuard(self):Show()
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
    end
    if anchor then
        anchor:SetMovable(false)
        ns.WindowManager:ApplyStrata(anchor, ns.WindowManager.PRIORITY.FLOATING)
        self:ApplyOverlayMouse()
        self:ApplyAnchor()
    end
    ReleaseAllEntries(self)
    SetEditHintVisible(self, false)
    self._positionEdit = false
    self:LayoutStack()
    if self._editGuard and self._editGuard:IsShown() then
        self._editGuard:Hide()
    end
    self._editClosing = false
    if ns.RefreshAddonSettings then
        ns.RefreshAddonSettings()
    end
end

function SessionLootOverlayUI:SavePositionEdit()
    if not self._positionEdit then
        return
    end
    self:EndPositionEdit(true)
    local addon = ns.ArtisanNexus
    if addon and addon.Print then
        addon:Print((L and L["OVERLAY_MOVE_DONE"]) or "Loot overlay position saved.")
    end
end

function SessionLootOverlayUI:TogglePositionEdit()
    if self._positionEdit then
        self:SavePositionEdit()
        return false
    end
    return self:BeginPositionEdit()
end

-- ── Stack ──

--- Target slots (newest on top) + anchor size; the anchor OnUpdate moves toasts to them.
function SessionLootOverlayUI:LayoutStack()
    local anchor = self.anchor
    if not anchor then
        return
    end
    local n = #self._active
    local w, h = ToastWidth(), ToastHeight()
    if n < 1 then
        anchor:SetSize(w, h)
        anchor:Hide()
        return
    end
    local step = StackStep()
    anchor:SetSize(w, n * h + (n - 1) * ToastPx(ALERT_GAP))
    for i = 1, n do
        local entry = self._active[i]
        entry.targetY = (i - 1) * step
        if entry.y == nil then
            entry.y = entry.targetY
        end
    end
    anchor:Show()
    AnchorOnUpdate(anchor, 0)
end

--- Begin the WN fade-out on one toast (click dismiss).
function SessionLootOverlayUI:DismissEntry(entry)
    if not entry or entry.closingAt or entry.keep then
        return
    end
    entry.closingAt = GetTime()
    if entry.toast then
        entry.toast:EnableMouse(false)
    end
end

function SessionLootOverlayUI:PushToast(event)
    if not event or not event.itemID then
        return
    end
    self:EnsureAnchor()
    local stackMax = GetStackMax()
    while #self._active >= stackMax do
        local old = table.remove(self._active)
        if old then
            ReleaseToast(old.toast)
        end
    end
    local toast = AcquireToast(self.anchor)
    local entry = { toast = toast, born = GetTime(), rt = event.rt or GetTime() }
    toast._anEntry = entry
    PaintToast(toast, event)
    table.insert(self._active, 1, entry)
    self:LayoutStack()
end

function SessionLootOverlayUI:ClearToasts()
    if self._positionEdit then
        return
    end
    if self._scalePreview then
        self:ClearScalePreview()
        return
    end
    ReleaseAllEntries(self)
    if self.anchor then
        self.anchor:Hide()
    end
end

function SessionLootOverlayUI:OnLootUpdated()
    if not IsOverlayEnabled() or self._positionEdit then
        return
    end
    if self._scalePreview then
        self:ClearScalePreview()
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
    --- Every event since the last flush (oldest first), not only the newest cluster: a burst
    --- longer than one cluster otherwise loses its older pickups.
    local batch = {}
    for i = #events, 1, -1 do
        local e = events[i]
        local rt = e and e.rt
        if rt and rt > self._lastShownRt then
            batch[#batch + 1] = e
        end
    end
    for i = 1, #batch do
        self:PushToast(batch[i])
    end
    if #batch > 0 then
        self._lastShownRt = newestRt
    end
end

--- Theme / font / scale change: re-layout and repaint every live toast.
function SessionLootOverlayUI:RefreshTheme()
    for i = 1, #self._pool do
        LayoutToast(self._pool[i])
    end
    for i = 1, #self._active do
        local toast = self._active[i].toast
        if toast then
            LayoutToast(toast)
            if toast._anLastEvent then
                PaintToast(toast, toast._anLastEvent)
            end
        end
    end
    if self._editHint and self._editHint:IsShown() then
        SetEditHintVisible(self, true)
    end
    self:LayoutStack()
end

function SessionLootOverlayUI:Hide()
    if self._positionEdit then
        self:EndPositionEdit(true)
    end
    if self._scalePreview then
        self:ClearScalePreview()
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
    if ns.RefreshAddonSettings then
        ns.RefreshAddonSettings()
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
    if ns.RefreshAddonSettings then
        ns.RefreshAddonSettings()
    end
    return true
end

local function ScheduleLootPulse()
    if not (C_Timer and C_Timer.After) then
        SessionLootOverlayUI:OnLootUpdated()
        return
    end
    --- Fixed flush 0.06 s after the first event of a burst (not restarted per event), so a
    --- long burst flushes every 0.06 s and each flush takes all events since the previous one.
    if SessionLootOverlayUI._lootPulsePending then
        return
    end
    SessionLootOverlayUI._lootPulsePending = true
    C_Timer.After(0.06, function()
        SessionLootOverlayUI._lootPulsePending = false
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

    owner:RegisterMessage(E.SESSION_LOOT_UPDATED, onLoot)
    owner:RegisterMessage(E.LOOT_HISTORY_UPDATED, onLoot)
    owner:RegisterMessage(E.AH_PRICES_UPDATED, function()
        if not IsOverlayEnabled() then
            return
        end
        for i = 1, #SessionLootOverlayUI._active do
            local toast = SessionLootOverlayUI._active[i].toast
            if toast and toast._anLastEvent then
                PaintToast(toast, toast._anLastEvent)
            end
        end
    end)
    owner:RegisterMessage(E.THEME_CHANGED, function()
        SessionLootOverlayUI:RefreshTheme()
    end)
    owner:RegisterMessage(E.FONT_CHANGED, function()
        SessionLootOverlayUI:RefreshTheme()
    end)
end

--- Settings / profile change: re-read the saved anchor.
function SessionLootOverlayUI:ApplySettingsAnchor()
    EnsureInitialized()
    self:ApplyAnchor()
    self:LayoutStack()
end

--- Settings overlay size slider: re-layout pooled + active toasts.
function SessionLootOverlayUI:ApplySettingsScale()
    EnsureInitialized()
    self:RefreshTheme()
end

--- Real-time preview toast while dragging the settings scale slider.
function SessionLootOverlayUI:TriggerScalePreview()
    EnsureInitialized()
    if self._positionEdit then
        self:ApplySettingsScale()
        return
    end
    self:EnsureAnchor()
    local anchor = self.anchor
    ns.WindowManager:ApplyStrata(anchor, ns.WindowManager.PRIORITY.POPUP)
    if not self._scalePreviewEntry then
        ReleaseAllEntries(self)
        self._scalePreviewEntry = PushPreviewEntry(self)
    end
    self._scalePreview = true
    self:ApplySettingsScale()

    self._scalePreviewSeq = (self._scalePreviewSeq or 0) + 1
    local seq = self._scalePreviewSeq
    if C_Timer and C_Timer.After then
        C_Timer.After(SCALE_PREVIEW_SEC, function()
            if SessionLootOverlayUI._scalePreviewSeq ~= seq then
                return
            end
            SessionLootOverlayUI:ClearScalePreview()
        end)
    end
end

function SessionLootOverlayUI:ClearScalePreview()
    if not self._scalePreview then
        return
    end
    self._scalePreview = false
    self._scalePreviewSeq = (self._scalePreviewSeq or 0) + 1
    ReleaseAllEntries(self)
    if self.anchor then
        ns.WindowManager:ApplyStrata(self.anchor, ns.WindowManager.PRIORITY.FLOATING)
        self.anchor:Hide()
    end
end

ns.SessionLootOverlayUI = SessionLootOverlayUI
