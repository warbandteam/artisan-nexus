--[[
    Artisan Nexus — versioned, NON-destructive SavedVariables migrations.

    `db.global._schemaVersion` vs file-local `CURRENT_SCHEMA_VERSION`: each step in
    `MIGRATIONS` transforms schema v → v+1 in place. Steps must be idempotent and must
    NEVER wipe another character's data (offline characters keep their records).
    `_schemaVersion` / `addonVersion` are stamped here and deliberately absent from
    Core.lua defaults — AceDB strips stored values equal to defaults at logout.
]]

local ADDON_NAME, ns = ...

local DebugPrint = ns.DebugPrint

local function PrintUserMessage(message)
    if not message or message == "" then return end
    local addon = ns.ArtisanNexus
    if addon and addon.Print then
        addon:Print(message)
    else
        _G.print(message)
    end
end

---@class MigrationService
local MigrationService = {}
ns.MigrationService = MigrationService

-- Bump when the SavedVariables layout changes; add a matching MIGRATIONS step.
local CURRENT_SCHEMA_VERSION = 4

--- Removed fishing input / double-cast gesture keys (feature deleted; strip from profile).
local LEGACY_FISHING_INPUT_PROFILE_KEYS = {
    "fishingSecureLootClickEnabled",
    "fishingSoftTargetInteractTuneEnabled",
    "settingsAdvancedFishingExpanded",
    "fishingDoubleClickUseLeftButton",
    "fishingDoubleClickUseRightButton",
    "fishingDoubleClickEnabled",
    "fishingClickThreshold",
    "fishingDoubleRightClickEnabled",
    "fishingDoubleRightClickCastEnabled",
    "fishingRightClickInteractEnabled",
    "fishingDoubleRightArmSeconds",
    "fishingInputDebug",
    "_fishingUnifiedDoubleRight202605",
    "_fishingWorldClickMigration2026",
    "_fishingRemovedUiToggles202606",
    "_fishingInputRemoved202602",
    "_fishingDoubleCastRemoved202606",
}

--- MIGRATIONS[v] upgrades schema v → v+1 in place. Idempotent; never wipes
--- other characters' data.
local MIGRATIONS = {
    --- v1 → v2: GUID-keyed character attribution. New stores are created empty;
    --- legacy event rows carry no character key and group under the "unknown"
    --- bucket at read time — nothing is destroyed.
    [1] = function(db)
        local g = db.global
        g.charRegistry = g.charRegistry or {}
        g.professionSnapshots = g.professionSnapshots or {}
    end,
    --- v2 → v3: drop legacy fishing input / double-cast profile keys (no runtime feature).
    [2] = function(db)
        local p = db.profile
        if not p then
            return
        end
        for i = 1, #LEGACY_FISHING_INPUT_PROFILE_KEYS do
            p[LEGACY_FISHING_INPUT_PROFILE_KEYS[i]] = nil
        end
    end,
    --- v3 → v4: legacy overload tracker default was TOP-center (too high); anchor above action bars.
    [3] = function(db)
        local p = db.profile
        if not p or type(p.overloadTrackerFrame) ~= "table" then
            return
        end
        local t = p.overloadTrackerFrame
        if t._overloadAnchorBottom202607 then
            return
        end
        local px = tonumber(t.x) or 0
        local py = tonumber(t.y) or 0
        local rel = t.relativePoint or t.point or "TOP"
        if t.point == "TOP" and rel == "TOP" and px == 0 and py == -140 then
            t.point = "BOTTOMRIGHT"
            t.relativePoint = "BOTTOMRIGHT"
            t.x = -24
            t.y = 120
            t._overloadAnchorBottom202607 = true
        end
    end,
}

function MigrationService:CheckAddonVersion(db, addon)
    local ADDON_VERSION = (ns.Constants and ns.Constants.ADDON_VERSION) or "0.1.0"
    local savedVersion = db.global.addonVersion or "0.0.0"
    if savedVersion ~= ADDON_VERSION then
        DebugPrint("|cff9370DB[AN Migration]|r version " .. savedVersion .. " → " .. ADDON_VERSION)
    end
    -- Stamp unconditionally: the value must differ from any AceDB default to persist.
    db.global.addonVersion = ADDON_VERSION
end

---@param db table
---@return boolean didReset always false — migrations transform, never reset
function MigrationService:RunMigrations(db)
    if not db or not db.global then return false end
    local g = db.global
    local stored = g._schemaVersion
    if stored == nil then
        -- Pre-versioned install, or the old `_schemaVersion = 1` default was
        -- stripped by AceDB at logout: treat existing data as v1.
        stored = 1
    end
    if stored > CURRENT_SCHEMA_VERSION then
        return false -- downgraded addon: leave newer data untouched
    end
    while stored < CURRENT_SCHEMA_VERSION do
        local step = MIGRATIONS[stored]
        if step then
            local ok, err = pcall(step, db)
            if not ok then
                DebugPrint("|cff9370DB[AN Migration]|r step v" .. stored .. " failed: " .. tostring(err))
                break
            end
            DebugPrint("|cff9370DB[AN Migration]|r schema v" .. stored .. " → v" .. (stored + 1))
        end
        stored = stored + 1
    end
    g._schemaVersion = stored
    return false
end
