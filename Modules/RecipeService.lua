--[[
    Artisan Nexus — Midnight Recipe Service.

    Two-way index over Midnight recipes:
      * spellID → reagents (what to loot/farm for a chosen recipe)
      * itemID  → recipes that use it (what can I craft from what I have)

    The canonical recipe ID list lives in ns.MidnightRecipeCatalog (generated
    from wago.tools DB2 dumps). Reagent data cannot be fully derived from DB2
    alone on Midnight (modified reagents + quality tiers), so this service
    harvests reagent schematics at runtime via C_TradeSkillUI and persists
    them to SavedVariables. Once a profession window has been opened on any
    character, the reagent index is stable across sessions.

    SavedVariables shape (ArtisanNexusDB.global.recipeSchematics):
      [spellID] = {
        name       = string,
        profession = string,
        output     = { itemID = number|nil },
        reagents   = { { itemID = number, qty = number, slotType = number|nil }, ... },
        updated    = unix,
      }
]]

local ADDON_NAME, ns = ...

---@class RecipeService
local RecipeService = {
    _reverseIndex = nil,
    _bagCounts = nil,
    _bagCacheGen = 0,
    _listHarvestPending = false,
}
ns.RecipeService = RecipeService

local E = ns.Constants.EVENTS

--==========================================================================
-- Catalog helpers
--==========================================================================

--- Craft use game spell/recipe IDs as numbers; force consistent keying for lookups / SavedVariables.
---@param id any
---@return number|any
local function NormalizeSpellID(id)
    local n = tonumber(id)
    return n or id
end

---@return table<number, string>  spellID -> profession name
local function BuildSpellToProfession()
    local out = {}
    local cat = ns.MidnightRecipeCatalog
    if not cat then return out end
    for prof, data in pairs(cat) do
        for spellID, _ in pairs(data.recipes or {}) do
            out[NormalizeSpellID(spellID)] = prof
        end
    end
    return out
end

local SPELL_TO_PROF

---@param spellID number
---@return string|nil
function RecipeService:GetProfession(spellID)
    if not SPELL_TO_PROF then SPELL_TO_PROF = BuildSpellToProfession() end
    return SPELL_TO_PROF[NormalizeSpellID(spellID)]
end

---@param spellID number
---@return boolean
function RecipeService:IsMidnightRecipe(spellID)
    return self:GetProfession(spellID) ~= nil
end

---@param spellID number
---@return string|nil
function RecipeService:GetRecipeName(spellID)
    spellID = NormalizeSpellID(spellID)
    local sch = self:GetSchematic(spellID)
    if sch and type(sch.name) == "string" and sch.name ~= "" then
        return sch.name
    end
    local cat = ns.MidnightRecipeCatalog
    if not cat then return nil end
    spellID = NormalizeSpellID(spellID)
    local prof = self:GetProfession(spellID)
    if not prof then return nil end
    local map = cat[prof].recipes or {}
    local name = map[spellID] or map[tostring(spellID)]
    if name and name ~= "" then return name end
    return nil
end

--==========================================================================
-- SavedVariables accessors
--==========================================================================

local function Store()
    if not ns.db or not ns.db.global then return nil end
    ns.db.global.recipeSchematics = ns.db.global.recipeSchematics or {}
    return ns.db.global.recipeSchematics
end

---@return table|nil spellID -> schematic row
function RecipeService:GetSchematicStore()
    return Store()
end

---@param spellID number
---@return table|nil
function RecipeService:GetSchematic(spellID)
    local s = Store()
    if not s then return nil end
    return s[NormalizeSpellID(spellID)]
end

---@param spellID number
---@return table[]  array of { itemID, qty, slotType }
function RecipeService:GetReagents(spellID)
    local sch = self:GetSchematic(spellID)
    return (sch and sch.reagents) or {}
end

---@param spellID number
---@return number|nil output itemID
function RecipeService:GetOutputItem(spellID)
    local sch = self:GetSchematic(spellID)
    return sch and sch.output and sch.output.itemID or nil
end

--- Icon fileID for lists: harvested schematic, else live GetRecipeInfo (works before first harvest).
---@param spellID number
---@return number|nil fileID
function RecipeService:GetRecipeDisplayIconFileID(spellID)
    spellID = NormalizeSpellID(spellID)
    local sch = self:GetSchematic(spellID)
    if sch and type(sch.recipeIcon) == "number" and sch.recipeIcon > 0 then
        return sch.recipeIcon
    end
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
        local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, spellID)
        if ok and type(info) == "table" and type(info.icon) == "number" and info.icon > 0 then
            return info.icon
        end
    end
    return nil
end

--- Mandatory reagent requirements deduped per schematic slot. Harvest stores
--- EVERY quality-tier candidate of a slot as its own row with the full slot
--- quantity — flat sums over those rows multiply cost/needs by the tier count.
--- Here tiers collapse into ONE requirement with a candidate list, and
--- non-Basic slots (modifying/finishing — optional) are excluded from cost,
--- craftability and shopping math. Legacy rows without slotType count as
--- Basic; rows without dataSlotIndex each form their own slot.
---@param spellID number
---@return table[] slots: { qty:number, candidates: table[] (harvested reagent rows) }
function RecipeService:GetMandatorySlots(spellID)
    local out = {}
    local bySlot = {}
    for _, r in ipairs(self:GetReagents(spellID)) do
        local st = r.slotType
        if st == nil or st == 1 then
            local key = r.dataSlotIndex
            local slot = (key ~= nil) and bySlot[key] or nil
            if not slot then
                slot = { qty = tonumber(r.qty) or 0, candidates = {} }
                if key ~= nil then
                    bySlot[key] = slot
                end
                out[#out + 1] = slot
            end
            local q = tonumber(r.qty) or 0
            if q > slot.qty then
                slot.qty = q
            end
            slot.candidates[#slot.candidates + 1] = r
        end
    end
    return out
end

--- Total AH cost (copper) of the reagents for one craft, using AHPriceService.
--- Per slot: cheapest priced quality-tier candidate (alternatives, not sums).
---@param spellID number
---@return number|nil cost, number missingPriceCount
function RecipeService:EstimateReagentCost(spellID)
    local svc = ns.AHPriceService
    if not svc or not svc.GetPrice then return nil, 0 end
    local total, missing = 0, 0
    local slots = self:GetMandatorySlots(spellID)
    for si = 1, #slots do
        local slot = slots[si]
        local best = nil
        for ci = 1, #slot.candidates do
            local c = slot.candidates[ci]
            if c.itemID then
                local p = svc:GetPrice(c.itemID)
                if p and (not best or p < best) then
                    best = p
                end
            end
        end
        if best then
            total = total + best * slot.qty
        else
            --- Currency-only slot or no candidate priced.
            missing = missing + 1
        end
    end
    return total, missing
end

---@param spellID number
---@return number|nil copper price of output item
function RecipeService:EstimateOutputValue(spellID)
    local item = self:GetOutputItem(spellID)
    if not item then return nil end
    local svc = ns.AHPriceService
    if not svc or not svc.GetPrice then return nil end
    return svc:GetPrice(item)
end

---@param itemID number
---@return number[]  list of spellIDs that consume itemID
function RecipeService:GetRecipesForItem(itemID)
    if not self._reverseIndex then self:RebuildReverseIndex() end
    local bucket = self._reverseIndex[itemID]
    if not bucket then return {} end
    local out = {}
    for sid in pairs(bucket) do out[#out + 1] = sid end
    table.sort(out)
    return out
end

function RecipeService:RebuildReverseIndex()
    local idx = {}
    local s = Store()
    if s then
        for spellID, sch in pairs(s) do
            for _, r in ipairs(sch.reagents or {}) do
                if r.itemID then
                    idx[r.itemID] = idx[r.itemID] or {}
                    idx[r.itemID][spellID] = true
                end
            end
        end
    end
    self._reverseIndex = idx
end

--==========================================================================
-- Harvest from C_TradeSkillUI
--==========================================================================

local function SafeProfessionInfo()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetProfessionInfo then return nil end
    local ok, info = pcall(C_TradeSkillUI.GetProfessionInfo)
    if ok then return info end
    return nil
end

local function TradeSkillReady()
    if not C_TradeSkillUI then
        return false
    end
    if C_TradeSkillUI.IsTradeSkillReady then
        return C_TradeSkillUI.IsTradeSkillReady() == true
    end
    return true
end

---@param link string|nil
---@return number|nil
local function ParseItemIDFromLink(link)
    if not link or link == "" then
        return nil
    end
    if issecretvalue and issecretvalue(link) then
        return nil
    end
    local id = link:match("item:(%d+)")
    return id and tonumber(id) or nil
end

---@param link string|nil
---@return number|nil
local function ParseCurrencyIDFromLink(link)
    if not link or link == "" then
        return nil
    end
    if issecretvalue and issecretvalue(link) then
        return nil
    end
    local id = link:match("currency:(%d+)")
    return id and tonumber(id) or nil
end

--- WoW API tables are usually arrays; iterate ipairs first, then numeric pairs.
---@param tbl table|nil
---@param fn fun(entry:table, index:number)
local function ForEachArrayLike(tbl, fn)
    if type(tbl) ~= "table" or not fn then
        return
    end
    local n = #tbl
    if n > 0 then
        for i = 1, n do
            fn(tbl[i], i)
        end
        return
    end
    for k, v in pairs(tbl) do
        if type(k) == "number" and type(v) == "table" then
            fn(v, k)
        end
    end
end

---@param reagents table[]
---@param itemID number|nil
---@param currencyID number|nil
---@param qty number
---@param slotType number|nil
---@param dataSlotIndex number|nil
---@param dataSlotType number|nil
local function PushHarvestReagent(reagents, itemID, currencyID, qty, slotType, dataSlotIndex, dataSlotType)
    qty = tonumber(qty) or 0
    if qty <= 0 then
        return
    end
    if type(itemID) == "number" and itemID > 0 then
        reagents[#reagents + 1] = {
            itemID = itemID,
            qty = qty,
            slotType = slotType,
            dataSlotIndex = dataSlotIndex,
            dataSlotType = dataSlotType,
        }
    elseif type(currencyID) == "number" and currencyID > 0 then
        reagents[#reagents + 1] = {
            currencyID = currencyID,
            qty = qty,
            slotType = slotType,
            dataSlotIndex = dataSlotIndex,
            dataSlotType = dataSlotType,
        }
    end
end

--- Midnight 12.0+: schematic slots may ship empty `reagents` / `variableQuantities`;
--- resolve tier candidates via GetRecipeQualityReagentLink (wiki 12.0.0).
---@param spellID number
---@param dataSlotIndex number
---@param qty number
---@param slotType number|nil
---@param dataSlotType number|nil
---@param reagents table[]
local function HarvestQualityReagentLinks(spellID, dataSlotIndex, qty, slotType, dataSlotType, reagents)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeQualityReagentLink then
        return
    end
    for qi = 1, 8 do
        local ok, link = pcall(C_TradeSkillUI.GetRecipeQualityReagentLink, spellID, dataSlotIndex, qi)
        if not ok or type(link) ~= "string" or link == "" then
            break
        end
        local itemID = ParseItemIDFromLink(link)
        local currencyID = (not itemID) and ParseCurrencyIDFromLink(link) or nil
        if itemID or currencyID then
            PushHarvestReagent(reagents, itemID, currencyID, qty, slotType, dataSlotIndex, dataSlotType)
        end
    end
end

---@param spellID number
---@param slot table
---@param reagents table[]
local function HarvestSlotReagents(spellID, slot, reagents)
    if type(slot) ~= "table" then
        return
    end
    local slotType = slot.reagentType
    local dataSlotIndex = slot.dataSlotIndex
    local dataSlotType = slot.dataSlotType
    local qty = tonumber(slot.quantityRequired) or 0
    local before = #reagents

    ForEachArrayLike(slot.variableQuantities, function(vq)
        if type(vq) == "table" and type(vq.reagent) == "table" then
            local rq = tonumber(vq.quantity) or qty
            PushHarvestReagent(reagents, vq.reagent.itemID, vq.reagent.currencyID, rq,
                slotType, dataSlotIndex, dataSlotType)
        end
    end)

    if qty > 0 then
        ForEachArrayLike(slot.reagents, function(r)
            if type(r) == "table" then
                PushHarvestReagent(reagents, r.itemID, r.currencyID, qty,
                    slotType, dataSlotIndex, dataSlotType)
            end
        end)
    end

    if dataSlotIndex and qty > 0 and #reagents == before then
        HarvestQualityReagentLinks(spellID, dataSlotIndex, qty, slotType, dataSlotType, reagents)
    end
end

--- Pull reagent schematic for `spellID` and persist it. Returns true if stored.
---@param spellID number
---@param force boolean|nil When true, re-fetch even if reagents are already cached.
---@return boolean stored  Schematic row exists / is valid in SavedVariables.
---@return boolean fetched  True when this call hit TradeSkill APIs (not a cache skip).
function RecipeService:HarvestOne(spellID, force)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeSchematic then return false, false end
    spellID = NormalizeSpellID(spellID)
    if not self:IsMidnightRecipe(spellID) then return false, false end

    if not force then
        local sEarly = Store()
        local prev = sEarly and sEarly[spellID]
        if prev and type(prev.reagents) == "table" and #prev.reagents > 0 then
            return true, false
        end
    end

    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, spellID, false)
    if not ok or type(schematic) ~= "table" then return false, false end

    --- Enum.CraftingReagentType: 0 Modifying, 1 Basic, 2 Finishing, 3 Automatic.
    --- Enum.TradeskillSlotDataType: 1 Reagent, 2 ModifiedReagent, 3 Currency.
    local reagents = {}
    ForEachArrayLike(schematic.reagentSlotSchematics, function(slot)
        HarvestSlotReagents(spellID, slot, reagents)
    end)

    local s = Store()
    if not s then return false, false end
    local prev = s[spellID]
    if prev and type(prev.reagents) == "table" and #prev.reagents > 0 and #reagents < 1 then
        reagents = prev.reagents
    end

    local info
    if C_TradeSkillUI.GetRecipeInfo then
        local okI, ri = pcall(C_TradeSkillUI.GetRecipeInfo, spellID)
        if okI then info = ri end
    end

    local name = (info and info.name) or self:GetRecipeName(spellID) or ""

    --- Output item: schematic.outputItemID first; fall back to GetRecipeOutputItemData / hyperlink parse.
    local outputItemID = schematic.outputItemID
    if not outputItemID and C_TradeSkillUI.GetRecipeOutputItemData then
        local okO, od = pcall(C_TradeSkillUI.GetRecipeOutputItemData, spellID)
        if okO and type(od) == "table" then
            outputItemID = od.itemID or outputItemID
        end
    end
    if not outputItemID and info and info.itemLink then
        local link = info.itemLink
        if not (issecretvalue and issecretvalue(link)) then
            local id = link:match("item:(%d+):")
            if id then outputItemID = tonumber(id) end
        end
    end

    --- Texture id for UI when output item is missing (enchants, abilities): matches RecipeInfo / schematic.
    local recipeIcon = schematic.icon
    if (not recipeIcon or recipeIcon <= 0) and info and type(info.icon) == "number" and info.icon > 0 then
        recipeIcon = info.icon
    end

    local qualityItemIDs
    if info and type(info.qualityItemIDs) == "table" and #info.qualityItemIDs > 0 then
        qualityItemIDs = {}
        for qi = 1, #info.qualityItemIDs do
            qualityItemIDs[qi] = info.qualityItemIDs[qi]
        end
    end

    s[spellID] = {
        name = name,
        profession = self:GetProfession(spellID),
        output = {
            itemID = outputItemID,
            quantityMin = tonumber(schematic.quantityMin) or 1,
            quantityMax = tonumber(schematic.quantityMax) or tonumber(schematic.quantityMin) or 1,
        },
        reagents = reagents,
        recipeIcon = recipeIcon,
        updated = time(),
        supportsQualities = info and info.supportsQualities or nil,
        maxQuality = info and info.maxQuality or nil,
        qualityItemIDs = qualityItemIDs,
        learned = (info and info.learned ~= nil) and info.learned or nil,
        hasCraftingOperationInfo = schematic.hasCraftingOperationInfo == true,
    }
    self._reverseIndex = nil
    return true, true
end

local HARVEST_CHUNK_SIZE = 14

local function CountHarvested(ids, startIdx, endIdx, force)
    local fetched, withReagents = 0, 0
    for i = startIdx, endIdx do
        local sid = ids[i]
        local _, didFetch = RecipeService:HarvestOne(sid, force)
        if didFetch then
            fetched = fetched + 1
            local sch = RecipeService:GetSchematic(sid)
            if sch and sch.reagents and #sch.reagents > 0 then
                withReagents = withReagents + 1
            end
        end
    end
    return fetched, withReagents
end

--- Harvest every recipe visible in the currently open profession window (single frame).
---@param force boolean|nil Re-fetch schematics that already have reagents.
---@return number count
function RecipeService:HarvestOpenProfession(force)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetAllRecipeIDs then return 0 end
    if not TradeSkillReady() then
        return 0
    end
    local ok, rawIds = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or type(rawIds) ~= "table" then return 0 end
    local ids = {}
    for ri = 1, #rawIds do
        local sid = NormalizeSpellID(rawIds[ri])
        if self:IsMidnightRecipe(sid) then
            ids[#ids + 1] = sid
        end
    end
    local fetched, withReagents = CountHarvested(ids, 1, #ids, force)
    if fetched > 0 then
        ns.ArtisanNexus:SendMessage(E.RECIPE_SCHEMATICS_UPDATED, withReagents)
    end
    return fetched
end

--- Spread harvest across frames to avoid UI hitches (Scan button / manual refresh).
---@param onComplete fun(count:number, withReagents:number)|nil
---@return boolean started
function RecipeService:HarvestOpenProfessionChunked(onComplete)
    if self._harvestChunkActive then
        return false
    end
    if not C_TradeSkillUI or not C_TradeSkillUI.GetAllRecipeIDs then
        if onComplete then onComplete(0, 0) end
        return false
    end
    if not TradeSkillReady() then
        if onComplete then onComplete(0, 0) end
        return false
    end
    local ok, rawIds = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or type(rawIds) ~= "table" then
        if onComplete then onComplete(0, 0) end
        return false
    end
    local ids = {}
    for ri = 1, #rawIds do
        local sid = NormalizeSpellID(rawIds[ri])
        if self:IsMidnightRecipe(sid) then
            ids[#ids + 1] = sid
        end
    end
    if #ids < 1 then
        if onComplete then onComplete(0, 0) end
        return false
    end
    self._harvestChunkActive = true
    local idx, totalFetched, totalWith = 1, 0, 0
    local function step()
        if not self._harvestChunkActive then
            return
        end
        local limit = math.min(idx + HARVEST_CHUNK_SIZE - 1, #ids)
        local n, withR = CountHarvested(ids, idx, limit, false)
        totalFetched = totalFetched + n
        totalWith = totalWith + withR
        idx = limit + 1
        if idx <= #ids then
            if C_Timer and C_Timer.After then
                C_Timer.After(0, step)
            else
                step()
            end
            return
        end
        self._harvestChunkActive = false
        if totalFetched > 0 then
            ns.ArtisanNexus:SendMessage(E.RECIPE_SCHEMATICS_UPDATED, totalWith)
        end
        if onComplete then
            onComplete(totalFetched, totalWith)
        end
    end
    step()
    return true
end

function RecipeService:IsHarvestChunkActive()
    return self._harvestChunkActive == true
end

--==========================================================================
-- Bag scan + match logic
--==========================================================================

function RecipeService:InvalidateBagCache()
    self._bagCounts = nil
    self._bagCacheGen = (self._bagCacheGen or 0) + 1
end

--- Cached bag scan; invalidated on BAG_UPDATE bucket and after crafting loot moves.
---@param force boolean|nil
---@return table<number, number>
function RecipeService:GetBagCounts(force)
    if force or not self._bagCounts then
        self._bagCounts = self:ScanBags()
    end
    return self._bagCounts
end

---@return number generation token for UI list caches
function RecipeService:GetBagCacheGeneration()
    return self._bagCacheGen or 0
end

---@return table<number, number>  itemID -> stack count across bags (+ optional warband bank)
function RecipeService:ScanBags()
    local counts = {}
    if not C_Container or not C_Container.GetContainerNumSlots then
        return counts
    end
    local bags = { 0, 1, 2, 3, 4, 5 }
    if REAGENTBANK_CONTAINER then
        bags[#bags + 1] = REAGENTBANK_CONTAINER
    end
    local profile = ns.db and ns.db.profile
    local includeWarband = not profile or profile.includeWarbandBank ~= false
    if includeWarband and Enum and Enum.BagIndex then
        local BI = Enum.BagIndex
        for i = 1, 5 do
            local bag = BI["AccountBankTab_" .. i]
            if bag then
                bags[#bags + 1] = bag
            end
        end
    end
    for b = 1, #bags do
        local bag = bags[b]
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end
    return counts
end

---@param spellID number
---@param bagCounts table<number,number>|nil
---@return { itemID:number, qty:number, have:number, short:number }[] rows
---@return boolean craftable
function RecipeService:MatchReagents(spellID, bagCounts)
    bagCounts = bagCounts or self:GetBagCounts()
    local rows = {}
    local craftable = true
    local any = false
    local slots = self:GetMandatorySlots(spellID)
    for si = 1, #slots do
        local slot = slots[si]
        --- Quality tiers of one slot are alternatives: show the candidate the
        --- player owns most of, not one row per tier.
        local bestItem, bestHave = nil, -1
        for ci = 1, #slot.candidates do
            local c = slot.candidates[ci]
            if c.itemID then
                local have = self:EffectiveReagentCount(c.itemID, bagCounts)
                if have > bestHave then
                    bestItem, bestHave = c.itemID, have
                end
            end
        end
        if bestItem then
            any = true
            local short = math.max(0, slot.qty - bestHave)
            if short > 0 then craftable = false end
            rows[#rows + 1] = {
                itemID = bestItem,
                qty = slot.qty,
                have = bestHave,
                short = short,
                slotType = 1,
            }
        end
    end
    if not any then craftable = false end
    return rows, craftable
end

--- List recipes where at least one reagent is present in bags; craftable first.
---@param profession string|nil  filter by profession, nil = all
---@return { spellID:number, name:string, profession:string, craftable:boolean, matched:number, total:number }[]
function RecipeService:FindCraftableFromBags(profession, bagCounts)
    local bags = bagCounts or self:GetBagCounts()
    local s = Store()
    if not s then return {} end
    local out = {}
    for spellID, sch in pairs(s) do
        if not profession or sch.profession == profession then
            local total, matched, craftable = 0, 0, true
            local anyMatch = false
            local slots = self:GetMandatorySlots(spellID)
            for si = 1, #slots do
                local slot = slots[si]
                total = total + 1
                local have = 0
                for ci = 1, #slot.candidates do
                    local c = slot.candidates[ci]
                    if c.itemID then
                        local h = self:EffectiveReagentCount(c.itemID, bags)
                        if h > have then
                            have = h
                        end
                    end
                end
                if have > 0 then
                    matched = matched + 1
                    anyMatch = true
                end
                if have < slot.qty then craftable = false end
            end
            if total > 0 and anyMatch then
                out[#out + 1] = {
                    spellID = spellID,
                    name = sch.name,
                    profession = sch.profession,
                    craftable = craftable,
                    matched = matched,
                    total = total,
                    outputItemID = sch.output and sch.output.itemID or nil,
                    recipeIcon = sch.recipeIcon,
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.craftable ~= b.craftable then return a.craftable end
        if a.matched ~= b.matched then return a.matched > b.matched end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

--==========================================================================
-- Availability: bags + optional session totals (rank-equivalent reagents)
--==========================================================================

local rankGroupByItemId

local function BuildRankGroupIndex()
    if rankGroupByItemId then
        return
    end
    rankGroupByItemId = {}
    local Resolve = ns.ResolveCatalogEntryRanks
    if not Resolve then
        return
    end
    local lists = {}
    if ns.GetGatheringCatalogByCategory then
        for _, cat in ipairs({ "herb", "mine", "leather", "disenchant", "others" }) do
            lists[#lists + 1] = ns.GetGatheringCatalogByCategory(cat) or {}
        end
    end
    if ns.GetFishingCatalogEntries then
        lists[#lists + 1] = ns.GetFishingCatalogEntries() or {}
    end
    for li = 1, #lists do
        local entries = lists[li]
        for i = 1, #entries do
            local ranks = Resolve(entries[i])
            if #ranks > 0 then
                for r = 1, #ranks do
                    rankGroupByItemId[ranks[r]] = ranks
                end
            end
        end
    end
end

--- Sum stacks across catalog rank tiers for the same mat row.
---@param itemID number
---@param counts table<number, number>
---@return number
function RecipeService:EffectiveReagentCount(itemID, counts)
    if not itemID or not counts then
        return 0
    end
    BuildRankGroupIndex()
    local group = rankGroupByItemId and rankGroupByItemId[itemID]
    if not group then
        return counts[itemID] or 0
    end
    local sum = 0
    for i = 1, #group do
        sum = sum + (counts[group[i]] or 0)
    end
    return sum
end

---@param a table<number, number>
---@param b table<number, number>|nil
---@return table<number, number>
function RecipeService:MergeItemCounts(a, b)
    local out = {}
    if type(a) == "table" then
        for id, qty in pairs(a) do
            local n = tonumber(qty) or 0
            if n > 0 then
                out[id] = n
            end
        end
    end
    if type(b) == "table" then
        for id, qty in pairs(b) do
            local n = tonumber(qty) or 0
            if n > 0 then
                out[id] = (out[id] or 0) + n
            end
        end
    end
    return out
end

--- Bags plus in-memory session totals for a loot tab (`fishing` or gathering category).
---@param sessionTab string|nil
---@return table<number, number>
function RecipeService:GetBagAndSessionCounts(sessionTab)
    local counts = self:GetBagCounts()
    if not sessionTab or not ns.SessionLootService then
        return counts
    end
    local svc = ns.SessionLootService
    local session = {}
    if sessionTab == "fishing" then
        session = svc:GetItemTotals("fishing", nil, false) or {}
    elseif type(sessionTab) == "string" and sessionTab ~= "" then
        session = svc:GetItemTotals("gathering", sessionTab, false) or {}
    end
    return self:MergeItemCounts(counts, session)
end

--- Session-only item totals (no bags) for Hub session craft filter.
---@param sessionTab string|nil fishing | herb | mine | leather | disenchant | others; nil = all session tabs merged
---@return table<number, number>
function RecipeService:GetSessionCounts(sessionTab)
    local svc = ns.SessionLootService
    if not svc or not svc.GetItemTotals then
        return {}
    end
    if sessionTab == "fishing" then
        return svc:GetItemTotals("fishing", nil, false) or {}
    end
    if type(sessionTab) == "string" and sessionTab ~= "" then
        return svc:GetItemTotals("gathering", sessionTab, false) or {}
    end
    local merged = svc:GetItemTotals("fishing", nil, false) or {}
    local cats = { "herb", "mine", "leather", "disenchant", "others" }
    for i = 1, #cats do
        merged = self:MergeItemCounts(merged, svc:GetItemTotals("gathering", cats[i], false) or {})
    end
    return merged
end

--- Max complete crafts for `spellID` given itemID -> qty (uses rank-equivalent totals).
---@param spellID number
---@param counts table<number, number>|nil
---@return number
function RecipeService:MaxCraftsForCounts(spellID, counts)
    counts = counts or self:GetBagCounts()
    local slots = self:GetMandatorySlots(spellID)
    if #slots < 1 then
        return 0
    end
    local maxCrafts = nil
    for si = 1, #slots do
        local slot = slots[si]
        local need = slot.qty
        if need > 0 then
            --- Best single candidate pool: rank-grouped counts already sum
            --- interchangeable tiers, so max (not Σ) avoids double counting.
            local have, hasItem = 0, false
            for ci = 1, #slot.candidates do
                local c = slot.candidates[ci]
                if c.itemID then
                    hasItem = true
                    local h = self:EffectiveReagentCount(c.itemID, counts)
                    if h > have then
                        have = h
                    end
                end
            end
            if hasItem then
                local n = math.floor(have / need)
                if maxCrafts == nil or n < maxCrafts then
                    maxCrafts = n
                end
            end
        end
    end
    return maxCrafts or 0
end

--- Recipes fully craftable with merged bag+session counts; optional tab filter via reagent overlap.
---@param opts table|nil { sessionTab?: string, limit?: number }
---@return { fullyCraftable: number, top: { spellID: number, name: string, maxCrafts: number }[] }
function RecipeService:SummarizeCraftable(opts)
    opts = opts or {}
    local counts = self:GetBagAndSessionCounts(opts.sessionTab)
    local s = Store()
    local summary = { fullyCraftable = 0, top = {} }
    if not s then
        return summary
    end
    local rows = {}
    for spellID, sch in pairs(s) do
        local maxN = self:MaxCraftsForCounts(spellID, counts)
        if maxN > 0 then
            rows[#rows + 1] = {
                spellID = spellID,
                name = sch.name or self:GetRecipeName(spellID) or ("Recipe " .. tostring(spellID)),
                maxCrafts = maxN,
            }
        end
    end
    table.sort(rows, function(a, b)
        if a.maxCrafts ~= b.maxCrafts then
            return a.maxCrafts > b.maxCrafts
        end
        return (a.name or "") < (b.name or "")
    end)
    summary.fullyCraftable = #rows
    local limit = opts.limit or 3
    for i = 1, math.min(limit, #rows) do
        summary.top[i] = rows[i]
    end
    return summary
end

--==========================================================================
-- Event wiring
--==========================================================================

function RecipeService:Enable()
    if self._enabled then return end
    self._enabled = true
    local owner = self._eventOwner or ns.NewEventOwner("RecipeService")
    self._eventOwner = owner
    local AN = ns.ArtisanNexus
    if AN and AN.RegisterBucketEvent then
        AN:RegisterBucketEvent("BAG_UPDATE", 0.35, function()
            RecipeService:InvalidateBagCache()
        end)
    end
    owner:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function()
        if not TradeSkillReady() or RecipeService._listHarvestPending then
            return
        end
        RecipeService._listHarvestPending = true
        AN:ScheduleTimer(function()
            RecipeService._listHarvestPending = false
            if TradeSkillReady() then
                RecipeService:HarvestOpenProfession()
            end
        end, 0.2)
    end)
    owner:RegisterEvent("TRADE_SKILL_SHOW", function()
        --- List data is not always ready on SHOW; wait until TradeSkillUI is ready.
        local function tryHarvest(attempt)
            if TradeSkillReady() then
                RecipeService:HarvestOpenProfession()
                return
            end
            if attempt < 6 then
                ns.ArtisanNexus:ScheduleTimer(function() tryHarvest(attempt + 1) end, 0.25)
            end
        end
        ns.ArtisanNexus:ScheduleTimer(function() tryHarvest(1) end, 0.35)
    end)
end

function RecipeService:Disable()
    if not self._enabled then return end
    self._enabled = false
    if self._eventOwner then
        self._eventOwner:UnregisterEvent("TRADE_SKILL_LIST_UPDATE")
        self._eventOwner:UnregisterEvent("TRADE_SKILL_SHOW")
    end
end

--==========================================================================
-- Craft briefing helpers (quality tiers, operation info, owned professions)
--==========================================================================

local skillLineToProfession

local function SkillLineProfessionMap()
    if skillLineToProfession then
        return skillLineToProfession
    end
    skillLineToProfession = {}
    local cat = ns.MidnightRecipeCatalog
    if type(cat) == "table" then
        for profName, data in pairs(cat) do
            if type(data) == "table" then
                if data.skillLineID then
                    skillLineToProfession[data.skillLineID] = profName
                end
                if data.parentSkillLineID then
                    skillLineToProfession[data.parentSkillLineID] = profName
                end
            end
        end
    end
    return skillLineToProfession
end

--- Midnight craft profession names the logged-in character knows (Alchemy, Tailoring, ...).
---@return string[]
function RecipeService:GetOwnedCraftProfessions()
    local out = {}
    local seen = {}
    local slMap = SkillLineProfessionMap()
    local craftSet = {}
    local filters = ns.Constants and ns.Constants.CRAFT_PROFESSION_FILTERS
    if type(filters) == "table" then
        for i = 1, #filters do
            local name = filters[i]
            if name and name ~= "All" then
                craftSet[name] = true
            end
        end
    end

    local function considerSkillLine(skillLineID)
        skillLineID = tonumber(skillLineID)
        if not skillLineID then
            return
        end
        local prof = slMap[skillLineID]
        if prof and craftSet[prof] and not seen[prof] then
            seen[prof] = true
            out[#out + 1] = prof
        end
    end

    if GetProfessions and GetProfessionInfo then
        local p1, p2, p3, p4, p5 = GetProfessions()
        local idxs = { p1, p2, p3, p4, p5 }
        for i = 1, #idxs do
            local profIdx = idxs[i]
            if profIdx then
                --- Only return 7 (skillLine) is a skill-line ID; feeding the other
                --- returns (skill levels, icons) produced false "owned" positives.
                local ok, _, _, _, _, _, _, skillLine = pcall(GetProfessionInfo, profIdx)
                if ok then
                    considerSkillLine(skillLine)
                end
            end
        end
    end

    table.sort(out)
    return out
end

--- 12.0 CraftingReagentInfo[] for GetCraftingOperationInfo / GetRecipeOutputItemData.
--- Picks cheapest AH-priced reagent per dataSlotIndex when harvest lists alternatives.
---@param spellID number
---@return table[]
function RecipeService:BuildCraftingReagentInfo(spellID)
    local sch = self:GetSchematic(spellID)
    if not sch or type(sch.reagents) ~= "table" then
        return {}
    end
    local slotCandidates = {}
    for i = 1, #sch.reagents do
        local r = sch.reagents[i]
        if r.itemID and r.dataSlotIndex then
            local slotIdx = r.dataSlotIndex
            local bucket = slotCandidates[slotIdx]
            if not bucket then
                bucket = {}
                slotCandidates[slotIdx] = bucket
            end
            bucket[#bucket + 1] = r
        end
    end
    local function pickReagent(candidates)
        if not candidates or #candidates < 1 then
            return nil
        end
        if #candidates == 1 then
            return candidates[1]
        end
        local best = candidates[1]
        local bestPrice = nil
        local ahs = ns.AHPriceService
        for ci = 1, #candidates do
            local c = candidates[ci]
            local price = ahs and ahs.GetPrice and ahs:GetPrice(c.itemID)
            if price and (not bestPrice or price < bestPrice) then
                best = c
                bestPrice = price
            end
        end
        return best
    end
    local bySlot = {}
    for slotIdx, candidates in pairs(slotCandidates) do
        local pick = pickReagent(candidates)
        if pick then
            --- CraftingReagentInfo is a FLAT struct: { itemID, dataSlotIndex, quantity }.
            bySlot[slotIdx] = {
                itemID = pick.itemID,
                dataSlotIndex = slotIdx,
                quantity = pick.qty or 1,
            }
        end
    end
    local out = {}
    for _, entry in pairs(bySlot) do
        out[#out + 1] = entry
    end
    table.sort(out, function(a, b)
        return (a.dataSlotIndex or 0) < (b.dataSlotIndex or 0)
    end)
    return out
end

--- Output item for a quality tier (1-based index into harvested qualityItemIDs).
---@param spellID number
---@param qualityTier number|nil
---@return number|nil
function RecipeService:GetOutputItemID(spellID, qualityTier)
    local sch = self:GetSchematic(spellID)
    if sch then
        if qualityTier and sch.qualityItemIDs and sch.qualityItemIDs[qualityTier] then
            return sch.qualityItemIDs[qualityTier]
        end
        if sch.output and sch.output.itemID then
            return sch.output.itemID
        end
    end
    if C_TradeSkillUI and C_TradeSkillUI.IsTradeSkillReady and C_TradeSkillUI.IsTradeSkillReady()
        and C_TradeSkillUI.GetRecipeOutputItemData then
        local reagents = self:BuildCraftingReagentInfo(spellID)
        local ok, od
        if #reagents > 0 then
            ok, od = pcall(C_TradeSkillUI.GetRecipeOutputItemData, spellID, reagents, nil, qualityTier)
        else
            ok, od = pcall(C_TradeSkillUI.GetRecipeOutputItemData, spellID)
        end
        if ok and type(od) == "table" and od.itemID then
            return od.itemID
        end
    end
    return self:GetOutputItem(spellID)
end

--- Expected output stack count from harvested schematic (midpoint when min/max differ).
---@param spellID number
---@return number
function RecipeService:GetOutputQuantity(spellID)
    local sch = self:GetSchematic(spellID)
    if not sch or not sch.output then
        return 1
    end
    local qmin = tonumber(sch.output.quantityMin) or 1
    local qmax = tonumber(sch.output.quantityMax) or qmin
    if qmax > qmin then
        return math.floor((qmin + qmax) / 2 + 0.5)
    end
    return qmin
end

--- Wiki: GetCraftingOperationInfo(recipeID, craftingReagents, allocationItemGUID?, applyConcentration).
---@param spellID number
---@param applyConcentration boolean|nil
---@return table|nil
function RecipeService:GetCraftingOperation(spellID, applyConcentration)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetCraftingOperationInfo then
        return nil
    end
    if C_TradeSkillUI.IsTradeSkillReady and not C_TradeSkillUI.IsTradeSkillReady() then
        return nil
    end
    local reagents = self:BuildCraftingReagentInfo(spellID)
    if #reagents < 1 then
        return nil
    end
    local ok, info = pcall(C_TradeSkillUI.GetCraftingOperationInfo, spellID, reagents, nil, applyConcentration == true)
    if ok and type(info) == "table" then
        return info
    end
    return nil
end

--- Unique item IDs to price for a recipe (reagents + output quality tiers).
---@param spellID number
---@param seen table|nil optional dedupe map
---@return number[]
function RecipeService:CollectPriceItemIDs(spellID, seen)
    local ids = {}
    seen = seen or {}
    local function push(itemID)
        if itemID and not seen[itemID] then
            seen[itemID] = true
            ids[#ids + 1] = itemID
        end
    end
    for _, r in ipairs(self:GetReagents(spellID)) do
        push(r.itemID)
    end
    local sch = self:GetSchematic(spellID)
    if sch then
        push(sch.output and sch.output.itemID)
        if type(sch.qualityItemIDs) == "table" then
            for qi = 1, #sch.qualityItemIDs do
                push(sch.qualityItemIDs[qi])
            end
        end
    end
    return ids
end

--- All harvested schematic reagents, quality-tier outputs, and alternatives (no profession filter).
--- Used by AH full/quick queues so Recipe Matcher and profit rows price every candidate.
---@return number[]
function RecipeService:CollectSchematicPriceItemIDs()
    local seen = {}
    local out = {}
    local s = Store()
    if not s then
        return out
    end
    for spellID, sch in pairs(s) do
        if type(sch) == "table" and type(sch.reagents) == "table" and #sch.reagents > 0 then
            local batch = self:CollectPriceItemIDs(spellID, seen)
            for bi = 1, #batch do
                out[#out + 1] = batch[bi]
            end
        end
    end
    return out
end

--- Item IDs for owned-profession harvested recipes (AH briefing subset).
---@return number[]
function RecipeService:CollectBriefingPriceItemIDs()
    local owned = self:GetOwnedCraftProfessions()
    local ownedSet = {}
    for i = 1, #owned do
        ownedSet[owned[i]] = true
    end
    local seen = {}
    local out = {}
    local s = Store()
    if not s then
        return out
    end
    for spellID, sch in pairs(s) do
        if type(sch) == "table" and sch.reagents and #sch.reagents > 0 then
            local prof = sch.profession or self:GetProfession(spellID)
            if prof and ownedSet[prof] and sch.learned ~= false then
                local batch = self:CollectPriceItemIDs(spellID, seen)
                for bi = 1, #batch do
                    out[#out + 1] = batch[bi]
                end
            end
        end
    end
    return out
end

--==========================================================================
-- Stats
--==========================================================================

---@return { total:number, harvested:number, byProfession: table<string,{harvested:number,total:number}> }
function RecipeService:GetStats()
    local stats = { total = 0, harvested = 0, byProfession = {} }
    local cat = ns.MidnightRecipeCatalog or {}
    for prof, data in pairs(cat) do
        stats.byProfession[prof] = { total = 0, harvested = 0 }
        for _ in pairs(data.recipes or {}) do
            stats.byProfession[prof].total = stats.byProfession[prof].total + 1
            stats.total = stats.total + 1
        end
    end
    local s = Store()
    if s then
        for spellID, sch in pairs(s) do
            if type(sch) == "table" and sch.reagents and #sch.reagents > 0 then
                local prof = self:GetProfession(spellID)
                if prof and stats.byProfession[prof] then
                    stats.byProfession[prof].harvested = stats.byProfession[prof].harvested + 1
                    stats.harvested = stats.harvested + 1
                end
            end
        end
    end
    return stats
end
