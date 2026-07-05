--[[
    Fishing — channel / line-out state for loot attribution only.
    Recording: FishingLootService via CHAT_MSG_LOOT (no input overrides or CVar changes).
]]

local _, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS
local FishingSpellData = ns.FishingSpellData

local FISHING_LINE_OUT_SAFETY_SEC = 1800
local LOOT_ATTRIBUTION_AFTER_CHANNEL_STOP = 120

local function SafeSpellId(spellID)
    if spellID == nil then
        return nil
    end
    if issecretvalue and issecretvalue(spellID) then
        return nil
    end
    if type(spellID) ~= "number" then
        spellID = tonumber(spellID)
    end
    if not spellID or spellID == 0 then
        return nil
    end
    return spellID
end

local FISHING_POLE_ICON_ID = 136245

local function IsFishingBobberChannelSpell(spellID)
    spellID = SafeSpellId(spellID)
    if not spellID then
        return false
    end
    if FishingSpellData.IsFishingSpell(spellID) then
        return true
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and info and type(info.iconID) == "number" and not (issecretvalue and issecretvalue(info.iconID)) then
            if info.iconID == FISHING_POLE_ICON_ID then
                return true
            end
        end
    end
    return false
end

local function PlayerChannelFishingSpellId()
    local _, _, textureID, _, _, _, _, spellID = UnitChannelInfo("player")
    spellID = SafeSpellId(spellID)
    if spellID and IsFishingBobberChannelSpell(spellID) then
        return spellID
    end
    if type(textureID) == "number" and textureID == FISHING_POLE_ICON_ID then
        local sid = FishingSpellData.GetKnownPlayerCastSpellId and FishingSpellData.GetKnownPlayerCastSpellId()
        return SafeSpellId(sid) or spellID
    end
    return nil
end

local function PlayerCastingFishingSpellId()
    if type(UnitCastingInfo) ~= "function" then
        return nil
    end
    local _, _, textureID, _, _, _, _, _, castingSpellID = UnitCastingInfo("player")
    castingSpellID = SafeSpellId(castingSpellID)
    if castingSpellID and IsFishingBobberChannelSpell(castingSpellID) then
        return castingSpellID
    end
    if type(textureID) == "number" and textureID == FISHING_POLE_ICON_ID then
        local sid = FishingSpellData.GetKnownPlayerCastSpellId and FishingSpellData.GetKnownPlayerCastSpellId()
        return SafeSpellId(sid) or castingSpellID
    end
    return nil
end

---@class FishingService
local FishingService = {
    _frame = nil,
    _lifecycle = nil,
    _channelingFishing = false,
    _lastFishingChannelStopTime = nil,
    _fishingBobberLineOut = false,
    _fishingBobberLineOutExpireAt = nil,
    _fishingLootWindowWasOpen = false,
}

local function GetLifecycleFrame(self)
    if not self._lifecycle then
        local f = CreateFrame("Frame")
        f:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_LOGOUT" then
                self._fishingBobberLineOut = false
                self._fishingBobberLineOutExpireAt = nil
                self._lastFishingChannelStopTime = nil
                self._channelingFishing = false
                self._fishingLootWindowWasOpen = false
            elseif event == "LOOT_OPENED" then
                if IsFishingLoot and IsFishingLoot() then
                    self._fishingLootWindowWasOpen = true
                end
            elseif event == "LOOT_CLOSED" then
                if self._fishingLootWindowWasOpen then
                    self._fishingLootWindowWasOpen = false
                    self:ClearPostLootState()
                end
            end
        end)
        self._lifecycle = f
    end
    return self._lifecycle
end

function FishingService:IsFishingChanneling()
    if self._channelingFishing then
        return true
    end
    return PlayerChannelFishingSpellId() ~= nil
end

function FishingService:IsBobberLineOut()
    if self._channelingFishing or PlayerChannelFishingSpellId() or PlayerCastingFishingSpellId() then
        return false
    end
    if not self._fishingBobberLineOut then
        return false
    end
    local exp = self._fishingBobberLineOutExpireAt
    return exp ~= nil and GetTime() < exp
end

function FishingService:IsInFishingLootContext()
    if self:IsFishingChanneling() then
        return true
    end
    if self._lastFishingChannelStopTime then
        if (GetTime() - self._lastFishingChannelStopTime) < LOOT_ATTRIBUTION_AFTER_CHANNEL_STOP then
            return true
        end
    end
    if self._fishingBobberLineOut then
        local exp = self._fishingBobberLineOutExpireAt
        return exp and GetTime() < exp
    end
    return false
end

function FishingService:MarkFishingLineOutWindow()
    self._fishingBobberLineOut = true
    self._fishingBobberLineOutExpireAt = GetTime() + FISHING_LINE_OUT_SAFETY_SEC
end

function FishingService:ClearPostLootState()
    self._lastFishingChannelStopTime = nil
    self._fishingBobberLineOut = false
    self._fishingBobberLineOutExpireAt = nil
end

local function GetFrame(self)
    if not self._frame then
        local f = CreateFrame("Frame")
        f:SetScript("OnEvent", function(_, event, unitTarget, _, spellID)
            if unitTarget ~= "player" then
                return
            end
            spellID = SafeSpellId(spellID)
            if event == "UNIT_SPELLCAST_CHANNEL_START" then
                if spellID and IsFishingBobberChannelSpell(spellID) then
                    self._channelingFishing = true
                    self._lastFishingChannelStopTime = nil
                    self._fishingBobberLineOut = false
                    self._fishingBobberLineOutExpireAt = nil
                    ArtisanNexus:SendMessage(E.FISHING_CHANNEL_STARTED, spellID)
                end
            elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
                if self._channelingFishing then
                    self._channelingFishing = false
                    self._lastFishingChannelStopTime = GetTime()
                    self:MarkFishingLineOutWindow()
                    ArtisanNexus:SendMessage(E.FISHING_CHANNEL_STOPPED, spellID)
                elseif spellID and IsFishingBobberChannelSpell(spellID) then
                    self._lastFishingChannelStopTime = GetTime()
                    self:MarkFishingLineOutWindow()
                    ArtisanNexus:SendMessage(E.FISHING_CHANNEL_STOPPED, spellID)
                end
            elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
                if spellID and IsFishingBobberChannelSpell(spellID) and not PlayerChannelFishingSpellId() then
                    self:MarkFishingLineOutWindow()
                end
            end
        end)
        self._frame = f
    end
    return self._frame
end

function FishingService:Enable()
    local fr = GetFrame(self)
    fr:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    fr:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
    fr:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    local lf = GetLifecycleFrame(self)
    lf:RegisterEvent("PLAYER_ENTERING_WORLD")
    lf:RegisterEvent("PLAYER_LOGOUT")
    lf:RegisterEvent("LOOT_OPENED")
    lf:RegisterEvent("LOOT_CLOSED")
end

function FishingService:Disable()
    if self._frame then
        self._frame:UnregisterAllEvents()
    end
    if self._lifecycle then
        self._lifecycle:UnregisterAllEvents()
    end
    self._channelingFishing = false
    self._lastFishingChannelStopTime = nil
    self._fishingBobberLineOut = false
    self._fishingBobberLineOutExpireAt = nil
    self._fishingLootWindowWasOpen = false
end

ns.FishingService = FishingService
