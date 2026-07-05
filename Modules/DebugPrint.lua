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

--- Chat-frame debug lines (`[AN-Dbg]` …) — **only** when `profile.debugMode` is true. No output when off.
---@param text string
local function DebugChatMessage(text)
    if not ns.IsDebugModeEnabled() then
        return
    end
    if not text or type(text) ~= "string" then
        return
    end
    local cf = _G.DEFAULT_CHAT_FRAME
    if cf and cf.AddMessage then
        cf:AddMessage(text, 0.45, 0.82, 1)
    end
end

ns.DebugPrint = DebugPrint
ns.DebugChatMessage = DebugChatMessage
