--[[
    Gathering loot: Blizzard Loot frame only (LootWindowBridge). Fishing wins when both claim.
    Session / Last Loot use the same window snapshot — no CHAT_MSG_LOOT.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS
local GatheringSpellData = ns.GatheringSpellData

---@class GatheringLootService
local GatheringLootService = {
    _gatheringWindowUntil = nil,
    _lootOpenedGatheringHint = false,
    _pendingCategory = nil,
    _pendingCategoryUntil = 0,
}

local eventFrame = CreateFrame("Frame")

local GATHERING_WINDOW_SPELL = 45
local GATHERING_WINDOW_LOOT = 24

--- Dedupe rapid duplicate window scans for the same item stack.
local lastWindowAt = {}

local function LootSourcesAreOnlyGameObjects()
    return ns.LootFrameSourcesAreOnlyGameObjects and ns.LootFrameSourcesAreOnlyGameObjects() or false
end

function GatheringLootService:ShouldAttributeLootToGathering()
    if self._gatheringWindowUntil and GetTime() <= self._gatheringWindowUntil then
        return true
    end
    if self._lootOpenedGatheringHint then
        return true
    end
    return false
end

function GatheringLootService:ShouldAttributeLootWindowScan()
    if IsFishingLoot and IsFishingLoot() then
        return false
    end
    if self:ShouldAttributeLootToGathering() then
        return true
    end
    return LootSourcesAreOnlyGameObjects()
end

function GatheringLootService:ExtendGatheringWindow(seconds)
    self._gatheringWindowUntil = GetTime() + (seconds or GATHERING_WINDOW_SPELL)
end

local function RecordItem(itemID, qty, itemName)
    if not itemID or itemID < 1 then
        return
    end
    qty = math.max(1, qty or 1)
    local now = GetTime()
    if lastWindowAt[itemID] and (now - lastWindowAt[itemID]) < 0.4 then
        return
    end
    lastWindowAt[itemID] = now

    local db = ArtisanNexus.db.global.gatheringLootHistory
    if type(db) ~= "table" then
        ArtisanNexus.db.global.gatheringLootHistory = {}
        db = ArtisanNexus.db.global.gatheringLootHistory
    end
    if not db[itemID] then
        db[itemID] = { count = 0, lastAt = 0, name = nil }
    end
    local row = db[itemID]
    row.count = (row.count or 0) + qty
    row.lastAt = time()
    if itemName and itemName ~= "" and not (issecretvalue and issecretvalue(itemName)) then
        row.name = itemName
    elseif not row.name or row.name == "" then
        local name = GetItemInfo(itemID)
        if name and not (issecretvalue and issecretvalue(name)) then
            row.name = name
        end
    end

    ArtisanNexus:SendMessage(E.GATHERING_LOOT_RECORDED, itemID, qty)
    ArtisanNexus:SendMessage(E.GATHERING_HISTORY_UPDATED)
    ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)

    --- Session UI: one tab per profession — never default to herb; unattributed loot is DB-only.
    local cat = nil
    if GatheringLootService._pendingCategory and GetTime() < (GatheringLootService._pendingCategoryUntil or 0) then
        cat = GatheringLootService._pendingCategory
    end
    if not cat then
        cat = GatheringSpellData.InferCategoryFromItemId(itemID)
    end

    if cat and ns.SessionLootService and ns.SessionLootService.PushGatheringSession then
        ns.SessionLootService:PushGatheringSession(itemID, qty, cat)
    end
end

--- Fallback when auto-loot leaves no scannable slots: still show Last Loot from chat (session only; DB via window).
local function ProcessChatSessionOnly(msg)
    if not msg or (issecretvalue and issecretvalue(msg)) then
        return
    end
    if ns.FishingLootService and ns.FishingLootService.ShouldAttributeLootToFishing then
        if ns.FishingLootService:ShouldAttributeLootToFishing() then
            return
        end
    end
    if not GatheringLootService:ShouldAttributeLootToGathering() then
        return
    end
    local counts = (ns.ParseChatLootItemQuantities and ns.ParseChatLootItemQuantities(msg)) or {}
    for itemID, qty in pairs(counts) do
        local cat = nil
        if GatheringLootService._pendingCategory and GetTime() < (GatheringLootService._pendingCategoryUntil or 0) then
            cat = GatheringLootService._pendingCategory
        end
        if not cat then
            cat = GatheringSpellData.InferCategoryFromItemId(itemID)
        end
        if cat and ns.SessionLootService and ns.SessionLootService.PushGatheringSession then
            ns.SessionLootService:PushGatheringSession(itemID, qty, cat)
        end
    end
end

---@param counts table<number, number>
function GatheringLootService.RecordWindowLootCounts(counts)
    if not counts or not next(counts) then
        return
    end
    if not GatheringLootService:ShouldAttributeLootWindowScan() then
        return
    end
    for itemID, qty in pairs(counts) do
        RecordItem(itemID, qty, nil)
    end
    GatheringLootService._lootOpenedGatheringHint = false
end

function GatheringLootService:Enable()
    eventFrame:RegisterEvent("CHAT_MSG_LOOT")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    eventFrame:RegisterEvent("LOOT_OPENED")

    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_LOOT" then
            ProcessChatSessionOnly(select(1, ...))
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unitTarget, castGUID, spellID = ...
            if unitTarget == "player" and GatheringSpellData.IsGatheringSpell(spellID) then
                local c = GatheringSpellData.GetCategory(spellID)
                if not c then
                    c = GatheringSpellData.InferGatheringCategoryFromSpell(spellID)
                end
                if c then
                    GatheringLootService._pendingCategory = c
                    GatheringLootService._pendingCategoryUntil = GetTime() + 50
                end
                GatheringLootService:ExtendGatheringWindow(GATHERING_WINDOW_SPELL)
            end
        elseif event == "LOOT_OPENED" then
            if IsFishingLoot and IsFishingLoot() then
                GatheringLootService._lootOpenedGatheringHint = false
                return
            end
            if LootSourcesAreOnlyGameObjects() then
                GatheringLootService._lootOpenedGatheringHint = true
                GatheringLootService._gatheringWindowUntil = GetTime() + GATHERING_WINDOW_LOOT
            end
        end
    end)
end

function GatheringLootService:Disable()
    eventFrame:UnregisterAllEvents()
    eventFrame:SetScript("OnEvent", nil)
    self._gatheringWindowUntil = nil
    self._lootOpenedGatheringHint = false
    self._pendingCategory = nil
    self._pendingCategoryUntil = 0
end

ns.GatheringLootService = GatheringLootService
