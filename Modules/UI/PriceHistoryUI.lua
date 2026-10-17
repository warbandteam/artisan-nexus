--[[
    Artisan Nexus — Price History popup + sparkline.

    Public API:
      PriceHistoryUI:CreateSparkline(parent, width, height) -> Frame
        :Update(itemID, windowSec)
        :Clear()

      PriceHistoryUI:ShowPopup(itemID, anchor, anchorPoint?, relativePoint?, xOfs?, yOfs?)
        Small popup with the 7-day sparkline + stats for an item (Hub Crafting detail
        "Price history" button). PriceHistoryUI:HidePopup() closes it.

    Popup = Warband Nexus external window (WindowFactory.lua CreateExternalWindow, as
    GoldManagementPopup.lua:91 / MailDetailsPopup.lua:559 use it): title band, close button,
    ESC + combat hide (WindowManager POPUP tier), click outside closes, body below the band.
    Built once (persistent shell) and re-anchored beside the opener on every show.

    Chart: the viewport surface of the WN floating windows (ns.ArtisanWindow.ApplyViewportShellChrome)
    with accent bars and a step line drawn from plain textures (no LibGraph dependency).
]]

local ADDON_NAME, ns = ...
-- Pixel-perfect frames (SharedWidgets_Pixel: SetPoint/SetSize snap to whole physical pixels).
local CreateFrame = function(...) return (ns.UI_CreateFrame or _G.CreateFrame)(...) end

local PriceHistoryUI = {}
local POPUP_FRAME = nil
--- Last ShowPopup args so a theme change can repaint the visible popup in place.
local LAST_ITEMID, LAST_ANCHOR, LAST_POINT, LAST_REL, LAST_X, LAST_Y = nil, nil, nil, nil, nil, nil

local WEEK = 7 * 24 * 3600

-- Popup geometry (MailDetailsPopup.lua LAYOUT pattern: one pad, body stacked top-down).
local POPUP_W = 360
local PAD = 12
local ITEM_ROW_H = 24
local ITEM_ICON = 22
local BLOCK_GAP = 8
local CHART_H = 104
-- Sparkline insets: stats line on top, min label at the bottom, plot area between.
local SPARK_PAD = 6
local SPARK_TOP = 20
local SPARK_BOTTOM = 18
local LINE_W = 2

local function L(key, fallback)
    return (ns.L and ns.L[key]) or fallback
end

local function COLORS()
    return ns.UI_COLORS or { accent = { 0.5, 0.4, 0.7 }, accentDark = { 0.25, 0.2, 0.35 } }
end

--- WN text-role / semantic inline colors (RecipeCompanionWindow.lua TextRoleHex pattern).
local function RoleHex(role)
    local raw = (ns.UI_GetTextRoleHexRaw and ns.UI_GetTextRoleHexRaw(role)) or "ffffff"
    return "|cff" .. raw
end

local function GreenHex()
    return (ns.UI_GetSemanticGreenHex and ns.UI_GetSemanticGreenHex()) or "|cff44ff44"
end

local function RedHex()
    if ns.UI_GetSemanticRedColor then
        local r, g, b = ns.UI_GetSemanticRedColor()
        return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
    end
    return "|cffff6666"
end

--- Shared money formatter (Modules/Utilities.lua); "-" for missing values.
local function FormatCopper(c)
    return ns.FormatCopper(c) or "-"
end

local ItemName = ns.GetItemDisplayName
local ItemIcon = ns.GetItemIconFileID

--- Chart surface: WN floating-window viewport shell (panel fill + card border).
local function SkinSparkline(f)
    local W = ns.ArtisanWindow
    if W and W.ApplyViewportShellChrome then
        W.ApplyViewportShellChrome(f)
    end
    ns.UI_SetTextColorRole(f._title, "Normal")
    ns.UI_SetTextColorRole(f._lo, "Muted")
    ns.UI_SetTextColorRole(f._hi, "Muted")
end

local function HideAll(list)
    for i = 1, #list do list[i]:Hide() end
end

local function AcquireTexture(f, list, i, layer)
    local tex = list[i]
    if not tex then
        tex = f:CreateTexture(nil, layer)
        list[i] = tex
    end
    tex:ClearAllPoints()
    return tex
end

--- Build a reusable sparkline frame.
function PriceHistoryUI:CreateSparkline(parent, width, height)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width or 240, height or 72)
    f._lines = {}
    f._bars = {}

    local FontManager = ns.FontManager
    local title = FontManager:CreateFontString(f, "small", "OVERLAY")
    title:SetPoint("TOPLEFT", SPARK_PAD, -SPARK_PAD + 1)
    title:SetPoint("RIGHT", f, "RIGHT", -SPARK_PAD, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    f._title = title

    local lo = FontManager:CreateFontString(f, "small", "OVERLAY")
    lo:SetPoint("BOTTOMLEFT", SPARK_PAD, SPARK_PAD - 2)
    lo:SetJustifyH("LEFT")
    f._lo = lo

    local hi = FontManager:CreateFontString(f, "small", "OVERLAY")
    hi:SetPoint("BOTTOMRIGHT", -SPARK_PAD, SPARK_PAD - 2)
    hi:SetJustifyH("RIGHT")
    f._hi = hi
    SkinSparkline(f)

    f.Update = function(self, itemID, windowSec)
        -- Re-resolve chrome per render: embedded instances can outlive a theme toggle.
        SkinSparkline(self)
        HideAll(self._lines)
        HideAll(self._bars)
        local svc = ns.PriceHistoryService
        local samples = svc and svc:GetSamples(itemID) or {}
        local stats = svc and svc:GetStats(itemID, windowSec) or { count = 0 }
        if not samples or #samples < 2 or stats.count < 2 then
            ns.UI_SetTextColorRole(self._title, "Muted")
            self._title:SetText(L("PRICE_HISTORY_NO_HISTORY", "No price history yet."))
            self._lo:SetText("")
            self._hi:SetText("")
            return
        end

        -- Filter to window
        local cutoff = time() - (windowSec or WEEK)
        local pts = {}
        for si = 1, #samples do
            local s = samples[si]
            if s.t and s.t >= cutoff and s.p and s.p > 0 then pts[#pts + 1] = s end
        end
        if #pts < 2 then
            ns.UI_SetTextColorRole(self._title, "Muted")
            self._title:SetText(L("PRICE_HISTORY_NOT_ENOUGH", "Not enough data in the last 7 days."))
            self._lo:SetText("")
            self._hi:SetText("")
            return
        end

        local w = self:GetWidth() - SPARK_PAD * 2
        local h = self:GetHeight() - SPARK_TOP - SPARK_BOTTOM
        local x0, y0 = SPARK_PAD, SPARK_BOTTOM

        local mn = stats.min or pts[1].p
        local mx = stats.max or pts[#pts].p
        local pad = math.max(1, math.floor((mx - mn) * 0.05))
        mn = math.max(0, mn - pad); mx = mx + pad
        local span = math.max(1, mx - mn)

        local tMin = pts[1].t
        local tSpan = math.max(1, pts[#pts].t - tMin)

        local function XAt(i) return x0 + ((pts[i].t - tMin) / tSpan) * w end
        local function YAt(i) return y0 + ((pts[i].p - mn) / span) * h end

        local ac = COLORS().accent
        -- Sample columns: accent wash under every point.
        for i = 1, #pts do
            local bar = AcquireTexture(self, self._bars, i, "BACKGROUND")
            bar:SetDrawLayer("BACKGROUND", 2)
            bar:SetColorTexture(ac[1], ac[2], ac[3], 0.25)
            local y = YAt(i)
            bar:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", XAt(i) - 1, y0)
            bar:SetSize(2, math.max(2, y - y0))
            bar:Show()
        end

        -- Step line: horizontal run at the previous price, vertical riser at the next sample.
        local n = 0
        local function Segment(x, y, sw, sh)
            n = n + 1
            local seg = AcquireTexture(self, self._lines, n, "ARTWORK")
            seg:SetColorTexture(ac[1], ac[2], ac[3], 0.95)
            seg:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x, y)
            seg:SetSize(math.max(LINE_W, sw), math.max(LINE_W, sh))
            seg:Show()
        end
        for i = 1, #pts - 1 do
            local x1, y1 = XAt(i), YAt(i)
            local x2, y2 = XAt(i + 1), YAt(i + 1)
            Segment(x1, y1 - LINE_W / 2, x2 - x1, LINE_W)
            if math.abs(y2 - y1) >= 1 then
                Segment(x2 - LINE_W / 2, math.min(y1, y2) - LINE_W / 2, LINE_W, math.abs(y2 - y1) + LINE_W)
            end
        end

        local trend, pct = svc:GetTrend(itemID, windowSec)
        local arrow = (trend > 0 and (GreenHex() .. "▲|r"))
            or (trend < 0 and (RedHex() .. "▼|r"))
            or (RoleHex("Dim") .. "•|r")
        ns.UI_SetTextColorRole(self._title, "Normal")
        self._title:SetText(string.format(
            L("PRICE_HISTORY_TITLE_FMT", "%s avg %s - last %s - %s%+.1f%%"),
            arrow,
            FormatCopper(stats.avg),
            FormatCopper(stats.latest),
            ((pct or 0) >= 0) and GreenHex() or RedHex(),
            pct or 0) .. "|r")
        self._lo:SetText(string.format(L("PRICE_HISTORY_MIN_FMT", "min %s"), FormatCopper(stats.min)))
        self._hi:SetText(string.format(L("PRICE_HISTORY_MAX_FMT", "max %s"), FormatCopper(stats.max)))
    end

    f.Clear = function(self)
        HideAll(self._lines)
        HideAll(self._bars)
        self._title:SetText("")
        self._lo:SetText("")
        self._hi:SetText("")
    end

    return f
end

--- External-window shell (WindowFactory CreateExternalWindow, persistent) + body.
local function BuildPopup()
    local create = ns.UI_CreateExternalWindow
    if not create then return nil end
    local chartW = POPUP_W - PAD * 2
    local headerH = (ns.UI_LAYOUT and ns.UI_LAYOUT.MAIN_SHELL and ns.UI_LAYOUT.MAIN_SHELL.HEADER_BAR_HEIGHT) or 40
    local height = headerH + PAD + ITEM_ROW_H + BLOCK_GAP + CHART_H + PAD
    local dialog, content = create({
        name = "PriceHistoryPopup",
        title = L("PRICE_HISTORY_POPUP_TITLE", "Price history"),
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        width = POPUP_W,
        height = height,
        preventDuplicates = false,
        persistent = true,
    })
    if not dialog or not content then return nil end

    local FontManager = ns.FontManager
    -- Item row: icon + name (MailDetailsPopup item rows: icon well + body text).
    local iconFrame = ns.UI_CreateIcon(content, 134400, ITEM_ICON, false, nil, false)
    iconFrame:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -PAD - (ITEM_ROW_H - ITEM_ICON) / 2)
    iconFrame:Show()
    dialog._anIcon = iconFrame

    local name = FontManager:CreateFontString(content, "title", "OVERLAY")
    name:SetPoint("LEFT", iconFrame, "RIGHT", BLOCK_GAP, 0)
    -- Long localized item names truncate inside the popup.
    name:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    name:SetMaxLines(1)
    ns.UI_SetTextColorRole(name, "Bright")
    dialog._anName = name

    local spark = PriceHistoryUI:CreateSparkline(content, chartW, CHART_H)
    spark:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -(PAD + ITEM_ROW_H + BLOCK_GAP))
    dialog._anSpark = spark
    return dialog
end

local function SetItemIcon(iconFrame, itemID)
    local tex = iconFrame and (iconFrame.texture or iconFrame.icon or iconFrame.Icon)
    if tex and tex.SetTexture then
        tex:SetTexture(ItemIcon(itemID))
    end
end

function PriceHistoryUI:ShowPopup(itemID, anchor, anchorPoint, relativePoint, xOfs, yOfs)
    LAST_ITEMID, LAST_ANCHOR, LAST_POINT = itemID, anchor, anchorPoint
    LAST_REL, LAST_X, LAST_Y = relativePoint, xOfs, yOfs
    if not POPUP_FRAME then POPUP_FRAME = BuildPopup() end
    if not POPUP_FRAME then return end
    POPUP_FRAME:ClearAllPoints()
    if GameTooltip and GameTooltip:IsShown() and GameTooltip:GetOwner() == anchor then
        POPUP_FRAME:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, -4)
    elseif anchor then
        POPUP_FRAME:SetPoint(anchorPoint or "TOPLEFT", anchor, relativePoint or "TOPRIGHT", xOfs or 8, yOfs or 0)
    else
        POPUP_FRAME:SetPoint("CENTER")
    end
    SetItemIcon(POPUP_FRAME._anIcon, itemID)
    POPUP_FRAME._anName:SetText(ItemName(itemID))
    POPUP_FRAME._anSpark:Update(itemID, WEEK)
    POPUP_FRAME:Show()
    if POPUP_FRAME.Raise then POPUP_FRAME:Raise() end
end

function PriceHistoryUI:HidePopup()
    if POPUP_FRAME and POPUP_FRAME:IsShown() then
        if POPUP_FRAME.Close then
            POPUP_FRAME.Close()
        else
            POPUP_FRAME:Hide()
        end
    end
end

--- Theme change: re-skin the kept shell in place (WindowFactory RefreshExternalWindowChrome).
function PriceHistoryUI:ResetForTheme()
    if not POPUP_FRAME then return end
    if ns.UI_RefreshExternalWindowChrome then
        ns.UI_RefreshExternalWindowChrome(POPUP_FRAME)
    end
    ns.UI_SetTextColorRole(POPUP_FRAME._anName, "Bright")
    SkinSparkline(POPUP_FRAME._anSpark)
end

--- Theme / font change: repaint the cached popup; a visible one re-renders with the same
--- item and the full anchor (point, relativePoint, offsets).
do
    local E = ns.Constants.EVENTS
    if E and ns.NewEventOwner then
        local owner = ns.NewEventOwner("PriceHistoryUI")
        PriceHistoryUI._eventOwner = owner
        local function Repaint()
            PriceHistoryUI:ResetForTheme()
            if POPUP_FRAME and POPUP_FRAME:IsShown() and LAST_ITEMID then
                PriceHistoryUI:ShowPopup(LAST_ITEMID, LAST_ANCHOR, LAST_POINT, LAST_REL, LAST_X, LAST_Y)
            end
        end
        if E.THEME_CHANGED then owner:RegisterMessage(E.THEME_CHANGED, Repaint) end
        if E.FONT_CHANGED then owner:RegisterMessage(E.FONT_CHANGED, Repaint) end
    end
end

ns.PriceHistoryUI = PriceHistoryUI
