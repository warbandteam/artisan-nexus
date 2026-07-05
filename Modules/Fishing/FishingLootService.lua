--[[
    Fishing loot: **CHAT_MSG_LOOT** (self-only) is the single source of truth for Last pickups + Overall DB.
    Blizzard / clients sometimes dispatch the **same** line twice in <0.25s — we drop repeats by raw message text
    (same pattern as `GatheringLootService` `CHAT_MSG_DUP_SEC`).
    Window slot scans are **not** used for recording (avoids chat+window double commits and GUID/preOpen races).

    API note: `IsFishingLoot()` / loot events are only used by `ShouldAttributeLootToFishing` to decide
    “does this chat line count as fishing?” — not for incrementing totals.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS

---@class FishingLootService
local FishingLootService = {
    --- Batches `EmitFishingLootTabSignal` when one chat line contains multiple fish.
    _deferFishingSessionTabSignals = false,
}

--- Loot bridge still resets this on LOOT_OPENED (delta math unused for fishing; kept for API compat).
local lastWindowCounts = {}

--- Same chat line re-fired within this window → ignore (FastLoot, ElvUI, server echo).
local lastFishLootChatAt = {}
local CHAT_MSG_DUP_SEC = 0.25

--- Short UI tick when optional fish-record sound is on. `SOUNDKIT.LOOT_WINDOW_COIN_SOUND` = 120 (BlizzardInterfaceResources).
local function PlayFishingLootRecordedTick()
    local kit = (type(SOUNDKIT) == "table" and SOUNDKIT.LOOT_WINDOW_COIN_SOUND) or 120
    pcall(PlaySound, kit)
end

local function NormFishItemID(id)
    local n = tonumber(id)
    if n and n >= 1 then
        return n
    end
    return nil
end

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

function FishingLootService:MergeLootSourceSnapshotFromWindow()
    --- Legacy no-op: recording uses chat only.
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

--- One self-loot chat line → one batch of DB + session lines (per item in that line).
local function ProcessChatSessionOnly(msg)
    if not msg or (issecretvalue and issecretvalue(msg)) then
        return
    end
    local dbg = ArtisanNexus.db and ArtisanNexus.db.profile and ArtisanNexus.db.profile.debugMode
    if not (ns.IsSelfLootChatMessage and ns.IsSelfLootChatMessage(msg)) then
        return
    end

    local now = GetTime()
    local prevAt = lastFishLootChatAt[msg]
    if prevAt and (now - prevAt) < CHAT_MSG_DUP_SEC then
        return
    end
    lastFishLootChatAt[msg] = now
    if (now % 30) < 0.05 then
        for k, t in pairs(lastFishLootChatAt) do
            if (now - t) > CHAT_MSG_DUP_SEC * 4 then
                lastFishLootChatAt[k] = nil
            end
        end
    end

    local counts = (ns.ParseChatLootItemQuantities and ns.ParseChatLootItemQuantities(msg)) or {}
    if not ShouldAttributeLootToFishing(counts) then
        return
    end

    FishingLootService._deferFishingSessionTabSignals = true
    local hadSessionTouch = false
    local primaryItemId = nil
    local totalQuantity = 0
    local distinctItems = 0
    for rawId, qty in pairs(counts) do
        local itemID = NormFishItemID(rawId)
        if not itemID or not (ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID)) then
            --- Non-catalog drops in a mixed line: skip session rows for those IDs.
        elseif ns.SessionLootService and ns.SessionLootService.PushFishingSession then
            local q = math.max(1, qty or 1)
            IncrementFishingLootHistoryDb(itemID, qty, nil)
            ns.SessionLootService:PushFishingSession(itemID, qty, { quiet = true })
            hadSessionTouch = true
            distinctItems = distinctItems + 1
            totalQuantity = totalQuantity + q
            if not primaryItemId or itemID < primaryItemId then
                primaryItemId = itemID
            end
        end
    end
    FishingLootService._deferFishingSessionTabSignals = false

    if hadSessionTouch then
        --- One internal message per processed self-loot chat line (not per item row).
        ArtisanNexus:SendMessage(E.FISHING_LOOT_RECORDED, {
            primaryItemId = primaryItemId,
            totalQuantity = totalQuantity,
            distinctItems = distinctItems,
        })
        local profile = ArtisanNexus.db and ArtisanNexus.db.profile
        if profile and profile.fishingLootSoundEnabled then
            PlayFishingLootRecordedTick()
        end
        if dbg then
            ArtisanNexus:Print("[FishingLoot] Recorded fishing loot from chat (session + history).")
        end
        ArtisanNexus:SendMessage(E.FISHING_HISTORY_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
        if ns.SessionLootService and ns.SessionLootService.EmitFishingLootTabSignal then
            ns.SessionLootService:EmitFishingLootTabSignal()
        end
    elseif dbg and next(counts) then
        ArtisanNexus:Print("[FishingLoot] Fishing-attributed chat line had no catalog items to record.")
    end
    if next(counts) and ns.FishingService and ns.FishingService.ClearPostLootState then
        ns.FishingService:ClearPostLootState()
    end
end

function FishingLootService:ShouldAttributeLootToFishing()
    return ShouldAttributeLootToFishing(nil)
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
