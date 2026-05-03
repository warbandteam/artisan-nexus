--[[
    Artisan Nexus — Shopping List Service.

    Aggregates reagent demand across a set of (recipe, count) entries the
    player has chosen to craft. Subtracts what's already in bags so the
    list shows only what still needs to be acquired.

    Storage shape (ArtisanNexusDB.global.shoppingList):
      entries = { { spellID = number, count = number }, ... }

    Public API:
      ShoppingListService:Add(spellID, count?)       -- count default 1, additive
      ShoppingListService:Remove(spellID)
      ShoppingListService:SetCount(spellID, count)
      ShoppingListService:Clear()
      ShoppingListService:GetEntries() -> array
      ShoppingListService:Aggregate(opts) -> { itemID = { needed, have, short, cost? } }
      ShoppingListService:TotalCost() -> copper, missingPriceCount
]]

local ADDON_NAME, ns = ...

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
    if ns.ArtisanNexus and ns.ArtisanNexus.SendMessage then
        ns.ArtisanNexus:SendMessage("AN_SHOPPING_LIST_UPDATED")
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

--- Aggregate reagent demand across all queued recipes.
--- opts.subtractBags: when true, reduce "needed" by the bag count and report "short".
---@return table itemID -> { itemID, needed, have, short, unitPrice, cost }
function ShoppingListService:Aggregate(opts)
    opts = opts or {}
    local rs = ns.RecipeService
    if not rs then return {} end
    local entries = self:GetEntries()
    local agg = {}
    for _, entry in ipairs(entries) do
        local reagents = rs:GetReagents(entry.spellID) or {}
        for _, r in ipairs(reagents) do
            local row = agg[r.itemID]
            if not row then
                row = { itemID = r.itemID, needed = 0, have = 0, short = 0 }
                agg[r.itemID] = row
            end
            row.needed = row.needed + (r.qty or 0) * (entry.count or 1)
        end
    end

    -- Bag counts (single source of truth: RecipeService:ScanBags)
    if opts.subtractBags ~= false then
        local bag = (rs.ScanBags and rs:ScanBags()) or {}
        for itemID, row in pairs(agg) do
            row.have = bag[itemID] or 0
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

ns.ShoppingListService = ShoppingListService
