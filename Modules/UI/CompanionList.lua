--[[
    Artisan Nexus — WN Recipe Companion list parts, pooled.

    The reagent block of Warband Nexus RecipeCompanionWindow.RenderContent
    (RecipeCompanionWindow.lua:438-700): per reagent a Factory:CreateSectionHeader (check when covered,
    name in green / yellow / white, right xN) with storage rows under it (character bags "Banker",
    bank "VignetteLoot", Warband bank "warbands-icon"; quality columns for ranked reagents) and the
    Total row; Crafters rows with the best crafter starred. Same metrics as the companion
    (RecipeCompanionWindow.lua:83-101, 176-184, 362-363).

    WN creates these frames on every render (it repaints only on recipe selection). The profession
    sidecar and the Hub Queue & Shopping page repaint on every bag / price message, so the Factory
    headers and rows are kept in a pool and rebound instead.

      CL.NewPool()                                   -> pool
      CL.Begin(pool)                                 hide everything, restart the pool
      CL.Discard(pool)                               drop the frames (theme change: Factory chrome is
                                                     baked in at creation)
      CL.Header(pool, parent, x, y, rightInset, collapsed, title, right, onToggle, height) -> y
      CL.Row(pool, parent, x, y, rightInset, rowIndex) -> row, y
      CL.SetRowName(row, text, atlas, w, h, star)
      CL.SetRowCounts(row, counts, numTiers, color)
      CL.SlotCounts(slot)                            counts per tier: total, warband, mine.bag / .bank,
                                                     characters = { { charName, classFile, bagCounts,
                                                     bankCounts } } (RecipeService:GetStockByLocation,
                                                     CharacterData:GetItemCountsAcrossCharacters)
      CL.Reagent(pool, parent, x, y, rightInset, rowIndex, slot, needed, collapsed, onToggle, opts)
                                                     -> y, rowIndex   one companion reagent block;
                                                     opts.sufficient overrides "have >= needed"
                                                     (shopping list: the whole list's demand)
]]

local ADDON_NAME, ns = ...

local CL = {}
ns.UI_CompanionList = CL

local PADDING = 8
local ROW_HEIGHT = 22
CL.SECTION_SPACING = 6
CL.HEADER_HEIGHT = 22
local QUALITY_RANK_ICON_SIZE = 18
local STORAGE_ICON = 16
local TIER_COL_WIDTH = 96
local TIER_ICON_TO_TEXT_GAP = 2

local function Factory()
    return ns.UI and ns.UI.Factory
end

local function L(key, fallback)
    return (ns.SafeLocaleString and ns.SafeLocaleString(key, fallback)) or fallback
end

local function TextRoleHex(role)
    return (ns.UI_GetTextRoleHexRaw and ns.UI_GetTextRoleHexRaw(role)) or "ffffff"
end

local function SemanticHex(getter, fallback)
    local h = ns[getter] and ns[getter]()
    if type(h) == "string" then
        return (h:gsub("|cff", ""))
    end
    return fallback
end

local function GreenHex() return SemanticHex("UI_GetSemanticGreenHex", "44ff44") end
local function YellowHex() return SemanticHex("UI_GetSemanticGoldHex", "ffcc00") end

local function FormatNumber(n)
    return (ns.UI_FormatNumber and ns.UI_FormatNumber(n)) or tostring(n or 0)
end

function CL.ClassName(name, classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c and c.colorStr then
        return "|c" .. c.colorStr .. tostring(name) .. "|r"
    end
    return tostring(name)
end

local function SumCounts(t)
    local total = 0
    for _, v in pairs(t) do total = total + v end
    return total
end
CL.SumCounts = SumCounts

function CL.NewPool()
    return { hdr = {}, row = {}, usedHdr = 0, usedRow = 0 }
end

function CL.Begin(pool)
    for i = 1, #pool.hdr do pool.hdr[i]:Hide() end
    for i = 1, #pool.row do pool.row[i]:Hide() end
    pool.usedHdr, pool.usedRow = 0, 0
end

function CL.Discard(pool)
    CL.Begin(pool)
    pool.hdr, pool.row = {}, {}
end

local function Place(frame, parent, x, y, rightInset, height)
    frame:SetParent(parent)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
    frame:SetPoint("RIGHT", parent, "RIGHT", -(rightInset or 0), 0)
    frame:SetHeight(height)
    frame:Show()
end

--- Factory:CreateSectionHeader (SharedWidgets_RowPool.lua, WN verbatim). The factory keeps no handles:
--- its title and right label are the header's font strings in creation order, the chevron is its
--- only child; they are picked up once and rebound on reuse.
function CL.Header(pool, parent, x, y, rightInset, collapsed, titleStr, rightStr, onToggle, height)
    height = height or CL.HEADER_HEIGHT
    local i = pool.usedHdr + 1
    pool.usedHdr = i
    local header = pool.hdr[i]
    if not header then
        local F = Factory()
        if not (F and F.CreateSectionHeader) then
            return y
        end
        local _, h = F:CreateSectionHeader(parent, y, collapsed, titleStr, " ", onToggle, height)
        -- Classic skin: the header is a UIPanelButtonTemplate whose own label comes first; skip it.
        local templateText = h.GetFontString and h:GetFontString()
        local fontStrings = {}
        local regions = { h:GetRegions() }
        for r = 1, #regions do
            if regions[r] ~= templateText and regions[r].GetObjectType and regions[r]:GetObjectType() == "FontString" then
                fontStrings[#fontStrings + 1] = regions[r]
            end
        end
        h._anTitle, h._anRight = fontStrings[1], fontStrings[2]
        h._anChevron = (h:GetChildren())
        pool.hdr[i] = h
        header = h
    end
    Place(header, parent, x, y, rightInset, height)
    header:SetFrameLevel((parent:GetFrameLevel() or 0) + 10)
    if header._anTitle then header._anTitle:SetText(titleStr) end
    if header._anRight then header._anRight:SetText(rightStr or "") end
    if header._anChevron and ns.UI_CollapseExpandSetState then
        ns.UI_CollapseExpandSetState(header._anChevron, not collapsed)
        header._anChevron:SetScript("OnClick", onToggle)
    end
    header:SetScript("OnClick", onToggle)
    return y + height
end

--- Factory:CreateDataRow (alternating background) with the companion's row parts: storage icon
--- (RecipeCompanionWindow.lua:215 CreateStorageIcon), name, right count, best-crafter star and up to
--- three quality columns (RenderQualityColumns).
function CL.Row(pool, parent, x, y, rightInset, rowIndex)
    local i = pool.usedRow + 1
    pool.usedRow = i
    local row = pool.row[i]
    local F = Factory()
    if not row then
        if not (F and F.CreateDataRow) then
            return nil, y
        end
        row = F:CreateDataRow(parent, y, rowIndex, ROW_HEIGHT)
        row._anIcon = row:CreateTexture(nil, "ARTWORK")
        row._anStar = row:CreateTexture(nil, "ARTWORK")
        row._anStar:SetAtlas("PetJournal-FavoritesIcon")
        row._anStar:SetSize(12, 12)
        row._anStar:SetPoint("LEFT", PADDING + 2, 0)
        row._anName = ns.FontManager:CreateFontString(row, "body", "OVERLAY")
        row._anName:SetJustifyH("LEFT")
        row._anName:SetWordWrap(false)
        row._anValue = ns.FontManager:CreateFontString(row, "body", "OVERLAY")
        row._anValue:SetPoint("RIGHT", row, "RIGHT", -PADDING, 0)
        row._anValue:SetJustifyH("RIGHT")
        row._anCols = {}
        pool.row[i] = row
    end
    Place(row, parent, x, y, rightInset, ROW_HEIGHT)
    if F and F.ApplyRowBackground then
        F:ApplyRowBackground(row, rowIndex)
    end
    row._anIcon:Hide()
    row._anStar:Hide()
    row._anValue:SetText("")
    for c = 1, #row._anCols do
        row._anCols[c]:Hide()
    end
    return row, y + ROW_HEIGHT
end

--- Name at the companion's offsets: after the storage icon, after the star, or PADDING + 10.
function CL.SetRowName(row, text, atlas, w, h, star)
    row._anName:ClearAllPoints()
    if atlas then
        row._anIcon:SetAtlas(atlas)
        row._anIcon:SetSize(w or STORAGE_ICON, h or STORAGE_ICON)
        row._anIcon:ClearAllPoints()
        row._anIcon:SetPoint("LEFT", PADDING + 10, 0)
        row._anIcon:Show()
        row._anName:SetPoint("LEFT", row._anIcon, "RIGHT", 4, 0)
    elseif star then
        row._anStar:Show()
        row._anName:SetPoint("LEFT", PADDING + 16, 0)
    else
        row._anName:SetPoint("LEFT", PADDING + 10, 0)
    end
    row._anName:SetPoint("RIGHT", row, "RIGHT", -(PADDING + 140), 0)
    row._anName:SetText(text)
end

--- RecipeCompanionWindow.lua:398 RenderQualityColumns: tier N rightmost, rank atlas + "(count)".
local function SetQualityColumns(row, counts, numTiers)
    for ti = numTiers, 1, -1 do
        local col = row._anCols[ti]
        if not col then
            col = CreateFrame("Frame", nil, row)
            col._icon = col:CreateTexture(nil, "ARTWORK")
            col._icon:SetPoint("LEFT", col, "LEFT", 0, 0)
            col._text = ns.FontManager:CreateFontString(col, "body", "OVERLAY")
            col._text:SetPoint("LEFT", col._icon, "RIGHT", TIER_ICON_TO_TEXT_GAP, 0)
            col._text:SetJustifyH("LEFT")
            col._text:SetWidth(TIER_COL_WIDTH - QUALITY_RANK_ICON_SIZE - TIER_ICON_TO_TEXT_GAP - 2)
            row._anCols[ti] = col
        end
        col:SetSize(TIER_COL_WIDTH, ROW_HEIGHT)
        col:ClearAllPoints()
        col:SetPoint("RIGHT", row, "RIGHT", -PADDING - (numTiers - ti) * TIER_COL_WIDTH, 0)
        if ns.UI_ApplyProfessionCraftingQualityAtlasToTexture then
            ns.UI_ApplyProfessionCraftingQualityAtlasToTexture(col._icon, ti, QUALITY_RANK_ICON_SIZE)
        end
        local count = counts[ti] or 0
        if count > 0 then
            col._text:SetText("|cff" .. TextRoleHex("Bright") .. "(" .. FormatNumber(count) .. ")|r")
        else
            col._text:SetText("|cff" .. TextRoleHex("Dim") .. "(-)|r")
        end
        col:Show()
    end
    -- Three tiers reach past the companion's 140 px name reserve: end the name at the first column.
    row._anName:SetPoint("RIGHT", row, "RIGHT", -(PADDING + math.max(140, numTiers * TIER_COL_WIDTH)), 0)
end

--- Quality columns for a ranked reagent, else one right-aligned number.
function CL.SetRowCounts(row, counts, numTiers, color)
    if numTiers >= 2 then
        SetQualityColumns(row, counts, numTiers)
        return
    end
    row._anValue:SetText((color or ("|cff" .. TextRoleHex("Bright"))) .. SumCounts(counts) .. "|r")
end

local function CandidateID(c)
    return type(c) == "table" and c.itemID or c
end

function CL.SlotCounts(slot)
    local rs, cd = ns.RecipeService, ns.CharacterData
    local counts = { total = {}, warband = {}, mine = { bag = {}, bank = {} }, characters = {} }
    local byName = {}
    for ti = 1, #slot.candidates do
        local id = CandidateID(slot.candidates[ti])
        if id and rs then
            local st = rs:GetStockByLocation(id)
            counts.mine.bag[ti], counts.mine.bank[ti], counts.warband[ti] = st.bags, st.bank, st.warband
            local total = st.bags + st.bank + st.warband
            local other = cd and cd.GetItemCountsAcrossCharacters and cd:GetItemCountsAcrossCharacters(id)
            for _, c in ipairs(other and other.chars or {}) do
                local key = c.name or "?"
                local ch = byName[key]
                if not ch then
                    ch = { charName = key, classFile = c.classFile, bagCounts = {}, bankCounts = {} }
                    byName[key] = ch
                    counts.characters[#counts.characters + 1] = ch
                end
                ch.bagCounts[ti] = (ch.bagCounts[ti] or 0) + (tonumber(c.bagCount) or 0)
                ch.bankCounts[ti] = (ch.bankCounts[ti] or 0) + (tonumber(c.bankCount) or 0)
                total = total + (tonumber(c.total) or 0)
            end
            counts.total[ti] = total
        end
    end
    return counts
end

--- Bags and bank rows of one holder with stock (RecipeCompanionWindow.lua:615-665).
local function HolderRows(pool, parent, x, y, rightInset, rowIndex, name, bagCounts, bankCounts, numTiers)
    local row
    if SumCounts(bagCounts) > 0 then
        rowIndex = rowIndex + 1
        row, y = CL.Row(pool, parent, x, y, rightInset, rowIndex)
        if row then
            CL.SetRowName(row, name, "Banker")
            CL.SetRowCounts(row, bagCounts, numTiers)
        end
    end
    if SumCounts(bankCounts) > 0 then
        rowIndex = rowIndex + 1
        row, y = CL.Row(pool, parent, x, y, rightInset, rowIndex)
        if row then
            CL.SetRowName(row, name, "VignetteLoot")
            CL.SetRowCounts(row, bankCounts, numTiers)
        end
    end
    return y, rowIndex
end

--- One reagent block (RecipeCompanionWindow.lua:555-700): header, this character, alts, Warband bank,
--- Total. slot = { qty, candidates = { itemID by quality tier } } (RecipeService:GetRequiredBasicSlots).
function CL.Reagent(pool, parent, x, y, rightInset, rowIndex, slot, needed, collapsed, onToggle, opts)
    local firstID = CandidateID(slot.candidates[1])
    if not firstID then
        return y, rowIndex
    end
    local numTiers = #slot.candidates
    local counts = CL.SlotCounts(slot)
    local totalHave = SumCounts(counts.total)
    local isSufficient = totalHave >= needed
    if opts and opts.sufficient ~= nil then
        isSufficient = opts.sufficient
    end
    local name = (ns.GetItemDisplayName and ns.GetItemDisplayName(firstID)) or "?"
    local nameColor = isSufficient and ("|cff" .. GreenHex())
        or (totalHave > 0 and ("|cff" .. YellowHex()) or ("|cff" .. TextRoleHex("Bright")))
    local check = ns.UI_GetIconMarkup and ns.UI_GetIconMarkup("status_ok", 14, 14, 0, 0) or ""
    y = CL.Header(pool, parent, x, y, rightInset, collapsed,
        (isSufficient and (check .. " ") or "") .. nameColor .. name .. "|r",
        "|cff" .. TextRoleHex("Bright") .. "x" .. needed .. "|r", onToggle, CL.HEADER_HEIGHT)
    if not collapsed then
        local me = CL.ClassName(UnitName and UnitName("player") or "?", UnitClass and select(2, UnitClass("player")) or nil)
        y, rowIndex = HolderRows(pool, parent, x, y, rightInset, rowIndex, me, counts.mine.bag, counts.mine.bank, numTiers)
        for ci = 1, #counts.characters do
            local ch = counts.characters[ci]
            y, rowIndex = HolderRows(pool, parent, x, y, rightInset, rowIndex, CL.ClassName(ch.charName, ch.classFile),
                ch.bagCounts, ch.bankCounts, numTiers)
        end
        local row
        if SumCounts(counts.warband) > 0 then
            rowIndex = rowIndex + 1
            row, y = CL.Row(pool, parent, x, y, rightInset, rowIndex)
            if row then
                CL.SetRowName(row, "|cff" .. YellowHex() .. L("SIDECAR_WARBAND_BANK", "Warband bank") .. "|r", "warbands-icon")
                CL.SetRowCounts(row, counts.warband, numTiers)
            end
        end
        if opts and opts.extraRow then
            rowIndex = rowIndex + 1
            row, y = CL.Row(pool, parent, x, y, rightInset, rowIndex)
            if row then
                CL.SetRowName(row, opts.extraRow.name, opts.extraRow.atlas)
                row._anValue:SetText(opts.extraRow.value or "")
            end
        end
        y = y + 4
        rowIndex = rowIndex + 1
        row, y = CL.Row(pool, parent, x, y, rightInset, rowIndex)
        if row then
            CL.SetRowName(row, nameColor .. L("HUB_SHOP_TOTAL_REAGENTS", "Total reagents") .. "|r")
            CL.SetRowCounts(row, counts.total, numTiers, nameColor)
        end
    end
    return y + CL.SECTION_SPACING, rowIndex
end
