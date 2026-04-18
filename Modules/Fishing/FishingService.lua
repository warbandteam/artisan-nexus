--[[
    Fishing QoL — channel state + timing for interact vs cast (double right-click).
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS
local FishingSpellData = ns.FishingSpellData

--- Seconds after fishing channel ends: treat double–right-click as interact (bobber loot).
local INTERACT_WINDOW_AFTER_CHANNEL_STOP = 12

---@class FishingService
local FishingService = {
    _frame = nil,
    _channelingFishing = false,
    --- GetTime() when UNIT_SPELLCAST_CHANNEL_STOP fired for a fishing spell (fish may bite next).
    _lastFishingChannelStopTime = nil,
}

function FishingService:IsChannelingFishing()
    return self._channelingFishing
end

--- True after a fishing cast/channel so CHAT_MSG_LOOT can be attributed to fishing without LOOT_OPENED.
-- Seconds after bobber channel ends: still treat loot as fishing (chat + loot window may be late).
local LOOT_ATTRIBUTION_AFTER_CHANNEL_STOP = 120

function FishingService:IsInFishingLootContext()
    if self._channelingFishing then
        return true
    end
    if self._lastFishingChannelStopTime then
        return (GetTime() - self._lastFishingChannelStopTime) < LOOT_ATTRIBUTION_AFTER_CHANNEL_STOP
    end
    return false
end

--- Double-click should trigger interact macro (bobber) instead of /cast Fishing.
function FishingService:ShouldUseInteractInsteadOfCast()
    if self._channelingFishing then
        return true
    end
    if self._lastFishingChannelStopTime then
        local dt = GetTime() - self._lastFishingChannelStopTime
        if dt >= 0 and dt < INTERACT_WINDOW_AFTER_CHANNEL_STOP then
            return true
        end
    end
    return false
end

--- After loot is recorded, narrow the interact window so the next double-click starts a new cast.
function FishingService:ClearPostLootState()
    self._lastFishingChannelStopTime = nil
end

local function GetFrame(self)
    if not self._frame then
        local f = CreateFrame("Frame")
        f:SetScript("OnEvent", function(_, event, unitTarget, castGUID, spellID)
            if unitTarget ~= "player" then return end
            if event == "UNIT_SPELLCAST_CHANNEL_START" then
                if FishingSpellData.IsFishingSpell(spellID) then
                    self._channelingFishing = true
                    self._lastFishingChannelStopTime = nil
                    ArtisanNexus:SendMessage(E.FISHING_CHANNEL_STARTED, spellID)
                end
            elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
                if FishingSpellData.IsFishingSpell(spellID) or (self._channelingFishing and not spellID) then
                    self._channelingFishing = false
                    self._lastFishingChannelStopTime = GetTime()
                    ArtisanNexus:SendMessage(E.FISHING_CHANNEL_STOPPED, spellID)
                end
            end
        end)
        self._frame = f
    end
    return self._frame
end

function FishingService:Enable()
    local f = GetFrame(self)
    f:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    f:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
end

function FishingService:Disable()
    if self._frame then
        self._frame:UnregisterAllEvents()
    end
    self._channelingFishing = false
    self._lastFishingChannelStopTime = nil
end

ns.FishingService = FishingService
