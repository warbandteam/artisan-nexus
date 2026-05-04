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

local PriceHistoryUI = {}
local POPUP_FRAME = nil

local function Apply(frame, bg, border)
    if ns.UI_ApplyVisuals then ns.UI_ApplyVisuals(frame, bg, border)
    elseif frame.SetBackdrop then
        frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
        frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    end
end

local function FormatCopper(c)
    if not c or c <= 0 then return "-" end
    local g = math.floor(c / 10000)
    local s = math.floor((c / 100) % 100)
    local cu = c % 100
    if g > 0 then return string.format("%dg %ds", g, s) end
    if s > 0 then return string.format("%ds %dc", s, cu) end
    return string.format("%dc", cu)
end

local function ItemName(itemID)
    if not itemID then return "?" end
    return (GetItemInfo and GetItemInfo(itemID)) or ("item:" .. itemID)
end

local function ItemIcon(itemID)
    if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(itemID) end
    return select(10, GetItemInfo(itemID)) or 134400
end

--- Build a reusable sparkline frame.
function PriceHistoryUI:CreateSparkline(parent, width, height)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(width or 240, height or 72)
    Apply(f, {0.05, 0.05, 0.07, 0.95}, {0.30, 0.26, 0.36, 0.85})
    f._lines = {}
    f._bars = {}
    f._labels = {}

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 6, -4)
    f._title = title

    local lo = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lo:SetPoint("BOTTOMLEFT", 6, 4)
    lo:SetTextColor(0.7, 0.7, 0.75)
    f._lo = lo

    local hi = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hi:SetPoint("TOPRIGHT", -6, -4)
    hi:SetTextColor(0.7, 0.7, 0.75)
    f._hi = hi

    f.Update = function(self, itemID, windowSec)
        for _, t in ipairs(self._lines) do t:Hide() end
        for _, t in ipairs(self._bars)  do t:Hide() end
        local svc = ns.PriceHistoryService
        local samples = svc and svc:GetSamples(itemID) or {}
        local stats = svc and svc:GetStats(itemID, windowSec) or { count = 0 }
        if not samples or #samples < 2 or stats.count < 2 then
            self._title:SetText("|cff888888no history|r")
            self._lo:SetText("")
            self._hi:SetText("")
            return
        end

        local w = self:GetWidth() - 12
        local h = self:GetHeight() - 28
        local x0, y0 = 6, 16

        local mn = stats.min or samples[1].p
        local mx = stats.max or samples[#samples].p
        local pad = math.max(1, math.floor((mx - mn) * 0.05))
        mn = math.max(0, mn - pad); mx = mx + pad
        local span = math.max(1, mx - mn)

        -- Filter to window
        local cutoff = time() - (windowSec or (7 * 24 * 3600))
        local pts = {}
        for _, s in ipairs(samples) do
            if s.t and s.t >= cutoff and s.p and s.p > 0 then pts[#pts + 1] = s end
        end
        if #pts < 2 then
            self._title:SetText("|cff888888not enough data|r")
            self._lo:SetText(""); self._hi:SetText("")
            return
        end

        local tMin = pts[1].t
        local tMax = pts[#pts].t
        local tSpan = math.max(1, tMax - tMin)

        local function XAt(i) return x0 + ((pts[i].t - tMin) / tSpan) * w end
        local function YAt(i) return y0 + ((pts[i].p - mn) / span) * h end

        -- Draw bars (subtle backdrop columns)
        for i = 1, #pts do
            local bar = self._bars[i]
            if not bar then
                bar = self:CreateTexture(nil, "BACKGROUND")
                bar:SetColorTexture(0.30, 0.26, 0.36, 0.25)
                self._bars[i] = bar
            end
            local x = XAt(i)
            local y = YAt(i)
            bar:SetPoint("BOTTOMLEFT", x - 1, y0)
            bar:SetSize(2, math.max(2, y - y0))
            bar:Show()
        end

        -- Draw line as connected segments (thin diagonal textures)
        for i = 1, #pts - 1 do
            local seg = self._lines[i]
            if not seg then
                seg = self:CreateTexture(nil, "ARTWORK")
                seg:SetColorTexture(0.85, 0.65, 1.0, 1)
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
            seg:SetColorTexture(0.85, 0.65, 1.0, 0.85)
            seg:Show()
        end

        local trend, pct = svc:GetTrend(itemID, windowSec)
        local arrow = (trend > 0 and "|cff66ff66▲|r") or (trend < 0 and "|cffff6666▼|r") or "|cffaaaaaa•|r"
        self._title:SetText(string.format("%s avg %s · last %s · %s%+.1f%%",
            arrow,
            FormatCopper(stats.avg),
            FormatCopper(stats.latest),
            (pct >= 0) and "|cff66ff66" or "|cffff6666",
            pct or 0))
        self._lo:SetText("min " .. FormatCopper(stats.min))
        self._hi:SetText("max " .. FormatCopper(stats.max))
    end

    f.Clear = function(self)
        for _, t in ipairs(self._lines) do t:Hide() end
        for _, t in ipairs(self._bars)  do t:Hide() end
        self._title:SetText("")
        self._lo:SetText("")
        self._hi:SetText("")
    end

    return f
end

local function BuildPopup()
    local f = CreateFrame("Frame", "ArtisanNexusPriceHistoryPopup", UIParent, "BackdropTemplate")
    f:SetSize(320, 120)
    f:SetFrameStrata("TOOLTIP")
    f:SetClampedToScreen(true)
    f:Hide()
    Apply(f, {0.08, 0.08, 0.10, 0.97}, {0.52, 0.40, 0.66, 0.9})

    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20); icon:SetPoint("TOPLEFT", 6, -6)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f._icon = icon

    local name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetTextColor(1, 1, 1)
    f._name = name

    local spark = PriceHistoryUI:CreateSparkline(f, 304, 80)
    spark:SetPoint("BOTTOM", 0, 6)
    f._spark = spark
    return f
end

function PriceHistoryUI:ShowPopup(itemID, anchor, anchorPoint)
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

ns.PriceHistoryUI = PriceHistoryUI
