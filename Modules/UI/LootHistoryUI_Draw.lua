--[[ LootHistoryUI catalog + session list drawing (split chunk). ]]
local ADDON_NAME, ns = ...

local L = ns.L
local COLORS = ns.UI_COLORS
local LAYOUT = ns.UI_LAYOUT
local ApplyVisuals = ns.UI_ApplyVisuals
local SetProfessionRankAtlasForItem = ns.SetProfessionRankAtlasForItem
local SetProfessionRankAtlas = ns.SetProfessionRankAtlas
local GetCatalogRankIndexForItem = ns.GetCatalogRankIndexForItem
local GetQualityRGB = ns.GetQualityRGB or function()
    return 1, 1, 1
end

local Draw = {}
ns.LootHistoryUIDraw = Draw

local ROW_H = math.max(30, (LAYOUT.ROW_HEIGHT or 36))
local ICON_SZ = math.max(28, (LAYOUT.ICON_SIZE or 34))
local RANK_ATLAS_SZ = 22
local SESSION_ROW_GAP = 2
local FONTS = ns.UI_FONTS or {}
local SESSION_ROW_TEXT_FONT = FONTS.WINDOW_EMPHASIS or "GameFontNormalLarge"
local SESSION_ROW_META_FONT = FONTS.WINDOW_BODY or "GameFontNormal"
local SESSION_ROW_COIN_ICON_H = 14
local CAT_SZ = LAYOUT.CATALOG_ICON or 36
local MAX_QUALITY_TIERS = (ns.PROFESSION_QUALITY_MAX_TIER) or 5
local CELL_PAD = (LAYOUT.LOOT_CATALOG_CELL_PAD) or 8
--- Inter-card gap (grid gutter) is intentionally decoupled from CELL_PAD
--- (interior cell content padding) — tightening the grid must not cramp the
--- icon/quality/amount pattern inside each card.
local GRID_GAP = (LAYOUT.LOOT_CATALOG_GRID_GAP) or 5
--- Fixed left/right margin for the whole catalog grid — distinct from GRID_GAP
--- so the outer columns never sit flush against the panel edge.
local GRID_SIDE_PAD = (LAYOUT.LOOT_CATALOG_SIDE_PAD) or 10
--- Resolve at call time: UI_RefreshColors replaces the palette sub-tables, so
--- captured refs go stale after a light/dark theme switch.
local function QTY_ON()
    return COLORS.lootQtyOn or COLORS.textBright
end
local function QTY_ZERO()
    return COLORS.lootQtyZero or COLORS.textDim
end
local CATALOG_CELL_TEXT_FONT = FONTS.WINDOW_BODY or "GameFontNormal"

local function GetLastLootListCap()
    local s = ns.SessionLootService
    if s and s.GetMaxRecentLoot then
        return s:GetMaxRecentLoot()
    end
    return 15
end

--- Shared money / unit-price helpers (Modules/Utilities.lua; loads before this file per TOC).
--- LootUnitCopper includes the AH-cache fallback, so Draw rows price exactly
--- like the LootHistoryUI header Total.
local FormatCopper = ns.FormatCopper
local LootUnitCopper = ns.GetLootUnitCopperWithFallback

local function TexForItem(itemID)
    if not itemID or not C_Item or not C_Item.GetItemIconByID then
        return "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    local fileID = C_Item.GetItemIconByID(itemID)
    return (fileID and fileID > 0) and fileID or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function AttachItemTooltip(frame, itemID)
    if not frame or not itemID or type(itemID) ~= "number" or itemID < 1 then
        return
    end
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function(self)
        if IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton") then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(itemID)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

--==========================================================================
-- Frame pools — WoW frames are never garbage collected, so catalog cells,
-- session rows and char-earnings lines are pooled and reconfigured on every
-- refresh instead of being recreated. Pools live ON the content frame
-- (content._anPools): a UI-mode switch destroys the whole window (and its
-- content frames), so a pool never outlives the Classic/Modern mode it was
-- styled for.
--==========================================================================

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

--- Catalog grid is capped at 2 columns but collapses to 1 when the live
--- viewport cannot give each card enough width for icon + tier + count +
--- money (embedded coin icons). Thresholds are derived from layout constants,
--- not hard-coded pixel guesses.
local CATALOG_MAX_COLS = (LAYOUT.LOOT_CATALOG_MAX_COLS) or 2
--- Gap between the item icon and the quality/rank block — kept small so the
--- rank atlas reads as "attached" to the icon rather than floating.
local RANK_ICON_GAP = 6

local function CatalogCellWidthForCols(usableW, cols)
    if not usableW or usableW < 1 or not cols or cols < 1 then
        return usableW or 1
    end
    local avail = math.max(1, usableW - GRID_GAP * (cols - 1))
    return math.floor(avail / cols)
end

local function CatalogMinCellWidth()
    local themeMin = LAYOUT.LOOT_CATALOG_MIN_CELL_W
    if themeMin and themeMin > 0 then
        return themeMin
    end
    local atlasSz = math.max(20, math.floor(CAT_SZ * 0.46))
    local atlasW = atlasSz + 4
    local minCntW = 36
    local minValW = (LAYOUT.LOOT_CATALOG_MIN_VALUE_W) or 72
    local minRankLineW = atlasW + minCntW + 4 + minValW
    return CELL_PAD * 2 + CAT_SZ + RANK_ICON_GAP + minRankLineW
end

local function CatalogColumnCount(usableW)
    if not usableW or usableW < 1 then
        return 1
    end
    local minCellW = CatalogMinCellWidth()
    local maxCols = CATALOG_MAX_COLS
    if maxCols < 1 then
        maxCols = 1
    end
    for cols = maxCols, 1, -1 do
        if CatalogCellWidthForCols(usableW, cols) >= minCellW then
            return cols
        end
    end
    return 1
end

--- Rank text block width: left inset (icon) + icon + gap + rank block + right
--- inset must all sum to cellW, with the SAME inset (CELL_PAD) on both sides —
--- explicit terms here (not a CELL_PAD*3 shortcut) keep left/right symmetric
--- even if RANK_ICON_GAP is tuned independently of CELL_PAD.
local function CatalogRankBlockWidth(cellW)
    return math.max(52, cellW - CAT_SZ - RANK_ICON_GAP - CELL_PAD * 2)
end

--- Icon + rank lines as one cluster; height drives card/row sizing.
local function CatalogClusterHeight(showRanks, rowLineH)
    local blockH = showRanks * rowLineH
    return math.max(CAT_SZ, blockH), blockH
end

local function CatalogCellHeight(showRanks, rowLineH)
    local clusterH = CatalogClusterHeight(showRanks, rowLineH)
    return CELL_PAD + clusterH + CELL_PAD
end

--- Vertically center the icon + rank block inside the card. Row height may
--- exceed this card's own tier count (taller neighbor in the same row), so
--- leftover space is split evenly above/below instead of piling under the icon.
local function LayoutCatalogCellChrome(cellFrame, cellH, showRanks, rowLineH, cellW)
    local ic = cellFrame._icon
    local rankBlock = cellFrame._rankBlock
    if not rankBlock then
        return CatalogRankBlockWidth(cellW)
    end
    local clusterH, blockH = CatalogClusterHeight(showRanks, rowLineH)
    local innerH = math.max(clusterH, cellH - CELL_PAD * 2)
    local clusterTop = CELL_PAD + math.max(0, math.floor((innerH - clusterH) * 0.5))
    local rankW = CatalogRankBlockWidth(cellW)
    local rankLeft = CELL_PAD + CAT_SZ + RANK_ICON_GAP

    rankBlock:SetSize(rankW, blockH)
    rankBlock:ClearAllPoints()

    if ic then
        ic:ClearAllPoints()
        if blockH > CAT_SZ then
            local iconTop = clusterTop + math.floor((blockH - CAT_SZ) * 0.5)
            ic:SetPoint("TOPLEFT", cellFrame, "TOPLEFT", CELL_PAD, -iconTop)
            rankBlock:SetPoint("TOPLEFT", cellFrame, "TOPLEFT", rankLeft, -clusterTop)
        else
            ic:SetPoint("TOPLEFT", cellFrame, "TOPLEFT", CELL_PAD, -clusterTop)
            local rankTop = clusterTop + math.floor((CAT_SZ - blockH) * 0.5)
            rankBlock:SetPoint("TOPLEFT", cellFrame, "TOPLEFT", rankLeft, -rankTop)
        end
    else
        rankBlock:SetPoint("TOPLEFT", cellFrame, "TOPLEFT", rankLeft, -clusterTop)
    end
    return rankW
end

--- Keep count + copper value inside the rank line without bleeding past the cell edge.
---@param showValue boolean When false (×0 rows), count uses the full line — no price column reserve.
local function LayoutCatalogValueLine(line, lineW, atlasSz, showValue)
    local val = line._val
    local cnt = line._cnt
    local tex = line._tex
    if not val or not cnt or not tex then
        return
    end
    local atlasW = atlasSz + 4
    local minCntW = 36
    cnt:ClearAllPoints()
    val:ClearAllPoints()
    if showValue then
        --- 2-column cards are wide enough that the value column rarely needs
        --- to hit this cap — it exists only to stop the count from being
        --- squeezed to nothing, not to artificially truncate the money text.
        local valW = math.max(26, math.min(math.floor(lineW * 0.5), 120))
        if valW + atlasW + minCntW + 2 > lineW then
            valW = math.max(20, lineW - atlasW - minCntW - 2)
        end
        local cntW = math.max(minCntW, lineW - atlasW - valW - 2)
        val:SetWidth(valW)
        cnt:SetWidth(cntW)
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

--- Ease-out for fade curves (smooth end toward default).
local function Smooth01(u)
    u = math.max(0, math.min(1, u))
    return u * u * (3 - 2 * u)
end

--- Session “Last pickups” satırı — hafif nabız; katalog kartları pulse kullanmıyor (sürekli yanıp sönmeyi önlemek için).
local LOOT_SHIMMER_PULSE_HZ = 1.2

--- Katalog referans vurgusu: tek karede sabit alfa (güncelleme `SessionLootService` glow ticker + Refresh ile).
local CATALOG_REF_GLOW_ALPHA_MULT = 0.10

--- Katalog: güç 0..1 (GetReferenceGlowStrength) — dikkat çekici ama titremeyen yumuşak dolgu.
local function AddCatalogCellLootBorder(cellFrame, strength)
    if not cellFrame or not strength or strength < 0.04 then
        return
    end
    local content = cellFrame:GetParent()
    if not content then
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

    local alpha = strSm * CATALOG_REF_GLOW_ALPHA_MULT
    bg:SetVertexColor(r0 * 0.94, g0 * 0.94, b0 * 0.94)
    bg:SetAlpha(alpha)
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

    --- Nabız 0..1; zarf ile birlikte alfa — katalogdan daha düşük kontrast.
    local function applyPickupShimmer(age)
        local env = envelope(age)
        local pulse = (math.sin(GetTime() * (math.pi * 2 * LOOT_SHIMMER_PULSE_HZ)) + 1) * 0.5
        local aLo, aHi = 0.06, 0.22
        local alpha = env * (aLo + (aHi - aLo) * pulse)
        local bright = 0.91 + 0.09 * pulse
        bg:SetVertexColor(r0 * bright, g0 * bright, b0 * bright)
        bg:SetAlpha(alpha)
    end

    local startRt = evRt
    applyPickupShimmer(age0)
    bg:Show()

    row._lootPickupBorder = bg
    row:SetScript("OnUpdate", function(f)
        local lh = ns.LootHistoryUI
        if lh and lh._pauseLootFx then
            return
        end
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
--- Fishing grid: caught items (qty>0) first; within those, AH value desc then items missing AH price; uncaught (×0) last.
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
        local q = totals[rid] or totals[tostring(rid)] or tonumber(totals[rid]) or 0
        return math.max(0, tonumber(q) or 0), rid
    end
    table.sort(sorted, function(a, b)
        local qa, ida = qtyPrimary(a)
        local qb, idb = qtyPrimary(b)
        local ca, cb = qa > 0, qb > 0
        if ca ~= cb then
            return ca
        end
        if ca then
            local pa = ida and LootUnitCopper(ida) or nil
            local pb = idb and LootUnitCopper(idb) or nil
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

--- Current accent border for CreateIcon-style icon frames (modern mode).
local function AccentIconBorder()
    local ac = COLORS.accent or { 0.52, 0.40, 0.66 }
    return { ac[1], ac[2], ac[3], 0.72 }
end

--- Minimal icon frame when SharedWidgets is unavailable (must never block catalog paint).
local function LootFallbackCreateIcon(parent, _texture, size)
    if not parent then
        return nil
    end
    size = size or CAT_SZ
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(size, size)
    local tex = frame:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", 2, -2)
    tex:SetPoint("BOTTOMRIGHT", -2, 2)
    frame.texture = tex
    return frame
end

local function LootResolveCatalogRanks(entry)
    if ns.ResolveCatalogEntryRanks then
        return ns.ResolveCatalogEntryRanks(entry)
    end
    if entry and entry.ranks and type(entry.ranks) == "table" and #entry.ranks > 0 then
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

--- Create a catalog cell once (icon + rank block); rank lines are added
--- lazily via GetCellLine. Per-render code only reconfigures children.
local function CreateCatalogCell(content, classicUi)
    local createIcon = ns.UI_CreateIcon or LootFallbackCreateIcon
    local cell = CreateFrame("Frame", nil, content)
    local ic = createIcon(cell, nil, CAT_SZ, false, nil, classicUi and true or false)
    if ic then
        ic:SetPoint("TOPLEFT", cell, "TOPLEFT", CELL_PAD, -CELL_PAD)
    end
    cell._icon = ic
    local rankBlock = CreateFrame("Frame", nil, cell)
    cell._rankBlock = rankBlock
    cell._lines = {}
    return cell
end

--- Lazily create rank line `r` on a pooled cell: tier atlas + count string +
--- right-aligned value string. Atlas depends only on the line index, so it is
--- resolved once at creation (matches the old per-render behavior).
local function GetCellLine(cell, r, rowLineH, atlasSz)
    local line = cell._lines[r]
    if line then
        return line
    end
    line = CreateFrame("Frame", nil, cell._rankBlock)
    line:SetPoint("TOPLEFT", cell._rankBlock, "TOPLEFT", 0, -(r - 1) * rowLineH)

    local tex = line:CreateTexture(nil, "ARTWORK")
    tex:SetSize(atlasSz, atlasSz)
    tex:SetPoint("LEFT", line, "LEFT", 0, 0)
    line._tex = tex
    --- Catalog row `r` (1..2) maps to profession tier atlases; do not infer tier from item APIs here.
    line._rankOk = false
    if SetProfessionRankAtlas and SetProfessionRankAtlas(tex, r, atlasSz, atlasSz) then
        line._rankOk = true
    else
        tex:Hide()
    end

    local cntStr = line:CreateFontString(nil, "OVERLAY", CATALOG_CELL_TEXT_FONT)
    cntStr:SetJustifyH("LEFT")
    cntStr:SetPoint("LEFT", tex, "RIGHT", 4, 0)
    line._cnt = cntStr

    local val = line:CreateFontString(nil, "OVERLAY", CATALOG_CELL_TEXT_FONT)
    val:SetJustifyH("RIGHT")
    val:SetPoint("RIGHT", line, "RIGHT", 0, 0)
    --- Without this, a money string wider than its allotted column (embedded
    --- coin icons + digits) wraps to a 2nd line — the FontString is anchored
    --- by its vertical center, so the extra line spills downward past the
    --- row's box and into the card's bottom border/next row.
    val:SetWordWrap(false)
    val:SetMaxLines(1)
    --- Narrow 2-col band: count must yield to the money string, never overlap it.
    cntStr:SetPoint("RIGHT", val, "LEFT", -4, 0)
    cntStr:SetWordWrap(false)
    cntStr:SetMaxLines(1)
    local dr, dg, db, da = val:GetTextColor()
    line._valR, line._valG, line._valB, line._valA = dr, dg, db, da or 1
    line._val = val

    cell._lines[r] = line
    return line
end

--- Release-time reset: hide highlight/tooltip state so a reused cell never
--- shows stale glow or fires stale tooltip handlers.
local function ResetCatalogCell(cell)
    if cell._catalogShimmerBg then
        cell._catalogShimmerBg:Hide()
    end
    local ic = cell._icon
    if ic then
        ic:Hide()
        ic:SetScript("OnEnter", nil)
        ic:SetScript("OnLeave", nil)
    end
    local lines = cell._lines
    for i = 1, #lines do
        local line = lines[i]
        line:Hide()
        line:SetScript("OnEnter", nil)
        line:SetScript("OnLeave", nil)
    end
end

---@param tabKey string|nil Active tab — `GetReferenceGlowStrength` ile katalog kenar solması
---@param innerWOverride number|nil Scroll viewport width when content:GetWidth() is stale
local function PopulateCatalog(content, entries, totals, tabKey, innerWOverride)
    content:SetScript("OnUpdate", nil)
    if content.SetClipsChildren then
        content:SetClipsChildren(true)
    end
    totals = totals or {}
    entries = entries or {}
    local createIcon = ns.UI_CreateIcon or LootFallbackCreateIcon
    local resolveRanks = LootResolveCatalogRanks
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

    local innerW = innerWOverride or content:GetWidth()
    if innerWOverride then
        if not innerW or innerW < 1 then
            innerW = 80
        end
    elseif not innerW or innerW < 100 then
        innerW = 280
    end
    --- Fixed side margins carve out the usable grid width first; the
    --- inter-card gap only governs spacing *between* cards, not the edges.
    local usableW = math.max(1, innerW - GRID_SIDE_PAD * 2)
    local cols = CatalogColumnCount(usableW)
    local gapX = GRID_GAP
   --- Kalan piksel `remPx` ilk sütunlara +1: grid genişliği tam `usableW` (scroll içi ile hizalı, sütunlar eşit ±1px).
    local availForCells = math.max(1, usableW - gapX * (cols - 1))
    local baseCellW = cols > 0 and math.floor(availForCells / cols) or 108
    local remPx = cols > 0 and (availForCells - baseCellW * cols) or 0
    local function CellWidthForCol(col0)
        local c = col0 + 1
        return baseCellW + (c <= remPx and 1 or 0)
    end
    local colLeft = {}
    local xAcc = GRID_SIDE_PAD
    for col0 = 0, cols - 1 do
        colLeft[col0] = xAcc
        xAcc = xAcc + CellWidthForCol(col0) + gapX
    end
    --- Tall enough for embedded coin icons in the value column, but not so
    --- loose that 1–2 tier cards leave a large dead band under the icon.
    local rowLineH = math.max(25, math.floor(CAT_SZ * 0.55))
    local atlasSz = math.max(20, math.floor(CAT_SZ * 0.46))
    local fmt = (L and L["LOOT_REF_TOTAL_FMT"]) or "×%d"

    local n = #entries
    if n < 1 then
        local empty = content._anCatalogEmptyFS
        if not empty then
            empty = content:CreateFontString(nil, "OVERLAY", CATALOG_CELL_TEXT_FONT)
            content._anCatalogEmptyFS = empty
        end
        empty:ClearAllPoints()
        empty:SetPoint("TOPLEFT", content, "TOPLEFT", GRID_SIDE_PAD, -GRID_SIDE_PAD)
        empty:SetWidth(math.max(80, innerW - GRID_SIDE_PAD * 2))
        local emptyMsg
        if tabKey == "crafted" then
            emptyMsg = (L and L["LOOT_CRAFTED_HINT"]) or "Items you crafted this login appear here."
        else
            emptyMsg = (L and L["LOOT_SESSION_EMPTY"]) or "No loot recorded yet."
        end
        empty:SetText(emptyMsg)
        local dim = COLORS.textDim or { 0.55, 0.55, 0.58, 1 }
        empty:SetTextColor(dim[1], dim[2], dim[3], 1)
        empty:Show()
        content:SetSize(innerW, math.max(32, empty:GetStringHeight() + GRID_SIDE_PAD * 2))
        content:SetScript("OnUpdate", nil)
        return
    end
    if content._anCatalogEmptyFS then
        content._anCatalogEmptyFS:Hide()
    end

    local rows = math.max(1, math.ceil(n / cols))

    --- Row-relative card height: each row's height matches only the ranks
    --- actually present IN THAT ROW, not the tab-wide worst case. A tab-wide
    --- max (old behavior) forced every 1-2 line card to inherit a single
    --- 5-tier outlier's height, leaving large dead space at the bottom of
    --- every other card ("kartlar aşağı doğru çok kalıyor").
    local entryRanks = {}
    local rowMaxLines = {}
    for r = 0, rows - 1 do
        rowMaxLines[r] = 1
    end
    for idx = 1, n do
        local entry = entries[idx]
        local ranks = resolveRanks(entry)
        if #ranks < 1 and entry then
            if entry.id then
                ranks = { entry.id }
            elseif entry.itemID then
                ranks = { entry.itemID }
            end
        end
        entryRanks[idx] = ranks
        if #ranks >= 1 then
            local row = math.floor((idx - 1) / cols)
            local lines = math.min(MAX_QUALITY_TIERS, #ranks)
            rowMaxLines[row] = math.max(rowMaxLines[row] or 1, lines)
        end
    end

    --- Cumulative Y per row (rows are NOT uniform height) — each card's top
    --- padding (icon + first line) is CELL_PAD from ITS OWN row's top, and
    --- bottom padding is CELL_PAD from ITS OWN row's bottom: fully fixed on
    --- all 4 sides for every card, math derived (not eyeballed).
    local rowH, rowY = {}, {}
    do
        local yAcc = 0
        for r = 0, rows - 1 do
            rowH[r] = CatalogCellHeight(rowMaxLines[r], rowLineH)
            rowY[r] = yAcc
            yAcc = yAcc + rowH[r] + gapX
        end
    end

    local svcLoot = ns.SessionLootService
    local cellBorder = COLORS.lootCellBorder
    if not cellBorder then
        cellBorder = { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.44 }
    end

    --- Classic + modern: per-cell border via WindowShell loot chrome helpers.
    local classicUi = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    local cellPool = ContentPool(content, "cell")

    for idx = 1, n do
        local entry = entries[idx]
        local ranks = entryRanks[idx]
        local row = math.floor((idx - 1) / cols)
        local col = (idx - 1) % cols
        local showRanks = math.min(MAX_QUALITY_TIERS, #ranks)

        local cellW = CellWidthForCol(col)
        local cellX = colLeft[col] or 0
        local cellH = rowH[row]

        --- Rankless entries render nothing (positions are absolute; the old
        --- invisible placeholder frame carried no visuals and is skipped).
        if #ranks >= 1 then
            local cellFrame = PoolAcquire(cellPool, CreateCatalogCell, content, classicUi)
            cellFrame._glowEntryId = entry and (entry.id or entry.itemID) or nil
            cellFrame._glowRankIds = ranks
            cellFrame:SetSize(cellW, cellH)
            if cellFrame.SetClipsChildren then
                cellFrame:SetClipsChildren(true)
            end
            cellFrame:ClearAllPoints()
            cellFrame:SetPoint("TOPLEFT", content, "TOPLEFT", cellX, -rowY[row])
            cellFrame:Show()
            if ns.UI_StyleLootCatalogCell then
                ns.UI_StyleLootCatalogCell(cellFrame, cellBorder)
            elseif not classicUi and ApplyVisuals and COLORS.lootCellBg then
                ApplyVisuals(cellFrame, COLORS.lootCellBg, cellBorder)
            end

            local iconId = ranks[1]
            local ic = cellFrame._icon
            if ic then
                if ic.texture then
                    ic.texture:SetTexture(TexForItem(iconId))
                    ic.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                end
                if ns.UI_StyleLootIconFrame then
                    ns.UI_StyleLootIconFrame(ic, AccentIconBorder())
                elseif not classicUi and ic.BorderTop and ns.UI_UpdateBorderColor then
                    ns.UI_UpdateBorderColor(ic, AccentIconBorder())
                end
                ic:Show()
                AttachItemTooltip(ic, iconId)
                local glowStr = CatalogCellMaxGlowStrength(entry, ranks, tabKey, svcLoot)
                if glowStr > 0.04 then
                    AddCatalogCellLootBorder(cellFrame, glowStr)
                end
            end

            local rankW = LayoutCatalogCellChrome(cellFrame, cellH, showRanks, rowLineH, cellW)
            local rankBlock = cellFrame._rankBlock

            local usedLines = 0
            for r = 1, showRanks do
                local rid = ranks[r]
                if not rid then
                    break
                end
                local line = GetCellLine(cellFrame, r, rowLineH, atlasSz)
                line:SetSize(rankW, rowLineH)
                line:Show()
                usedLines = r
                if line._rankOk then
                    line._tex:Show()
                else
                    line._tex:Hide()
                end

                local cnt = qtyForItem(rid)
                LayoutCatalogValueLine(line, rankW, atlasSz, cnt > 0)
                local cntStr = line._cnt
                cntStr:SetFormattedText(fmt, cnt)
                local qc = (cnt > 0) and QTY_ON() or QTY_ZERO()
                cntStr:SetTextColor(qc[1], qc[2], qc[3], 1)

                --- Value: AH buyout if cached, else vendor; em dash when both unknown.
                local unitPrice = LootUnitCopper(rid)
                local val = line._val
                if cnt > 0 then
                    if unitPrice and unitPrice > 0 then
                        val:SetText(FormatCopper(cnt * unitPrice) or "")
                        val:SetTextColor(line._valR, line._valG, line._valB, line._valA)
                    else
                        val:SetText((L and L["LOOT_CATALOG_AH_EMPTY"]) or ((L and L["AH_PRICE_NO_DATA"]) or "—"))
                        local zc = QTY_ZERO()
                        val:SetTextColor(zc[1], zc[2], zc[3], 1)
                    end
                    val:Show()
                else
                    val:Hide()
                end

                line:EnableMouse(true)
                AttachItemTooltip(line, rid)
            end
            --- Hide leftover lines from a previous render with more ranks.
            for r = usedLines + 1, #cellFrame._lines do
                cellFrame._lines[r]:Hide()
            end
        end
    end

    local gridW = innerW
    --- Sum of per-row heights + inter-row gaps (rows are non-uniform now) —
    --- rowY[lastRow] already carries every prior row's height + gap, so add
    --- just the last row's own height on top, plus bottom margin.
    local gridH = (rows > 0 and (rowY[rows - 1] + rowH[rows - 1]) or 0) + 8
    content:SetSize(gridW, gridH)
    content:SetScript("OnUpdate", nil)
end

--- En yeni pickup satırına kısa süre accent vurgusu (rt penceresi).
local SESSION_ROW_GLOW_RT_SEC = 2.2
--- Aynı loot çözümünde ardışık PushFront’lar (~aynı GetTime): çoklu satırda hepsi border alır; sonraki satır keser.
local MULTI_LOOT_RT_CLUSTER_SEC = 1.2
--- Cap per-row OnUpdate shimmer handlers (multi-loot clusters must not spawn dozens).
local SESSION_ROW_SHIMMER_MAX = 5

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

--- Update catalog cell glow alpha only (no full PopulateCatalog) — called from SessionLootService glow ticker.
local function RefreshCatalogGlowStrengths(content, tabKey)
    if not content or not tabKey then
        return
    end
    local pools = content._anPools
    local cellPool = pools and pools.cell
    if not cellPool or not cellPool.used then
        return
    end
    local svc = ns.SessionLootService
    if not svc or not svc.GetReferenceGlowStrength then
        return
    end
    local used = cellPool.used
    for i = 1, #used do
        local cell = used[i]
        if cell and cell:IsShown() then
            local maxS = 0
            local entryId = cell._glowEntryId
            if entryId then
                local s = svc:GetReferenceGlowStrength(entryId, tabKey)
                if s > maxS then
                    maxS = s
                end
            end
            local rankIds = cell._glowRankIds
            if rankIds then
                for ri = 1, #rankIds do
                    local s = svc:GetReferenceGlowStrength(rankIds[ri], tabKey)
                    if s > maxS then
                        maxS = s
                    end
                end
            end
            if maxS > 0.04 then
                AddCatalogCellLootBorder(cell, maxS)
            elseif cell._catalogShimmerBg then
                cell._catalogShimmerBg:Hide()
            end
        end
    end
end

--- Char-earnings line: created once per pool slot, texts refreshed per render.
local function CreateCharEarningsLine(content)
    local line = CreateFrame("Frame", nil, content)
    local valStr = line:CreateFontString(nil, "OVERLAY", SESSION_ROW_META_FONT)
    valStr:SetPoint("RIGHT", line, "RIGHT", -2, 0)
    valStr:SetJustifyH("RIGHT")
    line._val = valStr
    local nameStr = line:CreateFontString(nil, "OVERLAY", SESSION_ROW_TEXT_FONT)
    nameStr:SetPoint("LEFT", line, "LEFT", 4, 0)
    nameStr:SetPoint("RIGHT", valStr, "LEFT", -6, 0)
    nameStr:SetJustifyH("LEFT")
    if nameStr.SetWordWrap then
        nameStr:SetWordWrap(false)
    end
    line._name = nameStr
    return line
end

--- Per-character earnings rows (Overall mode): "Name-Realm    12g 34s".
--- Section title is fixed chrome on the session host (`LootHistoryUI:Refresh`).
--- Draws at the top of `content`; returns the y offset consumed so the
--- session list continues below.
local function PopulateCharEarnings(content, rows)
    if content._anCharHeader then
        content._anCharHeader:Hide()
    end
    if not rows or #rows == 0 then
        return 0
    end
    local w = content:GetWidth() > 80 and content:GetWidth() or 360
    local y = 0
    local lineH = 22
    local linePool = ContentPool(content, "charLine")
    for i = 1, #rows do
        local r = rows[i]
        local line = PoolAcquire(linePool, CreateCharEarningsLine, content)
        line:SetSize(w, lineH)
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        line:Show()
        line._val:SetText(FormatCopper(r.copper, 12) or ((L and L["LOOT_CATALOG_AH_EMPTY"]) or "—"))
        line._name:SetText(r.label or "?")
        local bright = COLORS.textBright or { 1, 1, 1 }
        line._name:SetTextColor(bright[1], bright[2], bright[3], 1)
        local dim = COLORS.textDim or { 0.7, 0.7, 0.7 }
        line._val:SetTextColor(dim[1], dim[2], dim[3], 1)
        y = y + lineH
    end
    return y + 10
end

--- Session row: full child set created once (icon, rank holder, count/price/
--- name strings); per-render code reconfigures texts, anchors and colors.
local function CreateSessionRow(content, classicUi)
    local row = CreateFrame("Frame", nil, content)

    local ib = COLORS.lootCellBorder
    local iconBr = ib and { ib[1], ib[2], ib[3], 0.62 }
        or { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.56 }
    local createIcon = ns.UI_CreateIcon or LootFallbackCreateIcon
    local iconFrame = createIcon(row, nil, ICON_SZ, false, iconBr, classicUi and true or false)
    if iconFrame then
        iconFrame:SetPoint("LEFT", 0, 0)
    end
    row._icon = iconFrame

    local rankHolder = CreateFrame("Frame", nil, row)
    rankHolder:SetSize(RANK_ATLAS_SZ, RANK_ATLAS_SZ)
    rankHolder:SetPoint("LEFT", iconFrame or row, "RIGHT", 6, 0)
    local rankTex = rankHolder:CreateTexture(nil, "ARTWORK")
    rankTex:SetAllPoints()
    row._rankHolder = rankHolder
    row._rankTex = rankTex

    local countStr = row:CreateFontString(nil, "OVERLAY", SESSION_ROW_TEXT_FONT)
    countStr:SetPoint("LEFT", rankHolder, "RIGHT", 4, 0)
    countStr:SetJustifyH("LEFT")
    row._count = countStr

    local priceStr = row:CreateFontString(nil, "OVERLAY", SESSION_ROW_TEXT_FONT)
    priceStr:SetJustifyH("RIGHT")
    priceStr:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    local pr, pg, pb, pa = priceStr:GetTextColor()
    row._priceR, row._priceG, row._priceB, row._priceA = pr, pg, pb, pa or 1
    row._price = priceStr

    local nameStr = row:CreateFontString(nil, "OVERLAY", SESSION_ROW_TEXT_FONT)
    nameStr:SetJustifyH("LEFT")
    if nameStr.SetWordWrap then
        nameStr:SetWordWrap(false)
    end
    row._name = nameStr
    return row
end

--- Release-time reset: kill the transient OnUpdate shimmer, hide highlight
--- textures, drop tooltip handlers and invalidate pending async name loads.
local function ResetSessionRow(row)
    row:SetScript("OnUpdate", nil)
    local parts = row._sessionPickParts
    if parts and parts[1] then
        parts[1]:Hide()
    end
    row._lootPickupBorder = nil
    row._anItemGen = (row._anItemGen or 0) + 1
    local ic = row._icon
    if ic then
        ic:SetScript("OnEnter", nil)
        ic:SetScript("OnLeave", nil)
    end
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
    if e and e.tabKey then
        return e.tabKey
    end
    if e and e.cat then
        return e.cat
    end
    if e and (e.spellID or e.profession) then
        return "crafted"
    end
    return fallbackTabKey or "fishing"
end

local function PopulateSessionList(content, events, catalogEntries, listCap, emptyMsg, tabKey, startY, opts)
    listCap = listCap or GetLastLootListCap()
    opts = opts or {}
    local rs = ns.RecipeService
    local nowRt = GetTime()
    local y = tonumber(startY) or 0
    if y > 0 and not opts.skipSubHeader then
        local sub = content._anPickupsSubHeader
        if not sub then
            sub = content:CreateFontString(nil, "OVERLAY", FONTS.WINDOW_SECTION or "GameFontHighlightMedium")
            content._anPickupsSubHeader = sub
        end
        sub:ClearAllPoints()
        sub:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        local fmt = (L and L["LOOT_SECTION_SESSION_FMT"]) or "Last %d pickups"
        sub:SetFormattedText(fmt, listCap)
        local tb = COLORS.textBright or { 1, 1, 1 }
        sub:SetTextColor(tb[1], tb[2], tb[3], 1)
        sub:Show()
        y = y + 20
    elseif content._anPickupsSubHeader then
        content._anPickupsSubHeader:Hide()
    end
    local w = tonumber(opts.contentWidth)
    if not w or w < 80 then
        w = content:GetWidth() > 80 and content:GetWidth() or 360
    end
    local maxN = math.min(listCap, #events)
    local borderEndIdx = math.min(
        SessionPickBorderEndIndex(events, maxN, nowRt, SESSION_ROW_GLOW_RT_SEC, MULTI_LOOT_RT_CLUSTER_SEC),
        SESSION_ROW_SHIMMER_MAX)
    local classicUi = (ns.UI_IsClassicUi and ns.UI_IsClassicUi()) and true or false
    local rowPool = ContentPool(content, "sessRow")
    for i = 1, maxN do
        local e = events[i]
        if not e then break end
        local itemID = e.itemID
        local qty = e.qty or 1
        local rowTabKey = tabKey
        local rowCatalog = catalogEntries
        if opts.perEventTabKey then
            rowTabKey = ResolveEventTabKey(e, tabKey)
            rowCatalog = ResolveCatalogEntriesForTab(rowTabKey)
        end
        local row = PoolAcquire(rowPool, CreateSessionRow, content, classicUi)
        --- Tam scroll genişliği; vurgu soldan sağa liste alanıyla hizalı (eskiden w-8 + x=2 kesiyordu).
        row:SetSize(w, ROW_H)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
        row:Show()
        local evRt = tonumber(e.rt)
        local showFreshPickupBorder = borderEndIdx > 0 and i <= borderEndIdx and evRt

        local iconFrame = row._icon
        if iconFrame then
            if iconFrame.texture then
                iconFrame.texture:SetTexture(TexForItem(itemID))
                iconFrame.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            end
            local iconBr = COLORS.lootCellBorder
            local iconBorder = iconBr and { iconBr[1], iconBr[2], iconBr[3], 0.62 }
                or { COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.56 }
            if ns.UI_StyleLootIconFrame then
                ns.UI_StyleLootIconFrame(iconFrame, iconBorder)
            elseif not classicUi and iconFrame.BorderTop and ns.UI_UpdateBorderColor then
                ns.UI_UpdateBorderColor(iconFrame, iconBorder)
            end
            iconFrame:Show()
            AttachItemTooltip(iconFrame, itemID)
        end

        local tierFb = 1
        if GetCatalogRankIndexForItem then
            tierFb = GetCatalogRankIndexForItem(itemID, rowCatalog) or 1
        end
        tierFb = math.min(math.max(tierFb, 1), MAX_QUALITY_TIERS)

        local rankHolder = row._rankHolder
        local rankTex = row._rankTex
        rankHolder:SetSize(RANK_ATLAS_SZ, RANK_ATLAS_SZ)
        rankTex:Show()
        local rankOk = SetProfessionRankAtlasForItem
            and SetProfessionRankAtlasForItem(rankTex, itemID, RANK_ATLAS_SZ, RANK_ATLAS_SZ, tierFb)
        if not rankOk then
            rankHolder:SetWidth(2)
            rankTex:Hide()
        end

        local countStr = row._count
        countStr:SetText(tostring(qty) .. "×")
        --- Same semantic as catalog counts: theme token, not hardcoded white
        --- (light theme needs the dark lootQtyOn variant).
        local qc = QTY_ON()
        countStr:SetTextColor(qc[1], qc[2], qc[3], 1)

        local unitPrice = LootUnitCopper(itemID)
        local priceStr = row._price
        local priceShown = false
        local totalCopper = (qty > 0 and unitPrice and unitPrice > 0) and (qty * unitPrice) or nil
        if totalCopper and totalCopper > 0 then
            priceStr:SetText(FormatCopper(totalCopper, SESSION_ROW_COIN_ICON_H) or "")
            priceStr:SetTextColor(row._priceR, row._priceG, row._priceB, row._priceA)
            priceShown = true
        elseif qty > 0 then
            priceStr:SetText((L and L["LOOT_CATALOG_AH_EMPTY"]) or "—")
            local zc = QTY_ZERO()
            priceStr:SetTextColor(zc[1], zc[2], zc[3], 1)
            priceShown = true
        end
        priceStr:SetShown(priceShown)

        local nameStr = row._name
        nameStr:ClearAllPoints()
        nameStr:SetPoint("LEFT", countStr, "RIGHT", 8, 0)
        if priceShown then
            nameStr:SetPoint("RIGHT", priceStr, "LEFT", -6, 0)
        else
            nameStr:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        end

        --- Generation guard: async ContinueOnItemLoad must not restyle a row
        --- that was released/reused for a different item in the meantime.
        row._anItemGen = (row._anItemGen or 0) + 1
        local itemGen = row._anItemGen

        local function ApplyNameAndColor()
            local nm = GetItemInfo(itemID)
            local qIdx = select(3, GetItemInfo(itemID))
            if qIdx == nil then
                qIdx = 1
            end
            if nm and not (issecretvalue and issecretvalue(nm)) then
                local display = nm
                if rowTabKey == "crafted" and e.spellID and rs and rs.GetRecipeName then
                    local rname = rs:GetRecipeName(e.spellID)
                    if rname and not (issecretvalue and issecretvalue(rname)) then
                        display = nm .. " — " .. rname
                    elseif e.profession and type(e.profession) == "string"
                        and not (issecretvalue and issecretvalue(e.profession)) then
                        --- Profession names originate from profession APIs; guard
                        --- like `rname` above or a secret value errors the row paint.
                        display = nm .. " — " .. e.profession
                    end
                end
                nameStr:SetText(display)
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
                if row._anItemGen == itemGen then
                    ApplyNameAndColor()
                end
            end)
        end
        if showFreshPickupBorder and evRt then
            ApplySessionPickupHighlight(row, evRt, SESSION_ROW_GLOW_RT_SEC)
        end
        y = y + ROW_H + SESSION_ROW_GAP
    end
    if maxN == 0 then
        local empty = content._anEmptyFS
        if not empty then
            empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
            content._anEmptyFS = empty
        end
        empty:ClearAllPoints()
        empty:SetPoint("TOPLEFT", 8, -(y + 6))
        empty:SetText(emptyMsg or (L and L["LOOT_SESSION_EMPTY"]) or "No recent loot this session.")
        empty:SetTextColor(COLORS.textDim[1], COLORS.textDim[2], COLORS.textDim[3])
        empty:Show()
        y = y + 28
    end
    content:SetSize(w, math.max(y + 4, 32))
end
--- Release every pooled frame acquired on `content` back to its pool and
--- hide the cached one-off FontStrings. Called from LootHistoryUI's
--- ClearScrollContent before each repopulate (replaces the old
--- SetParent(nil) discard — WoW frames are never garbage collected).
local function ReleaseContent(content)
    if not content then
        return
    end
    content:SetScript("OnUpdate", nil)
    local pools = content._anPools
    if pools then
        if pools.cell then
            PoolReleaseAll(pools.cell, ResetCatalogCell)
        end
        if pools.sessRow then
            PoolReleaseAll(pools.sessRow, ResetSessionRow)
        end
        if pools.charLine then
            PoolReleaseAll(pools.charLine, nil)
        end
    end
    if content._anCatalogEmptyFS then
        content._anCatalogEmptyFS:Hide()
    end
    if content._anEmptyFS then
        content._anEmptyFS:Hide()
    end
    if content._anCharHeader then
        content._anCharHeader:Hide()
    end
    if content._anPickupsSubHeader then
        content._anPickupsSubHeader:Hide()
    end
end

function Draw.ReleaseContent(content)
    return ReleaseContent(content)
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

--- Floating loot overlay: mixed-tab session rows (icon, name, qty, AH/vendor price).
function Draw.PopulateOverlaySessionList(content, events, listCap, emptyMsg, contentWidth)
    return PopulateSessionList(content, events, {}, listCap, emptyMsg, "fishing", 0, {
        perEventTabKey = true,
        skipSubHeader = true,
        contentWidth = contentWidth,
    })
end

function Draw.PopulateCharEarnings(content, rows)
    return PopulateCharEarnings(content, rows)
end

function Draw.RefreshCatalogGlowStrengths(content, tabKey)
    return RefreshCatalogGlowStrengths(content, tabKey)
end
