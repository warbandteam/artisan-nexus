--[[
    Artisan Nexus — craft output session tracking.

    Listens on CraftEventService; persists via SessionLootService:PushCraftedSession.
    Counts base output + multicraft extras + bonusCraft results, de-duplicated per
    operationID through CraftEventService:CreateOutputDeduper (the only dedup — no time
    window). First-craft rewards are not output: Blizzard_ProfessionsCraftingOutputLog
    files `firstCraftReward` results as children of the craft, not as crafted items
    (verified 2026-10-15, TradeSkillUITypesDocumentation 12.1.5: CraftingItemResultData.firstCraftReward).
]]

local ADDON_NAME, ns = ...

local CraftEventService = ns.CraftEventService
local SessionLootService = ns.SessionLootService

local CraftLootService = {}

--- Multicraft extras and separate bonusCraft results of one operation are credited once.
local outputDeduper = nil

local function OnCraftResult(data, pendingSpellID)
    if not SessionLootService or not SessionLootService.PushCraftedSession then
        return
    end
    if type(data) ~= "table" or not CraftEventService then
        return
    end
    -- First-craft rewards (skill XP currency, Artisan's Mettle) are never crafted output.
    -- Blizzard_ProfessionsCraftingOutputLog.lua:303-307 files one with operationID == 0 as a
    -- parent row, but only so it still appears in the log when the pairing ID is missing;
    -- the reward itself is unchanged, so it is skipped regardless of operationID
    -- (verified 2026-10-15, wow-ui-source-live).
    if data.firstCraftReward then
        return
    end
    local itemID = CraftEventService:GetResultItemID(data)
    if not itemID then
        return
    end
    local spellID = CraftEventService:ResolveSpellForResult(data, pendingSpellID)
    if not outputDeduper then
        outputDeduper = CraftEventService:CreateOutputDeduper()
    end
    local qty = outputDeduper:Credit(data, spellID)
    if not qty or qty < 1 then
        return
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
    -- CraftEventService has no unregister; register once and gate on _enabled.
    if not self._registered then
        self._registered = true
        CraftEventService:RegisterCraftResult(function(data, pendingSpellID)
            if CraftLootService._enabled then
                OnCraftResult(data, pendingSpellID)
            end
        end)
    end
end

function CraftLootService:Disable()
    self._enabled = false
end

ns.CraftLootService = CraftLootService
