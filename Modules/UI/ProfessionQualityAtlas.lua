--[[
    Session loot — Midnight (12.x) gathering quality: **exactly two** rank atlases.

    Midnight 12.x: prefer `Professions-ChatIcon-Quality-12-Tier1` / `...-Tier2`, then legacy Tier1/Tier2
    atlases.  The old Dragonflight
    Tier2/Tier3 names (which rendered 2 and 3 diamond dots) are kept as fallbacks in case
    the client still ships them, but should NOT fire first - they produce confusing visuals
    (e.g. rank-1 item showing two dots, rank-2 showing three dots).

    Rules:
    1) Never bind textures from `GetItemReagentQualityInfo` fields (`iconSmall`, ...) - they can
       still resolve to removed art for some item IDs.
    2) Always SetAtlas from the two fixed candidate lists below; first valid atlas wins.
    3) Display index is 1 or 2 only: catalog row index wins when passed; else API numeric tier;
       else item-quality band; else 1.

    API table is still read for optional numeric tier hints (`ExtractCraftingTierIndex`).
]]

local ADDON_NAME, ns = ...

--- Midnight: two visible quality steps only.
ns.PROFESSION_QUALITY_MAX_TIER = 2

--- Rank 1 = lower step (Midnight 12.x chat icons first, then generic Tier1 fallbacks).
ns.PROFESSION_QUALITY_ATLAS_RANK1 = {
    "Professions-ChatIcon-Quality-12-Tier1",
    "Professions-Icon-Quality-Tier1",
    "Professions-ChatIcon-Quality-Tier1",
    "Professions-Crafting-Quality-Icon-Tier1",
}

--- Rank 2 = upper step (Midnight 12.x chat icons first, then generic Tier2 fallbacks).
ns.PROFESSION_QUALITY_ATLAS_RANK2 = {
    "Professions-ChatIcon-Quality-12-Tier2",
    "Professions-Icon-Quality-Tier2",
    "Professions-ChatIcon-Quality-Tier2",
    "Professions-Crafting-Quality-Icon-Tier2",
}

local TIER_LISTS = {
    ns.PROFESSION_QUALITY_ATLAS_RANK1,
    ns.PROFESSION_QUALITY_ATLAS_RANK2,
}

---@param itemID number|nil
---@return table|nil
local function FetchReagentQualityInfo(itemID)
    if not itemID or type(itemID) ~= "number" or itemID < 1 then
        return nil
    end
    if not (C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityInfo) then
        return nil
    end
    local ok, info = pcall(function()
        return C_TradeSkillUI.GetItemReagentQualityInfo(itemID)
    end)
    if ok and type(info) == "table" then
        return info
    end
    return nil
end

--- Best-effort numeric crafting tier from API table (field names vary by patch).
---@param info table|nil
---@return number|nil
local function ExtractCraftingTierIndex(info)
    if type(info) ~= "table" then
        return nil
    end
    local keys = {
        "quality",
        "craftingQuality",
        "qualityTier",
        "tier",
        "qualityIndex",
    }
    for i = 1, #keys do
        local v = info[keys[i]]
        if type(v) == "number" and v >= 1 and v <= 10 then
            return math.floor(v + 0.5)
        end
    end
    return nil
end

--- Clamp any legacy 3–5 / API noise to the two Midnight display slots.
---@param n number|nil
---@return number 1|2
local function ClampDisplayTier(n)
    if type(n) ~= "number" then
        return 1
    end
    local t = math.floor(n + 0.5)
    if t < 1 then
        t = 1
    end
    if t > 2 then
        t = 2
    end
    return t
end

--- Tier index 1 or 2 for Session loot atlases (never uses API texture strings).
---@param itemID number|nil
---@param catalogTierHint number|nil 1-based row in catalog `ranks[]` for this cell
---@param info table|nil optional cached `GetItemReagentQualityInfo` result
---@return number
function ns.ResolveProfessionLootTierIndex(itemID, catalogTierHint, info)
    if type(catalogTierHint) == "number" and catalogTierHint >= 1 then
        return ClampDisplayTier(catalogTierHint)
    end
    info = info or FetchReagentQualityInfo(itemID)
    local t = ExtractCraftingTierIndex(info)
    if t then
        return ClampDisplayTier(t)
    end
    local r = ns.GetProfessionDisplayTierForItem and ns.GetProfessionDisplayTierForItem(itemID)
    if type(r) == "number" and r >= 1 then
        return ClampDisplayTier(r)
    end
    return 1
end

--- Returns true if the named atlas is known to the current client build.
local function AtlasExists(name)
    if C_Texture and C_Texture.GetAtlasInfo then
        return C_Texture.GetAtlasInfo(name) ~= nil
    end
    return true  -- can't validate; let SetAtlas try
end

---@param tex Texture
---@param rank number 1–2 (Midnight)
---@param width number|nil
---@param height number|nil
---@return boolean success
function ns.SetProfessionRankAtlas(tex, rank, width, height)
    if not tex or not tex.SetAtlas then
        return false
    end
    local tier = ClampDisplayTier(rank)
    local list = TIER_LISTS[tier] or TIER_LISTS[1]
    local w = width or 20
    local h = height or 20
    for i = 1, #list do
        local name = list[i]
        if AtlasExists(name) then
            local ok = pcall(function()
                tex:SetAtlas(name, false)
                tex:SetSize(w, h)
                tex:Show()
            end)
            if ok then
                return true
            end
        end
    end
    return false
end

--- Always one of the two Midnight atlas lists; `catalogTierHint` should match the catalog row.
---@param tex Texture
---@param itemID number|nil
---@param width number|nil
---@param height number|nil
---@param catalogTierHint number|nil catalog `ranks[]` index (1..2) for this row/cell
---@return boolean success
function ns.SetProfessionRankAtlasForItem(tex, itemID, width, height, catalogTierHint)
    if not tex or not tex.SetAtlas then
        return false
    end
    local w = width or 20
    local h = height or 20
    local info = FetchReagentQualityInfo(itemID)
    local tier = ns.ResolveProfessionLootTierIndex(itemID, catalogTierHint, info)
    return ns.SetProfessionRankAtlas(tex, tier, w, h)
end

--- Map item quality to **1 or 2** for rank fallback (rare+ → high slot).
---@param itemID number|nil
---@return number|nil
function ns.GetProfessionDisplayTierForItem(itemID)
    if not itemID or type(itemID) ~= "number" or itemID < 1 then
        return nil
    end
    local q
    if C_Item and C_Item.GetItemQualityByID then
        local ok, qv = pcall(C_Item.GetItemQualityByID, C_Item, itemID)
        if ok then
            q = qv
        end
    end
    if q == nil and GetItemInfo then
        q = select(3, GetItemInfo(itemID))
    end
    if q == nil then
        return nil
    end
    q = tonumber(q) or 1
    if q < 1 then
        q = 1
    end
    if q >= 3 then
        return 2
    end
    return 1
end
