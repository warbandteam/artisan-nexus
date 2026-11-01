--[[
    Artisan Nexus — shared TRADE_SKILL craft event bridge.

    Wiki (Midnight): TRADE_SKILL_CRAFT_BEGIN (recipeSpellID),
    TRADE_SKILL_ITEM_CRAFTED_RESULT (CraftingItemResultData table).

    Single frame owner; CraftingQueueService, CraftLootService and CraftLedgerService
    register listeners.

    Verified 2026-10-14, TradeSkillUITypesDocumentation.lua (12.1.5.70391):
      CraftingItemResultData { itemID, quantity, multicraft (extra items), bonusCraft,
        operationID, firstCraftReward, resourcesReturned?, concentrationSpent,
        hasIngenuityProc, ingenuityRefund, craftingQuality?, isEnchant, ... }
      TRADE_SKILL_CURRENCY_REWARD_RESULT (CraftingCurrencyResultData { currencyID, quantity,
        operationID, firstCraftReward, showCurrencyText })
    Blizzard_ProfessionsCraftingOutputLog.lua: one craft can fire several result events that
    share an operationID; Blizzard settles them 0.35 s after the last one.
]]

local ADDON_NAME, ns = ...

local CraftEventService = {
    pendingSpellID = nil,
    _craftBeginListeners = {},
    _craftResultListeners = {},
    _currencyResultListeners = {},
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
        if self:IsQualityItemOfRecipe(spellID, resultID) then
            return true
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

--- True when itemID is one of the recipe's per-tier outputs (harvested schematic first,
--- then live TradeSkillRecipeInfo.qualityItemIDs while the profession window is open).
---@param spellID number
---@param itemID number
---@return boolean
function CraftEventService:IsQualityItemOfRecipe(spellID, itemID)
    spellID, itemID = tonumber(spellID), tonumber(itemID)
    if not spellID or not itemID or itemID <= 0 then
        return false
    end
    local rs = ns.RecipeService
    local sch = rs and rs.GetSchematic and rs:GetSchematic(spellID)
    local qids = sch and sch.qualityItemIDs
    if type(qids) == "table" then
        for i = 1, #qids do
            if tonumber(qids[i]) == itemID then
                return true
            end
        end
    end
    -- verified 2026-10-14, TradeSkillUITypesDocumentation: TradeSkillRecipeInfo.qualityItemIDs?
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
        local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, spellID)
        local live = ok and type(info) == "table" and info.qualityItemIDs
        if type(live) == "table" then
            for i = 1, #live do
                if tonumber(live[i]) == itemID then
                    return true
                end
            end
        end
    end
    return false
end

--- Recipe whose output (base or quality tier) is itemID, from the harvested schematics.
---@param itemID number
---@return number|nil spellID
function CraftEventService:ResolveSpellFromOutput(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID <= 0 then
        return nil
    end
    local rs = ns.RecipeService
    local s = rs and rs.GetSchematicStore and rs:GetSchematicStore()
    if type(s) ~= "table" then
        return nil
    end
    local tierHit
    for spellID, sch in pairs(s) do
        if type(sch) == "table" then
            if sch.output and tonumber(sch.output.itemID) == itemID then
                return spellID
            end
            if not tierHit and type(sch.qualityItemIDs) == "table" then
                for i = 1, #sch.qualityItemIDs do
                    if tonumber(sch.qualityItemIDs[i]) == itemID then
                        tierHit = spellID
                        break
                    end
                end
            end
        end
    end
    return tierHit
end

--- Recipe a result belongs to: the pending CRAFT_BEGIN spell when the output matches it,
--- else a reverse lookup on the output item. Bonus results match nothing by design.
---@param data table|nil
---@param pendingSpellID number|nil
---@return number|nil spellID
function CraftEventService:ResolveSpellForResult(data, pendingSpellID)
    if type(data) ~= "table" then
        return nil
    end
    local probe = data
    if data.bonusCraft then
        -- Match on the item alone; bonus flag would make ResultMatchesRecipe refuse it.
        probe = { itemID = data.itemID, isEnchant = data.isEnchant }
    end
    if pendingSpellID and self:ResultMatchesRecipe(pendingSpellID, probe) then
        return tonumber(pendingSpellID)
    end
    local itemID = self:GetResultItemID(data)
    if itemID then
        return self:ResolveSpellFromOutput(itemID)
    end
    return nil
end

--- Units a single result event put in the bags.
--- `multicraft` is the number of extra items (Blizzard_ProfessionsCraftingOutputLog shows it
--- as a separate "+N" row).
---
--- EVIDENCE THAT THE DEFAULT BELOW IS WRONG (checked 2026-11-01, wow-ui-source live): that log
--- sets the result button's count from `resultData.quantity` alone
--- (Blizzard_ProfessionsCraftingOutputLog.lua:46) and gives the Multicraft row no count at all,
--- only a tooltip formatting `resultData.multicraft` into a description (:72-82). If `quantity`
--- excluded the extras, Blizzard's own log would show fewer items than the craft produced. So
--- `quantity` most likely ALREADY includes them, and the "not included" default here
--- double-counts a proc whenever quantity <= quantityMax -- which also inflates the multicraft
--- calibration that feeds every recipe's expected value.
--- NOT flipped on that inference alone: it changes what gets written to the ledger. The stored
--- rows keep `multicraft` separately, so a migration can recompute them once one in-game proc
--- settles it. Whether `quantity` already includes those extras is still UNVERIFIED
--- (OutputLog only shows `quantity` as the item count and `multicraft` in a tooltip):
--- when quantity exceeds the recipe's quantityMax the extras are taken as included,
--- otherwise they are added on top. quantityMax comes from the cached RecipeService
--- schematic, else the live C_TradeSkillUI.GetRecipeSchematic(recipeSpellID, isRecraft)
--- (verified 2026-10-15, TradeSkillUIDocumentation.lua / TradeSkillUITypesDocumentation.lua
--- 12.1.5: CraftingRecipeSchematic.quantityMax). With neither (no recipe resolved) the
--- same "not included" default applies: if one in-game multicraft proc shows quantity
--- already includes the extras, flip both branches together.
---@param data table|nil
---@param spellID number|nil
---@return number total
---@return number extra multicraft extra units within total
---@return number base total - extra
function CraftEventService:GetResultTotalQuantity(data, spellID)
    if type(data) ~= "table" then
        return 0, 0, 0
    end
    local qty = math.max(0, tonumber(data.quantity) or 0)
    local mc = math.max(0, tonumber(data.multicraft) or 0)
    if qty == 0 and mc == 0 then
        qty = 1
    end
    if mc <= 0 then
        return qty, 0, qty
    end
    local rs = ns.RecipeService
    local sch = spellID and rs and rs.GetSchematic and rs:GetSchematic(spellID)
    local qmax = sch and sch.output and tonumber(sch.output.quantityMax or sch.output.quantityMin)
    if not qmax and spellID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
        local ok, live = pcall(C_TradeSkillUI.GetRecipeSchematic, spellID, false)
        if ok and type(live) == "table" then
            local v = live.quantityMax or live.quantityMin
            if type(v) == "number" and not (issecretvalue and issecretvalue(v)) then
                qmax = v
            end
        end
    end
    if qmax and qmax > 0 and qty > qmax and qty - mc >= 1 then
        return qty, mc, qty - mc
    end
    return qty + mc, mc, qty
end

--- Per-operation de-duplication of multicraft extras against separate bonusCraft results.
--- A primary result credits base + multicraft; a later bonusCraft result of the same item in
--- the same operation is assumed to be those same extras (UNVERIFIED pairing) and only the
--- part not already credited counts. The reverse order is handled symmetrically.
---@return table deduper with :Credit(data, spellID) -> creditedUnits, extraUnits
function CraftEventService:CreateOutputDeduper()
    local ops = {}
    local svc = self
    local deduper = {}
    local function Op(opID)
        local now = GetTime()
        for k, o in pairs(ops) do
            if now - o.t > 10 then
                ops[k] = nil
            end
        end
        local o = ops[opID]
        if not o then
            o = { t = now, mcCredited = {}, bonusCredited = {} }
            ops[opID] = o
        end
        o.t = now
        return o
    end
    function deduper:Credit(data, spellID)
        if type(data) ~= "table" then
            return 0, 0
        end
        local itemID = svc:GetResultItemID(data) or 0
        local opID = tonumber(data.operationID) or 0
        if data.bonusCraft then
            local q = math.max(0, tonumber(data.quantity) or 0)
            if opID == 0 then
                return q, q
            end
            local o = Op(opID)
            local covered = math.min(q, o.mcCredited[itemID] or 0)
            o.mcCredited[itemID] = (o.mcCredited[itemID] or 0) - covered
            local credit = q - covered
            o.bonusCredited[itemID] = (o.bonusCredited[itemID] or 0) + credit
            return credit, credit
        end
        local total, extra = svc:GetResultTotalQuantity(data, spellID)
        if opID == 0 or extra <= 0 then
            return total, extra
        end
        local o = Op(opID)
        local already = math.min(extra, o.bonusCredited[itemID] or 0)
        o.bonusCredited[itemID] = (o.bonusCredited[itemID] or 0) - already
        local creditExtra = extra - already
        o.mcCredited[itemID] = (o.mcCredited[itemID] or 0) + creditExtra
        return total - already, creditExtra
    end
    return deduper
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

---@param listener function(data: table|nil, pendingSpellID: number|nil) CraftingCurrencyResultData
---@return number listenerId
function CraftEventService:RegisterCurrencyResult(listener)
    self._currencyResultListeners[#self._currencyResultListeners + 1] = listener
    return #self._currencyResultListeners
end

--- One failing listener must not starve the others (queue, loot, ledger).
local function SafeCall(fn, a, b)
    local ok, err = pcall(fn, a, b)
    if not ok and geterrorhandler then
        geterrorhandler()(err)
    end
end

--- The craft-begin spell is a hint for the results of that run. It used to live forever, so a
--- later cast that fires no TRADE_SKILL_CRAFT_BEGIN of its own — a shaman weapon imbue, a weapon
--- oil — could resolve through the previous craft's spell and slip back past IsNonRecipeEnchant.
--- That hole is specifically ResultMatchesRecipe's "isEnchant and the recipe has no output item"
--- branch, which an enchanting recipe satisfies, so an imbue after an enchant craft matched it.
---
--- The TTL measures IDLE time, refreshed on every craft result, not time since CRAFT_BEGIN: a
--- "Create all" run streams results for as long as it lasts and must keep its hint, because a
--- real enchanting craft reports the ENCHANTED item as its itemID and so cannot be resolved by
--- ResolveSpellFromOutput at all — dropping the hint mid-run would silently lose real ledger rows.
--- UNVERIFIED: whether TRADE_SKILL_CRAFT_BEGIN fires per cast or once per multi-cast run. The idle
--- window is sized so it does not matter; confirm in-game before shortening it.
local PENDING_SPELL_IDLE_TTL = 60

local function PendingSpell()
    local at = CraftEventService.pendingAt
    if not at or (GetTime() - at) > PENDING_SPELL_IDLE_TTL then
        CraftEventService.pendingSpellID = nil
        CraftEventService.pendingAt = nil
        return nil
    end
    return CraftEventService.pendingSpellID
end

local function DispatchCraftBegin(recipeSpellID)
    CraftEventService.pendingSpellID = tonumber(recipeSpellID)
    CraftEventService.pendingAt = CraftEventService.pendingSpellID and GetTime() or nil
    local listeners = CraftEventService._craftBeginListeners
    for i = 1, #listeners do
        SafeCall(listeners[i], CraftEventService.pendingSpellID)
    end
end

--- Spell-based item enchants that are not professions — shaman weapon imbues
--- (Flametongue/Windfury Weapon), weapon oils and stones — raise
--- TRADE_SKILL_ITEM_CRAFTED_RESULT with isEnchant set and the enchanted item as itemID,
--- while no profession recipe owns the cast. Verified in-game 2026-10-31 (Flametongue
--- Weapon): no TRADE_SKILL_CRAFT_BEGIN fires at all, so pendingSpellID is nil or stale,
--- and each cast gets its own operationID. Nothing enters the bags, so they must not
--- reach the session loot toast, the ledger or the queue. A real enchanting craft
--- resolves to a profession through RecipeService and still goes through.
---@param data table|nil CraftingItemResultData
---@return boolean
local function IsNonRecipeEnchant(data)
    if type(data) ~= "table" or not data.isEnchant then
        return false
    end
    local rs = ns.RecipeService
    if not (rs and rs.GetProfession) then
        return false
    end
    local spellID = CraftEventService:ResolveSpellForResult(data, PendingSpell())
    return spellID == nil or rs:GetProfession(spellID) == nil
end

local function DispatchCraftResult(data)
    if IsNonRecipeEnchant(data) then
        return
    end
    local spellID = PendingSpell()
    -- A result got through: the run is still going, so hold the hint for another idle window.
    if spellID then
        CraftEventService.pendingAt = GetTime()
    end
    local listeners = CraftEventService._craftResultListeners
    for i = 1, #listeners do
        SafeCall(listeners[i], data, spellID)
    end
end

local function DispatchCurrencyResult(data)
    local listeners = CraftEventService._currencyResultListeners
    for i = 1, #listeners do
        SafeCall(listeners[i], data, PendingSpell())
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("TRADE_SKILL_CRAFT_BEGIN")
frame:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT")
frame:RegisterEvent("TRADE_SKILL_CURRENCY_REWARD_RESULT")
frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "TRADE_SKILL_CRAFT_BEGIN" then
        DispatchCraftBegin(arg1)
    elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        DispatchCraftResult(arg1)
    elseif event == "TRADE_SKILL_CURRENCY_REWARD_RESULT" then
        DispatchCurrencyResult(arg1)
    end
end)

ns.CraftEventService = CraftEventService
