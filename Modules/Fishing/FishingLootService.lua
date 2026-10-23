--[[
    Fishing loot: **CHAT_MSG_LOOT** (self-only) is the single recorder for Last pickups + Overall DB.

    Attribution: a line counts as fishing only when
      1) it consumes a fishing loot-window token (LootWindowBridge: LOOT_OPENED with
         IsFishingLoot()), or
      2) the player is channelling a fishing cast, or stopped one within FISH_CHANNEL_GRACE_SEC.
    A line made of fish alone is NOT enough (vendor / AH / quest fish are not catches).
    Duplicate lines are dropped by the chat `lineID` (exact; no time window).
]]

local ADDON_NAME, ns = ...

-- 12.1.5 removed the global item/coin fallbacks; bind the namespaced APIs.
local GetItemInfo = C_Item.GetItemInfo

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS

---@class FishingLootService
local FishingLootService = {
    --- Batches `EmitFishingLootTabSignal` when one chat line contains multiple fish.
    _deferFishingSessionTabSignals = false,
}

--- Bobber click ends the channel just before the loot window/chat line arrives.
local FISH_CHANNEL_GRACE_SEC = 5

local chatLines = ns.Utilities.CreateChatLineDeduper(120)

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

--- Live fishing channel (or one that just ended) — fallback when no fishing window token exists.
local function IsFishingChannelContext()
    local fs = ns.FishingService
    if not fs then
        return false
    end
    if fs.IsFishingChanneling and fs:IsFishingChanneling() then
        return true
    end
    local stopAt = fs._lastFishingChannelStopTime
    return stopAt ~= nil and (GetTime() - stopAt) <= FISH_CHANNEL_GRACE_SEC
end

--- True when this pickup is a catch (consumes one fishing window token if any).
---@param itemID number
---@param qty number
---@return boolean
local function ClaimFishingPickup(itemID, qty)
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return false
    end
    local bridge = ns.LootWindowBridge
    if bridge and bridge.ConsumeToken and bridge:ConsumeToken("fishing", itemID, qty) then
        return true
    end
    return IsFishingChannelContext()
end

local function IncrementFishingLootHistoryDb(itemID, qty, itemName)
    if not itemID or itemID < 1 then
        return
    end
    if not (ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID)) then
        return
    end
    if not itemName or itemName == "" or (issecretvalue and issecretvalue(itemName)) then
        local name = GetItemInfo(itemID)
        itemName = (name and not (issecretvalue and issecretvalue(name))) and name or nil
    end
    local svc = ns.SessionLootService
    if svc and svc.CreditLootHistory then
        svc:CreditLootHistory("fishingLootHistory", itemID, math.max(1, qty or 1), itemName)
    end
end

--- One self-loot chat line → one batch of DB + session lines (per caught item in that line).
local function ProcessChatLoot(msg, lineID)
    if not msg or (issecretvalue and issecretvalue(msg)) then
        return
    end
    local dbg = ArtisanNexus.db and ArtisanNexus.db.profile and ArtisanNexus.db.profile.debugMode
    if not (ns.IsSelfLootChatMessage and ns.IsSelfLootChatMessage(msg)) then
        return
    end
    if chatLines:Seen(lineID) then
        return
    end

    local counts = (ns.ParseChatLootItemQuantities and ns.ParseChatLootItemQuantities(msg)) or {}
    local boutStartAt = ns.FishingService and ns.FishingService._channelStartAt or nil

    FishingLootService._deferFishingSessionTabSignals = true
    local hadSessionTouch = false
    for rawId, qty in pairs(counts) do
        local itemID = NormFishItemID(rawId)
        if itemID and ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID)
            and ClaimFishingPickup(itemID, qty) then
            if ns.SessionLootService and ns.SessionLootService.PushFishingSession
                and ns.SessionLootService:PushFishingSession(itemID, qty, { quiet = true, boutStartAt = boutStartAt }) then
                IncrementFishingLootHistoryDb(itemID, qty, nil)
                hadSessionTouch = true
            end
        end
    end
    FishingLootService._deferFishingSessionTabSignals = false

    if hadSessionTouch then
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
    end
end

local eventFrame = CreateFrame("Frame")

function FishingLootService:Enable()
    eventFrame:RegisterEvent("CHAT_MSG_LOOT")
    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_LOOT" then
            -- verified 2026-10-15, ChatInfoDocumentation.lua 12.1.5: arg 1 text, arg 11 lineID.
            local text, _, _, _, _, _, _, _, _, _, lineID = ...
            ProcessChatLoot(text, lineID)
        end
    end)
end

function FishingLootService:Disable()
    eventFrame:UnregisterAllEvents()
    eventFrame:SetScript("OnEvent", nil)
end

ns.FishingLootService = FishingLootService
