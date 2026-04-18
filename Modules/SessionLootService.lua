--[[
    Session UI: last N discrete loot events + per–item-ID totals for reference grid.
    Fishing: FIFO newest-first list. Gathering: same, tagged by category (herb/mine/leather/dis).
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS

local MAX_EVENTS = 10
local BUFFER = 40

local GATHER_KEYS = { "herb", "mine", "leather", "disenchant" }

--- Chat + loot-window can report the same pickup within ~1s; collapse to one session line + totals delta once.
local lastGatherSessionSig = { t = 0, k = "" }
local lastFishSessionSig = { t = 0, k = "" }

---@class SessionLootService
local SessionLootService = {
    ---@type table[] { itemID = number, qty = number, t = number }
    fishingEvents = {},
    ---@type table[] { itemID = number, qty = number, t = number, cat = string }
    gatheringEvents = {},
    ---@type table<number, number> itemID -> qty this session
    fishingTotals = {},
    ---@type table<string, table<number, number>>
    gatheringTotals = {},
}

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        SessionLootService:ResetSession()
    end
end)

function SessionLootService:ResetSession()
    wipe(self.fishingEvents)
    wipe(self.gatheringEvents)
    wipe(self.fishingTotals)
    wipe(self.gatheringTotals)
    for i = 1, #GATHER_KEYS do
        self.gatheringTotals[GATHER_KEYS[i]] = {}
    end
    lastGatherSessionSig.t, lastGatherSessionSig.k = 0, ""
    lastFishSessionSig.t, lastFishSessionSig.k = 0, ""
    if ArtisanNexus and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
end

local function PushFront(list, entry)
    table.insert(list, 1, entry)
    while #list > BUFFER do
        table.remove(list)
    end
end

---@param itemID number
---@param qty number
--- Prefer this from loot services so chat+window do not duplicate Last Loot / session totals.
---@param itemID number
---@param qty number
function SessionLootService:PushFishingSession(itemID, qty)
    if not itemID or not qty or qty < 1 then
        return
    end
    local key = tostring(itemID) .. ":" .. tostring(qty)
    local now = GetTime()
    if lastFishSessionSig.k == key and (now - lastFishSessionSig.t) < 1.0 then
        return
    end
    lastFishSessionSig.k, lastFishSessionSig.t = key, now
    self:AddFishingEvent(itemID, qty)
end

function SessionLootService:AddFishingEvent(itemID, qty)
    if not itemID or not qty or qty < 1 then
        return
    end
    self.fishingTotals[itemID] = (self.fishingTotals[itemID] or 0) + qty
    PushFront(self.fishingEvents, {
        itemID = itemID,
        qty = qty,
        t = time(),
    })
    ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED)
    ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
end

---@param itemID number
---@param qty number
---@param cat "herb"|"mine"|"leather"|"disenchant"|string
--- Prefer this from loot services so chat+window do not duplicate Last Loot / session totals.
---@param itemID number
---@param qty number
---@param cat string|nil
function SessionLootService:PushGatheringSession(itemID, qty, cat)
    if not itemID or not qty or qty < 1 then
        return
    end
    cat = cat or "herb"
    local key = cat .. ":" .. tostring(itemID) .. ":" .. tostring(qty)
    local now = GetTime()
    if lastGatherSessionSig.k == key and (now - lastGatherSessionSig.t) < 1.0 then
        return
    end
    lastGatherSessionSig.k, lastGatherSessionSig.t = key, now
    self:AddGatheringEvent(itemID, qty, cat)
end

function SessionLootService:AddGatheringEvent(itemID, qty, cat)
    if not itemID or not qty or qty < 1 then
        return
    end
    cat = cat or "herb"
    if not self.gatheringTotals[cat] then
        self.gatheringTotals[cat] = {}
    end
    local gt = self.gatheringTotals[cat]
    gt[itemID] = (gt[itemID] or 0) + qty
    PushFront(self.gatheringEvents, {
        itemID = itemID,
        qty = qty,
        t = time(),
        cat = cat,
    })
    ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED)
    ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
end

--- Legacy hook (aggregated totals) — no longer used by UI; keep no-op for older callers.
---@deprecated
function SessionLootService:Add(kind, itemID, qty)
    if kind == "gathering" then
        self:AddGatheringEvent(itemID, qty, "herb")
    else
        self:AddFishingEvent(itemID, qty)
    end
end

---@param kind "fishing"|"gathering"
---@return table[] events (newest first, capped for UI)
function SessionLootService:GetRecentEvents(kind, gatherCategory)
    if kind == "fishing" then
        local out = {}
        for i = 1, math.min(MAX_EVENTS, #self.fishingEvents) do
            out[i] = self.fishingEvents[i]
        end
        return out
    end
    local out = {}
    for i = 1, #self.gatheringEvents do
        local e = self.gatheringEvents[i]
        if e and e.cat == gatherCategory then
            out[#out + 1] = e
            if #out >= MAX_EVENTS then
                break
            end
        end
    end
    return out
end

--- Per–item-ID quantities this session (for reference totals). Not split by event.
---@param kind "fishing"|"gathering"
---@param gatherCategory string|nil herb / mine / … when kind is gathering
---@return table<number, number>
function SessionLootService:GetItemTotals(kind, gatherCategory)
    if kind == "fishing" then
        return self.fishingTotals or {}
    end
    local cat = gatherCategory or "herb"
    if not self.gatheringTotals[cat] then
        self.gatheringTotals[cat] = {}
    end
    return self.gatheringTotals[cat]
end

---@deprecated Kept for accidental callers — returns empty (UI uses GetRecentEvents).
function SessionLootService:GetTable(kind)
    return {}
end

ns.SessionLootService = SessionLootService
