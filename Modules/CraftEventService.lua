--[[
    Artisan Nexus — shared TRADE_SKILL craft event bridge.

    Wiki (Midnight): TRADE_SKILL_CRAFT_BEGIN (recipeSpellID),
    TRADE_SKILL_ITEM_CRAFTED_RESULT (CraftingItemResultData table).

    Single frame owner; CraftingQueueService and CraftLootService register listeners.
]]

local ADDON_NAME, ns = ...

local CraftEventService = {
    pendingSpellID = nil,
    _craftBeginListeners = {},
    _craftResultListeners = {},
}

---@param spellID number|nil
---@param data table|nil CraftingItemResultData
---@return boolean
function CraftEventService:ResultMatchesRecipe(spellID, data)
    if type(data) ~= "table" then
        return true
    end
    if data.bonusCraft then
        return false
    end
    spellID = tonumber(spellID)
    if not spellID then
        return false
    end
    local rs = ns.RecipeService
    local outID = rs and rs.GetOutputItem and rs:GetOutputItem(spellID)
    local resultID = tonumber(data.itemID)
    if resultID and resultID > 0 then
        if outID and resultID == outID then
            return true
        end
        --- Quality-tier crafts return a tier item that differs from the base output.
        local sch = rs and rs.GetSchematic and rs:GetSchematic(spellID)
        local qids = sch and sch.qualityItemIDs
        if type(qids) == "table" then
            for i = 1, #qids do
                if tonumber(qids[i]) == resultID then
                    return true
                end
            end
        end
        if outID and outID > 0 then
            return false
        end
        return true
    end
    if data.isEnchant and (not outID or outID <= 0) then
        return true
    end
    return false
end

---@param data table|nil
---@return number|nil itemID
function CraftEventService:GetResultItemID(data)
    if type(data) ~= "table" then
        return nil
    end
    local itemID = tonumber(data.itemID)
    if itemID and itemID > 0 then
        return itemID
    end
    return nil
end

---@param listener function(spellID: number|nil)
---@return number listenerId
function CraftEventService:RegisterCraftBegin(listener)
    self._craftBeginListeners[#self._craftBeginListeners + 1] = listener
    return #self._craftBeginListeners
end

---@param listener function(data: table|nil, pendingSpellID: number|nil)
---@return number listenerId
function CraftEventService:RegisterCraftResult(listener)
    self._craftResultListeners[#self._craftResultListeners + 1] = listener
    return #self._craftResultListeners
end

local function DispatchCraftBegin(recipeSpellID)
    CraftEventService.pendingSpellID = tonumber(recipeSpellID)
    local listeners = CraftEventService._craftBeginListeners
    for i = 1, #listeners do
        listeners[i](CraftEventService.pendingSpellID)
    end
end

local function DispatchCraftResult(data)
    local listeners = CraftEventService._craftResultListeners
    for i = 1, #listeners do
        listeners[i](data, CraftEventService.pendingSpellID)
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("TRADE_SKILL_CRAFT_BEGIN")
frame:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "TRADE_SKILL_CRAFT_BEGIN" then
        DispatchCraftBegin(arg1)
    elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        DispatchCraftResult(arg1)
    end
end)

ns.CraftEventService = CraftEventService
