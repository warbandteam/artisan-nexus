--[[
    Session Loot window body painters (catalog grid + "Last N pickups" list), Warband Nexus
    components only:

      catalog cell   -> ns.UI_CreateCard (standard elevated card chrome) + ns.UI_CreateIcon
                        (WN icon well) + profession quality atlases with count / value columns
                        (RecipeCompanionWindow.lua:398-436 RenderQualityColumns)
      pickup row     -> Factory:ApplyRowBackground striped data row (RecipeCompanionWindow.lua
                        RenderContent / Factory:CreateDataRow) + ns.UI_CreateIcon + body text
      fresh pickup   -> Factory:ApplyOnlineCharacterHighlight (accent row tint + accent edge)
      catalog glow   -> card border eased toward the hover accent border (ns.UI_UpdateBorderColor)
      empty message  -> PlansTrackerWindow.lua:1528-1555 pooled Dim body line (one per window)

    WoW frames are never garbage collected, so every cell / row / line is pooled on its content
    frame (content._anPools) and reconfigured on each paint.
]]
local ADDON_NAME, ns = ...

-- 12.1.5 removed the global item/coin fallbacks; bind the namespaced APIs.
local GetItemInfo = C_Item.GetItemInfo

local SetProfessionRankAtlasForItem = ns.SetProfessionRankAtlasForItem
local SetProfessionRankAtlas = ns.SetProfessionRankAtlas
local GetCatalogRankIndexForItem = ns.GetCatalogRankIndexForItem
local GetQualityRGB = ns.GetQualityRGB or function()
    return 1, 1, 1
end

local Draw = {}
ns.LootHistoryUIDraw = Draw

local function LT(key, fallback)
    return (ns.L and ns.L[key]) or fallback
end

local function Factory()
    return ns.UI and ns.UI.Factory
end

local function FontManager()
    return ns.FontManager
end

-- Window-specific metrics (Session Loot grid / list).
local ROW_H = 28                 -- pickup row (WN STORAGE_ROW_HEIGHT band: icon + coin icons)
local ROW_ICON = 22
local RANK_ATLAS_SZ = 20
local ROW_GAP = 2
local ROW_PAD = 6
local COIN_ICON_H = 12
local CAT_SZ = 40                -- catalog icon well
local MAX_QUALITY_TIERS = (ns.PROFESSION_QUALITY_MAX_TIER) or 5
local CELL_PAD = 8
local GRID_GAP = 6
local GRID_SIDE_PAD = 4
local CATALOG_MAX_COLS = 2
local MIN_VALUE_W = 72
local RANK_ICON_GAP = 6
local CHAR_LINE_H = 24
local EMPTY_H = 50

local FormatCopper = ns.FormatCopper
--- Resolves exactly like ns.GetLootValueCopper (current market unit), so rows (unit x qty =
--- gross) match the window's gross Total and the overlay.
local LootUnitCopper = ns.GetLootUnitCopperWithFallback

local function TexForItem(itemID)
    if not itemID or not C_Item or not C_Item.GetItemIconByID then
        return "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    local fileID = C_Item.GetItemIconByID(itemID)
    return (fileID and fileID > 0) and fileID or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function NewFS(parent, role, colorRole)
    local fs = FontManager():CreateFontString(parent, role or "body", "OVERLAY")
    if colorRole then
        ns.UI_SetTextColorRole(fs, colorRole)
    end
    return fs
end

-- Shared handlers read frame._anItemID so pooled cells get no new closures per refresh.
local function ItemTooltipOnEnter(self)
    local itemID = self._anItemID
    if not itemID or IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
        return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(itemID)
    GameTooltip:Show()
end

local function ItemTooltipOnLeave()
    GameTooltip:Hide()
end

local function ItemTooltipOnMouseUp(self, btn)
    local itemID = self._anItemID
    if itemID and btn == "LeftButton" and IsModifiedClick and IsModifiedClick() and HandleModifiedItemClick then
        -- Uncached item: no hyperlink yet; a bare "item:" string would paste as plain text.
        local link = select(2, GetItemInfo(itemID))
        if link then
            HandleModifiedItemClick(link)
        end
    end
end

local function AttachItemTooltip(frame, itemID)
    if not frame or type(itemID) ~= "number" or itemID < 1 then
        return
    end
    frame:EnableMouse(true)
    frame._anItemID = itemID
    frame:SetScript("OnEnter", ItemTooltipOnEnter)
    frame:SetScript("OnLeave", ItemTooltipOnLeave)
    frame:SetScript("OnMouseUp", ItemTooltipOnMouseUp)
end

local function DetachItemTooltip(frame)
    if not frame then return end
    frame._anItemID = nil
    frame:SetScript("OnEnter", nil)
    frame:SetScript("OnLeave", nil)
    frame:SetScript("OnMouseUp", nil)
end

-- ── Pools ──

local function ContentPool(content, key)
    local pools = content._anPools
    if not pools then
        pools = {}
        content._anPools = pools
    end
    local pool = pools[key]
    if not pool then
        pool = { free = {}, used = {} }
        pools[key] = pool
    end
    return pool
end

local function PoolAcquire(pool, createFn, ...)
    local nFree = #pool.free
    local frame = pool.free[nFree]
    if frame then
        pool.free[nFree] = nil
    else
        frame = createFn(...)
    end
    pool.used[#pool.used + 1] = frame
    return frame
end

local function PoolReleaseAll(pool, resetFn)
    local used = pool.used
    for i = #used, 1, -1 do
        local frame = used[i]
        if resetFn then
            resetFn(frame)
        end
        frame:Hide()
        pool.free[#pool.free + 1] = frame
        used[i] = nil
    end
end

local function ForEachPooled(content, key, fn)
    local pool = content and content._anPools and content._anPools[key]
    if not pool then return end
    for i = 1, #pool.used do fn(pool.used[i]) end
    for i = 1, #pool.free do fn(pool.free[i]) end
end

-- ── Empty message (PlansTrackerWindow.lua:1528-1555) ──

local function ShowEmptyMessage(content, width, text)
    local F = Factory()
    local emptyFrame = content._anEmptyFrame
    if not emptyFrame then
        emptyFrame = (F and F.CreateContainer and F:CreateContainer(content, width, EMPTY_H, false))
            or CreateFrame("Frame", nil, content)
        local fs = FontManager():CreateFontString(emptyFrame, "body", "OVERLAY")
        fs:SetPoint("TOPLEFT", emptyFrame, "TOPLEFT", 0, -12)
        fs:SetWordWrap(true)
        fs:SetJustifyH("CENTER")
        emptyFrame._anEmptyText = fs
        content._anEmptyFrame = emptyFrame
    end
    emptyFrame:ClearAllPoints()
    emptyFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    emptyFrame:SetSize(math.max(1, width), EMPTY_H)
    local fs = emptyFrame._anEmptyText
    fs:SetWidth(math.max(1, width))
    local hex = (ns.UI_GetTextRoleHex and ns.UI_GetTextRoleHex("Dim")) or "|cff666666"
    fs:SetText(hex .. (text or "") .. "|r")
    emptyFrame:Show()
    return math.max(EMPTY_H, (fs:GetStringHeight() or 0) + 24)
end

local function HideEmptyMessage(content)
    if content and content._anEmptyFrame then
        content._anEmptyFrame:Hide()
    end
end

-- ── Catalog grid ──

local function CatalogCellWidthForCols(usableW, cols)
    if not usableW or usableW < 1 or not cols or cols < 1 then
        return usableW or 1
    end
    return math.floor(math.max(1, usableW - GRID_GAP * (cols - 1)) / cols)
end

local function AtlasSize()
    return math.max(20, math.floor(CAT_SZ * 0.46))
end

local function RowLineHeight()
    return math.max(24, math.floor(CAT_SZ * 0.55))
end

local function CatalogMinCellWidth()
    local minRankLineW = AtlasSize() + 4 + 36 + 4 + MIN_VALUE_W
    return CELL_PAD * 2 + CAT_SZ + RANK_ICON_GAP + minRankLineW
end

local function CatalogColumnCount(usableW)
    if not usableW or usableW < 1 then
        return 1
    end
    local minCellW = CatalogMinCellWidth()
    for cols = CATALOG_MAX_COLS, 1, -1 do
        if CatalogCellWidthForCols(usableW, cols) >= minCellW then
            return cols
        end
    end
    return 1
end

local function CatalogRankBlockWidth(cellW)
    return math.max(52, cellW - CAT_SZ - RANK_ICON_GAP - CELL_PAD * 2)
end

local function CatalogCellHeight(lines, rowLineH)
    return CELL_PAD + math.max(CAT_SZ, lines * rowLineH) + CELL_PAD
end

--- Vertically center the icon + rank block inside the card (row height may exceed this card's
--- own tier count when a neighbour in the same row is taller).
local function LayoutCatalogCellChrome(cell, cellH, lines, rowLineH, cellW)
    local ic, rankBlock = cell._icon, cell._rankBlock
    local blockH = lines * rowLineH
    local clusterH = math.max(CAT_SZ, blockH)
    local innerH = math.max(clusterH, cellH - CELL_PAD * 2)
    local clusterTop = CELL_PAD + math.max(0, math.floor((innerH - clusterH) * 0.5))
    local rankW = CatalogRankBlockWidth(cellW)
    local rankLeft = CELL_PAD + CAT_SZ + RANK_ICON_GAP
    rankBlock:SetSize(rankW, blockH)
    rankBlock:ClearAllPoints()
    ic:ClearAllPoints()
    if blockH > CAT_SZ then
        ic:SetPoint("TOPLEFT", cell, "TOPLEFT", CELL_PAD, -(clusterTop + math.floor((blockH - CAT_SZ) * 0.5)))
        rankBlock:SetPoint("TOPLEFT", cell, "TOPLEFT", rankLeft, -clusterTop)
    else
        ic:SetPoint("TOPLEFT", cell, "TOPLEFT", CELL_PAD, -clusterTop)
        rankBlock:SetPoint("TOPLEFT", cell, "TOPLEFT", rankLeft, -(clusterTop + math.floor((CAT_SZ - blockH) * 0.5)))
    end
    return rankW
end

--- Count + value inside one rank line (value column only when the count is > 0).
local function LayoutCatalogValueLine(line, lineW, showValue)
    local val, cnt, tex = line._val, line._cnt, line._tex
    local atlasW = AtlasSize() + 4
    local minCntW = 36
    cnt:ClearAllPoints()
    val:ClearAllPoints()
    if showValue then
        local valW = math.max(26, math.min(math.floor(lineW * 0.5), 120))
        if valW + atlasW + minCntW + 2 > lineW then
            valW = math.max(20, lineW - atlasW - minCntW - 2)
        end
        val:SetWidth(valW)
        val:SetPoint("RIGHT", line, "RIGHT", 0, 0)
        cnt:SetPoint("LEFT", tex, "RIGHT", 4, 0)
        cnt:SetPoint("RIGHT", val, "LEFT", -4, 0)
    else
        val:SetWidth(1)
        val:SetPoint("RIGHT", line, "RIGHT", 0, 0)
        cnt:SetPoint("LEFT", tex, "RIGHT", 4, 0)
        cnt:SetPoint("RIGHT", line, "RIGHT", 0, 0)
    end
end

--- Card border for a catalog cell: standard card stroke eased toward the hover accent border
--- by the reference-glow strength (0..1). Classic panels keep their Blizzard border.
local function ApplyCatalogCellGlow(cell, strength)
    if not cell or not ns.UI_UpdateBorderColor then return end
    if ns.UI_CanApplyCustomChrome and not ns.UI_CanApplyCustomChrome(cell) then return end
    if ns.UI_IsClassicMode and ns.UI_IsClassicMode() then return end
    strength = math.max(0, math.min(1, tonumber(strength) or 0))
    if strength < 0.04 then
        if cell._anGlowOn then
            cell._anGlowOn = nil
            if ns.UI_ApplyStandardCardElevatedChrome then
                ns.UI_ApplyStandardCardElevatedChrome(cell)
            end
        end
        return
    end
    local W = ns.ArtisanWindow
    local cc = W and W.GetCardColors and W.GetCardColors()
    if not cc then return end
    local u = strength * strength * (3 - 2 * strength)
    local a, b = cc.border, cc.hoverBorder
    ns.UI_UpdateBorderColor(cell, {
        a[1] + (b[1] - a[1]) * u,
        a[2] + (b[2] - a[2]) * u,
        a[3] + (b[3] - a[3]) * u,
        (a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * u,
    })
    cell._anGlowOn = true
end

local function GlowStrengthForIds(svc, tabKey, entryId, rankIds)
    if not svc or not tabKey or not svc.GetReferenceGlowStrength then
        return 0
    end
    local maxS = 0
    if entryId then
        maxS = svc:GetReferenceGlowStrength(entryId, tabKey) or 0
    end
    if rankIds then
        for i = 1, #rankIds do
            local s = svc:GetReferenceGlowStrength(rankIds[i], tabKey) or 0
            if s > maxS then maxS = s end
        end
    end
    return maxS
end

--- Fishing grid: caught items first (AH value desc, then unpriced); uncaught (x0) last.
local function SortFishingCatalogEntries(entries, totals)
    local Resolve = ns.ResolveCatalogEntryRanks
    if not Resolve or type(entries) ~= "table" or type(totals) ~= "table" then
        return entries
    end
    local sorted = {}
    for i = 1, #entries do
        sorted[i] = entries[i]
    end
    local function qtyPrimary(entry)
        local ranks = Resolve(entry)
        if not ranks or #ranks < 1 then
            if entry and entry.id then
                ranks = { entry.id }
            else
                return 0, nil
            end
        end
        local rid = ranks[1]
        if not rid then
            return 0, nil
        end
        local q = totals[rid] or totals[tostring(rid)] or 0
        return math.max(0, tonumber(q) or 0), rid
    end
    -- Decorate once: the comparator runs O(n log n) times and price lookups are not free.
    local keyQty, keyId, keyPrice = {}, {}, {}
    for i = 1, #sorted do
        local e = sorted[i]
        local q, rid = qtyPrimary(e)
        keyQty[e], keyId[e] = q, rid
        if q > 0 and rid then
            keyPrice[e] = LootUnitCopper(rid) or false
        end
    end
    table.sort(sorted, function(a, b)
        local qa, ida = keyQty[a], keyId[a]
        local qb, idb = keyQty[b], keyId[b]
        local ca, cb = qa > 0, qb > 0
        if ca ~= cb then
            return ca
        end
        if ca then
            local pa = keyPrice[a] or nil
            local pb = keyPrice[b] or nil
            local ha = pa and pa > 0
            local hb = pb and pb > 0
            if ha ~= hb then
                return ha
            end
            local va = (ha and qa * pa) or 0
            local vb = (hb and qb * pb) or 0
            if va ~= vb then
                return va > vb
            end
        end
        local na = (a and a.note) or ""
        local nb = (b and b.note) or ""
        if na ~= nb then
            return na < nb
        end
        return tostring(ida or 0) < tostring(idb or 0)
    end)
    return sorted
end

local function ResolveCatalogRanks(entry)
    if ns.ResolveCatalogEntryRanks then
        local r = ns.ResolveCatalogEntryRanks(entry)
        if r and #r > 0 then return r end
    elseif entry and type(entry.ranks) == "table" and #entry.ranks > 0 then
        return entry.ranks
    end
    if entry and entry.id then
        return { entry.id }
    end
    if entry and entry.itemID then
        return { entry.itemID }
    end
    return {}
end

--- Catalog card (created once per pool slot): WN card + icon well + rank block.
local function CreateCatalogCell(content)
    local cell = ns.UI_CreateCard(content, CAT_SZ + CELL_PAD * 2)
    local ic = ns.UI_CreateIcon(cell, nil, CAT_SZ)
    ic:SetPoint("TOPLEFT", cell, "TOPLEFT", CELL_PAD, -CELL_PAD)
    cell._icon = ic
    local rankBlock = CreateFrame("Frame", nil, cell)
    cell._rankBlock = rankBlock
    cell._lines = {}
    return cell
end

--- Rank line `r`: quality atlas + count + right-aligned value (RenderQualityColumns pattern).
local function GetCellLine(cell, r, rowLineH)
    local line = cell._lines[r]
    if line then
        return line
    end
    local atlasSz = AtlasSize()
    line = CreateFrame("Frame", nil, cell._rankBlock)
    line:SetPoint("TOPLEFT", cell._rankBlock, "TOPLEFT", 0, -(r - 1) * rowLineH)
    local tex = line:CreateTexture(nil, "ARTWORK")
    tex:SetSize(atlasSz, atlasSz)
    tex:SetPoint("LEFT", line, "LEFT", 0, 0)
    line._tex = tex
    -- Catalog line `r` maps to profession tier atlas r (not inferred from item APIs).
    line._rankOk = (SetProfessionRankAtlas and SetProfessionRankAtlas(tex, r, atlasSz, atlasSz)) and true or false
    if not line._rankOk then
        tex:Hide()
    end
    local val = NewFS(line, "body", "Normal")
    val:SetJustifyH("RIGHT")
    -- A money string wider than its column must not wrap into the next line.
    val:SetWordWrap(false)
    val:SetMaxLines(1)
    line._val = val
    local cnt = NewFS(line, "body", "Bright")
    cnt:SetJustifyH("LEFT")
    cnt:SetWordWrap(false)
    cnt:SetMaxLines(1)
    line._cnt = cnt
    cell._lines[r] = line
    return line
end

local function ResetCatalogCell(cell)
    DetachItemTooltip(cell._icon)
    for i = 1, #cell._lines do
        local line = cell._lines[i]
        line:Hide()
        DetachItemTooltip(line)
    end
    cell._glowEntryId, cell._glowRankIds = nil, nil
end

---@param tabKey string|nil active tab (reference glow)
---@param innerW number|nil scroll viewport width
local function PopulateCatalog(content, entries, totals, tabKey, innerW)
    totals = totals or {}
    entries = entries or {}
    innerW = tonumber(innerW) or content:GetWidth() or 0
    if innerW < 1 then innerW = 280 end

    local function qtyForItem(id)
        if not id then return 0 end
        local q = totals[id]
        if q then return tonumber(q) or 0 end
        if type(id) == "number" then
            return tonumber(totals[tostring(id)]) or 0
        end
        return tonumber(totals[tonumber(id)]) or 0
    end

    local n = #entries
    if n < 1 then
        local msg
        if tabKey == "crafted" then
            msg = LT("LOOT_CRAFTED_HINT", "Crafted items appear here.")
        else
            msg = LT("LOOT_SESSION_EMPTY", "Nothing collected this session yet.")
        end
        local h = ShowEmptyMessage(content, innerW, msg)
        content:SetSize(innerW, h)
        return
    end
    HideEmptyMessage(content)

    local usableW = math.max(1, innerW - GRID_SIDE_PAD * 2)
    local cols = CatalogColumnCount(usableW)
    local availForCells = math.max(1, usableW - GRID_GAP * (cols - 1))
    local baseCellW = math.floor(availForCells / cols)
    local remPx = availForCells - baseCellW * cols
    local function CellWidthForCol(col0)
        return baseCellW + ((col0 + 1) <= remPx and 1 or 0)
    end
    local colLeft = {}
    local xAcc = GRID_SIDE_PAD
    for col0 = 0, cols - 1 do
        colLeft[col0] = xAcc
        xAcc = xAcc + CellWidthForCol(col0) + GRID_GAP
    end
    local rowLineH = RowLineHeight()
    local fmt = LT("LOOT_REF_TOTAL_FMT", "×%d")
    local rows = math.max(1, math.ceil(n / cols))

    -- Per-row card height: only the tiers present in THAT row.
    local entryRanks, rowMaxLines = {}, {}
    for r = 0, rows - 1 do
        rowMaxLines[r] = 1
    end
    for idx = 1, n do
        local ranks = ResolveCatalogRanks(entries[idx])
        entryRanks[idx] = ranks
        if #ranks >= 1 then
            local row = math.floor((idx - 1) / cols)
            rowMaxLines[row] = math.max(rowMaxLines[row], math.min(MAX_QUALITY_TIERS, #ranks))
        end
    end
    local rowH, rowY = {}, {}
    local yAcc = 0
    for r = 0, rows - 1 do
        rowH[r] = CatalogCellHeight(rowMaxLines[r], rowLineH)
        rowY[r] = yAcc
        yAcc = yAcc + rowH[r] + GRID_GAP
    end

    local svc = ns.SessionLootService
    local cellPool = ContentPool(content, "cell")
    local noPrice = LT("LOOT_CATALOG_AH_EMPTY", "—")

    for idx = 1, n do
        local entry = entries[idx]
        local ranks = entryRanks[idx]
        if #ranks >= 1 then
            local row = math.floor((idx - 1) / cols)
            local col = (idx - 1) % cols
            local lines = math.min(MAX_QUALITY_TIERS, #ranks)
            local cellW = CellWidthForCol(col)
            local cellH = rowH[row]

            local cell = PoolAcquire(cellPool, CreateCatalogCell, content)
            cell._glowEntryId = entry and (entry.id or entry.itemID) or nil
            cell._glowRankIds = ranks
            cell:SetSize(cellW, cellH)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", content, "TOPLEFT", colLeft[col], -rowY[row])
            cell:Show()

            local ic = cell._icon
            ic.texture:SetTexture(TexForItem(ranks[1]))
            ic.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            ic:Show()
            AttachItemTooltip(ic, ranks[1])
            ApplyCatalogCellGlow(cell, GlowStrengthForIds(svc, tabKey, cell._glowEntryId, ranks))

            local rankW = LayoutCatalogCellChrome(cell, cellH, lines, rowLineH, cellW)
            for r = 1, lines do
                local rid = ranks[r]
                local line = GetCellLine(cell, r, rowLineH)
                line:SetSize(rankW, rowLineH)
                line:Show()
                line._tex:SetShown(line._rankOk)
                local cnt = qtyForItem(rid)
                LayoutCatalogValueLine(line, rankW, cnt > 0)
                line._cnt:SetFormattedText(fmt, cnt)
                ns.UI_SetTextColorRole(line._cnt, cnt > 0 and "Bright" or "Dim")
                local val = line._val
                if cnt > 0 then
                    local unit = LootUnitCopper(rid)
                    if unit and unit > 0 then
                        val:SetText(FormatCopper(cnt * unit, COIN_ICON_H) or "")
                        ns.UI_SetTextColorRole(val, "Normal")
                    else
                        val:SetText(noPrice)
                        ns.UI_SetTextColorRole(val, "Dim")
                    end
                    val:Show()
                else
                    val:Hide()
                end
                AttachItemTooltip(line, rid)
            end
            for r = lines + 1, #cell._lines do
                cell._lines[r]:Hide()
            end
        end
    end

    local gridH = rowY[rows - 1] + rowH[rows - 1] + GRID_SIDE_PAD
    content:SetSize(innerW, gridH)
end

--- Glow fade only (SessionLootService glow ticker, ~3 Hz): no grid rebuild.
local function RefreshCatalogGlowStrengths(content, tabKey)
    local pool = content and content._anPools and content._anPools.cell
    local svc = ns.SessionLootService
    if not pool or not tabKey or not svc then
        return
    end
    for i = 1, #pool.used do
        local cell = pool.used[i]
        if cell:IsShown() then
            ApplyCatalogCellGlow(cell, GlowStrengthForIds(svc, tabKey, cell._glowEntryId, cell._glowRankIds))
        end
    end
end

-- ── Pickup list ──

--- Fresh-pickup accent: a short window after a pickup (multi-loot clusters highlight together).
local SESSION_ROW_GLOW_SEC = 2.2
local MULTI_LOOT_CLUSTER_SEC = 1.2
local SESSION_ROW_GLOW_MAX = 5
local PULSE_HZ = 1.2

--- Newest-first list: how many top rows belong to the fresh pickup cluster.
local function FreshPickupCount(events, maxN, nowT)
    local e1 = events and events[1]
    local t1 = e1 and tonumber(e1.rt)
    if not t1 or (nowT - t1) > SESSION_ROW_GLOW_SEC then
        return 0
    end
    local k = 1
    for i = 2, maxN do
        local ti = events[i] and tonumber(events[i].rt)
        if not ti or (nowT - ti) > SESSION_ROW_GLOW_SEC or math.abs(ti - t1) > MULTI_LOOT_CLUSTER_SEC then
            break
        end
        k = i
    end
    return k
end

local function ClearPickupHighlight(row)
    row:SetScript("OnUpdate", nil)
    if row._anFresh then
        row._anFresh = nil
        local F = Factory()
        if F and F.ApplyOnlineCharacterHighlight then
            F:ApplyOnlineCharacterHighlight(row, false)
        end
        if row.bg then row.bg:SetAlpha(1) end
        if row.onlineAccent then row.onlineAccent:SetAlpha(1) end
    end
end

local function PickupHighlightOnUpdate(row)
    local lh = ns.LootHistoryUI
    if lh and lh._pauseLootFx then
        return
    end
    local age = GetTime() - (row._anFreshRt or 0)
    if age >= SESSION_ROW_GLOW_SEC then
        ClearPickupHighlight(row)
        return
    end
    local u = 1 - age / SESSION_ROW_GLOW_SEC
    local env = u * u * (3 - 2 * u)
    local pulse = (math.sin(GetTime() * math.pi * 2 * PULSE_HZ) + 1) * 0.5
    if row.onlineAccent then
        row.onlineAccent:SetAlpha(env * (0.55 + 0.45 * pulse))
    end
    if row.bg then
        row.bg:SetAlpha(0.35 + 0.65 * env)
    end
end

--- Accent row highlight (WN online-character highlight) that pulses and fades out.
local function ApplyPickupHighlight(row, evRt)
    local F = Factory()
    if not (F and F.ApplyOnlineCharacterHighlight) then return end
    F:ApplyOnlineCharacterHighlight(row, true)
    row._anFresh = true
    row._anFreshRt = evRt
    PickupHighlightOnUpdate(row)
    if row._anFresh then
        row:SetScript("OnUpdate", PickupHighlightOnUpdate)
    end
end

local function CreateSessionRow(content)
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_H)
    local ic = ns.UI_CreateIcon(row, nil, ROW_ICON)
    ic:SetPoint("LEFT", row, "LEFT", ROW_PAD, 0)
    row._icon = ic
    local rankTex = row:CreateTexture(nil, "ARTWORK")
    rankTex:SetSize(RANK_ATLAS_SZ, RANK_ATLAS_SZ)
    rankTex:SetPoint("LEFT", ic, "RIGHT", 6, 0)
    row._rankTex = rankTex
    local count = NewFS(row, "body", "Bright")
    count:SetJustifyH("LEFT")
    row._count = count
    local price = NewFS(row, "body", "Normal")
    price:SetJustifyH("RIGHT")
    price:SetPoint("RIGHT", row, "RIGHT", -ROW_PAD, 0)
    price:SetWordWrap(false)
    row._price = price
    local name = NewFS(row, "body")
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    name:SetMaxLines(1)
    row._name = name
    return row
end

local function ResetSessionRow(row)
    ClearPickupHighlight(row)
    row._anItemGen = (row._anItemGen or 0) + 1
    DetachItemTooltip(row._icon)
end

local function ResolveCatalogEntriesForTab(tabKey)
    if tabKey == "fishing" then
        return (ns.GetFishingCatalogEntries and ns.GetFishingCatalogEntries()) or {}
    end
    if tabKey == "crafted" then
        return {}
    end
    return (ns.GetGatheringCatalogByCategory and ns.GetGatheringCatalogByCategory(tabKey)) or {}
end

local function ResolveEventTabKey(e, fallbackTabKey)
    if e and e.tabKey then return e.tabKey end
    if e and e.cat then return e.cat end
    if e and (e.spellID or e.profession) then return "crafted" end
    return fallbackTabKey or "fishing"
end

local function SafeString(s)
    return s and not (issecretvalue and issecretvalue(s)) and s or nil
end

---@param emptyMsg string|false|nil false = the window already shows its one empty message
local function PopulateSessionList(content, events, catalogEntries, listCap, emptyMsg, tabKey, startY, opts)
    opts = opts or {}
    events = events or {}
    listCap = listCap or 15
    local rs = ns.RecipeService
    local y = tonumber(startY) or 0
    local w = tonumber(opts.contentWidth) or content:GetWidth() or 0
    if w < 80 then w = 360 end

    if y > 0 and not opts.skipSubHeader then
        local sub = content._anPickupsSubHeader
        if not sub then
            sub = NewFS(content, "subtitle", "Bright")
            sub:SetJustifyH("LEFT")
            content._anPickupsSubHeader = sub
        end
        sub:ClearAllPoints()
        sub:SetPoint("TOPLEFT", content, "TOPLEFT", ROW_PAD, -y)
        sub:SetFormattedText(LT("LOOT_SECTION_SESSION_FMT", "Last %d pickups"), listCap)
        ns.UI_SetTextColorRole(sub, "Bright")
        sub:Show()
        y = y + 22
    elseif content._anPickupsSubHeader then
        content._anPickupsSubHeader:Hide()
    end

    local maxN = math.min(listCap, #events)
    local fresh = math.min(FreshPickupCount(events, maxN, GetTime()), SESSION_ROW_GLOW_MAX)
    local F = Factory()
    local rowPool = ContentPool(content, "sessRow")
    local noPrice = LT("LOOT_CATALOG_AH_EMPTY", "—")
    for i = 1, maxN do
        local e = events[i]
        if not e then break end
        local itemID = e.itemID
        local qty = tonumber(e.qty) or 1
        local rowTabKey, rowCatalog = tabKey, catalogEntries
        if opts.perEventTabKey then
            rowTabKey = ResolveEventTabKey(e, tabKey)
            rowCatalog = ResolveCatalogEntriesForTab(rowTabKey)
        end
        local row = PoolAcquire(rowPool, CreateSessionRow, content)
        row:SetSize(w, ROW_H)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        if F and F.ApplyRowBackground then
            F:ApplyRowBackground(row, i)
        end
        row:Show()

        local ic = row._icon
        ic.texture:SetTexture(TexForItem(itemID))
        ic.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic:Show()
        AttachItemTooltip(ic, itemID)

        local tierHint = (GetCatalogRankIndexForItem and GetCatalogRankIndexForItem(itemID, rowCatalog)) or 1
        tierHint = math.min(math.max(tierHint, 1), MAX_QUALITY_TIERS)
        local rankTex = row._rankTex
        local rankOk = SetProfessionRankAtlasForItem
            and SetProfessionRankAtlasForItem(rankTex, itemID, RANK_ATLAS_SZ, RANK_ATLAS_SZ, tierHint)
        rankTex:SetShown(rankOk and true or false)

        local count = row._count
        count:ClearAllPoints()
        count:SetPoint("LEFT", rankOk and rankTex or ic, "RIGHT", 4, 0)
        count:SetText(tostring(qty) .. "×")

        local unit = LootUnitCopper(itemID)
        local price = row._price
        local priceShown = false
        if qty > 0 and unit and unit > 0 then
            price:SetText(FormatCopper(qty * unit, COIN_ICON_H) or "")
            ns.UI_SetTextColorRole(price, "Normal")
            priceShown = true
        elseif qty > 0 then
            price:SetText(noPrice)
            ns.UI_SetTextColorRole(price, "Dim")
            priceShown = true
        end
        price:SetShown(priceShown)

        local name = row._name
        name:ClearAllPoints()
        name:SetPoint("LEFT", count, "RIGHT", 8, 0)
        if priceShown then
            name:SetPoint("RIGHT", price, "LEFT", -6, 0)
        else
            name:SetPoint("RIGHT", row, "RIGHT", -ROW_PAD, 0)
        end

        -- Generation guard: an async item load must not restyle a row reused meanwhile.
        row._anItemGen = (row._anItemGen or 0) + 1
        local gen = row._anItemGen
        local function ApplyName()
            local nm, _, quality = GetItemInfo(itemID)
            nm = SafeString(nm)
            if nm then
                local display = nm
                if rowTabKey == "crafted" and e.spellID and rs and rs.GetRecipeName then
                    local rname = SafeString(rs:GetRecipeName(e.spellID))
                    local prof = type(e.profession) == "string" and SafeString(e.profession) or nil
                    if rname then
                        display = nm .. " — " .. rname
                    elseif prof then
                        display = nm .. " — " .. prof
                    end
                end
                name:SetText(display)
            else
                name:SetText("#" .. tostring(itemID))
            end
            name:SetTextColor(GetQualityRGB(quality or 1))
        end
        ApplyName()
        if not GetItemInfo(itemID) and Item and Item.CreateFromItemID then
            Item:CreateFromItemID(itemID):ContinueOnItemLoad(function()
                if row._anItemGen == gen then
                    ApplyName()
                end
            end)
        end

        local evRt = tonumber(e.rt)
        if i <= fresh and evRt then
            ApplyPickupHighlight(row, evRt)
        end
        y = y + ROW_H + ROW_GAP
    end

    if maxN == 0 and emptyMsg ~= false then
        local text = emptyMsg or LT("LOOT_SESSION_EMPTY", "Nothing collected this session yet.")
        local h = ShowEmptyMessage(content, w, text)
        if y > 0 and content._anEmptyFrame then
            content._anEmptyFrame:ClearAllPoints()
            content._anEmptyFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        end
        y = y + h
    else
        HideEmptyMessage(content)
    end
    content:SetSize(w, math.max(y + 4, 32))
end

-- ── Per-character value lines (Overall mode) ──

local function CreateCharEarningsLine(content)
    local line = CreateFrame("Frame", nil, content)
    line:SetHeight(CHAR_LINE_H)
    local val = NewFS(line, "body", "Normal")
    val:SetPoint("RIGHT", line, "RIGHT", -ROW_PAD, 0)
    val:SetJustifyH("RIGHT")
    line._val = val
    local nm = NewFS(line, "body", "Bright")
    nm:SetPoint("LEFT", line, "LEFT", ROW_PAD, 0)
    nm:SetPoint("RIGHT", val, "LEFT", -6, 0)
    nm:SetJustifyH("LEFT")
    nm:SetWordWrap(false)
    line._name = nm
    return line
end

--- "Name-Realm    12g 34s" rows at the top of `content`; returns the y offset consumed.
local function PopulateCharEarnings(content, rows)
    if not rows or #rows == 0 then
        return 0
    end
    local w = content:GetWidth() or 0
    if w < 80 then w = 360 end
    local F = Factory()
    local y = 0
    local pool = ContentPool(content, "charLine")
    local noPrice = LT("LOOT_CATALOG_AH_EMPTY", "—")
    for i = 1, #rows do
        local r = rows[i]
        local line = PoolAcquire(pool, CreateCharEarningsLine, content)
        line:SetSize(w, CHAR_LINE_H)
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        if F and F.ApplyRowBackground then
            F:ApplyRowBackground(line, i)
        end
        line:Show()
        line._val:SetText(FormatCopper(r.copper, COIN_ICON_H) or noPrice)
        line._name:SetText(r.label or "?")
        y = y + CHAR_LINE_H
    end
    return y + 10
end

--- Release every pooled frame on `content` and hide the one-off strings (before each repaint).
local function ReleaseContent(content)
    if not content then
        return
    end
    local pools = content._anPools
    if pools then
        if pools.cell then PoolReleaseAll(pools.cell, ResetCatalogCell) end
        if pools.sessRow then PoolReleaseAll(pools.sessRow, ResetSessionRow) end
        if pools.charLine then PoolReleaseAll(pools.charLine, nil) end
    end
    HideEmptyMessage(content)
    if content._anPickupsSubHeader then
        content._anPickupsSubHeader:Hide()
    end
end

--- Theme switch: re-skin pooled cards / icon wells (WN chrome is applied at creation).
local function RestyleContent(content)
    local accent = ns.UI_COLORS and ns.UI_COLORS.accent
    local function restyleIcon(ic)
        if ic and accent and ns.UI_UpdateBorderColor
            and not (ns.UI_IsClassicMode and ns.UI_IsClassicMode()) then
            ns.UI_UpdateBorderColor(ic, { accent[1], accent[2], accent[3], 0.6 })
        end
    end
    ForEachPooled(content, "cell", function(cell)
        cell._anGlowOn = nil
        if ns.UI_ApplyStandardCardElevatedChrome then
            ns.UI_ApplyStandardCardElevatedChrome(cell)
        end
        restyleIcon(cell._icon)
    end)
    ForEachPooled(content, "sessRow", function(row)
        restyleIcon(row._icon)
    end)
end

function Draw.ReleaseContent(content)
    return ReleaseContent(content)
end

function Draw.RestyleContent(content)
    return RestyleContent(content)
end

function Draw.SortFishingCatalogEntries(entries, totals)
    return SortFishingCatalogEntries(entries, totals)
end

function Draw.PopulateCatalog(content, entries, totals, tabKey, innerW)
    return PopulateCatalog(content, entries, totals, tabKey, innerW)
end

function Draw.PopulateSessionList(content, events, catalogEntries, listCap, emptyMsg, tabKey, startY, opts)
    return PopulateSessionList(content, events, catalogEntries, listCap, emptyMsg, tabKey, startY, opts)
end

function Draw.PopulateCharEarnings(content, rows)
    return PopulateCharEarnings(content, rows)
end

function Draw.RefreshCatalogGlowStrengths(content, tabKey)
    return RefreshCatalogGlowStrengths(content, tabKey)
end
