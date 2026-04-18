--[[
    Debug print helper — respects profile.debugMode (ArtisanNexus db).
]]

local ADDON_NAME, ns = ...

local function GetProfile()
    local addon = _G.ArtisanNexus
    if not addon or not addon.db or not addon.db.profile then
        return nil
    end
    return addon.db.profile
end

local function IsDebugModeEnabled()
    local profile = GetProfile()
    return profile and profile.debugMode == true or false
end

---@param ... any
local function DebugPrint(...)
    if not IsDebugModeEnabled() then return end
    _G.print("|cff6a0dad[AN]|r", ...)
end

ns.DebugPrint = DebugPrint
