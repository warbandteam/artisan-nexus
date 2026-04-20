--[[
    Fishing loot: Blizzard Loot frame only (LootWindowBridge + GetLootSlotItemCounts).
    Last Loot / session and DB use the same window snapshot — no CHAT_MSG_LOOT.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS

---@class FishingLootService
local FishingLootService = {
    --- Batches session tab signals for one loot-window delta.
    _deferFishingSessionTabSignals = false,
}

--- Last loot-window snapshot for delta (itemID -> qty).
local lastWindowCounts = {}

local CHAT_SUPPRESS_SEC = 2.85

--- counts optional: when present, all fish-catalog item IDs count as fishing if Blizzard flags are late.
local function ShouldAttributeLootToFishing(counts)
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return false
    end
    if IsFishingLoot and IsFishingLoot() then
        return true
    end
    if ns.GatheringLootService and ns.GatheringLootService.ShouldAttributeLootToGathering then
        local gatheringWantsWindow = ns.GatheringLootService.ShouldAttributeLootWindowScan
            and ns.GatheringLootService:ShouldAttributeLootWindowScan()
        if gatheringWantsWindow and ns.GatheringLootService:ShouldAttributeLootToGathering() then
            return false
        end
    end
    if ns.FishingService and ns.FishingService:IsInFishingLootContext() then
        return true
    end
    if counts and next(counts) and ns.IsFishingCatalogItem then
        for itemID in pairs(counts) do
            if not ns.IsFishingCatalogItem(itemID) then
                return false
            end
        end
        return true
    end
    return false
end

function FishingLootService:ResetWindowCountSnapshot()
    wipe(lastWindowCounts)
end

local function IncrementFishingLootHistoryDb(itemID, qty, itemName)
    if not itemID or itemID < 1 then
        return
    end
    qty = math.max(1, qty or 1)
    if not (ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID)) then
        return
    end
    local db = ArtisanNexus.db.global.fishingLootHistory
    if type(db) ~= "table" then
        ArtisanNexus.db.global.fishingLootHistory = {}
        db = ArtisanNexus.db.global.fishingLootHistory
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
end

local function RecordItem(itemID, qty, itemName)
    if not itemID or itemID < 1 then
        return
    end
    qty = math.max(1, qty or 1)
    if not (ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID)) then
        return
    end

    IncrementFishingLootHistoryDb(itemID, qty, itemName)

    --- Session push first: tab switch (SESSION_LOOT_UPDATED) must happen before history signals.
    if ns.SessionLootService and ns.SessionLootService.PushFishingSession then
        FishingLootService._suppressChatLootUntil = FishingLootService._suppressChatLootUntil or {}
        FishingLootService._suppressChatLootUntil[itemID] = GetTime() + CHAT_SUPPRESS_SEC
        ns.SessionLootService:PushFishingSession(itemID, qty, {
            quiet = FishingLootService._deferFishingSessionTabSignals,
        })
    end

    ArtisanNexus:SendMessage(E.FISHING_LOOT_RECORDED, itemID, qty)
    if not FishingLootService._deferFishingSessionTabSignals then
        ArtisanNexus:SendMessage(E.FISHING_HISTORY_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
end

--- Fallback when auto-loot skips a window snapshot: Last Loot + Overall DB from chat when the window path did not run.
local function ProcessChatSessionOnly(msg)
    if not msg or (issecretvalue and issecretvalue(msg)) then
        return
    end
    if not (ns.IsSelfLootChatMessage and ns.IsSelfLootChatMessage(msg)) then
        return
    end
    local counts = (ns.ParseChatLootItemQuantities and ns.ParseChatLootItemQuantities(msg)) or {}
    if not ShouldAttributeLootToFishing(counts) then
        return
    end
    local now = GetTime()
    local sup = FishingLootService._suppressChatLootUntil
    local hadSessionTouch = false
    for itemID, qty in pairs(counts) do
        if not (ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID)) then
            -- Ignore non-catalog fish for session lines.
        else
            if sup and sup[itemID] and now >= sup[itemID] then
                sup[itemID] = nil
            end
            if sup and sup[itemID] and now < sup[itemID] then
                if ns.SessionLootService and ns.SessionLootService.ReconcileFishingFromChat then
                    ns.SessionLootService:ReconcileFishingFromChat(itemID, qty, { quietTab = true })
                    hadSessionTouch = true
                end
            elseif ns.SessionLootService and ns.SessionLootService.PushFishingSession then
                local suppressActive = sup and sup[itemID] and now < sup[itemID]
                if not suppressActive then
                    IncrementFishingLootHistoryDb(itemID, qty, nil)
                end
                ns.SessionLootService:PushFishingSession(itemID, qty, { quiet = true })
                hadSessionTouch = true
            end
        end
    end
    if hadSessionTouch then
        ArtisanNexus:SendMessage(E.FISHING_HISTORY_UPDATED)
        if ns.SessionLootService and ns.SessionLootService.EmitFishingLootTabSignal then
            ns.SessionLootService:EmitFishingLootTabSignal()
        end
    end
    if next(counts) and ns.FishingService and ns.FishingService.ClearPostLootState then
        ns.FishingService:ClearPostLootState()
    end
end

--- Used by GatheringLootService so fishing wins attribution vs gathering.
function FishingLootService:ShouldAttributeLootToFishing()
    return ShouldAttributeLootToFishing(nil)
end

---@param counts table<number, number>
function FishingLootService.RecordWindowLootCounts(counts)
    counts = counts or {}
    local attr = ShouldAttributeLootToFishing(counts)
    if not attr and not next(counts) then
        attr = ShouldAttributeLootToFishing(nil)
    end
    if not attr then
        return
    end

    local prev = lastWindowCounts
    local looted = {}

    local ids = {}
    for id in pairs(prev) do
        ids[id] = true
    end
    for id in pairs(counts) do
        ids[id] = true
    end
    for id in pairs(ids) do
        local pq = prev[id] or 0
        local cq = counts[id] or 0
        if pq > cq then
            local taken = pq - cq
            looted[id] = (looted[id] or 0) + taken
        end
    end

    wipe(prev)
    for id, q in pairs(counts) do
        if q and q > 0 then
            prev[id] = q
        end
    end

    if not next(looted) then
        return
    end

    FishingLootService._deferFishingSessionTabSignals = true
    for itemID, qty in pairs(looted) do
        if qty and qty > 0 then
            RecordItem(itemID, qty, nil)
        end
    end
    FishingLootService._deferFishingSessionTabSignals = false

    local anyFish = false
    for itemID, qty in pairs(looted) do
        if qty and qty > 0 and ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID) then
            anyFish = true
            break
        end
    end
    if anyFish then
        ArtisanNexus:SendMessage(E.FISHING_HISTORY_UPDATED)
        if ns.SessionLootService and ns.SessionLootService.EmitFishingLootTabSignal then
            ns.SessionLootService:EmitFishingLootTabSignal()
        end
    end
    if ns.FishingService and ns.FishingService.ClearPostLootState then
        ns.FishingService:ClearPostLootState()
    end
end

local eventFrame = CreateFrame("Frame")

function FishingLootService:Enable()
    eventFrame:RegisterEvent("CHAT_MSG_LOOT")
    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_LOOT" then
            ProcessChatSessionOnly(select(1, ...))
        end
    end)
end

function FishingLootService:Disable()
    eventFrame:UnregisterAllEvents()
    eventFrame:SetScript("OnEvent", nil)
end

ns.FishingLootService = FishingLootService
