--[[
    Bag pressure guard for gathering loops.
    Warns when free bag slots drop below configured threshold.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local L = ns.L

---@class BagPressureGuard
local BagPressureGuard = {
    _enabled = false,
    _lastWarnAt = 0,
}

local frame = CreateFrame("Frame")

local function IsEnabled()
    local db = ns.db and ns.db.profile
    return db and db.bagPressureGuardEnabled ~= false
end

local function GetThreshold()
    local db = ns.db and ns.db.profile
    local v = db and db.bagPressureThreshold
    if not v then
        return 8
    end
    return math.max(1, math.floor(v))
end

local function GetFreeSlots()
    local free = 0
    for bag = 0, 4 do
        local n
        if C_Container and C_Container.GetContainerNumFreeSlots then
            local x = C_Container.GetContainerNumFreeSlots(bag)
            n = type(x) == "number" and x or nil
        elseif GetContainerNumFreeSlots then
            n = GetContainerNumFreeSlots(bag)
        end
        if n and n > 0 then
            free = free + n
        end
    end
    return free
end

local function Warn(free, threshold)
    if not ArtisanNexus or not ArtisanNexus.Print then
        return
    end
    local fmt = (L and L["BAG_PRESSURE_WARN_FMT"]) or "Bag pressure: %d free slots (threshold: %d)."
    ArtisanNexus:Print(string.format(fmt, free, threshold))
    if RaidNotice_AddMessage and RaidWarningFrame then
        local txt = (L and L["BAG_PRESSURE_WARN_SHORT"]) or "Bag pressure"
        RaidNotice_AddMessage(RaidWarningFrame, txt, ChatTypeInfo["RAID_WARNING"])
    end
end

function BagPressureGuard:Check()
    if not self._enabled or not IsEnabled() then
        return
    end
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return
    end
    local free = GetFreeSlots()
    local threshold = GetThreshold()
    if free > threshold then
        return
    end
    local now = GetTime()
    if (now - (self._lastWarnAt or 0)) < 45 then
        return
    end
    self._lastWarnAt = now
    Warn(free, threshold)
end

function BagPressureGuard:Enable()
    if self._enabled then
        return
    end
    self._enabled = true
    frame:RegisterEvent("BAG_UPDATE_DELAYED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_ENTERING_WORLD" then
            C_Timer.After(2, function()
                BagPressureGuard:Check()
            end)
        else
            BagPressureGuard:Check()
        end
    end)
end

function BagPressureGuard:Disable()
    if not self._enabled then
        return
    end
    self._enabled = false
    frame:UnregisterAllEvents()
    frame:SetScript("OnEvent", nil)
end

ns.BagPressureGuard = BagPressureGuard
