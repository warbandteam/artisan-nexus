--[[
    Session loot: last 10 events; one top-level tab per profession (fish + herb/mine/leather/DE).
    Reference: reagent icon | quality-tier atlases (R1–R5) + x(amount) — responsive grid.
    Session row: icon · qty · profession rank atlas · name (rarity color).
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
local SetProfessionRankAtlas = ns.SetProfessionRankAtlas
local GetCatalogRankIndexForItem = ns.GetCatalogRankIndexForItem

local ROW_H = (LAYOUT.ROW_HEIGHT or 30) + 6
local ICON_SZ = (LAYOUT.ICON_SIZE or 28) + 2
local RANK_ATLAS_SZ = 18
local CAT_SZ = LAYOUT.CATALOG_ICON or 36
local PAD = LAYOUT.BASE_INDENT or 12
local LOOT_MIN_W = LAYOUT.LOOT_FRAME_MIN_WIDTH or 300
local LOOT_MIN_H = LAYOUT.LOOT_FRAME_MIN_HEIGHT or 380
local LOOT_MAX_W = LAYOUT.LOOT_FRAME_MAX_WIDTH or 900
local LOOT_MAX_H = LAYOUT.LOOT_FRAME_MAX_HEIGHT or 900

local GetQualityRGB = ns.GetQualityRGB or function()
    return 1, 1, 1
end

local MAX_QUALITY_TIERS = (ns.PROFESSION_QUALITY_MAX_TIER) or 5

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

--- Top-level tabs: fishing + four gathering professions (each has its own catalog + session slice).
local TAB_ORDER = { "fishing", "herb", "mine", "leather", "disenchant" }

local function TexForItem(itemID)
    local fileID = C_Item.GetItemIconByID(itemID)
    return (fileID and fileID > 0) and fileID or "Interface\\Icons\\INV_Misc_QuestionMark"
end

---@class FishingHistoryUI
local LootHistoryUI = {
    main = nil,
    activeTab = "fishing",
    catalogContent = nil,
    sessionContent = nil,
    catalogScroll = nil,
    sessionScroll = nil,
    sessionPanel = nil,
    tabBar = nil,
    tabButtons = {},
    resizeGrip = nil,
    _sizeSaveTimer = nil,
}

local function ClearScrollContent(scroll, content)
    if not content then return end
    local regions = { content:GetRegions() }
    for i = 1, #regions do
        regions[i]:Hide()
        regions[i]:SetParent(nil)
    end
    local ch = { content:GetChildren() }
    for i = 1, #ch do
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

local SESSION_FRAC = 0.38

function LootHistoryUI:LayoutTabs()
    if not self.main or not self.tabBar or not self.tabButtons then
        return
    end
    local w = self.tabBar:GetWidth()
    if not w or w < 80 then
        return
    end
    local gap = 5
    local n = #TAB_ORDER
    local btnW = math.max(56, math.floor((w - (n - 1) * gap) / n))
    for i = 1, n do
        local key = TAB_ORDER[i]
        local b = self.tabButtons[key]
        if b then
            b:ClearAllPoints()
            b:SetSize(btnW, 28)
            b:SetPoint("TOPLEFT", self.tabBar, "TOPLEFT", (i - 1) * (btnW + gap), 0)
        end
    end
end

function LootHistoryUI:OnLootFrameSizeChanged()
    if self.main and self.sessionPanel then
        local fh = self.main:GetHeight() or 668
        self.sessionPanel:SetHeight(math.max(140, math.floor(fh * SESSION_FRAC)))
    end
    self:LayoutTabs()
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

--- Reagent icon (left); R1 + R2 profession atlases stacked (right); amounts x(N) in white. Responsive grid.
local function PopulateCatalog(content, entries, totals)
    totals = totals or {}
    if not CreateIcon or not ResolveRanks then return end

    local innerW = content:GetWidth()
    if not innerW or innerW < 100 then innerW = 360 end
    local cols = CatalogColumnCount(innerW)
    local gapX = 8
    local cellW = math.max(100, math.floor((innerW - gapX * (cols - 1)) / cols))
    local rowLineH = 20
    local atlasSz = 16
    local fmt = (L and L["LOOT_REF_TOTAL_FMT"]) or "x(%d)"

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

    for idx = 1, n do
        local entry = entries[idx]
        local ranks = ResolveRanks(entry)
        if #ranks < 1 and entry.id then
            ranks = { entry.id }
        end
        local row = math.floor((idx - 1) / cols)
        local col = (idx - 1) % cols
        local showRanks = math.min(MAX_QUALITY_TIERS, #ranks)
        local cellH = 8 + math.max(CAT_SZ, showRanks * rowLineH) + 8

        if #ranks < 1 then
            local empty = CreateFrame("Frame", nil, content)
            empty:SetSize(cellW, cellH)
            empty:SetPoint("TOPLEFT", content, "TOPLEFT", col * (cellW + gapX), -row * (cellH + gapX))
        else
            local cellFrame = CreateFrame("Frame", nil, content)
            cellFrame:SetSize(cellW, cellH)
            cellFrame:SetPoint("TOPLEFT", content, "TOPLEFT", col * (cellW + gapX), -row * (cellH + gapX))

            local iconId = ranks[1]
            local ic = CreateIcon(cellFrame, TexForItem(iconId), CAT_SZ, false, nil, false)
            if ic then
                ic:SetPoint("TOPLEFT", cellFrame, "TOPLEFT", 4, -6)
                ic:Show()
                AttachItemTooltip(ic, iconId)
            end

            local blockH = showRanks * rowLineH
            local rankBlock = CreateFrame("Frame", nil, cellFrame)
            rankBlock:SetSize(cellW - CAT_SZ - 14, blockH)
            if ic then
                --- Snap to icon’s right; stack vertically centered on the icon (WoW: +y is up).
                rankBlock:SetPoint("LEFT", ic, "RIGHT", 8, 0)
                rankBlock:SetPoint("TOP", ic, "TOP", 0, (blockH - CAT_SZ) / 2)
            else
                rankBlock:SetPoint("TOPLEFT", cellFrame, "TOPLEFT", 4 + CAT_SZ, -6)
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
                if SetProfessionRankAtlas then
                    --- `r` = tier index in catalog (1–5), not item id — maps to Professions-Quality-TierN atlases.
                    SetProfessionRankAtlas(tex, r, atlasSz, atlasSz)
                else
                    tex:Hide()
                end

                local cnt = totals[rid] or 0
                local cntStr = line:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                cntStr:SetJustifyH("LEFT")
                cntStr:SetFormattedText(fmt, cnt)
                cntStr:SetTextColor(1, 1, 1)

                --- Left column: atlas + amount, vertically centered in the row (aligned to icon’s right edge).
                tex:SetPoint("CENTER", line, "LEFT", atlasSz / 2, 0)
                local tw = cntStr:GetStringWidth() or 0
                if tw < 1 then
                    tw = 24
                end
                cntStr:SetPoint("CENTER", line, "LEFT", atlasSz + 6 + tw / 2, 0)

                line:EnableMouse(true)
                AttachItemTooltip(line, rid)
            end
        end
    end

    local maxCellH = 8 + math.max(CAT_SZ, maxRankLines * rowLineH) + 8
    local gridW = cols * cellW + (cols - 1) * gapX
    local gridH = rows * maxCellH + math.max(0, rows - 1) * gapX + 12
    content:SetSize(gridW, gridH)
end

local function PopulateSessionList(content, events, catalogEntries)
    local y = 0
    local w = content:GetWidth() > 80 and content:GetWidth() or 360
    local maxN = math.min(10, #events)
    for i = 1, maxN do
        local e = events[i]
        if not e then break end
        local itemID = e.itemID
        local qty = e.qty or 1
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(w - 8, ROW_H)
        row:SetPoint("TOPLEFT", 2, -y)

        local tex = TexForItem(itemID)
        local iconFrame = CreateIcon and CreateIcon(row, tex, ICON_SZ, false, {
            COLORS.border[1],
            COLORS.border[2],
            COLORS.border[3],
            0.45,
        }, false)
        if iconFrame then
            iconFrame:SetPoint("LEFT", 0, 0)
            iconFrame:Show()
            AttachItemTooltip(iconFrame, itemID)
        end

        local countStr = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        countStr:SetPoint("LEFT", iconFrame or row, "RIGHT", 3, 0)
        countStr:SetWidth(40)
        countStr:SetJustifyH("RIGHT")
        countStr:SetText(tostring(qty) .. "×")
        countStr:SetTextColor(COLORS.textNormal[1], COLORS.textNormal[2], COLORS.textNormal[3])
        if countStr.SetFont then
            local f, s = countStr:GetFont()
            if f and s then
                countStr:SetFont(f, s + 2, "")
            end
        end

        local rankIdx = 1
        if GetCatalogRankIndexForItem then
            rankIdx = GetCatalogRankIndexForItem(itemID, catalogEntries)
        end
        local atlasRank = math.min(math.max(rankIdx, 1), MAX_QUALITY_TIERS)

        local rankHolder = CreateFrame("Frame", nil, row)
        rankHolder:SetSize(RANK_ATLAS_SZ, RANK_ATLAS_SZ)
        rankHolder:SetPoint("LEFT", countStr, "RIGHT", 2, 0)
        local rankTex = rankHolder:CreateTexture(nil, "ARTWORK")
        rankTex:SetAllPoints()
        local rankOk = SetProfessionRankAtlas and SetProfessionRankAtlas(rankTex, atlasRank, RANK_ATLAS_SZ, RANK_ATLAS_SZ)
        if not rankOk then
            rankHolder:SetWidth(2)
            rankTex:Hide()
        end

        local nameStr = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        nameStr:SetPoint("LEFT", rankHolder, "RIGHT", 3, 0)
        nameStr:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        nameStr:SetJustifyH("LEFT")

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
        if nameStr.SetFont then
            local f, s = nameStr:GetFont()
            if f and s then
                nameStr:SetFont(f, s + 2, "")
            end
        end

        y = y + ROW_H + 2
    end
    if maxN == 0 then
        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        empty:SetPoint("TOPLEFT", 8, -6)
        empty:SetText((L and L["LOOT_SESSION_EMPTY"]) or "No recent loot this session.")
        empty:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3])
        y = 28
    end
    content:SetSize(w, math.max(y + 8, 40))
end

function LootHistoryUI:Refresh()
    if not self.main or not self.catalogContent or not self.sessionContent then return end

    local svc = ns.SessionLootService
    local entries
    if self.activeTab == "fishing" then
        entries = (ns.GetFishingCatalogEntries and ns.GetFishingCatalogEntries()) or {}
    else
        entries = (ns.GetGatheringCatalogByCategory and ns.GetGatheringCatalogByCategory(self.activeTab)) or {}
    end

    local events = {}
    if svc then
        if self.activeTab == "fishing" then
            events = svc:GetRecentEvents("fishing") or {}
        else
            events = svc:GetRecentEvents("gathering", self.activeTab) or {}
        end
    end

    ClearScrollContent(self.catalogScroll, self.catalogContent)
    ClearScrollContent(self.sessionScroll, self.sessionContent)

    local cw = math.max((self.catalogScroll and self.catalogScroll:GetWidth()) or 360, 280)
    self.catalogContent:SetWidth(cw)

    local totals = {}
    if svc and svc.GetItemTotals then
        if self.activeTab == "fishing" then
            totals = svc:GetItemTotals("fishing") or {}
        else
            totals = svc:GetItemTotals("gathering", self.activeTab) or {}
        end
    end
    PopulateCatalog(self.catalogContent, entries, totals)

    local sw = math.max((self.sessionScroll and self.sessionScroll:GetWidth()) or 360, 280)
    self.sessionContent:SetWidth(sw)
    PopulateSessionList(self.sessionContent, events, entries)

end

local function StyleTabButton(btn, selected)
    if not btn or not ApplyVisuals then return end
    local bg = selected and COLORS.tabActive or COLORS.tabInactive
    local br = selected and { COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.78 }
        or { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.32 }
    ApplyVisuals(btn, bg, br)
    local fs = btn:GetFontString()
    if fs then
        if selected then
            fs:SetTextColor(COLORS.textBright[1], COLORS.textBright[2], COLORS.textBright[3])
        else
            fs:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3])
        end
    end
end

local function IsValidTab(tab)
    for i = 1, #TAB_ORDER do
        if TAB_ORDER[i] == tab then
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
    if self.tabButtons then
        for k, btn in pairs(self.tabButtons) do
            StyleTabButton(btn, k == tab)
        end
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
    if IsValidTab(which) then
        return which
    end
    return nil
end

function LootHistoryUI:Show(which)
    local w = NormalizeShowArg(which)
    if w then
        self.activeTab = w
    end
    if self.main then
        self.main:Show()
        if self.sessionPanel then
            local fh = self.main:GetHeight() or LAYOUT.WINDOW_HEIGHT or 640
            self.sessionPanel:SetHeight(math.max(140, math.floor(fh * SESSION_FRAC)))
        end
        if self.tabButtons then
            for k, btn in pairs(self.tabButtons) do
                StyleTabButton(btn, k == self.activeTab)
            end
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
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
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

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText((L and L["LOOT_HISTORY_TITLE"]) or "Session loot")
    title:SetTextColor(COLORS.accent[1], COLORS.accent[2], COLORS.accent[3])

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function()
        f:Hide()
    end)

    local labels = {
        fishing = (L and L["LOOT_TAB_FISHING"]) or "Fishing",
        herb = (L and L["LOOT_GATHER_HERB"]) or "Herbalism",
        mine = (L and L["LOOT_GATHER_MINE"]) or "Mining",
        leather = (L and L["LOOT_GATHER_LEATHER"]) or "Leather",
        disenchant = (L and L["LOOT_GATHER_DE"]) or "Disenchant",
    }

    local tabBar = CreateFrame("Frame", nil, f)
    tabBar:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -38)
    tabBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -38)
    tabBar:SetHeight(30)
    self.tabBar = tabBar

    self.tabButtons = {}
    for i = 1, #TAB_ORDER do
        local key = TAB_ORDER[i]
        local b = CreateFrame("Button", nil, f, "BackdropTemplate")
        b:SetParent(tabBar)
        b:SetHeight(28)
        local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetAllPoints()
        t:SetText(labels[key] or key)
        b:SetFontString(t)
        b:SetScript("OnClick", function()
            LootHistoryUI:SetTab(key)
        end)
        self.tabButtons[key] = b
        StyleTabButton(b, key == self.activeTab)
    end

    local resetBtn = CreateFrame("Button", nil, f, "BackdropTemplate")
    resetBtn:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, -8)
    resetBtn:SetPoint("TOPRIGHT", tabBar, "BOTTOMRIGHT", 0, -8)
    resetBtn:SetHeight(26)
    local resetText = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    resetText:SetAllPoints()
    resetText:SetText((L and L["LOOT_RESET_SESSION"]) or "Reset session")
    resetBtn:SetFontString(resetText)
    resetBtn:SetScript("OnClick", function()
        if ns.SessionLootService and ns.SessionLootService.ResetSession then
            ns.SessionLootService:ResetSession()
        end
        LootHistoryUI:Refresh()
    end)
    if ApplyVisuals then
        ApplyVisuals(resetBtn, COLORS.tabInactive, { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.35 })
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

    local labSes = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    labSes:SetPoint("BOTTOMLEFT", sessionPanel, "TOPLEFT", 4, 8)
    labSes:SetText((L and L["LOOT_SECTION_SESSION"]) or "Last loot (10)")
    labSes:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3])

    local labRef = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    labRef:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, -10)
    labRef:SetPoint("TOPRIGHT", resetBtn, "BOTTOMRIGHT", 0, -10)
    labRef:SetHeight(14)
    labRef:SetJustifyH("LEFT")
    labRef:SetText((L and L["LOOT_SECTION_REFERENCE"]) or "Reference")
    labRef:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3])

    local catalogPanel = CreateFrame("Frame", nil, f, "BackdropTemplate")
    catalogPanel:SetPoint("TOPLEFT", labRef, "BOTTOMLEFT", 0, -8)
    catalogPanel:SetPoint("TOPRIGHT", labRef, "BOTTOMRIGHT", 0, -8)
    catalogPanel:SetPoint("BOTTOM", labSes, "TOP", 0, 10)
    if ApplyVisuals then
        ApplyVisuals(catalogPanel, COLORS.bgCard, { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.38 })
    end

    local catScroll = CreateFrame("ScrollFrame", nil, catalogPanel, "UIPanelScrollFrameTemplate")
    catScroll:SetPoint("TOPLEFT", 10, -10)
    catScroll:SetPoint("BOTTOMRIGHT", -30, 12)
    local catContent = CreateFrame("Frame", nil, catScroll)
    catScroll:SetScrollChild(catContent)
    self.catalogScroll = catScroll
    self.catalogContent = catContent

    local sesScroll = CreateFrame("ScrollFrame", nil, sessionPanel, "UIPanelScrollFrameTemplate")
    sesScroll:SetPoint("TOPLEFT", 10, -10)
    sesScroll:SetPoint("BOTTOMRIGHT", -30, 12)
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
        f:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        LootHistoryUI:SaveFrameSize()
    end)
    self.resizeGrip = grip

    self.main = f
    if self.tabButtons then
        for k, btn in pairs(self.tabButtons) do
            StyleTabButton(btn, k == self.activeTab)
        end
    end
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
    self:Refresh()
    f:Show()
end

function LootHistoryUI:Hide()
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
    if LootHistoryUI.main and LootHistoryUI.main:IsShown() then
        LootHistoryUI:Refresh()
    end
end

function LootHistoryUI:Init()
    ArtisanNexus:RegisterMessage(E.FISHING_HISTORY_UPDATED, RefreshIfVisible)
    ArtisanNexus:RegisterMessage(E.GATHERING_HISTORY_UPDATED, RefreshIfVisible)
    ArtisanNexus:RegisterMessage(E.LOOT_HISTORY_UPDATED, RefreshIfVisible)
    ArtisanNexus:RegisterMessage(E.SESSION_LOOT_UPDATED, RefreshIfVisible)
end

ns.FishingHistoryUI = LootHistoryUI
