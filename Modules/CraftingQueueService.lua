--[[
    Artisan Nexus — Crafting Queue Service.

    A persistent ordered list of (recipe, target count, optional iLvl tier)
    entries the player wants to craft this session. Independent from the
    Shopping List: the queue tracks "what to craft", the shopping list
    tracks "what reagents to acquire". A recipe can live in both.

    Each entry's `progress` is bumped manually via :MarkOneCrafted (the
    UI calls this after a TRADE_SKILL_ITEM_UPDATE / craft completion).
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
    if ns.ArtisanNexus and ns.ArtisanNexus.SendMessage then
        ns.ArtisanNexus:SendMessage("AN_CRAFT_QUEUE_UPDATED")
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

--- Hook trade-skill craft completion to auto-bump progress for queued recipes.
local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("TRADE_SKILL_ITEM_UPDATE")
hookFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
hookFrame:SetScript("OnEvent", function(_, event, unit, _, spellID)
    if event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" and spellID then
        -- Best-effort: only react if this spell is in the queue.
        local store = Store()
        if not store then return end
        if FindIndex(store.entries, spellID) then
            CraftingQueueService:MarkOneCrafted(spellID)
        end
    end
end)

ns.CraftingQueueService = CraftingQueueService
