--[[
    Artisan Nexus — Price History sparkline.

    Public API:
      PriceHistoryUI:CreateSparkline(parent, width, height) -> Frame
        :Update(itemID, windowSec)
        :Clear()

      PriceHistoryUI:ShowPopup(itemID, anchor, anchorPoint?)
        Toggle a small floating window with the sparkline + stats for an
        item. Used by Hub rows and the AH sync button on right-click.

    Sparkline rendering: bars drawn as 1px-wide texture columns under the
    sample line; the sample line itself is a series of thin diagonal
    textures connecting consecutive points. Cheap (no LibGraph dependency).
]]

local ADDON_NAME, ns = ...

local L = ns.L

local PriceHistoryUI = {}
local POPUP_FRAME = nil
--- Last ShowPopup args so a theme-change rebuild can restore the popup in place.
local LAST_ITEMID, LAST_ANCHOR, LAST_POINT = nil, nil, nil

--- Live palette — resolve at call time (UI_RefreshColors swaps sub-tables).
local function C()
    return ns.UI_COLORS or {}
end

local function Font(role)
    local f = ns.UI_FONTS
    if f and role and f[role] then
        return f[role]
    end
    return (f and f.WINDOW_BODY) or "GameFontNormal"
end

--- Skin-branching surface styler: classic tooltip-border inset vs modern pixel
--- chrome. Bare UI_ApplyVisuals is a NO-OP in Classic — this popup used to
--- render as floating bars over nothing there.
local function Apply(frame, bg, border)
    if ns.UI_StylePanelInset then
        ns.UI_StylePanelInset(frame, bg, border)
    elseif ns.UI_ApplyVisuals then
        ns.UI_ApplyVisuals(frame, bg, border)
    elseif frame.SetBackdrop then
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
        frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    end
end

--- Semantic hex from the live palette (trend arrows / % tint).
local function HexRole(text, kind)
    local hex = ns.UI_GetSemanticHex and ns.UI_GetSemanticHex(kind)
    if not hex then
        return text
    end
    return "|cff" .. hex .. text .. "|r"
end

--- Shared helpers (Modules/Utilities.lua; loads before this file per TOC).
--- This UI shows "-" for missing values, so wrap the nil-returning shared formatter.
local function FormatCopper(c)
    return ns.FormatCopper(c) or "-"
end

local ItemName = ns.GetItemDisplayName
local ItemIcon = ns.GetItemIconFileID

--- Build a reusable sparkline frame.
function PriceHistoryUI:CreateSparkline(parent, width, height)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width or 240, height or 72)
    local rowBg = C().rowBg or { 0.05, 0.05, 0.07, 0.85 }
    local grid = C().sparkGrid or { 0.30, 0.26, 0.36, 1 }
    Apply(f, { rowBg[1], rowBg[2], rowBg[3], 0.95 }, { grid[1], grid[2], grid[3], 0.85 })
    f._lines = {}
    f._bars = {}
    f._labels = {}

    local title = f:CreateFontString(nil, "OVERLAY", Font("WINDOW_BODY"))
    title:SetPoint("TOPLEFT", 6, -4)
    f._title = title

    local muted = C().textMuted or { 0.72, 0.69, 0.78, 1 }
    local lo = f:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    lo:SetPoint("BOTTOMLEFT", 6, 4)
    lo:SetTextColor(muted[1], muted[2], muted[3])
    f._lo = lo

    local hi = f:CreateFontString(nil, "OVERLAY", Font("WINDOW_META"))
    hi:SetPoint("TOPRIGHT", -6, -4)
    hi:SetTextColor(muted[1], muted[2], muted[3])
    f._hi = hi

    f.Update = function(self, itemID, windowSec)
        --- Re-resolve surface/label chrome per render: embedded instances can
        --- outlive a theme toggle when their host window doesn't rebuild.
        local rowBg2 = C().rowBg or { 0.05, 0.05, 0.07, 0.85 }
        local grid2 = C().sparkGrid or { 0.30, 0.26, 0.36, 1 }
        Apply(self, { rowBg2[1], rowBg2[2], rowBg2[3], 0.95 }, { grid2[1], grid2[2], grid2[3], 0.85 })
        local muted2 = C().textMuted or { 0.72, 0.69, 0.78, 1 }
        self._lo:SetTextColor(muted2[1], muted2[2], muted2[3])
        self._hi:SetTextColor(muted2[1], muted2[2], muted2[3])
        local lines = self._lines
        for i = 1, #lines do lines[i]:Hide() end
        local bars = self._bars
        for i = 1, #bars do bars[i]:Hide() end
        local svc = ns.PriceHistoryService
        local samples = svc and svc:GetSamples(itemID) or {}
        local stats = svc and svc:GetStats(itemID, windowSec) or { count = 0 }
        if not samples or #samples < 2 or stats.count < 2 then
            self._title:SetText((L and L["PRICE_HISTORY_NO_HISTORY"]) or "|cff888888no history|r")
            self._lo:SetText("")
            self._hi:SetText("")
            return
        end

        local w = self:GetWidth() - 12
        local h = self:GetHeight() - 32
        local x0, y0 = 6, 18

        local mn = stats.min or samples[1].p
        local mx = stats.max or samples[#samples].p
        local pad = math.max(1, math.floor((mx - mn) * 0.05))
        mn = math.max(0, mn - pad); mx = mx + pad
        local span = math.max(1, mx - mn)

        -- Filter to window
        local cutoff = time() - (windowSec or (7 * 24 * 3600))
        local pts = {}
        for si = 1, #samples do
            local s = samples[si]
            if s.t and s.t >= cutoff and s.p and s.p > 0 then pts[#pts + 1] = s end
        end
        if #pts < 2 then
            self._title:SetText((L and L["PRICE_HISTORY_NOT_ENOUGH"]) or "|cff888888not enough data|r")
            self._lo:SetText(""); self._hi:SetText("")
            return
        end

        local tMin = pts[1].t
        local tMax = pts[#pts].t
        local tSpan = math.max(1, tMax - tMin)

        local function XAt(i) return x0 + ((pts[i].t - tMin) / tSpan) * w end
        local function YAt(i) return y0 + ((pts[i].p - mn) / span) * h end

        -- Draw bars (subtle backdrop columns); color per render — theme may change
        local barCol = C().sparkBar or { 0.30, 0.26, 0.36, 1 }
        for i = 1, #pts do
            local bar = self._bars[i]
            if not bar then
                bar = self:CreateTexture(nil, "BACKGROUND")
                self._bars[i] = bar
            end
            bar:SetColorTexture(barCol[1], barCol[2], barCol[3], 0.25)
            local x = XAt(i)
            local y = YAt(i)
            bar:SetPoint("BOTTOMLEFT", x - 1, y0)
            bar:SetSize(2, math.max(2, y - y0))
            bar:Show()
        end

        -- Draw line as connected segments (thin diagonal textures)
        local lineCol = C().sparkLine or { 0.85, 0.65, 1.0, 1 }
        for i = 1, #pts - 1 do
            local seg = self._lines[i]
            if not seg then
                seg = self:CreateTexture(nil, "ARTWORK")
                self._lines[i] = seg
            end
            local x1, y1 = XAt(i), YAt(i)
            local x2, y2 = XAt(i + 1), YAt(i + 1)
            local dx, dy = x2 - x1, y2 - y1
            local len = math.max(1, math.sqrt(dx * dx + dy * dy))
            -- Approximate the segment as a thick textured bar; rotation isn't
            -- worth the cost for a 60-sample chart, so we tile horizontally.
            seg:ClearAllPoints()
            seg:SetPoint("BOTTOMLEFT", math.min(x1, x2), math.min(y1, y2))
            seg:SetSize(math.max(1, math.abs(dx)), math.max(2, math.abs(dy) + 2))
            seg:SetColorTexture(lineCol[1], lineCol[2], lineCol[3], 0.85)
            seg:Show()
        end

        local trend, pct = svc:GetTrend(itemID, windowSec)
        local arrow = (trend > 0 and HexRole("▲", "success"))
            or (trend < 0 and HexRole("▼", "danger"))
            or HexRole("•", "dim")
        local pctHex = ns.UI_GetSemanticHex
            and ("|cff" .. ns.UI_GetSemanticHex((pct >= 0) and "success" or "danger"))
            or ((pct >= 0) and "|cff66ff66" or "|cffff6666")
        self._title:SetText(string.format(
            (L and L["PRICE_HISTORY_TITLE_FMT"]) or "%s avg %s - last %s - %s%+.1f%%",
            arrow,
            FormatCopper(stats.avg),
            FormatCopper(stats.latest),
            pctHex,
            pct or 0))
        self._lo:SetText(string.format((L and L["PRICE_HISTORY_MIN_FMT"]) or "min %s", FormatCopper(stats.min)))
        self._hi:SetText(string.format((L and L["PRICE_HISTORY_MAX_FMT"]) or "max %s", FormatCopper(stats.max)))
    end

    f.Clear = function(self)
        local lines = self._lines
        for i = 1, #lines do lines[i]:Hide() end
        local bars = self._bars
        for i = 1, #bars do bars[i]:Hide() end
        self._title:SetText("")
        self._lo:SetText("")
        self._hi:SetText("")
    end

    return f
end

local function BuildPopup()
    local f = CreateFrame("Frame", "ArtisanNexusPriceHistoryPopup", UIParent, "BackdropTemplate")
    f:SetSize(336, 132)
    --- Hover-detail popup over DIALOG-strata craft windows; TOOLTIP is
    --- reserved (rule ceiling: FULLSCREEN_DIALOG for addon popups).
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetClampedToScreen(true)
    f:Hide()
    local bg = C().bg or { 0.065, 0.062, 0.076, 0.97 }
    local ac = C().accent or { 0.44, 0.32, 0.58, 1 }
    Apply(f, { bg[1], bg[2], bg[3], 0.97 }, { ac[1], ac[2], ac[3], 0.9 })

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22); icon:SetPoint("TOPLEFT", 6, -6)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f._icon = icon

    local name = f:CreateFontString(nil, "OVERLAY", Font("WINDOW_SECTION"))
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    --- Bound to the popup edge: long localized item names must truncate, not
    --- overflow the 336px frame.
    name:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    name:SetMaxLines(1)
    local tb = C().textBright or { 0.96, 0.95, 0.97, 1 }
    name:SetTextColor(tb[1], tb[2], tb[3])
    f._name = name

    local spark = PriceHistoryUI:CreateSparkline(f, 320, 88)
    spark:SetPoint("BOTTOM", 0, 6)
    f._spark = spark
    return f
end

function PriceHistoryUI:ShowPopup(itemID, anchor, anchorPoint)
    LAST_ITEMID, LAST_ANCHOR, LAST_POINT = itemID, anchor, anchorPoint
    if not POPUP_FRAME then POPUP_FRAME = BuildPopup() end
    POPUP_FRAME:ClearAllPoints()
    if anchor then
        POPUP_FRAME:SetPoint(anchorPoint or "TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    else
        POPUP_FRAME:SetPoint("CENTER")
    end
    POPUP_FRAME._icon:SetTexture(ItemIcon(itemID))
    POPUP_FRAME._name:SetText(ItemName(itemID))
    POPUP_FRAME._spark:Update(itemID, 7 * 24 * 3600)
    POPUP_FRAME:Show()
end

function PriceHistoryUI:HidePopup()
    if POPUP_FRAME then POPUP_FRAME:Hide() end
end

--- UI-mode switch: drop the cached popup so the next ShowPopup rebuilds with
--- the active skin (called from ns.UI_ResetMainWindowsForUiMode).
function PriceHistoryUI:ResetForUiMode()
    if POPUP_FRAME then
        POPUP_FRAME:Hide()
        --- Popup + embedded sparkline carry ApplyVisuals chrome — leave
        --- BORDER_REGISTRY before discarding (theme rebuild path included).
        if ns.UI_UnregisterVisuals then
            ns.UI_UnregisterVisuals(POPUP_FRAME)
        end
        POPUP_FRAME = nil
    end
end

--- Theme change: colors are baked at build time, so drop the cached popup.
--- If it was visible, rebuild immediately with the same item + anchor.
do
    local E = ns.Constants and ns.Constants.EVENTS
    if E and E.THEME_CHANGED and ns.NewEventOwner then
        local owner = ns.NewEventOwner("PriceHistoryUI")
        PriceHistoryUI._eventOwner = owner
        owner:RegisterMessage(E.THEME_CHANGED, function()
            local wasShown = POPUP_FRAME and POPUP_FRAME:IsShown()
            PriceHistoryUI:ResetForUiMode()
            if wasShown and LAST_ITEMID then
                PriceHistoryUI:ShowPopup(LAST_ITEMID, LAST_ANCHOR, LAST_POINT)
            end
        end)
    end
end

ns.PriceHistoryUI = PriceHistoryUI
