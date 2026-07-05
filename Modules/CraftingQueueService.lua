--[[
    Artisan Nexus — Crafting Queue Service.

    A persistent ordered list of (recipe, target count, optional iLvl tier)
    entries the player wants to craft this session. Independent from the
    Shopping List: the queue tracks "what to craft", the shopping list
    tracks "what reagents to acquire". A recipe can live in both.

    Progress auto-advances on craft completion via Blizzard events:
      TRADE_SKILL_CRAFT_BEGIN (recipeSpellID) pairs with
      TRADE_SKILL_ITEM_CRAFTED_RESULT (CraftingItemResultData).
    Manual :MarkOneCrafted remains for UI "+1 crafted" overrides.
    No automatic craft execution — Blizzard's protected craft API rules
    that out for non-secure addons.

    Storage shape (ArtisanNexusDB.global.craftQueue):
      entries = { { spellID, target, progress, tier?, note? }, ... }

    Public API:
      CraftingQueueService:Add(spellID, target, tier?)
      CraftingQueueService:Remove(spellID)
      CraftingQueueService:Move(spellID, dir)        -- dir = -1 up / +1 down
      CraftingQueueService:SetTarget(spellID, n)
      CraftingQueueService:SetTier(spellID, tier)
      CraftingQueueService:MarkOneCrafted(spellID)
      CraftingQueueService:Reset(spellID)
      CraftingQueueService:GetQueue()
      CraftingQueueService:GetSummary() -> { total, remaining, completed, recipes }
]]

local ADDON_NAME, ns = ...

local E = ns.Constants and ns.Constants.EVENTS

local CraftingQueueService = {}

local function Store()
    local db = ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.global
    if not db then return nil end
    if type(db.craftQueue) ~= "table" then
        db.craftQueue = { entries = {} }
    elseif type(db.craftQueue.entries) ~= "table" then
        db.craftQueue.entries = {}
    end
    return db.craftQueue
end

local function FindIndex(entries, spellID)
    for i = 1, #entries do
        if entries[i].spellID == spellID then return i end
    end
    return nil
end

local function Notify()
    if ns.ArtisanNexus and ns.ArtisanNexus.SendMessage and E and E.CRAFT_QUEUE_UPDATED then
        ns.ArtisanNexus:SendMessage(E.CRAFT_QUEUE_UPDATED)
    end
end

function CraftingQueueService:Add(spellID, target, tier)
    if not spellID then return end
    target = math.max(1, tonumber(target) or 1)
    local store = Store(); if not store then return end
    local idx = FindIndex(store.entries, spellID)
    if idx then
        store.entries[idx].target = (store.entries[idx].target or 0) + target
        if tier then store.entries[idx].tier = tier end
    else
        store.entries[#store.entries + 1] = {
            spellID = spellID, target = target, progress = 0, tier = tier,
        }
    end
    Notify()
end

function CraftingQueueService:Remove(spellID)
    local store = Store(); if not store then return end
    local idx = FindIndex(store.entries, spellID)
    if idx then table.remove(store.entries, idx) end
    Notify()
end

function CraftingQueueService:Move(spellID, dir)
    local store = Store(); if not store then return end
    local idx = FindIndex(store.entries, spellID)
    if not idx then return end
    local newIdx = idx + (dir or 0)
    if newIdx < 1 or newIdx > #store.entries then return end
    store.entries[idx], store.entries[newIdx] = store.entries[newIdx], store.entries[idx]
    Notify()
end

function CraftingQueueService:SetTarget(spellID, n)
    if (n or 0) <= 0 then return self:Remove(spellID) end
    local store = Store(); if not store then return end
    local idx = FindIndex(store.entries, spellID)
    if idx then
        store.entries[idx].target = n
    else
        store.entries[#store.entries + 1] = { spellID = spellID, target = n, progress = 0 }
    end
    Notify()
end

function CraftingQueueService:SetTier(spellID, tier)
    local store = Store(); if not store then return end
    local idx = FindIndex(store.entries, spellID)
    if idx then store.entries[idx].tier = tier; Notify() end
end

function CraftingQueueService:MarkOneCrafted(spellID)
    local store = Store(); if not store then return end
    local idx = FindIndex(store.entries, spellID)
    if not idx then return end
    local e = store.entries[idx]
    e.progress = math.min((e.target or 1), (e.progress or 0) + 1)
    if e.progress >= (e.target or 1) then
        -- Auto-remove completed entries; user can re-add for another batch.
        table.remove(store.entries, idx)
    end
    Notify()
end

function CraftingQueueService:Reset(spellID)
    local store = Store(); if not store then return end
    local idx = FindIndex(store.entries, spellID)
    if idx then store.entries[idx].progress = 0; Notify() end
end

function CraftingQueueService:GetQueue()
    local store = Store(); if not store then return {} end
    local out = {}
    for i, e in ipairs(store.entries) do
        out[i] = {
            spellID = e.spellID,
            target = e.target or 1,
            progress = e.progress or 0,
            remaining = math.max(0, (e.target or 1) - (e.progress or 0)),
            tier = e.tier,
            note = e.note,
        }
    end
    return out
end

function CraftingQueueService:GetSummary()
    local q = self:GetQueue()
    local total, remaining, completed = 0, 0, 0
    for _, e in ipairs(q) do
        total = total + (e.target or 0)
        completed = completed + (e.progress or 0)
        remaining = remaining + (e.remaining or 0)
    end
    return { total = total, remaining = remaining, completed = completed, recipes = #q }
end

--- Craft completion pairing via shared CraftEventService (wiki: TRADE_SKILL_CRAFT_BEGIN / TRADE_SKILL_ITEM_CRAFTED_RESULT).
local pendingCraftSpellID = nil
local pendingCraftHandled = false
local CraftEventService = ns.CraftEventService

local function ClearPendingCraft()
    pendingCraftSpellID = nil
    pendingCraftHandled = false
end

local function CraftResultMatchesRecipe(spellID, data)
    if CraftEventService and CraftEventService.ResultMatchesRecipe then
        return CraftEventService:ResultMatchesRecipe(spellID, data)
    end
    return type(data) == "table" and not data.bonusCraft
end

---@param data table|nil
local function ResolveQueuedSpellFromResult(data)
    if type(data) ~= "table" then
        return nil
    end
    if data.bonusCraft then
        --- Bonus/multicraft procs are extra yield from an already-counted cast.
        return nil
    end
    local resultID = tonumber(data.itemID)
    if not resultID or resultID <= 0 then
        return nil
    end
    local store = Store()
    local rs = ns.RecipeService
    if not store or not rs or not rs.GetOutputItem then
        return nil
    end
    for i = 1, #store.entries do
        local sid = store.entries[i].spellID
        if rs:GetOutputItem(sid) == resultID then
            return sid
        end
    end
    return nil
end

local function OnTradeSkillCraftBegin(recipeSpellID)
    recipeSpellID = tonumber(recipeSpellID)
    if not recipeSpellID then
        ClearPendingCraft()
        return
    end
    local store = Store()
    if not store then
        return
    end
    if FindIndex(store.entries, recipeSpellID) then
        pendingCraftSpellID = recipeSpellID
        pendingCraftHandled = false
    else
        ClearPendingCraft()
    end
end

local function OnTradeSkillItemCraftedResult(data)
    local spellID = pendingCraftSpellID
    local store = Store()
    if not store then
        return
    end

    if spellID and not pendingCraftHandled and FindIndex(store.entries, spellID) then
        if CraftResultMatchesRecipe(spellID, data) then
            CraftingQueueService:MarkOneCrafted(spellID)
            pendingCraftHandled = true
        end
        return
    end

    if spellID and pendingCraftHandled then
        --- Secondary RESULT event of an already-credited cast (multicraft /
        --- bonus proc): never re-credit via the itemID fallback below.
        return
    end

    local resolved = ResolveQueuedSpellFromResult(data)
    if resolved and FindIndex(store.entries, resolved) then
        CraftingQueueService:MarkOneCrafted(resolved)
    end
    ClearPendingCraft()
end

if CraftEventService then
    CraftEventService:RegisterCraftBegin(OnTradeSkillCraftBegin)
    CraftEventService:RegisterCraftResult(OnTradeSkillItemCraftedResult)
end

ns.CraftingQueueService = CraftingQueueService
