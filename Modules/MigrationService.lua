--[[
    Artisan Nexus — DB version stamp and optional full reset when schema bumps.
]]

local ADDON_NAME, ns = ...

local DebugPrint = ns.DebugPrint

local function PrintUserMessage(message)
    if not message or message == "" then return end
    local addon = _G.ArtisanNexus
    if addon and addon.Print then
        addon:Print(message)
    else
        _G.print(message)
    end
end

---@class MigrationService
local MigrationService = {}
ns.MigrationService = MigrationService

-- Increment when breaking SavedVariables layout requires a one-time wipe for existing users.
local CURRENT_SCHEMA_VERSION = 1

function MigrationService:CheckAddonVersion(db, addon)
    local ADDON_VERSION = (ns.Constants and ns.Constants.ADDON_VERSION) or "0.1.0"
    local savedVersion = db.global.addonVersion or "0.0.0"
    if savedVersion ~= ADDON_VERSION then
        DebugPrint("|cff9370DB[AN Migration]|r version " .. savedVersion .. " → " .. ADDON_VERSION)
        db.global.addonVersion = ADDON_VERSION
    end
end

---@param db table
---@return boolean didReset
function MigrationService:RunMigrations(db)
    if not db then return false end
    if self:CheckSchemaReset(db) then
        return true
    end
    return false
end

---@param db table
---@return boolean
function MigrationService:CheckSchemaReset(db)
    local storedVersion = db.global._schemaVersion or 0
    if storedVersion >= CURRENT_SCHEMA_VERSION then
        return false
    end

    DebugPrint("|cff9370DB[AN Migration]|r schema reset v" .. storedVersion .. " → v" .. CURRENT_SCHEMA_VERSION)
    PrintUserMessage("|cff6a0dad"
        .. ((ns.L and ns.L["ADDON_NAME"]) or "Artisan Nexus")
        .. "|r: Database schema updated — one-time reset.")

    if db.global then wipe(db.global) end
    local raw = _G.ArtisanNexusDB
    if raw and raw.char then
        wipe(raw.char)
    end
    if db.char then wipe(db.char) end
    if db.ResetProfile then
        db:ResetProfile(nil, true)
    elseif db.profile then
        wipe(db.profile)
    end

    db.global._schemaVersion = CURRENT_SCHEMA_VERSION
    return true
end
