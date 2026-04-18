--[[
    Midnight gathering reference by category (Herbalism / Mining / Leather / Disenchant).
    Single representative icon per row uses ranks[1]; qualities shown for all ranks[].
]]

local ADDON_NAME, ns = ...

---@type table<string, table[]>
local BY_CAT = {
    herb = {
        { note = "Tranquility Bloom", ranks = { 236761, 236767 } },
        { note = "Sanguithorn", ranks = { 236770 } },
        { note = "Azeroot", ranks = { 236774 } },
        { note = "Argentleaf", ranks = { 236776 } },
        { note = "Mana Lily", ranks = { 236778 } },
        { note = "Nocturnal Lotus", ranks = { 236780 } },
    },
    mine = {
        { note = "Refulgent Copper Ore", ranks = { 237359 } },
        { note = "Umbral Tin Ore", ranks = { 237362 } },
        { note = "Brilliant Silver Ore", ranks = { 237364 } },
        { note = "Dazzling Thorium", ranks = { 237366 } },
        { note = "Mote of Light", ranks = { 236949 } },
        { note = "Mote of Primal Energy", ranks = { 236950 } },
        { note = "Mote of Wild Magic", ranks = { 236951 } },
        { note = "Mote of Pure Void", ranks = { 236952 } },
    },
    leather = {
        { note = "Resilient Leather", ranks = { 193208 } },
        { note = "Dense Hide", ranks = { 193216 } },
        { note = "Thunderous Hide", ranks = { 193217 } },
    },
    disenchant = {
        { note = "Cosmic Essence (example)", ranks = { 124461 } },
        { note = "Temporal Shard (example)", ranks = { 172232 } },
    },
}

---@param cat "herb"|"mine"|"leather"|"disenchant"|string|nil
---@return table[]
function ns.GetGatheringCatalogByCategory(cat)
    local t = BY_CAT[cat or "herb"]
    if t then
        return t
    end
    return BY_CAT.herb
end

---@return table[]
function ns.GetGatheringCatalogEntries()
    return ns.GetGatheringCatalogByCategory("herb")
end

--- Lazy reverse map: itemID → tab key (herb / mine / leather / disenchant) for session routing.
local itemCategoryCache = {}
local itemCategoryCacheBuilt = false

---@param itemID number|nil
---@return string|nil
function ns.GetGatheringCategoryForItemId(itemID)
    if not itemID or type(itemID) ~= "number" then
        return nil
    end
    if not itemCategoryCacheBuilt then
        itemCategoryCacheBuilt = true
        local Resolve = ns.ResolveCatalogEntryRanks
        if Resolve then
            for _, cat in ipairs({ "herb", "mine", "leather", "disenchant" }) do
                local list = BY_CAT[cat]
                if list then
                    for i = 1, #list do
                        local entry = list[i]
                        local ranks = Resolve(entry)
                        for r = 1, #ranks do
                            local rid = ranks[r]
                            if rid and not itemCategoryCache[rid] then
                                itemCategoryCache[rid] = cat
                            end
                        end
                    end
                end
            end
        end
    end
    return itemCategoryCache[itemID]
end
