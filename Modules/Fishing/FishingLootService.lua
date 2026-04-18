--[[
    Fishing loot: Blizzard Loot frame only (LootWindowBridge + GetLootSlotItemCounts).
    Last Loot / session and DB use the same window snapshot — no CHAT_MSG_LOOT.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS

---@class FishingLootService
local FishingLootService = {}

--- Dedupe rapid duplicate window scans for the same item stack.
local lastWindowAt = {} ---@type table<number, number>

--- counts optional: when present, all fish-catalog item IDs count as fishing if Blizzard flags are late.
local function ShouldAttributeLootToFishing(counts)
    if IsFishingLoot and IsFishingLoot() then
        return true
    end
    if ns.GatheringLootService and ns.GatheringLootService.ShouldAttributeLootToGathering then
        if ns.GatheringLootService:ShouldAttributeLootToGathering() then
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

    ArtisanNexus:SendMessage(E.FISHING_LOOT_RECORDED, itemID, qty)
    ArtisanNexus:SendMessage(E.FISHING_HISTORY_UPDATED)
    ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)

    if ns.SessionLootService and ns.SessionLootService.PushFishingSession then
        ns.SessionLootService:PushFishingSession(itemID, qty)
    end
end

--- Fallback when auto-loot skips a window snapshot: Last Loot still updates from chat (session only).
local function ProcessChatSessionOnly(msg)
    if not msg or (issecretvalue and issecretvalue(msg)) then
        return
    end
    local counts = (ns.ParseChatLootItemQuantities and ns.ParseChatLootItemQuantities(msg)) or {}
    if not ShouldAttributeLootToFishing(counts) then
        return
    end
    for itemID, qty in pairs(counts) do
        if ns.SessionLootService and ns.SessionLootService.PushFishingSession then
            ns.SessionLootService:PushFishingSession(itemID, qty)
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
    if not counts or not next(counts) then
        return
    end
    if not ShouldAttributeLootToFishing(counts) then
        return
    end
    for itemID, qty in pairs(counts) do
        RecordItem(itemID, qty, nil)
    end
    if next(counts) and ns.FishingService and ns.FishingService.ClearPostLootState then
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
