--[[
    Artisan Nexus — Shopping List Service.

    Aggregates reagent demand across a set of (recipe, count) entries the
    player has chosen to craft. Subtracts what's already in bags so the
    list shows only what still needs to be acquired.

    Storage shape (ArtisanNexusDB.global.shoppingList):
      entries = { { spellID = number, count = number }, ... }

    Public API:
      ShoppingListService:Add(spellID, count?)       -- count default 1, additive
      ShoppingListService:AddMany(spellIDs, count?) -- batch merge, one notify; dedupes spellIDs
      ShoppingListService:Remove(spellID)
      ShoppingListService:SetCount(spellID, count)
      ShoppingListService:Clear()
      ShoppingListService:GetEntries() -> array
      ShoppingListService:Aggregate(opts) -> { itemID = { needed, have, short, cost? } }
      ShoppingListService:GetFarmTargets(opts) -> { { category, itemID, short }, ... }
      ShoppingListService:GetPurchaseShorts(opts) -> { { itemID, short, cost? }, ... }
      ShoppingListService:TotalCost() -> copper, missingPriceCount
]]

local ADDON_NAME, ns = ...

local E = ns.Constants and ns.Constants.EVENTS

local ShoppingListService = {}

local function Store()
    local db = ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.global
    if not db then return nil end
    if type(db.shoppingList) ~= "table" then
        db.shoppingList = { entries = {} }
    elseif type(db.shoppingList.entries) ~= "table" then
        db.shoppingList.entries = {}
    end
    return db.shoppingList
end

local function FindEntry(entries, spellID)
    for i = 1, #entries do
        if entries[i].spellID == spellID then return i end
    end
    return nil
end

local function Notify()
    if ns.ArtisanNexus and ns.ArtisanNexus.SendMessage and E and E.SHOPPING_LIST_UPDATED then
        ns.ArtisanNexus:SendMessage(E.SHOPPING_LIST_UPDATED)
    end
end

function ShoppingListService:Add(spellID, count)
    if not spellID then return end
    count = count or 1
    local store = Store(); if not store then return end
    local idx = FindEntry(store.entries, spellID)
    if idx then
        store.entries[idx].count = (store.entries[idx].count or 0) + count
    else
        store.entries[#store.entries + 1] = { spellID = spellID, count = count }
    end
    Notify()
end

--- Merge many recipes in one pass (dedupes duplicate spellIDs in the input list).
---@return number count of distinct spellIDs applied
function ShoppingListService:AddMany(spellIDs, count)
    if not spellIDs or #spellIDs == 0 then return 0 end
    count = math.max(1, tonumber(count) or 1)
    local store = Store(); if not store then return 0 end
    local uniq = {}
    local order = {}
    for i = 1, #spellIDs do
        local sid = spellIDs[i]
        if sid and not uniq[sid] then
            uniq[sid] = true
            order[#order + 1] = sid
        end
    end
    if #order == 0 then return 0 end
    for i = 1, #order do
        local spellID = order[i]
        local idx = FindEntry(store.entries, spellID)
        if idx then
            store.entries[idx].count = (store.entries[idx].count or 0) + count
        else
            store.entries[#store.entries + 1] = { spellID = spellID, count = count }
        end
    end
    Notify()
    return #order
end

function ShoppingListService:Remove(spellID)
    local store = Store(); if not store then return end
    local idx = FindEntry(store.entries, spellID)
    if idx then table.remove(store.entries, idx) end
    Notify()
end

function ShoppingListService:SetCount(spellID, count)
    if (count or 0) <= 0 then return self:Remove(spellID) end
    local store = Store(); if not store then return end
    local idx = FindEntry(store.entries, spellID)
    if idx then store.entries[idx].count = count
    else store.entries[#store.entries + 1] = { spellID = spellID, count = count } end
    Notify()
end

function ShoppingListService:Clear()
    local store = Store(); if not store then return end
    store.entries = {}
    Notify()
end

function ShoppingListService:GetEntries()
    local store = Store(); if not store then return {} end
    local out = {}
    for i, e in ipairs(store.entries) do out[i] = { spellID = e.spellID, count = e.count or 1 } end
    return out
end

---@param opts table|nil profession?: string — skip when nil or "All"
---@return table[]
local function FilterEntriesByProfession(entries, opts)
    opts = opts or {}
    local prof = opts.profession
    if not prof or prof == "All" then
        return entries
    end
    local rs = ns.RecipeService
    if not rs or not rs.GetProfession then
        return entries
    end
    local out = {}
    for i = 1, #entries do
        local e = entries[i]
        if rs:GetProfession(e.spellID) == prof then
            out[#out + 1] = e
        end
    end
    return out
end

--- Aggregate reagent demand across all queued recipes.
--- opts.subtractBags: when true, reduce "needed" by the bag count and report "short".
--- opts.profession: when set and not "All", only recipes for that craft profession.
---@return table itemID -> { itemID, needed, have, short, unitPrice, cost }
function ShoppingListService:Aggregate(opts)
    opts = opts or {}
    local rs = ns.RecipeService
    if not rs then return {} end
    local entries = FilterEntriesByProfession(self:GetEntries(), opts)
    local ahs = ns.AHPriceService
    local agg = {}
    for _, entry in ipairs(entries) do
        --- One requirement per mandatory slot: quality tiers are alternatives,
        --- so pick the cheapest priced candidate (else the first item candidate)
        --- instead of demanding every tier separately.
        local slots = (rs.GetMandatorySlots and rs:GetMandatorySlots(entry.spellID)) or {}
        for si = 1, #slots do
            local slot = slots[si]
            local pickID, pickPrice
            for ci = 1, #slot.candidates do
                local c = slot.candidates[ci]
                if c.itemID then
                    local p = ahs and ahs.GetPrice and ahs:GetPrice(c.itemID)
                    if pickID == nil or (p and (not pickPrice or p < pickPrice)) then
                        pickID = c.itemID
                        pickPrice = p or pickPrice
                    end
                end
            end
            if pickID then
                local row = agg[pickID]
                if not row then
                    row = { itemID = pickID, needed = 0, have = 0, short = 0 }
                    agg[pickID] = row
                end
                row.needed = row.needed + slot.qty * (entry.count or 1)
            end
        end
    end

    -- Bag counts (single source of truth: RecipeService:ScanBags); rank-grouped
    -- so higher-tier mats in bags satisfy the requirement like craftability does.
    if opts.subtractBags ~= false then
        local bag = (rs.ScanBags and rs:ScanBags()) or {}
        for itemID, row in pairs(agg) do
            if rs.EffectiveReagentCount then
                row.have = rs:EffectiveReagentCount(itemID, bag)
            else
                row.have = bag[itemID] or 0
            end
            row.short = math.max(0, row.needed - row.have)
        end
    end

    -- Pricing
    local svc = ns.AHPriceService
    if svc and svc.GetPrice then
        for _, row in pairs(agg) do
            local p = svc:GetPrice(row.itemID)
            if p then
                row.unitPrice = p
                local quantity = opts.subtractBags ~= false and row.short or row.needed
                row.cost = p * quantity
            end
        end
    end

    return agg
end

--- Total copper cost of remaining reagents (after subtracting bags).
function ShoppingListService:TotalCost()
    local agg = self:Aggregate({ subtractBags = true })
    local total, missing = 0, 0
    for _, row in pairs(agg) do
        if row.cost then total = total + row.cost
        elseif (row.short or 0) > 0 then missing = missing + 1 end
    end
    return total, missing
end

local FARM_TAB_ORDER = { herb = 1, mine = 2, leather = 3, fishing = 4, disenchant = 5 }

---@param opts table|nil profession?: string
---@return table[] { category = string, itemID = number, short = number }
function ShoppingListService:GetFarmTargets(opts)
    opts = opts or {}
    local agg = self:Aggregate({ subtractBags = true, profession = opts.profession })
    local byCat = {}
    for itemID, row in pairs(agg) do
        local short = row.short or 0
        if short > 0 and ns.GetGatheringCategoryForItemId then
            local cat = ns.GetGatheringCategoryForItemId(itemID)
            if cat and cat ~= "others" then
                local bucket = byCat[cat]
                if not bucket then
                    bucket = {}
                    byCat[cat] = bucket
                end
                bucket[#bucket + 1] = { category = cat, itemID = itemID, short = short }
            end
        end
    end
    local out = {}
    for _, rows in pairs(byCat) do
        for i = 1, #rows do
            out[#out + 1] = rows[i]
        end
    end
    table.sort(out, function(a, b)
        local ao = FARM_TAB_ORDER[a.category] or 99
        local bo = FARM_TAB_ORDER[b.category] or 99
        if ao ~= bo then
            return ao < bo
        end
        if a.short ~= b.short then
            return a.short > b.short
        end
        return (a.itemID or 0) < (b.itemID or 0)
    end)
    return out
end

--- Short reagents not covered by gathering farm tabs (AH / vendor purchase).
---@param opts table|nil profession?: string
---@return table[] { itemID = number, short = number, cost?: number }
function ShoppingListService:GetPurchaseShorts(opts)
    opts = opts or {}
    local agg = self:Aggregate({ subtractBags = true, profession = opts.profession })
    local out = {}
    for itemID, row in pairs(agg) do
        local short = row.short or 0
        if short > 0 then
            local cat = ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID)
            if not cat or cat == "others" then
                out[#out + 1] = {
                    itemID = itemID,
                    short = short,
                    cost = row.cost,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.short ~= b.short then
            return a.short > b.short
        end
        local ac, bc = a.cost or -1, b.cost or -1
        if ac ~= bc then
            return ac > bc
        end
        return (a.itemID or 0) < (b.itemID or 0)
    end)
    return out
end

ns.ShoppingListService = ShoppingListService
