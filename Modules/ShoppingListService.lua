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

local ACUITY_ITEM_ID = (ns.Constants and ns.Constants.ARTISANS_ACUITY_ITEM_ID) or 210814

local E = ns.Constants.EVENTS

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

--- Per-frame Aggregate memo: one Shopping render calls Aggregate via TotalCost,
--- GetFarmTargets and GetPurchaseShorts as well; GetTime() changes every frame.
local aggMemo = { stamp = nil, results = {} }

local function InvalidateAggregateMemo()
    aggMemo.stamp = nil
    aggMemo.results = {}
end

local function Notify()
    InvalidateAggregateMemo()
    ns.ArtisanNexus:SendMessage(E.SHOPPING_LIST_UPDATED)
end

--- Public re-broadcast (settings that change Aggregate output, e.g. shoppingIncludeFinishing / price provider).
function ShoppingListService:Notify()
    Notify()
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

--- Set the craft count for a recipe (count <= 0 removes it; unknown recipes are appended).
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
--- opts.subtractBags: when true, reduce "needed" by what is in stock and report "short". Stock is
--- the crafting count (RecipeService:GetStockByLocation: bags + bank + warband bank) summed over the
--- slot's quality tiers, the same have the Crafting tab and the sidecar use.
--- opts.profession: when set and not "All", only recipes for that craft profession.
---@return table itemID -> { itemID, needed, have, short, unitPrice, cost, cands = {itemID...},
---   bySpell = { [spellID] = qty }, bags, bank, warband }
function ShoppingListService:Aggregate(opts)
    opts = opts or {}
    local rs = ns.RecipeService
    if not rs then return {} end
    local now = GetTime()
    if aggMemo.stamp ~= now then
        aggMemo.stamp = now
        aggMemo.results = {}
    end
    local p = ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.profile
    local subtractAlts = p and p.shoppingSubtractAlts == true
    local memoKey = tostring(opts.subtractBags ~= false) .. "|" .. tostring(opts.profession or "All") .. "|" .. tostring(subtractAlts)
    local cached = aggMemo.results[memoKey]
    if cached then
        return cached
    end
    local entries = FilterEntriesByProfession(self:GetEntries(), opts)
    local ahs = ns.AHPriceService
    local withFinishing = p and p.shoppingIncludeFinishing == true
    local agg = {}
    for _, entry in ipairs(entries) do
        --- One requirement per mandatory slot: quality tiers are alternatives,
        --- so pick the cheapest priced candidate (else the first item candidate)
        --- instead of demanding every tier separately.
        local slots = (rs.GetMandatorySlots and rs:GetMandatorySlots(entry.spellID, withFinishing)) or {}
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
                    row = { itemID = pickID, needed = 0, have = 0, short = 0, cands = {}, candSeen = {}, bySpell = {} }
                    agg[pickID] = row
                end
                local qty = slot.qty * (entry.count or 1)
                row.needed = row.needed + qty
                row.bySpell[entry.spellID] = (row.bySpell[entry.spellID] or 0) + qty
                for ci = 1, #slot.candidates do
                    local id = slot.candidates[ci].itemID
                    if id and not row.candSeen[id] then
                        row.candSeen[id] = true
                        row.cands[#row.cands + 1] = id
                    end
                end
            end
        end
    end

    -- Stock (RecipeService:GetStockByLocation, cached per BAG_UPDATE / bank bucket generation): every
    -- quality tier of the slot counts, like the craft count of the Crafting tab.
    if opts.subtractBags ~= false then
        local chars = ns.CharacterData
        -- A tier counts toward one row only: two recipes can pick different tiers of one reagent
        -- (different candidate sets), and both rows would otherwise count the same stack.
        -- Rows go in item ID order so the same row keeps a shared tier on every paint.
        local claimed = {}
        local order = {}
        for itemID in pairs(agg) do
            order[#order + 1] = itemID
        end
        table.sort(order)
        for oi = 1, #order do
            local itemID = order[oi]
            local row = agg[itemID]
            local bags, bank, warband = 0, 0, 0
            for ci = 1, #row.cands do
                local id = row.cands[ci]
                if not claimed[id] or claimed[id] == itemID then
                    claimed[id] = itemID
                    local st = rs:GetStockByLocation(id)
                    bags, bank, warband = bags + st.bags, bank + st.bank, warband + st.warband
                end
            end
            row.bags, row.bank, row.warband = bags, bank, warband
            row.have = bags + bank + warband
            row.short = math.max(0, row.needed - row.have)

            -- Cross-character reagent inventory (Warband Nexus or AN-native snapshot).
            -- Alts' stock is subtracted only when the player opts in (it must be mailed over first).
            local counts = chars:GetItemCountsAcrossCharacters(itemID)
            if counts then
                row.altHave = counts.total or 0
                row.altDetails = counts.chars
                if subtractAlts and row.altHave > 0 then
                    row.short = math.max(0, row.short - row.altHave)
                end
            end
        end
    end

    -- Pricing & Soulbound detection
    local svc = ns.AHPriceService
    for _, row in pairs(agg) do
        local itemID = row.itemID
        if itemID == ACUITY_ITEM_ID then
            row.isAcuity = true
            row.isSoulbound = true
        elseif C_Item and C_Item.GetItemInfo then
            -- bindType is GetItemInfo return 14 (GetItemInfoInstant has only 7); nil while uncached = unknown.
            local bindType = select(14, C_Item.GetItemInfo(itemID))
            if bindType == 1 then
                row.isSoulbound = true
            end
        end

        if svc and svc.GetPrice then
            local unit = svc:GetPrice(itemID)
            if unit then
                row.unitPrice = unit
                local quantity = opts.subtractBags ~= false and row.short or row.needed
                -- Walk the stored commodity book: buying 200 units costs more than 200 x min.
                local econ = ns.Economy
                local total = econ and econ.BuyCost and econ:BuyCost(itemID, quantity)
                row.cost = total or (unit * quantity)
                if quantity > 0 and total then
                    row.avgUnitCost = total / quantity
                end
            end
        end
    end

    aggMemo.results[memoKey] = agg
    return agg
end

--- Total copper cost of remaining reagents (after subtracting bags), missing count, and acuity requirement.
---@param opts table|nil profession?: string (same filter as the rows the Hub shows)
function ShoppingListService:TotalCost(opts)
    opts = opts or {}
    local agg = self:Aggregate({ subtractBags = true, profession = opts.profession })
    local total, missing, acuityNeeded = 0, 0, 0
    for _, row in pairs(agg) do
        if row.cost then
            total = total + row.cost
        elseif (row.short or 0) > 0 and not row.isSoulbound then
            missing = missing + 1
        end
        if row.isAcuity or row.itemID == ACUITY_ITEM_ID then
            acuityNeeded = acuityNeeded + (row.short or 0)
        end
    end
    return total, missing, acuityNeeded
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
