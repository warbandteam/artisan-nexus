--[[
    Artisan Nexus — safe execution wrapper for services.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus

---@param func function
---@param context string|nil
---@return boolean, any
function ArtisanNexus:SafeCall(func, context, ...)
    if type(func) ~= "function" then
        return false, "not a function"
    end
    local ok, result = pcall(func, ...)
    if not ok then
        local msg = tostring(result)
        self:Print("|cffff0000[" .. (context or "ArtisanNexus") .. "]|r " .. msg)
        return false, msg
    end
    return true, result
end
