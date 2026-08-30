--[[
    Midnight fish — reference grid. Most fish are a single rank; use ranks = { id }.
    12.0.x base set is contiguous 238365–238384 (20 fish).
    12.1 “Coiled Isle” added 14 fish in two blocks: 274587–274594 (open water /
    Venom Fishing) and 279091–279106 (Temple Fishing, non-contiguous).
    Verified against wago.tools DB2 (Item, ItemSparse) build 12.1.0.69497, 2026-08-29.
    AH scan + session routing use this list.
]]

local ADDON_NAME, ns = ...

local ENTRIES = {
    { note = "Sin'dorei Swarmer", ranks = { 238365 } },
    { note = "Lynxfish", ranks = { 238366 } },
    { note = "Root Crab", ranks = { 238367 } },
    { note = "Twisted Tetra", ranks = { 238368 } },
    { note = "Bloomtail Minnow", ranks = { 238369 } },
    { note = "Shimmer Spinefish", ranks = { 238370 } },
    { note = "Arcane Wyrmfish", ranks = { 238371 } },
    { note = "Restored Songfish", ranks = { 238372 } },
    { note = "Ominous Octopus", ranks = { 238373 } },
    { note = "Tender Lumifin", ranks = { 238374 } },
    { note = "Fungalskin Pike", ranks = { 238375 } },
    { note = "Lucky Loa", ranks = { 238376 } },
    { note = "Blood Hunter", ranks = { 238377 } },
    { note = "Shimmersiren", ranks = { 238378 } },
    { note = "Warping Wise", ranks = { 238379 } },
    { note = "Null Voidfish", ranks = { 238380 } },
    { note = "Hollow Grouper", ranks = { 238381 } },
    { note = "Gore Guppy", ranks = { 238382 } },
    { note = "Eversong Trout", ranks = { 238383 } },
    { note = "Sunwell Fish", ranks = { 238384 } },

    --- 12.1 Coiled Isle — open water / Venom Fishing.
    { note = "Spotted Killifish", ranks = { 274587 } },
    { note = "Toxic Tlhapi", ranks = { 274588 } },
    { note = "Ula'tek Snakehead", ranks = { 274589 } },
    { note = "Sulfurous Sludgefish", ranks = { 274590 } },
    { note = "Coiled Stargorger", ranks = { 274591 } },
    { note = "Dirty Darter", ranks = { 274592 } },
    { note = "Blightswarmer", ranks = { 274593 } },
    { note = "Polluted Puffer", ranks = { 274594 } },

    --- 12.1 Coiled Isle — Temple Fishing pools.
    { note = "Oozing Goby", ranks = { 279091 } },
    { note = "Giggling Skull", ranks = { 279093 } },
    { note = "Grotesque Sturgeon", ranks = { 279094 } },
    { note = "Many-Eyed Flounder", ranks = { 279100 } },
    { note = "Twin-Headed Snipefish", ranks = { 279105 } },
    { note = "Loathsome Anglerfish", ranks = { 279106 } },
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
        wipe(fishingItemCache)
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
