--[[
    Midnight gathering reference by category (Herbalism / Mining / Leather / Disenchant / Others motes).
    Single representative icon per row uses ranks[1]; qualities shown for all ranks[].

    Some Midnight mats (e.g. Motes) can drop from more than one activity; they may appear in multiple
    tab grids. `GetGatheringCategoryForItemId` returns a primary tab (mine for motes) for DB reset
    ownership; `ItemListedInGatheringTab` is used for session routing and per-tab Overall totals.

    Maintenance (12.0.x): IDs follow beta/PTR builds and in-game verification. When Blizzard adds
    new rank tiers or mats, append `ranks` (and optionally a new row). Mining “Dazzling Thorium”
    ships as a single rank until a second item ID is confirmed. Leather rows use documented two-ID
    pairs where Silver/Gold splits exist; add missing IDs in the same column format.
]]

local ADDON_NAME, ns = ...

---@type table<string, table[]>
local BY_CAT = {
    herb = {
        { note = "Tranquility Bloom", ranks = { 236761, 236767 } },
        { note = "Sanguithorn", ranks = { 236770, 236771 } },
        { note = "Azeroot", ranks = { 236774, 236775 } },
        { note = "Argentleaf", ranks = { 236776, 236777 } },
        { note = "Mana Lily", ranks = { 236778, 236779 } },
        { note = "Nocturnal Lotus", ranks = { 236780, 236781 } },
    },
    mine = {
        -- Ores: R2 IDs from Midnight item pairs (Wowhead); copper skips 237360.
        { note = "Refulgent Copper Ore", ranks = { 237359, 237361 } },
        { note = "Umbral Tin Ore", ranks = { 237362, 237363 } },
        { note = "Brilliant Silver Ore", ranks = { 237364, 237365 } },
        -- No separate R2 item id documented next to 237366 (237367 is another item); single slot until confirmed.
        { note = "Dazzling Thorium", ranks = { 237366 } },
    },
    --- Midnight skinning (12.0.x). Two item IDs = Silver / Gold reagent ranks where Blizzard split them.
    --- Species-specific side mats may share one ID per type in the DB; add a second ID when confirmed in-game.
    leather = {
        { note = "Void-Tempered Leather", ranks = { 238511, 238512 } },
        { note = "Void-Tempered Scales", ranks = { 238513, 238514 } },
        { note = "Void-Tempered Hide", ranks = { 238518, 238519 } },
        { note = "Void-Tempered Plating", ranks = { 238520, 238521 } },
        { note = "Peerless Plumage", ranks = { 238522 } },
        { note = "Carving Canine", ranks = { 238523 } },
        { note = "Fantastic Fur", ranks = { 238525 } },
        { note = "Majestic Claw", ranks = { 238528 } },
        { note = "Majestic Hide", ranks = { 238529 } },
        { note = "Majestic Fin", ranks = { 238530 } },
    },
    --- Midnight disenchant / enchanting trade reagents (uncommon → dust, rare → shard, epic → crystal); two ranks each.
    disenchant = {
        { note = "Eversinging Dust", ranks = { 243599, 243600 } },
        { note = "Radiant Shard", ranks = { 243602, 243603 } },
        { note = "Dawn Crystal", ranks = { 243605, 243606 } },
    },
    --- Shared drops that can come from more than one gathering source.
    others = {
        { note = "Mote of Light", ranks = { 236949 } },
        { note = "Mote of Primal Energy", ranks = { 236950 } },
        { note = "Mote of Wild Magic", ranks = { 236951 } },
        { note = "Mote of Pure Void", ranks = { 236952 } },
    },
}

---@param cat "herb"|"mine"|"leather"|"disenchant"|"others"|string|nil
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

--- [itemID] = { herb = true, mine = true, ... } — an item may appear on multiple tab grids (e.g. motes).
local itemTabMembership = {}
--- Primary tab: used for legacy callers and `Reset overall` (single owner per item in DB).
local itemPrimaryTab = {}
local gatheringItemRegistryBuilt = false

local function BuildGatheringItemRegistry()
    if gatheringItemRegistryBuilt then
        return
    end
    gatheringItemRegistryBuilt = true
    local Resolve = ns.ResolveCatalogEntryRanks
    if not Resolve then
        return
    end
    for _, cat in ipairs({ "herb", "mine", "leather", "disenchant", "others" }) do
        local list = BY_CAT[cat]
        if list then
            for i = 1, #list do
                local entry = list[i]
                local ranks = Resolve(entry)
                for r = 1, #ranks do
                    local rid = ranks[r]
                    if rid then
                        itemTabMembership[rid] = itemTabMembership[rid] or {}
                        itemTabMembership[rid][cat] = true
                    end
                end
            end
        end
    end
    for rid, tabs in pairs(itemTabMembership) do
        local n = 0
        local only = nil
        for k in pairs(tabs) do
            n = n + 1
            only = only or k
        end
        if n == 1 then
            itemPrimaryTab[rid] = only
        else
            --- Multi-listed items (if any) prefer explicit "others" bucket.
            itemPrimaryTab[rid] = tabs.others and "others" or only
        end
    end
end

--- Primary catalog tab for an item (mine for dual-listed motes). Used by reset-overall (primary) and fallbacks.
---@param itemID number|nil
---@return string|nil
function ns.GetGatheringCategoryForItemId(itemID)
    if not itemID or type(itemID) ~= "number" then
        return nil
    end
    BuildGatheringItemRegistry()
    return itemPrimaryTab[itemID]
end

--- True if this item appears on the given profession tab grid (herb vs mine motes both true).
---@param itemID number|nil
---@param cat "herb"|"mine"|"leather"|"disenchant"|"others"|string|nil
---@return boolean
function ns.ItemListedInGatheringTab(itemID, cat)
    if not itemID or not cat or type(itemID) ~= "number" then
        return false
    end
    BuildGatheringItemRegistry()
    local t = itemTabMembership[itemID]
    return t and t[cat] and true or false
end

--- True if `itemID` appears in the gathering reference catalog (any profession tab).
---@param itemID number|nil
---@return boolean
function ns.IsGatheringCatalogItem(itemID)
    if not itemID or type(itemID) ~= "number" then
        return false
    end
    BuildGatheringItemRegistry()
    return itemTabMembership[itemID] ~= nil
end
