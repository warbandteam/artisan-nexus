--[[
    Debug print helper — respects profile.debugMode (ArtisanNexus db).
]]

local ADDON_NAME, ns = ...

local function GetProfile()
    local addon = ns.ArtisanNexus
    if not addon or not addon.db or not addon.db.profile then
        return nil
    end
    return addon.db.profile
end

function ns.IsDebugModeEnabled()
    local profile = GetProfile()
    return profile and profile.debugMode == true or false
end

---@param ... any
local function DebugPrint(...)
    if not ns.IsDebugModeEnabled() then
        return
    end
    _G.print("|cff6a0dad[AN]|r", ...)
end

ns.DebugPrint = DebugPrint
