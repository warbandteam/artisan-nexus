--[[
    Midnight (12.0.x) fish — reference grid. Most fish are a single rank; use ranks = { id }.
]]

local ADDON_NAME, ns = ...

local ENTRIES = {
    { note = "Sin'dorei Swarmer", ranks = { 238365 } },
    { note = "Lynxfish", ranks = { 238366 } },
    { note = "Root Crab", ranks = { 238367 } },
    { note = "Arcane Wyrmfish", ranks = { 238371 } },
    { note = "Restored Songfish", ranks = { 238372 } },
    { note = "Ominous Octopus", ranks = { 238373 } },
    { note = "Tender Lumifin", ranks = { 238374 } },
    { note = "Fungalskin Pike", ranks = { 238375 } },
    { note = "Blood Hunter", ranks = { 238377 } },
    { note = "Warping Wise", ranks = { 238379 } },
    { note = "Null Voidfish", ranks = { 238380 } },
    { note = "Gore Guppy", ranks = { 238382 } },
    { note = "Eversong Trout", ranks = { 238383 } },
}

---@return table[]
function ns.GetFishingCatalogEntries()
    return ENTRIES
end

local fishingItemCache = {}
local fishingItemCacheBuilt = false

---@param itemID number|nil
---@return boolean
function ns.IsFishingCatalogItem(itemID)
    if not itemID or type(itemID) ~= "number" then
        return false
    end
    if not fishingItemCacheBuilt then
        fishingItemCacheBuilt = true
        local Resolve = ns.ResolveCatalogEntryRanks
        if Resolve then
            for i = 1, #ENTRIES do
                local ranks = Resolve(ENTRIES[i])
                for r = 1, #ranks do
                    local rid = ranks[r]
                    if rid then
                        fishingItemCache[rid] = true
                    end
                end
            end
        end
    end
    return fishingItemCache[itemID] == true
end
