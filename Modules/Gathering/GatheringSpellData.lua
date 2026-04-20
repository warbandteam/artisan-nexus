--[[
    Gathering spells → UI category (herb / mine / leather / disenchant).
    Static IDs + C_Spell icon fallbacks for Midnight spell IDs not yet listed.
    Item routing: reference catalog first, then Trade Goods subclass heuristics.
]]

local ADDON_NAME, ns = ...

---@class GatheringSpellData
local GatheringSpellData = {}

--- Herbalism
local HERB = {
    [2366] = true, [3570] = true, [11993] = true, [28695] = true, [50300] = true,
    [55428] = true, [55480] = true, [55500] = true, [74519] = true, [158749] = true,
    [193290] = true, [265835] = true, [309827] = true, [391415] = true, [391416] = true,
    [423443] = true,
}

--- Mining
local MINE = {
    [2575] = true, [2576] = true, [3564] = true, [10248] = true, [29354] = true,
    [50310] = true, [74517] = true, [102161] = true, [158716] = true, [184457] = true,
    [383062] = true, [395886] = true, [423334] = true, [423335] = true,
}

--- Skinning / leather gathering (loot attributed to “leather” tab)
local LEATHER = {
    [8613] = true, [8617] = true, [8618] = true, [10768] = true, [32678] = true,
    [50305] = true, [74522] = true, [158756] = true, [194279] = true, [265865] = true,
}

--- Disenchant (classic + retail; add Midnight IDs when known)
local DISENCHANT = {
    [13262] = true,
    [207189] = true,
    [255630] = true,
}

local ALL = {}

local function MergeInto(dst, src)
    for k in pairs(src) do
        dst[k] = true
    end
end

MergeInto(ALL, HERB)
MergeInto(ALL, MINE)
MergeInto(ALL, LEATHER)
MergeInto(ALL, DISENCHANT)

--- Spell UI icons (Trade * / ability icons) — stable across locales; used when spellID ∉ ALL.
local SPELL_ICON_HERB = 136246
local SPELL_ICON_MINE = 134708
local SPELL_ICON_LEATHER = 134366
local SPELL_ICON_DISENCHANT = 135433

---@param spellId number|nil
---@return "herb"|"mine"|"leather"|"disenchant"|nil
function GatheringSpellData.GetCategory(spellId)
    if not spellId then return nil end
    if HERB[spellId] then return "herb" end
    if MINE[spellId] then return "mine" end
    if LEATHER[spellId] then return "leather" end
    if DISENCHANT[spellId] then return "disenchant" end
    return nil
end

--- Infer gathering tab from spell art + fishing exclusion (Midnight unknown IDs).
---@param spellId number|nil
---@return "herb"|"mine"|"leather"|"disenchant"|nil
function GatheringSpellData.InferGatheringCategoryFromSpell(spellId)
    if not spellId then
        return nil
    end
    if issecretvalue and issecretvalue(spellId) then
        return nil
    end
    local known = GatheringSpellData.GetCategory(spellId)
    if known then
        return known
    end
    if ns.FishingSpellData and ns.FishingSpellData.IsFishingSpell(spellId) then
        return nil
    end
    if not C_Spell or not C_Spell.GetSpellInfo then
        return nil
    end
    local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
    if not ok or not info or not info.iconID then
        return nil
    end
    local icon = info.iconID
    if issecretvalue and issecretvalue(icon) then
        return nil
    end
    if icon == SPELL_ICON_HERB then
        return "herb"
    end
    if icon == SPELL_ICON_MINE then
        return "mine"
    end
    if icon == SPELL_ICON_LEATHER then
        return "leather"
    end
    if icon == SPELL_ICON_DISENCHANT then
        return "disenchant"
    end
    return nil
end

---@param spellId number|nil
---@return boolean
function GatheringSpellData.IsGatheringSpell(spellId)
    if not spellId then
        return false
    end
    if ALL[spellId] then
        return true
    end
    return GatheringSpellData.InferGatheringCategoryFromSpell(spellId) ~= nil
end

--- Catalog first, then Trade Goods subclasses via C_Item.GetItemInfoInstant (works before GetItemInfo cache fills).
---@param itemID number|nil
---@return "herb"|"mine"|"leather"|"disenchant"|nil
function GatheringSpellData.InferCategoryFromItemId(itemID)
    if not itemID then
        return nil
    end
    local fromCat = ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID)
    if fromCat then
        return fromCat
    end
    local classID, subID
    if C_Item and C_Item.GetItemInfoInstant then
        local ok, inst = pcall(C_Item.GetItemInfoInstant, itemID)
        if ok and inst and type(inst) == "table" then
            classID = inst.classID or inst.itemClassID
            subID = inst.subclassID or inst.itemSubClassID
        end
    end
    if not classID then
        classID = select(12, GetItemInfo(itemID))
        subID = select(13, GetItemInfo(itemID))
    end
    if not classID then
        return nil
    end
    -- Trade Goods (7): subclass IDs vary by patch — heuristic fallback only.
    if classID == 7 and subID then
        -- Enchanting materials (shards, essences) → Disenchanting tab
        if subID == 12 then
            return "disenchant"
        end
        if subID == 4 or subID == 6 then
            return "mine"
        end
        if subID == 9 or subID == 11 then
            return "herb"
        end
        if subID == 5 or subID == 8 then
            return "leather"
        end
    end
    return nil
end

ns.GatheringSpellData = GatheringSpellData
