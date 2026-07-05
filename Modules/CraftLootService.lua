--[[
    Artisan Nexus — craft output session tracking.

    Listens on CraftEventService; persists via SessionLootService:PushCraftedSession.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants and ns.Constants.EVENTS
local CraftEventService = ns.CraftEventService
local SessionLootService = ns.SessionLootService

local CraftLootService = {}

local function ResolveSpellFromOutput(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 then
        return nil
    end
    local rs = ns.RecipeService
    if not rs or not rs.GetOutputItem then
        return nil
    end
    local s = ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.global.recipeSchematics
    if type(s) ~= "table" then
        return nil
    end
    for spellID in pairs(s) do
        if rs:GetOutputItem(spellID) == itemID then
            return spellID
        end
    end
    return nil
end

local function OnCraftResult(data, pendingSpellID)
    if not SessionLootService or not SessionLootService.PushCraftedSession then
        return
    end
    if type(data) ~= "table" or data.bonusCraft then
        return
    end
    local itemID = CraftEventService and CraftEventService:GetResultItemID(data)
    if not itemID then
        return
    end
    local spellID = pendingSpellID
    if spellID and CraftEventService and not CraftEventService:ResultMatchesRecipe(spellID, data) then
        spellID = nil
    end
    if not spellID then
        spellID = ResolveSpellFromOutput(itemID)
    end
    if spellID and CraftEventService and not CraftEventService:ResultMatchesRecipe(spellID, data) then
        return
    end
    local qty = tonumber(data.quantity) or 1
    if qty < 1 then
        qty = 1
    end
    local rs = ns.RecipeService
    local profession = (rs and rs.GetProfession and spellID) and rs:GetProfession(spellID) or nil
    SessionLootService:PushCraftedSession(itemID, qty, {
        spellID = spellID,
        profession = profession,
        quality = data.craftingQuality,
        isCrit = data.isCrit,
    })
end

function CraftLootService:Enable()
    if self._enabled or not CraftEventService then
        return
    end
    self._enabled = true
    CraftEventService:RegisterCraftResult(function(data, pendingSpellID)
        OnCraftResult(data, pendingSpellID)
    end)
end

ns.CraftLootService = CraftLootService
