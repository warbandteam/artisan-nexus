--[[
    Session loot: per-tab catalog (Session vs Overall totals) + Last N pickups (always in-memory session feed).
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local L = ns.L
local E = ns.Constants.EVENTS

local COLORS = ns.UI_COLORS
local LAYOUT = ns.UI_LAYOUT
local ApplyPanelBackdrop = ns.UI_ApplyPanelBackdrop
local ApplyVisuals = ns.UI_ApplyVisuals
local CreateIcon = ns.UI_CreateIcon
local ResolveRanks = ns.ResolveCatalogEntryRanks
local SetProfessionRankAtlasForItem = ns.SetProfessionRankAtlasForItem
local SetProfessionRankAtlas = ns.SetProfessionRankAtlas
local GetCatalogRankIndexForItem = ns.GetCatalogRankIndexForItem

local ROW_H = math.max(28, (LAYOUT.ROW_HEIGHT or 32))
local ICON_SZ = math.max(26, (LAYOUT.ICON_SIZE or 30))
local RANK_ATLAS_SZ = 22
local SESSION_ROW_GAP = 2
--- Last pickups row: one font for qty / name / value (GameFontNormalLarge family).
local SESSION_ROW_TEXT_FONT = "GameFontNormalLarge"
local SESSION_ROW_COIN_ICON_H = 14
local CAT_SZ = LAYOUT.CATALOG_ICON or 36
local PAD = LAYOUT.BASE_INDENT or 12
local LOOT_MIN_W = LAYOUT.LOOT_FRAME_MIN_WIDTH or 340
local LOOT_MIN_H = LAYOUT.LOOT_FRAME_MIN_HEIGHT or 420
local LOOT_MAX_W = LAYOUT.LOOT_FRAME_MAX_WIDTH or 900
local LOOT_MAX_H = LAYOUT.LOOT_FRAME_MAX_HEIGHT or 900

local GetQualityRGB = ns.GetQualityRGB or function()
    return 1, 1, 1
end

local MAX_QUALITY_TIERS = (ns.PROFESSION_QUALITY_MAX_TIER) or 5

local CELL_PAD = (LAYOUT.LOOT_CATALOG_CELL_PAD) or 8
local QTY_ON = COLORS.lootQtyOn or COLORS.textBright
local QTY_ZERO = COLORS.lootQtyZero or COLORS.textDim
--- Catalog / Reference başlıkları `GameFontNormal` — kart içi aynı aile (boyut uyumu).
local CATALOG_CELL_TEXT_FONT = "GameFontNormal"

local function GetLastLootListCap()
    local s = ns.SessionLootService
    return (s and s.MAX_RECENT_LOOT) or 15
end

local function OpenAddonSettings()
    local dlg = LibStub("AceConfigDialog-3.0", true)
    if dlg and dlg.Open then
        dlg:Open(ADDON_NAME)
        return
    end
    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(ADDON_NAME)
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(ADDON_NAME)
    end
end

--- Blizzard money display: amount + gold/silver/copper icons (embedded |T textures).
--- Used for both catalog AH column and session pickup value column.
---@param copper number
---@param iconHeight number|nil embedded coin icon height (match font size, e.g. 12 catalog, 14 session row)
local function FormatCopper(copper, iconHeight)
    if not copper or copper <= 0 then
        return nil
    end
    iconHeight = tonumber(iconHeight) or 12
    if GetCoinTextureString then
        local ok, s = pcall(function()
            return GetCoinTextureString(copper, iconHeight)
        end)
        if ok and s and s ~= "" then
            return s
        end
        ok, s = pcall(GetCoinTextureString, copper)
        if ok and s and s ~= "" then
            return s
        end
    end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then
        return string.format("%dg %ds", g, s)
    elseif s > 0 then
        return string.format("%ds %dc", s, c)
    end
    return string.format("%dc", c)
end

local function ComputeTotalsCopper(totals)
    local sum = 0
    if type(totals) ~= "table" then
        return 0
    end
    for rawId, qty in pairs(totals) do
        local q = tonumber(qty) or 0
        --- SavedVariables / DB pairs may use string keys; GetPrice expects consistent lookup.
        local itemID = tonumber(rawId) or rawId
        local unit = ns.AHPriceService and ns.AHPriceService:GetPrice(itemID)
        if q > 0 and unit and unit > 0 then
            sum = sum + (q * unit)
        end
    end
    return sum
end

local function ComputeSessionEfficiencyText(events)
    if type(events) ~= "table" or #events < 1 then
        return nil
    end
    local newestT = tonumber(events[1] and events[1].t) or time()
    local oldestT = newestT
    local qty = 0
    local copper = 0
    for i = 1, #events do
        local e = events[i]
        if e then
            qty = qty + math.max(0, tonumber(e.qty) or 0)
            local et = tonumber(e.t)
            if et and et < oldestT then
                oldestT = et
            end
            local itemID = tonumber(e.itemID)
            if itemID and itemID > 0 then
                local unit = ns.AHPriceService and ns.AHPriceService:GetPrice(itemID)
                if unit and unit > 0 then
                    copper = copper + ((tonumber(e.qty) or 0) * unit)
                end
            end
        end
    end
    if qty <= 0 then
        return nil
    end
    local hours = math.max((newestT - oldestT) / 3600, 1 / 3600)
    local iph = qty / hours
    local gph = copper / hours
    local goldStr = FormatCopper(math.floor(gph)) or "0c"
    --- Sabit metin: eski kayıtlı locale veya çeviri stash’inde "/min" kalmasın.
    return string.format("Rate: %.1f items/hr • %s/hr", iph, goldStr)
end

--- Standard item tooltip on icon frames (secure; no combat taint on GameTooltip from OnEnter).
local function AttachItemTooltip(frame, itemID)
    if not frame or not itemID or type(itemID) ~= "number" or itemID < 1 then
        return
    end
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(itemID)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

--- Top-level tab template; rendered set is filtered by owned professions.
local TAB_ORDER = { "fishing", "herb", "mine", "leather", "disenchant", "others" }
local PROF_SKILLS = {
    fishing = { 356 },
    herb = { 182 },
    mine = { 186 },
    -- Show leather tab for both Skinning (loot source) and Leatherworking (user expectation).
    leather = { 393, 165 },
    -- Enchanting owns disenchant materials.
    disenchant = { 333 },
}

local function SkillMatchesAny(skillLine, list)
    if not skillLine or type(list) ~= "table" then
        return false
    end
    for i = 1, #list do
        if skillLine == list[i] then
            return true
        end
    end
    return false
end

local function GetOwnedTabMap()
    local owned = { fishing = true }
    local p1, p2, _, fish = GetProfessions()
    local list = { p1, p2, fish }
    for i = 1, #list do
        local idx = list[i]
        if idx then
            local _, _, _, _, _, _, skillLine = GetProfessionInfo(idx)
            if SkillMatchesAny(skillLine, PROF_SKILLS.herb) then
                owned.herb = true
            elseif SkillMatchesAny(skillLine, PROF_SKILLS.mine) then
                owned.mine = true
            elseif SkillMatchesAny(skillLine, PROF_SKILLS.leather) then
                owned.leather = true
            elseif SkillMatchesAny(skillLine, PROF_SKILLS.disenchant) then
                owned.disenchant = true
            elseif SkillMatchesAny(skillLine, PROF_SKILLS.fishing) then
                owned.fishing = true
            end
        end
    end
    -- "Others" is shared gathering bucket; show it when any relevant gathering profession exists.
    if owned.herb or owned.mine or owned.leather or owned.disenchant then
        owned.others = true
    end
    return owned
end

local function GetVisibleTabOrder()
    local owned = GetOwnedTabMap()
    local out = {}
    for i = 1, #TAB_ORDER do
        local key = TAB_ORDER[i]
        if owned[key] then
            out[#out + 1] = key
        end
    end
    return out
end

local IsValidTab

local function TexForItem(itemID)
    local fileID = C_Item.GetItemIconByID(itemID)
    return (fileID and fileID > 0) and fileID or "Interface\\Icons\\INV_Misc_QuestionMark"
end

---@class LootHistoryUI
local LootHistoryUI = {
    main = nil,
    activeTab = "fishing",
    --- "session" = in-memory (resets on login/manual); "overall" = persisted db.global
    activeMode = "session",
    catalogContent = nil,
    sessionContent = nil,
    catalogScroll = nil,
    sessionScroll = nil,
    sessionPanel = nil,
    sessionEfficiencyLabel = nil,
    headerBar = nil,
    tabBar = nil,
    tabButtons = {},
    modeBar = nil,
    modeButtons = {},
    resetRow = nil,
    resetSessionBtn = nil,
    resetText = nil,
    settingsBtn = nil,
    resizeGrip = nil,
    _sizeSaveTimer = nil,
    --- Grip `StartSizing` aktifken ağır `Refresh` atlanır (takılma önlemi); bırakınca bir kez tam yenileme.
    _isLootFrameSizing = false,
}

--- `hooksecurefunc("StopMovingOrSizing")` bazı istemcilerde yok / hata verir. LMB bırakılınca anket + grip MouseUp.
local function FinishLootFrameSizing()
    if LootHistoryUI.main then
        LootHistoryUI.main:SetScript("OnUpdate", nil)
    end
    if not LootHistoryUI._isLootFrameSizing then
        return
    end
    LootHistoryUI._isLootFrameSizing = false
    LootHistoryUI:SaveFrameSize()
    LootHistoryUI:Refresh()
end

local function LootFrameSizingPoll()
    if not LootHistoryUI._isLootFrameSizing then
        if LootHistoryUI.main then
            LootHistoryUI.main:SetScript("OnUpdate", nil)
        end
        return
    end
    if not IsMouseButtonDown("LeftButton") then
        FinishLootFrameSizing()
    end
end

local function ClearSubtreeScripts(frame)
    if not frame then
        return
    end
    frame:SetScript("OnUpdate", nil)
    local ch = { frame:GetChildren() }
    for i = 1, #ch do
        ClearSubtreeScripts(ch[i])
    end
end

local function ClearScrollContent(scroll, content)
    if not content then return end
    local regions = { content:GetRegions() }
    for i = 1, #regions do
        regions[i]:Hide()
        regions[i]:SetParent(nil)
    end
    local ch = { content:GetChildren() }
    for i = 1, #ch do
        ClearSubtreeScripts(ch[i])
        ch[i]:Hide()
        ch[i]:SetParent(nil)
    end
end

local function GetLootFrameBounds()
    local p = UIParent
    local maxW, maxH = LOOT_MAX_W, LOOT_MAX_H
    if p and p.GetWidth and p.GetHeight then
        local pw = p:GetWidth() or 1200
        local ph = p:GetHeight() or 800
        maxW = math.min(LOOT_MAX_W, math.max(LOOT_MIN_W + 80, pw - 24))
        maxH = math.min(LOOT_MAX_H, math.max(LOOT_MIN_H + 80, ph - 24))
    end
    return maxW, maxH
end

function LootHistoryUI:ApplySavedFrameSize(f)
    if not f then
        return
    end
    local db = ns.db and ns.db.profile and ns.db.profile.lootHistoryFrame
    local w = (db and db.width) or LAYOUT.WINDOW_WIDTH
    local h = (db and db.height) or LAYOUT.WINDOW_HEIGHT
    local maxW, maxH = GetLootFrameBounds()
    w = math.max(LOOT_MIN_W, math.min(maxW, w))
    h = math.max(LOOT_MIN_H, math.min(maxH, h))
    f:SetWidth(w)
    f:SetHeight(h)
end

function LootHistoryUI:SaveFrameSize()
    if not self.main or not ns.db or not ns.db.profile then
        return
    end
    ns.db.profile.lootHistoryFrame = ns.db.profile.lootHistoryFrame or {}
    ns.db.profile.lootHistoryFrame.width = self.main:GetWidth()
    ns.db.profile.lootHistoryFrame.height = self.main:GetHeight()
end

local SESSION_FRAC = 0.34

function LootHistoryUI:LayoutTabs()
    if not self.main or not self.tabBar or not self.tabButtons then
        return
    end
    local order = GetVisibleTabOrder()
    for key, btn in pairs(self.tabButtons) do
        if btn then
            btn:Hide()
        end
    end
    local w = self.tabBar:GetWidth()
    if not w or w < 80 then
        return
    end
    local gap = 5
    local n = #order
    if n < 1 then
        return
    end
    local btnW = math.max(56, math.floor((w - (n - 1) * gap) / n))
    for i = 1, n do
        local key = order[i]
        local b = self.tabButtons[key]
        if b then
            b:ClearAllPoints()
            b:SetSize(btnW, 30)
            b:SetPoint("TOPLEFT", self.tabBar, "TOPLEFT", (i - 1) * (btnW + gap), 0)
            b:Show()
        end
    end
end

function LootHistoryUI:LayoutModeBtns()
    if not self.modeBar or not self.modeButtons then return end
    local w = self.modeBar:GetWidth()
    if not w or w < 80 then return end
    local gap = 5
    local btnW = math.max(56, math.floor((w - gap) / 2))
    local keys = { "session", "overall" }
    for i, key in ipairs(keys) do
        local b = self.modeButtons[key]
        if b then
            b:ClearAllPoints()
            b:SetSize(btnW, 30)
            b:SetPoint("TOPLEFT", self.modeBar, "TOPLEFT", (i - 1) * (btnW + gap), 0)
        end
    end
end

function LootHistoryUI:SetMode(mode)
    if mode ~= "session" and mode ~= "overall" then return end
    self.activeMode = mode
    self:Refresh()
end

function LootHistoryUI:RefreshModeButtonVisuals()
    if not self.modeButtons or not ApplyVisuals then return end
    for _, key in ipairs({ "session", "overall" }) do
        local btn = self.modeButtons[key]
        if btn then
            local sel = key == self.activeMode
            local bg = sel and COLORS.tabActive or COLORS.tabInactive
            local br = sel
                and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.78 }
                or { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.32 }
            ApplyVisuals(btn, bg, br)
            local fs = btn:GetFontString()
            if fs then
                if sel then
                    fs:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])
                else
                    fs:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3])
                end
            end
        end
    end
    if self.resetText then
        if self.activeMode == "overall" then
            self.resetText:SetText((L and L["LOOT_RESET_OVERALL"]) or "Reset overall")
        else
            self.resetText:SetText((L and L["LOOT_RESET_SESSION"]) or "Reset session")
        end
    end
end

function LootHistoryUI:OnLootFrameSizeChanged()
    if self.main and self.sessionPanel then
        local fh = self.main:GetHeight() or 668
        self.sessionPanel:SetHeight(math.max(140, math.floor(fh * SESSION_FRAC)))
    end
    self:LayoutTabs()
    self:LayoutModeBtns()
    --- Alt köşeden yeniden boyutlandırırken her pikselde `Refresh` = tüm scroll yeniden kurulum; takılır.
    if not self._isLootFrameSizing then
        self:Refresh()
        if self._sizeSaveTimer and self._sizeSaveTimer.Cancel then
            self._sizeSaveTimer:Cancel()
        end
        if C_Timer and C_Timer.NewTimer then
            self._sizeSaveTimer = C_Timer.NewTimer(0.2, function()
                self._sizeSaveTimer = nil
                if LootHistoryUI.main then
                    LootHistoryUI:SaveFrameSize()
                end
            end)
        else
            self:SaveFrameSize()
        end
    end
end

--- Responsive column count: wider window → more columns.
local function CatalogColumnCount(innerW)
    if not innerW or innerW < 120 then
        return 1
    end
    if innerW >= 640 then
        return 4
    end
    if innerW >= 480 then
        return 3
    end
    if innerW >= 320 then
        return 2
    end
    return 1
end

--- Ease-out for fade curves (smooth end toward default).
local function Smooth01(u)
    u = math.max(0, math.min(1, u))
    return u * u * (3 - 2 * u)
end

--- Session son pickup + katalog referans kartı — aynı nabız hızı.
local LOOT_SHIMMER_PULSE_HZ = 1.85

--- Katalog: güç 0..1 (GetReferenceGlowStrength) — session satırıyla aynı tam yüzey nabız shimmer.
local function AddCatalogCellLootBorder(cellFrame, strength)
    if not cellFrame or not strength or strength < 0.04 then
        return
    end
    local pick = COLORS.lootPickBorder
    local r0 = pick and pick[1] or COLORS.accent[1]
    local g0 = pick and pick[2] or COLORS.accent[2]
    local b0 = pick and pick[3] or COLORS.accent[3]
    local strSm = Smooth01(strength)

    local bg = cellFrame._catalogShimmerBg
    if not bg then
        bg = cellFrame:CreateTexture(nil, "BACKGROUND", nil, -8)
        bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        bg:SetAllPoints()
        cellFrame._catalogShimmerBg = bg
    end

    cellFrame:SetScript("OnUpdate", function()
        local pulse = (math.sin(GetTime() * (math.pi * 2 * LOOT_SHIMMER_PULSE_HZ)) + 1) * 0.5
        local aLo, aHi = 0.10, 0.34
        local alpha = strSm * (aLo + (aHi - aLo) * pulse)
        local bright = 0.86 + 0.14 * pulse
        bg:SetVertexColor(r0 * bright, g0 * bright, b0 * bright)
        bg:SetAlpha(alpha)
    end)
    bg:Show()
end

local function CatalogCellMaxGlowStrength(entry, ranks, tabKey, svc)
    if not svc or not tabKey or not svc.GetReferenceGlowStrength then
        return 0
    end
    local maxS = 0
    local function consider(itemID)
        if itemID then
            local s = svc:GetReferenceGlowStrength(itemID, tabKey)
            if s > maxS then
                maxS = s
            end
        end
    end
    consider(entry and entry.id)
    for i = 1, #ranks do
        consider(ranks[i])
    end
    return maxS
end

--- Son pickup: kenar yok — satır boyu BACKGROUND, hover benzeri nabız (sin) + süre zarfıyla sönüm; OVERLAY yazı/ikon üstte.
local function ApplySessionPickupHighlight(row, evRt, glowSec)
    if not row or not evRt then
        return
    end
    glowSec = tonumber(glowSec) or 2.0
    local age0 = math.max(0, GetTime() - evRt)
    if age0 >= glowSec then
        return
    end
    local pick = COLORS.lootPickBorder
    local r0 = pick and pick[1] or COLORS.accent[1]
    local g0 = pick and pick[2] or COLORS.accent[2]
    local b0 = pick and pick[3] or COLORS.accent[3]

    local parts = row._sessionPickParts
    if not parts or not parts[1] then
        parts = {}
        local bg = row:CreateTexture(nil, "BACKGROUND", nil, -8)
        bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        bg:SetAllPoints()
        parts[1] = bg
        row._sessionPickParts = parts
    end
    local bg = parts[1]

    local function envelope(age)
        local u = 1 - (age / glowSec)
        return Smooth01(math.max(0, math.min(1, u)))
    end

    --- Nabız 0..1; zarf ile birlikte alfa ve hafif renk “parlaması”.
    local function applyPickupShimmer(age)
        local env = envelope(age)
        local pulse = (math.sin(GetTime() * (math.pi * 2 * LOOT_SHIMMER_PULSE_HZ)) + 1) * 0.5
        local aLo, aHi = 0.10, 0.34
        local alpha = env * (aLo + (aHi - aLo) * pulse)
        local bright = 0.86 + 0.14 * pulse
        bg:SetVertexColor(r0 * bright, g0 * bright, b0 * bright)
        bg:SetAlpha(alpha)
    end

    local startRt = evRt
    applyPickupShimmer(age0)
    bg:Show()

    row._lootPickupBorder = bg
    row:SetScript("OnUpdate", function(f)
        local age = GetTime() - startRt
        if age >= glowSec then
            f:SetScript("OnUpdate", nil)
            f._lootPickupBorder = nil
            bg:Hide()
            return
        end
        applyPickupShimmer(age)
    end)
end

--- Reagent icon (left); R1 + R2 profession atlases stacked (right); amounts x(N) in white. Responsive grid.
---@param tabKey string|nil Active tab — `GetReferenceGlowStrength` ile katalog kenar solması
local function PopulateCatalog(content, entries, totals, tabKey)
    totals = totals or {}
    if not CreateIcon or not ResolveRanks then return end
    local function qtyForItem(id)
        if not id then
            return 0
        end
        local q = totals[id]
        if q then
            return q
        end
        if type(id) == "number" then
            return totals[tostring(id)] or 0
        end
        return totals[tonumber(id)] or 0
    end

    local innerW = content:GetWidth()
    if not innerW or innerW < 100 then innerW = 360 end
    local cols = CatalogColumnCount(innerW)
    local gapX = 8
   --- Kalan piksel `remPx` ilk sütunlara +1: grid genişliği tam `innerW` (scroll içi ile hizalı, sütunlar eşit ±1px).
    local availForCells = math.max(1, innerW - gapX * (cols - 1))
    local baseCellW = cols > 0 and math.floor(availForCells / cols) or 108
    local remPx = cols > 0 and (availForCells - baseCellW * cols) or 0
    local function CellWidthForCol(col0)
        local c = col0 + 1
        return baseCellW + (c <= remPx and 1 or 0)
    end
    local colLeft = {}
    local xAcc = 0
    for col0 = 0, cols - 1 do
        colLeft[col0] = xAcc
        xAcc = xAcc + CellWidthForCol(col0) + gapX
    end
    local rowLineH = math.max(24, math.floor(CAT_SZ * 0.52))
    local atlasSz = math.max(20, math.floor(CAT_SZ * 0.46))
    local fmt = (L and L["LOOT_REF_TOTAL_FMT"]) or "×%d"

    local n = #entries
    local rows = math.max(1, math.ceil(n / cols))

    local maxRankLines = 1
    for idx = 1, n do
        local entry = entries[idx]
        local ranks = ResolveRanks(entry)
        if #ranks < 1 and entry and entry.id then
            ranks = { entry.id }
        end
        if #ranks >= 1 then
            maxRankLines = math.max(maxRankLines, math.min(MAX_QUALITY_TIERS, #ranks))
        end
    end

    local svcLoot = ns.SessionLootService
    local fixedCellH = CELL_PAD + math.max(CAT_SZ, maxRankLines * rowLineH) + CELL_PAD
    local cellBorder = COLORS.lootCellBorder
    if not cellBorder then
        cellBorder = { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.30 }
    end

    for idx = 1, n do
        local entry = entries[idx]
        local ranks = ResolveRanks(entry)
        if #ranks < 1 and entry.id then
            ranks = { entry.id }
        end
        local row = math.floor((idx - 1) / cols)
        local col = (idx - 1) % cols
        local showRanks = math.min(MAX_QUALITY_TIERS, #ranks)

        local cellW = CellWidthForCol(col)
        local cellX = colLeft[col] or 0

        if #ranks < 1 then
            local empty = CreateFrame("Frame", nil, content)
            empty:SetSize(cellW, fixedCellH)
            empty:SetPoint("TOPLEFT", content, "TOPLEFT", cellX, -row * (fixedCellH + gapX))
        else
            local cellFrame = CreateFrame("Frame", nil, content)
            cellFrame:SetSize(cellW, fixedCellH)
            cellFrame:SetPoint("TOPLEFT", content, "TOPLEFT", cellX, -row * (fixedCellH + gapX))
            if ApplyVisuals and COLORS.lootCellBg then
                ApplyVisuals(cellFrame, COLORS.lootCellBg, cellBorder)
            end

            local iconId = ranks[1]
            local ic = CreateIcon(cellFrame, TexForItem(iconId), CAT_SZ, false, nil, false)
            if ic then
                ic:SetPoint("TOPLEFT", cellFrame, "TOPLEFT", CELL_PAD, -CELL_PAD)
                ic:Show()
                AttachItemTooltip(ic, iconId)
                local glowStr = CatalogCellMaxGlowStrength(entry, ranks, tabKey, svcLoot)
                if glowStr > 0.04 then
                    AddCatalogCellLootBorder(cellFrame, glowStr)
                end
            end

            local blockH = showRanks * rowLineH
            local rankBlock = CreateFrame("Frame", nil, cellFrame)
            rankBlock:SetSize(cellW - CAT_SZ - CELL_PAD * 3, blockH)
            if ic then
                --- Snap to icon’s right; stack vertically centered on the icon (WoW: +y is up).
                rankBlock:SetPoint("LEFT", ic, "RIGHT", 10, 0)
                rankBlock:SetPoint("TOP", ic, "TOP", 0, (blockH - CAT_SZ) / 2)
            else
                rankBlock:SetPoint("TOPLEFT", cellFrame, "TOPLEFT", CELL_PAD + CAT_SZ, -CELL_PAD)
            end

            for r = 1, showRanks do
                local rid = ranks[r]
                if not rid then
                    break
                end
                local line = CreateFrame("Frame", nil, rankBlock)
                line:SetSize(rankBlock:GetWidth(), rowLineH)
                line:SetPoint("TOPLEFT", rankBlock, "TOPLEFT", 0, -(r - 1) * rowLineH)

                local tex = line:CreateTexture(nil, "ARTWORK")
                tex:SetSize(atlasSz, atlasSz)
                tex:SetPoint("LEFT", line, "LEFT", 0, 0)
                --- Catalog row `r` (1..2) maps to profession tier atlases; do not infer tier from item APIs here.
                if SetProfessionRankAtlas then
                    if not SetProfessionRankAtlas(tex, r, atlasSz, atlasSz) then
                        tex:Hide()
                    end
                else
                    tex:Hide()
                end

                local cnt = qtyForItem(rid)
                local cntStr = line:CreateFontString(nil, "OVERLAY", CATALOG_CELL_TEXT_FONT)
                cntStr:SetJustifyH("LEFT")
                cntStr:SetFormattedText(fmt, cnt)
                if cnt > 0 then
                    cntStr:SetTextColor(QTY_ON[1], QTY_ON[2], QTY_ON[3], 1)
                else
                    cntStr:SetTextColor(QTY_ZERO[1], QTY_ZERO[2], QTY_ZERO[3], 1)
                end
                cntStr:SetPoint("LEFT", tex, "RIGHT", 4, 0)

                --- AH: only when this rank has collected qty > 0 (session/overall totals); no gold line at ×0.
                local unitPrice = ns.AHPriceService and ns.AHPriceService:GetPrice(rid)
                if cnt > 0 and unitPrice and unitPrice > 0 then
                    local earnStr = line:CreateFontString(nil, "OVERLAY", CATALOG_CELL_TEXT_FONT)
                    earnStr:SetJustifyH("RIGHT")
                    earnStr:SetPoint("RIGHT", line, "RIGHT", 0, 0)
                    earnStr:SetText(FormatCopper(cnt * unitPrice) or "")
                end

                line:EnableMouse(true)
                AttachItemTooltip(line, rid)
            end
        end
    end

    local gridW = innerW
    local gridH = rows * fixedCellH + math.max(0, rows - 1) * gapX + 8
    content:SetSize(gridW, gridH)
end

--- En yeni pickup satırına kısa süre accent vurgusu (rt penceresi).
local SESSION_ROW_GLOW_RT_SEC = 2.2
--- Aynı loot çözümünde ardışık PushFront’lar (~aynı GetTime): çoklu satırda hepsi border alır; sonraki satır keser.
local MULTI_LOOT_RT_CLUSTER_SEC = 1.2

--- Newest-first listede, üstteki tek dal için kaç satır vurgulanır (1..k).
local function SessionPickBorderEndIndex(events, maxN, nowT, glowSec, clusterSec)
    clusterSec = tonumber(clusterSec) or 1.2
    local e1 = events and events[1]
    if not e1 then
        return 0
    end
    local t1 = tonumber(e1.rt)
    if not t1 or (nowT - t1) > glowSec then
        return 0
    end
    local k = 1
    for i = 2, maxN do
        local ei = events[i]
        if not ei then
            break
        end
        local ti = tonumber(ei.rt)
        if not ti or (nowT - ti) > glowSec then
            break
        end
        if math.abs(ti - t1) > clusterSec then
            break
        end
        k = i
    end
    return k
end

local function PopulateSessionList(content, events, catalogEntries, listCap, emptyMsg)
    listCap = listCap or GetLastLootListCap()
    local nowRt = GetTime()
    local y = 0
    local w = content:GetWidth() > 80 and content:GetWidth() or 360
    local maxN = math.min(listCap, #events)
    local borderEndIdx = SessionPickBorderEndIndex(events, maxN, nowRt, SESSION_ROW_GLOW_RT_SEC, MULTI_LOOT_RT_CLUSTER_SEC)
    for i = 1, maxN do
        local e = events[i]
        if not e then break end
        local itemID = e.itemID
        local qty = e.qty or 1
        local row = CreateFrame("Frame", nil, content)
        --- Tam scroll genişliği; vurgu soldan sağa liste alanıyla hizalı (eskiden w-8 + x=2 kesiyordu).
        row:SetSize(w, ROW_H)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        local evRt = tonumber(e.rt)
        local showFreshPickupBorder = borderEndIdx > 0 and i <= borderEndIdx and evRt

        local tex = TexForItem(itemID)
        local ib = COLORS.lootCellBorder
        local iconBr = ib and { ib[1], ib[2], ib[3], 0.52 }
            or { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.45 }
        local iconFrame = CreateIcon and CreateIcon(row, tex, ICON_SZ, false, iconBr, false)
        if iconFrame then
            iconFrame:SetPoint("LEFT", 0, 0)
            iconFrame:Show()
            AttachItemTooltip(iconFrame, itemID)
        end

        local tierFb = 1
        if GetCatalogRankIndexForItem then
            tierFb = GetCatalogRankIndexForItem(itemID, catalogEntries) or 1
        end
        tierFb = math.min(math.max(tierFb, 1), MAX_QUALITY_TIERS)

        local rankHolder = CreateFrame("Frame", nil, row)
        rankHolder:SetSize(RANK_ATLAS_SZ, RANK_ATLAS_SZ)
        rankHolder:SetPoint("LEFT", iconFrame or row, "RIGHT", 6, 0)
        local rankTex = rankHolder:CreateTexture(nil, "ARTWORK")
        rankTex:SetAllPoints()
        local rankOk = SetProfessionRankAtlasForItem
            and SetProfessionRankAtlasForItem(rankTex, itemID, RANK_ATLAS_SZ, RANK_ATLAS_SZ, tierFb)
        if not rankOk then
            rankHolder:SetWidth(2)
            rankTex:Hide()
        end

        local countStr = row:CreateFontString(nil, "OVERLAY", SESSION_ROW_TEXT_FONT)
        countStr:SetPoint("LEFT", rankHolder, "RIGHT", 4, 0)
        countStr:SetJustifyH("LEFT")
        countStr:SetText(tostring(qty) .. "×")
        countStr:SetTextColor(1, 1, 1, 1)

        local unitPrice = ns.AHPriceService and ns.AHPriceService:GetPrice(itemID)
        local priceStr
        local totalCopper = (qty > 0 and unitPrice and unitPrice > 0) and (qty * unitPrice) or nil
        if totalCopper and totalCopper > 0 then
            priceStr = row:CreateFontString(nil, "OVERLAY", SESSION_ROW_TEXT_FONT)
            priceStr:SetJustifyH("RIGHT")
            priceStr:SetPoint("RIGHT", row, "RIGHT", -2, 0)
            priceStr:SetText(FormatCopper(totalCopper, SESSION_ROW_COIN_ICON_H) or "")
        end

        local nameStr = row:CreateFontString(nil, "OVERLAY", SESSION_ROW_TEXT_FONT)
        nameStr:SetPoint("LEFT", countStr, "RIGHT", 8, 0)
        if priceStr then
            nameStr:SetPoint("RIGHT", priceStr, "LEFT", -6, 0)
        else
            nameStr:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        end
        nameStr:SetJustifyH("LEFT")
        if nameStr.SetWordWrap then
            nameStr:SetWordWrap(false)
        end

        local function ApplyNameAndColor()
            local nm = GetItemInfo(itemID)
            local qIdx = select(3, GetItemInfo(itemID))
            if qIdx == nil then
                qIdx = 1
            end
            if nm and not (issecretvalue and issecretvalue(nm)) then
                nameStr:SetText(nm)
            else
                nameStr:SetText("#" .. tostring(itemID))
            end
            local qr, qg, qb = GetQualityRGB(qIdx)
            nameStr:SetTextColor(qr, qg, qb)
        end
        ApplyNameAndColor()
        if not GetItemInfo(itemID) and Item and Item.CreateFromItemID then
            local item = Item:CreateFromItemID(itemID)
            item:ContinueOnItemLoad(function()
                ApplyNameAndColor()
            end)
        end
        if showFreshPickupBorder and evRt then
            ApplySessionPickupHighlight(row, evRt, SESSION_ROW_GLOW_RT_SEC)
        end
        y = y + ROW_H + SESSION_ROW_GAP
    end
    if maxN == 0 then
        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        empty:SetPoint("TOPLEFT", 8, -6)
        empty:SetText(emptyMsg or (L and L["LOOT_SESSION_EMPTY"]) or "No recent loot this session.")
        empty:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3])
        y = 28
    end
    content:SetSize(w, math.max(y + 4, 32))
end

function LootHistoryUI:Refresh()
    if not self.main or not self.catalogContent or not self.sessionContent then return end
    if not IsValidTab(self.activeTab) then
        local order = GetVisibleTabOrder()
        self.activeTab = order[1] or "fishing"
    end

    local isOverall = self.activeMode == "overall"
    local svc = ns.SessionLootService
    local entries
    if self.activeTab == "fishing" then
        entries = (ns.GetFishingCatalogEntries and ns.GetFishingCatalogEntries()) or {}
    else
        entries = (ns.GetGatheringCatalogByCategory and ns.GetGatheringCatalogByCategory(self.activeTab)) or {}
    end

    --- Catalog: Session vs Overall persisted totals. Last pickups: always session event list (not Overall DB slice).
    local totals = {}
    local eventsLastPickups = {}
    if svc then
        if self.activeTab == "fishing" then
            totals = svc:GetItemTotals("fishing", nil, isOverall) or {}
            eventsLastPickups = svc:GetRecentEvents("fishing", nil, false) or {}
        else
            local cat = self.activeTab
            totals = svc:GetItemTotals("gathering", cat, isOverall) or {}
            eventsLastPickups = svc:GetRecentEvents("gathering", cat, false) or {}
        end
    end
    if self.catalogTotalLabel then
        local totalCopper = ComputeTotalsCopper(totals)
        local totalFmt = (L and L["LOOT_SECTION_TOTAL_FMT"]) or "Total: %s"
        self.catalogTotalLabel:SetFormattedText(totalFmt, FormatCopper(totalCopper) or "0c")
    end

    ClearScrollContent(self.catalogScroll, self.catalogContent)
    ClearScrollContent(self.sessionScroll, self.sessionContent)

    local cw = math.max((self.catalogScroll and self.catalogScroll:GetWidth()) or 360, 280)
    self.catalogContent:SetWidth(cw)
    PopulateCatalog(self.catalogContent, entries, totals, self.activeTab)

    local sw = math.max((self.sessionScroll and self.sessionScroll:GetWidth()) or 360, 280)
    self.sessionContent:SetWidth(sw)
    local cap = GetLastLootListCap()
    if self.sessionSectionLabel then
        local fmt = (L and L["LOOT_SECTION_SESSION_FMT"]) or "Last %d pickups"
        self.sessionSectionLabel:SetFormattedText(fmt, cap)
    end
    local emptyLastPickups = (L and L["LOOT_LAST_PICKUPS_EMPTY"]) or (L and L["LOOT_SESSION_EMPTY"]) or "No recent pickups yet."
    PopulateSessionList(self.sessionContent, eventsLastPickups, entries, cap, emptyLastPickups)
    if self.sessionEfficiencyLabel then
        local eff = ComputeSessionEfficiencyText(eventsLastPickups)
        self.sessionEfficiencyLabel:SetText(eff or "")
    end

    LootHistoryUI:RefreshTabButtonVisuals()
    LootHistoryUI:RefreshModeButtonVisuals()
end

---@param btn Frame|Button
---@param selected boolean
---@param otherTabLootPulse boolean|nil non-selected tab that just received catalog loot for its profession
local function StyleTabButton(btn, selected, otherTabLootPulse)
    if not btn or not ApplyVisuals then return end
    local bg, br
    if selected then
        bg = COLORS.tabActive
        br = { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.78 }
    elseif otherTabLootPulse then
        bg = {
            math.min(1, COLORS.tabInactive[1] + 0.12),
            math.min(1, COLORS.tabInactive[2] + 0.10),
            math.min(1, COLORS.tabInactive[3] + 0.18),
            1,
        }
        br = { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.92 }
    else
        bg = COLORS.tabInactive
        br = { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.32 }
    end
    ApplyVisuals(btn, bg, br)
    local fs = btn:GetFontString()
    if fs then
        if selected then
            fs:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])
        elseif otherTabLootPulse then
            fs:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])
        else
            fs:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3])
        end
    end
end

function LootHistoryUI:RefreshTabButtonVisuals()
    if not self.tabButtons then
        return
    end
    local order = GetVisibleTabOrder()
    local svc = ns.SessionLootService
    for i = 1, #TAB_ORDER do
        local key = TAB_ORDER[i]
        local btn = self.tabButtons[key]
        if btn then
            local visible = false
            for j = 1, #order do
                if order[j] == key then
                    visible = true
                    break
                end
            end
            if visible then
                local sel = key == self.activeTab
                local pulse = (not sel) and svc and svc.IsTabAttentionActive and svc:IsTabAttentionActive(key)
                StyleTabButton(btn, sel, pulse)
                btn:Show()
            else
                btn:Hide()
            end
        end
    end
end

IsValidTab = function(tab)
    local order = GetVisibleTabOrder()
    for i = 1, #order do
        if order[i] == tab then
            return true
        end
    end
    return false
end

---@param tab "fishing"|"herb"|"mine"|"leather"|"disenchant"
function LootHistoryUI:SetTab(tab)
    if not IsValidTab(tab) then
        return
    end
    self.activeTab = tab
    if ns.db and ns.db.profile then
        ns.db.profile.lootHistoryActiveTab = tab
    end
    if ns.SessionLootService and ns.SessionLootService.ClearTabAttentionForTab then
        ns.SessionLootService:ClearTabAttentionForTab(tab)
    end
    self:Refresh()
end

local function NormalizeShowArg(which)
    if not which or which == "" then
        return nil
    end
    if which == "gathering" or which == "gather" or which == "herb" then
        return "herb"
    end
    if which == "fish" or which == "fishing" then
        return "fishing"
    end
    if which == "mine" or which == "mining" or which == "ore" then
        return "mine"
    end
    if which == "leather" or which == "skinning" or which == "skin" then
        return "leather"
    end
    if which == "disenchant" or which == "de" or which == "enchant" or which == "enchanting" then
        return "disenchant"
    end
    if which == "others" or which == "other" or which == "shared" or which == "mote" then
        return "others"
    end
    if IsValidTab(which) then
        return which
    end
    return nil
end

function LootHistoryUI:Show(which)
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        if self.main and self.main:IsShown() then
            self.main:Hide()
        end
        return
    end
    local w = NormalizeShowArg(which)
    if w then
        self.activeTab = w
        if ns.db and ns.db.profile then
            ns.db.profile.lootHistoryActiveTab = w
        end
    end
    if self.main then
        self.main:Show()
        if self.sessionPanel then
            local fh = self.main:GetHeight() or LAYOUT.WINDOW_HEIGHT or 640
            self.sessionPanel:SetHeight(math.max(140, math.floor(fh * SESSION_FRAC)))
        end
        self:LayoutTabs()
        self:Refresh()
        return
    end

    local f = CreateFrame("Frame", "ArtisanNexusLootHistoryFrame", UIParent, "BackdropTemplate")
    f:SetSize(LAYOUT.WINDOW_WIDTH, LAYOUT.WINDOW_HEIGHT)
    LootHistoryUI:ApplySavedFrameSize(f)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:SetResizable(true)
    f:EnableMouse(true)
    local rbW, rbH = GetLootFrameBounds()
    if f.SetResizeBounds then
        pcall(function()
            f:SetResizeBounds(LOOT_MIN_W, LOOT_MIN_H, rbW, rbH)
        end)
    elseif f.SetMinResize then
        f:SetMinResize(LOOT_MIN_W, LOOT_MIN_H)
        f:SetMaxResize(rbW, rbH)
    end
    f:SetScript("OnSizeChanged", function()
        LootHistoryUI:OnLootFrameSizeChanged()
    end)
    ApplyPanelBackdrop(f)

    local headerH = math.max(36, (LAYOUT.HEADER_HEIGHT and (LAYOUT.HEADER_HEIGHT - 12)) or 40)
    local headerBar = CreateFrame("Frame", nil, f, "BackdropTemplate")
    headerBar:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    headerBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    headerBar:SetHeight(headerH)
    headerBar:EnableMouse(true)
    headerBar:RegisterForDrag("LeftButton")
    headerBar:SetScript("OnDragStart", function()
        f:StartMoving()
    end)
    headerBar:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
    end)
    if ApplyVisuals then
        ApplyVisuals(headerBar, COLORS.bgLight, { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.45 })
    end
    self.headerBar = headerBar

    local headerTitle = headerBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    headerTitle:SetPoint("LEFT", headerBar, "LEFT", PAD, 0)
    headerTitle:SetPoint("RIGHT", headerBar, "RIGHT", -88, 0)
    headerTitle:SetJustifyH("LEFT")
    headerTitle:SetText((L and L["ADDON_NAME"]) or "Artisan Nexus")
    headerTitle:SetTextColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3])

    local close = CreateFrame("Button", nil, headerBar, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", headerBar, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function()
        f:Hide()
    end)

    local settingsBtn = CreateFrame("Button", nil, headerBar)
    settingsBtn:SetSize(26, 26)
    settingsBtn:SetPoint("RIGHT", close, "LEFT", -2, 0)
    settingsBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    settingsBtn:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton")
    settingsBtn:SetScript("OnClick", function()
        OpenAddonSettings()
    end)
    settingsBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText((L and L["LOOT_SETTINGS_TOOLTIP"]) or "Artisan Nexus settings")
        GameTooltip:Show()
    end)
    settingsBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    self.settingsBtn = settingsBtn

    local labels = {
        fishing = (L and L["LOOT_TAB_FISHING"]) or "Fishing",
        herb = (L and L["LOOT_GATHER_HERB"]) or "Herbalism",
        mine = (L and L["LOOT_GATHER_MINE"]) or "Mining",
        leather = (L and L["LOOT_GATHER_LEATHER"]) or "Leather",
        disenchant = (L and L["LOOT_GATHER_DE"]) or "Disenchant",
        others = (L and L["LOOT_GATHER_OTHERS"]) or "Others",
    }

    local tabBar = CreateFrame("Frame", nil, f)
    tabBar:SetPoint("TOPLEFT", headerBar, "BOTTOMLEFT", PAD, -6)
    tabBar:SetPoint("TOPRIGHT", headerBar, "BOTTOMRIGHT", -PAD, -6)
    tabBar:SetHeight(34)
    self.tabBar = tabBar

    self.tabButtons = {}
    for i = 1, #TAB_ORDER do
        local key = TAB_ORDER[i]
        local b = CreateFrame("Button", nil, f, "BackdropTemplate")
        b:SetParent(tabBar)
        b:SetHeight(30)
        local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetAllPoints()
        t:SetText(labels[key] or key)
        b:SetFontString(t)
        b:SetScript("OnClick", function()
            LootHistoryUI:SetTab(key)
        end)
        self.tabButtons[key] = b
    end

    local modeBar = CreateFrame("Frame", nil, f)
    modeBar:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -8)
    modeBar:SetPoint("TOPRIGHT", tabBar, "BOTTOMRIGHT", 0, -8)
    modeBar:SetHeight(30)
    self.modeBar = modeBar

    local modeLabels = {
        session = (L and L["LOOT_MODE_SESSION"]) or "Session",
        overall = (L and L["LOOT_MODE_OVERALL"]) or "Overall",
    }
    self.modeButtons = {}
    for _, key in ipairs({ "session", "overall" }) do
        local mb = CreateFrame("Button", nil, f, "BackdropTemplate")
        mb:SetParent(modeBar)
        mb:SetHeight(30)
        local mt = mb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        mt:SetAllPoints()
        mt:SetText(modeLabels[key] or key)
        mb:SetFontString(mt)
        mb:SetScript("OnClick", function()
            LootHistoryUI:SetMode(key)
        end)
        self.modeButtons[key] = mb
    end

    local resetRow = CreateFrame("Frame", nil, f)
    resetRow:SetPoint("TOPLEFT", modeBar, "BOTTOMLEFT", 0, -4)
    resetRow:SetPoint("TOPRIGHT", modeBar, "BOTTOMRIGHT", 0, -4)
    resetRow:SetHeight(26)
    self.resetRow = resetRow

    local resetSessionBtn = CreateFrame("Button", nil, resetRow, "BackdropTemplate")
    resetSessionBtn:SetHeight(26)
    resetSessionBtn:SetPoint("TOPLEFT", resetRow, "TOPLEFT", 0, 0)
    resetSessionBtn:SetPoint("TOPRIGHT", resetRow, "TOPRIGHT", 0, 0)
    local resetText = resetSessionBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    resetText:SetAllPoints()
    resetText:SetText((L and L["LOOT_RESET_SESSION"]) or "Reset session")
    resetSessionBtn:SetFontString(resetText)
    self.resetText = resetText
    self.resetSessionBtn = resetSessionBtn

    --- Session: clear only this tab’s in-memory session. Overall: clear only this tab’s saved overall data.
    resetSessionBtn:SetScript("OnClick", function()
        local svc = ns.SessionLootService
        if not svc then
            return
        end
        if LootHistoryUI.activeMode == "overall" then
            if LootHistoryUI.activeTab == "fishing" then
                svc:ResetOverall("fishing")
            else
                svc:ResetOverall("gathering", LootHistoryUI.activeTab)
            end
        else
            svc:ResetSessionForTab(LootHistoryUI.activeTab)
        end
        LootHistoryUI:Refresh()
    end)
    if ApplyVisuals then
        ApplyVisuals(resetSessionBtn, COLORS.tabInactive, { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.35 })
        resetText:SetTextColor(COLORS.textNormal[1], COLORS.textNormal[2], COLORS.textNormal[3])
    end

    --- Bottom panel: larger share of height (SESSION_FRAC); explicit height so scroll works.
    local sessionPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
    sessionPanel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, 18)
    sessionPanel:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 18)
    do
        local fh = f:GetHeight() or LAYOUT.WINDOW_HEIGHT or 640
        sessionPanel:SetHeight(math.max(140, math.floor(fh * SESSION_FRAC)))
    end
    if ApplyVisuals then
        ApplyVisuals(sessionPanel, COLORS.bgCard, { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.38 })
    end

    local labSes = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    labSes:SetPoint("BOTTOMLEFT", sessionPanel, "TOPLEFT", 4, 5)
    labSes:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])
    self.sessionSectionLabel = labSes
    do
        local fmt = (L and L["LOOT_SECTION_SESSION_FMT"]) or "Last %d pickups"
        labSes:SetFormattedText(fmt, GetLastLootListCap())
    end
    local labEff = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    labEff:SetPoint("BOTTOMRIGHT", sessionPanel, "TOPRIGHT", -4, 5)
    labEff:SetJustifyH("RIGHT")
    labEff:SetText("")
    labEff:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3], 1)
    self.sessionEfficiencyLabel = labEff

    local refRow = CreateFrame("Frame", nil, f)
    refRow:SetPoint("TOPLEFT", resetRow, "BOTTOMLEFT", 0, -8)
    refRow:SetPoint("TOPRIGHT", resetRow, "BOTTOMRIGHT", 0, -8)
    refRow:SetHeight(22)

    local labRef = refRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    labRef:SetPoint("LEFT", refRow, "LEFT", 0, 0)
    labRef:SetJustifyH("LEFT")
    labRef:SetText((L and L["LOOT_SECTION_REFERENCE"]) or "Catalog")
    labRef:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])

    local labTotal = refRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    labTotal:SetPoint("RIGHT", refRow, "RIGHT", 0, 0)
    labTotal:SetJustifyH("RIGHT")
    labTotal:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])
    local totalFmt = (L and L["LOOT_SECTION_TOTAL_FMT"]) or "Total: %s"
    labTotal:SetFormattedText(totalFmt, "0c")
    labRef:SetPoint("RIGHT", labTotal, "LEFT", -8, 0)
    self.catalogTotalLabel = labTotal

    local catalogPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
    catalogPanel:SetPoint("TOPLEFT", refRow, "BOTTOMLEFT", 0, -4)
    catalogPanel:SetPoint("TOPRIGHT", refRow, "BOTTOMRIGHT", 0, -4)
    catalogPanel:SetPoint("BOTTOM", labSes, "TOP", 0, 6)
    if ApplyVisuals then
        ApplyVisuals(catalogPanel, COLORS.bgCard, { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.38 })
    end

    local catScroll = CreateFrame("ScrollFrame", nil, catalogPanel, "UIPanelScrollFrameTemplate")
    catScroll:SetPoint("TOPLEFT", 8, -8)
    catScroll:SetPoint("BOTTOMRIGHT", -28, 10)
    local catContent = CreateFrame("Frame", nil, catScroll)
    catScroll:SetScrollChild(catContent)
    self.catalogScroll = catScroll
    self.catalogContent = catContent

    local sesScroll = CreateFrame("ScrollFrame", nil, sessionPanel, "UIPanelScrollFrameTemplate")
    sesScroll:SetPoint("TOPLEFT", 8, -8)
    sesScroll:SetPoint("BOTTOMRIGHT", -28, 10)
    local sesContent = CreateFrame("Frame", nil, sesScroll)
    sesScroll:SetScrollChild(sesContent)
    self.sessionScroll = sesScroll
    self.sessionContent = sesContent
    self.sessionPanel = sessionPanel

    local grip = CreateFrame("Button", nil, f)
    grip:SetFrameLevel(f:GetFrameLevel() + 20)
    grip:SetSize(18, 18)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 5)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        LootHistoryUI._isLootFrameSizing = true
        f:StartSizing("BOTTOMRIGHT")
        f:SetScript("OnUpdate", LootFrameSizingPoll)
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        FinishLootFrameSizing()
    end)
    self.resizeGrip = grip

    self.main = f
    f:SetScript("OnShow", function()
        local rbW, rbH = GetLootFrameBounds()
        if f.SetResizeBounds then
            pcall(function()
                f:SetResizeBounds(LOOT_MIN_W, LOOT_MIN_H, rbW, rbH)
            end)
        elseif f.SetMaxResize then
            f:SetMaxResize(rbW, rbH)
        end
        LootHistoryUI:LayoutTabs()
    end)
    LootHistoryUI:LayoutTabs()
    LootHistoryUI:LayoutModeBtns()
    self:Refresh()
    f:Show()
end

function LootHistoryUI:Hide()
    self._isLootFrameSizing = false
    if self.main then
        self.main:SetScript("OnUpdate", nil)
    end
    if self._sizeSaveTimer and self._sizeSaveTimer.Cancel then
        pcall(function()
            self._sizeSaveTimer:Cancel()
        end)
        self._sizeSaveTimer = nil
    end
    if self.main then
        self.main:Hide()
    end
end

function LootHistoryUI:Toggle()
    if self.main and self.main:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end

local function RefreshIfVisible()
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return
    end
    if LootHistoryUI.main and LootHistoryUI.main:IsShown() then
        LootHistoryUI:Refresh()
    end
end

--- Payload: `nil` (session reset), legacy string tab, or policy table from `SessionLootService:Emit*LootTabSignal`.
--- Single-profession batch → switch to that tab when the window is open (or open to it when auto-open).
--- Multi-profession batch → keep current tab; other tabs get attention glow (handled before this message).
local function OnSessionLootUpdated(_, payload)
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return
    end
    local prof = ns.db and ns.db.profile
    if prof and prof.lootHistoryEnabled == false then
        if LootHistoryUI.main and LootHistoryUI.main:IsShown() then
            LootHistoryUI:Refresh()
        end
        return
    end
    --- Login `ResetSession` and tab resets send `SESSION_LOOT_UPDATED` with no policy — must not open the window.
    if payload == nil then
        if LootHistoryUI.main and LootHistoryUI.main:IsShown() then
            LootHistoryUI:Refresh()
        end
        return
    end
    local main = LootHistoryUI.main
    local visible = main and main:IsShown()
    local autoOpen = prof and prof.lootHistoryAutoOpen

    local singleTab = nil
    if type(payload) == "table" then
        if payload.multi then
            if visible then
                LootHistoryUI:Refresh()
            elseif autoOpen then
                LootHistoryUI:Show()
            end
            return
        end
        if type(payload.singleTab) == "string" and payload.singleTab ~= "" then
            singleTab = payload.singleTab
        end
    elseif type(payload) == "string" and payload ~= "" then
        singleTab = payload
    end

    if singleTab and IsValidTab(singleTab) then
        if visible then
            --- Loot → switch tab only when needed; same tab still refreshes pickup list + catalog.
            if LootHistoryUI.activeTab == singleTab then
                if ns.SessionLootService and ns.SessionLootService.ClearTabAttentionForTab then
                    ns.SessionLootService:ClearTabAttentionForTab(singleTab)
                end
                LootHistoryUI:Refresh()
            else
                LootHistoryUI:SetTab(singleTab)
            end
        elseif autoOpen then
            LootHistoryUI:Show(singleTab)
        end
        return
    end

    if visible then
        LootHistoryUI:Refresh()
    elseif autoOpen then
        LootHistoryUI:Show()
    end
end

function LootHistoryUI:Init()
    local saved = ns.db and ns.db.profile and ns.db.profile.lootHistoryActiveTab
    if saved and IsValidTab(saved) then
        LootHistoryUI.activeTab = saved
    end
    ArtisanNexus:RegisterMessage(E.FISHING_HISTORY_UPDATED, RefreshIfVisible)
    ArtisanNexus:RegisterMessage(E.GATHERING_HISTORY_UPDATED, RefreshIfVisible)
    ArtisanNexus:RegisterMessage(E.LOOT_HISTORY_UPDATED, RefreshIfVisible)
    ArtisanNexus:RegisterMessage(E.SESSION_LOOT_UPDATED, OnSessionLootUpdated)
    ArtisanNexus:RegisterMessage(E.AH_PRICES_UPDATED, RefreshIfVisible)
end

ns.LootHistoryUI = LootHistoryUI
