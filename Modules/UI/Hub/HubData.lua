--[[
    Artisan Nexus — Hub page data helpers (ns.HubUI_Internal, "H").

    Pure data / formatting helpers shared by the Artisan Hub tabs (Hub/Pages/*.lua). The window,
    rail, header and tab switching are the Warband Nexus main window (Modules/UI.lua +
    UI_MainShell.lua + UI_TabHost.lua); this file holds no UI.

      H.state.frame   the WN main window (ArtisanNexus.UI.mainFrame) once built; read live.

    Helpers: SafeL, SafeNumber, RecipeFallbackName, RecipeRowName, GetHubProfessionFilter,
    ProfessionListOpt, HubKnownBy, RecipeIconTexture, FormatDuration, ItemLink, HarvestNotice;
    ink + money text: InkRGB / InkHex / Ink / Dim (WN text roles + semantic colors), Money, Signed.
    The tab UI kit (body, toolbar, profession filter) is Hub/HubTabKit.lua.
]]

local ADDON_NAME, ns = ...

local H = {}
ns.HubUI_Internal = H

H.state = {
    frame = nil,
}

local function SafeL(key, fallback)
    if ns.SafeLocaleString then
        local s = ns.SafeLocaleString(key, fallback)
        if s and s ~= "" then
            return s
        end
    end
    return fallback
end

local function SafeNumber(val)
    if val == nil then
        return nil
    end
    if issecretvalue and issecretvalue(val) then
        return nil
    end
    return tonumber(val)
end

--- "Recipe 12345" for a recipe whose name is not known (yet).
local function RecipeFallbackName(spellID)
    return string.format(SafeL("RECIPE_ID_FMT", "Recipe %s"), tostring(spellID or "?"))
end

local function RecipeRowName(r)
    if not r then
        return "?"
    end
    local fallback = RecipeFallbackName(r.spellID)
    if ns.CoerceUiString then
        return ns.CoerceUiString(r.name, fallback)
    end
    if type(r.name) == "string" and r.name ~= "" and not (issecretvalue and issecretvalue(r.name)) then
        return r.name
    end
    return fallback
end

--- profile.hubProfessionFilter (shared by every page): profession name or "All".
local function GetHubProfessionFilter()
    local p = ns.db and ns.db.profile
    local f = p and p.hubProfessionFilter
    if type(f) == "string" and f ~= "" then
        return f
    end
    return "All"
end

--- "All" -> nil (service option shape), else the profession name.
local function ProfessionListOpt(filter)
    if not filter or filter == "All" then
        return nil
    end
    return filter
end

--- profile.hubKnownBy: "me" (current character) or "any" tracked character (default).
local function HubKnownBy()
    local p = ns.db and ns.db.profile
    return (p and p.hubKnownBy == "me") and "me" or "any"
end

--- Shared helper (Modules/Utilities.lua; loads before this file per TOC).
local ItemIcon = ns.GetItemIconFileID

--- Crafted item icon, else recipe spell UI icon (enchant / no-output recipes).
local function RecipeIconTexture(spellID, outputItemID)
    if outputItemID and outputItemID > 0 then
        local fid = ItemIcon(outputItemID)
        if type(fid) == "number" and fid > 0 then
            return fid
        end
    end
    if spellID and ns.RecipeService and ns.RecipeService.GetRecipeDisplayIconFileID then
        local fid = ns.RecipeService:GetRecipeDisplayIconFileID(spellID)
        if type(fid) == "number" and fid > 0 then
            return fid
        end
    end
    return 134400
end

-- ─────────────────────────────────────────────────────────────────
-- Ink: WN theme text roles + semantic colors as inline |cff markup (one helper for every tab,
-- the Hub tooltips and the AH scan tooltip).
-- ─────────────────────────────────────────────────────────────────

--- kind -> WN semantic getter. Both the color names and the status names are accepted.
local SEMANTIC_RGB = {
    green = "UI_GetSemanticGreenColor", success = "UI_GetSemanticGreenColor",
    red = "UI_GetSemanticRedColor", danger = "UI_GetSemanticRedColor",
    orange = "UI_GetSemanticOrangeColor", warning = "UI_GetSemanticOrangeColor",
    gold = "UI_GetSemanticGoldColor",
}
--- Lower-case aliases of the WN text roles (Bright / Normal / Muted / Dim).
local TEXT_ROLE = { bright = "Bright", normal = "Normal", muted = "Muted", dim = "Dim" }

--- r, g, b of an ink: green|success, red|danger, orange|warning, gold, accent, or a WN text role
--- (Bright / Normal / Muted / Dim, any case; default Normal).
local function InkRGB(kind)
    local getter = SEMANTIC_RGB[kind]
    if getter and ns[getter] then
        local r, g, b = ns[getter]()
        return r, g, b
    end
    if kind == "accent" then
        local a = ns.UI_COLORS and ns.UI_COLORS.accent or { 0.4, 0.2, 0.58 }
        return a[1], a[2], a[3]
    end
    local role = TEXT_ROLE[kind] or kind or "Normal"
    if ns.UI_GetTextRoleRGB then
        local r, g, b = ns.UI_GetTextRoleRGB(role)
        if r then
            return r, g, b
        end
    end
    return 0.85, 0.85, 0.85
end

local function Channel(v)
    return math.max(0, math.min(255, math.floor((tonumber(v) or 0) * 255 + 0.5)))
end

--- "rrggbb" of an ink (InkRGB kinds).
local function InkHex(kind)
    local r, g, b = InkRGB(kind)
    return string.format("%02x%02x%02x", Channel(r), Channel(g), Channel(b))
end

--- `text` wrapped in the ink (InkRGB kinds); nil / "" -> "".
local function Ink(text, kind)
    if text == nil or text == "" then
        return ""
    end
    return "|cff" .. InkHex(kind) .. tostring(text) .. "|r"
end

local function Dim(text)
    return Ink(text, "Dim")
end

--- Table-friendly precision: 100g+ shows gold only, 1g+ gold + silver, below that silver + copper
--- (rounded to the nearest shown coin) so money cells fit their column instead of truncating.
local function RoundForDisplay(c)
    local a = math.abs(c)
    local unit = (a >= 1000000 and 10000) or (a >= 10000 and 100) or 1
    a = math.floor(a / unit + 0.5) * unit
    return (c < 0) and -a or a
end

--- WN money text (ns.UI_FormatMoney coin icons); negative amounts get a leading "-";
--- nil -> `zeroText` (default dim "-"). Rounded by RoundForDisplay unless `exact`.
local function Money(c, zeroText, exact)
    c = SafeNumber(c)
    if not c then
        return zeroText or Dim("-")
    end
    c = math.floor(c + 0.5)
    if not exact then
        c = RoundForDisplay(c)
    end
    local s = ns.UI_FormatMoney(math.abs(c), 12, false)
    return (c < 0) and ("-" .. s) or s
end

--- Signed money: plain digits + coins in one semantic ink (WN TableKit FormatSignedMoneyPlain);
--- green > 0, red < 0, nil -> dim "-". Rounded by RoundForDisplay unless `exact`.
local function Signed(c, exact)
    c = SafeNumber(c)
    if not c then
        return Dim("-")
    end
    c = math.floor(c + 0.5)
    if not exact then
        c = RoundForDisplay(c)
    end
    local s = ns.UI_TableKit.FormatSignedMoneyPlain(c, 12)
    if c > 0 then
        return Ink(s, "green")
    elseif c < 0 then
        return Ink(s, "red")
    end
    return s
end

--- "2d 4h" from one day up, else the shared "%dh %dm" format.
local function FormatDuration(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    local hours = seconds / 3600
    if hours >= 24 then
        local d = math.floor(hours / 24)
        local h = math.floor(hours - d * 24)
        return string.format(SafeL("HUB_DURATION_DAYS_FMT", "%dd %dh"), d, h)
    end
    local h = math.floor(hours)
    local m = math.floor((hours - h) * 60)
    return string.format(SafeL("HUB_CONC_HOURS_FMT", "%dh %dm"), h, m)
end

local function ItemLink(itemID)
    if not itemID then
        return nil
    end
    local _, link = C_Item.GetItemInfo(itemID)
    return link or ("item:" .. tostring(itemID))
end

--- Harvest progress line (Crafting page notice); nil once every schematic is cached.
local function HarvestNotice()
    local rs = ns.RecipeService
    local stats = rs and rs.GetStats and rs:GetStats()
    if not stats or stats.total <= 0 or stats.harvested >= stats.total then
        return nil
    end
    local pct = math.floor((stats.harvested / stats.total) * 100)
    return string.format(SafeL("HUB_HARVEST_BANNER_FMT",
        "%d / %d recipes cached (%d%%). Open your professions once."),
        stats.harvested, stats.total, pct)
end

-- Stable helpers (safe to localize in other files; they read H.state live).
H.SafeL = SafeL
H.SafeNumber = SafeNumber
H.RecipeFallbackName = RecipeFallbackName
H.RecipeRowName = RecipeRowName
H.GetHubProfessionFilter = GetHubProfessionFilter
H.ProfessionListOpt = ProfessionListOpt
H.HubKnownBy = HubKnownBy
H.RecipeIconTexture = RecipeIconTexture
H.InkRGB = InkRGB
H.InkHex = InkHex
H.Ink = Ink
H.Dim = Dim
H.Money = Money
H.Signed = Signed
H.FormatDuration = FormatDuration
H.ItemLink = ItemLink
H.HarvestNotice = HarvestNotice

--- Page status in the window footer, right side (left of the version), e.g. "Cached recipes 236 / 1020".
--- UI_TabHost clears it before every tab draw; a tab sets its own. tooltip: optional hover text.
function ns.UI_SetFooterStatus(text, tooltip)
    local mf = ns.ArtisanNexus and ns.ArtisanNexus.UI and ns.ArtisanNexus.UI.mainFrame
    local ver = mf and mf.footerVersionText
    if not ver then return end
    local fs = mf._anFooterStatus
    if not fs then
        local bar = ver:GetParent()
        local hit = CreateFrame("Frame", nil, bar)
        fs = ns.FontManager:CreateFontString(hit, "small", "OVERLAY")
        fs:SetPoint("RIGHT", ver, "LEFT", -14, 0)
        fs:SetJustifyH("RIGHT")
        fs:SetWordWrap(false)
        hit:SetAllPoints(fs)
        hit:SetScript("OnEnter", function(self)
            if not fs._anTip then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(fs._anTip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
        fs._anHit = hit
        mf._anFooterStatus = fs
    end
    local left = mf.footerLeftText
    if not text or text == "" then
        fs:SetText("")
        fs._anTip = nil
        fs._anHit:EnableMouse(false)
        if left then
            left:SetPoint("RIGHT", ver, "LEFT", -14, 0)
        end
        return
    end
    fs:SetText(text)
    ns.UI_SetTextColorRole(fs, "Muted", 0.95)
    fs._anTip = tooltip
    fs._anHit:EnableMouse(tooltip ~= nil)
    if left then
        left:SetPoint("RIGHT", fs, "LEFT", -14, 0)
    end
end

--- Short tooltips with a Shift view (WN tooltips: summary first, detail on demand). Re-runs
--- redraw(owner) when Shift is pressed or released while GameTooltip still belongs to owner.
local shiftWatch = {}
local shiftFrame
function H.WatchShift(owner, redraw)
    shiftWatch.owner, shiftWatch.redraw = owner, redraw
    if not shiftFrame then
        shiftFrame = CreateFrame("Frame")
        shiftFrame:SetScript("OnEvent", function(self, _, key)
            local o, fn = shiftWatch.owner, shiftWatch.redraw
            -- Registered only while a watched tooltip is up: drop the event once it is gone.
            if not (o and fn and GameTooltip:IsShown() and GameTooltip:IsOwned(o)) then
                shiftWatch.owner, shiftWatch.redraw = nil, nil
                self:UnregisterEvent("MODIFIER_STATE_CHANGED")
                return
            end
            if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
            fn(o)
        end)
    end
    shiftFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
end
