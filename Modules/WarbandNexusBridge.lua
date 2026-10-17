--[[
    Artisan Nexus — Warband Nexus Bridge
    Safe, optional integration layer with Warband Nexus (if installed).
    Provides cross-character reagent inventories, alt concentration queries, recipe crafter lookup and
    the character roster. Consumers never call this directly: ns.CharacterData (Modules/Data/
    CharacterDataProvider.lua) picks per capability between these wrappers and AN's own collectors.
    Every wrapper pcalls a public WarbandNexus method (cited file:line, warband-nexus v3.6.0 c121ec5).
]]

local ADDON_NAME, ns = ...

local WarbandNexusBridge = { _wnListening = false, _relayPending = false, _relayKinds = nil }

--- WN message names verified 2026-10-14 against warband-nexus Modules/Constants.lua
--- (EVENTS.ITEMS_UPDATED / BAGS_UPDATED / CONCENTRATION_UPDATED / RECIPE_DATA_UPDATED),
--- sent via AceEvent-3.0 SendMessage (ItemsCacheService, DataService, ProfessionService).
--- CHARACTER_TRACKING_CHANGED verified 2026-10-15, warband-nexus Modules/Constants.lua:222.
--- AceEvent's message registry is library-global, so an AN-owned AceEvent owner hears them.
local WN_MESSAGES = {
    WN_ITEMS_UPDATED = "items",
    WN_BAGS_UPDATED = "bags",
    WN_CONCENTRATION_UPDATED = "concentration",
    WN_RECIPE_DATA_UPDATED = "recipes",
    WN_CHARACTER_TRACKING_CHANGED = "tracking",
}
local RELAY_COALESCE_SEC = 0.5

--- Get reference to the active Warband Nexus addon instance
function WarbandNexusBridge:GetAddon()
    if _G.WarbandNexus then
        return _G.WarbandNexus
    end
    if LibStub then
        local ace = LibStub("AceAddon-3.0", true)
        if ace then
            return ace:GetAddon("WarbandNexus", true)
        end
    end
    return nil
end

--- Check if Warband Nexus is loaded and available
function WarbandNexusBridge:IsAvailable()
    local available = self:GetAddon() ~= nil
    --- Lazy attach: WN may become reachable after Init ran (late load).
    if available and not self._wnListening and self._eventOwner then
        self:AttachListeners()
    end
    return available
end

--- True when WN is reachable and exposes `method` (capability probe for ns.CharacterData).
---@param method string
---@return boolean
function WarbandNexusBridge:HasMethod(method)
    if not self:IsAvailable() then
        return false
    end
    local wn = self:GetAddon()
    return wn ~= nil and type(wn[method]) == "function"
end

--- WN bursts (bag scans, batch item writes) collapse into one AN_WN_DATA_UPDATED.
local function QueueRelay(kind)
    local self = WarbandNexusBridge
    self._relayKinds = self._relayKinds or {}
    self._relayKinds[kind] = true
    if self._relayPending then
        return
    end
    self._relayPending = true
    C_Timer.After(RELAY_COALESCE_SEC, function()
        WarbandNexusBridge._relayPending = false
        local kinds = WarbandNexusBridge._relayKinds or {}
        WarbandNexusBridge._relayKinds = nil
        local E = ns.Constants.EVENTS
        ns.ArtisanNexus:SendMessage(E.WN_DATA_UPDATED, kinds)
    end)
end

--- Register the WN message listeners once WN is reachable. Idempotent.
function WarbandNexusBridge:AttachListeners()
    if self._wnListening or not self._eventOwner or self:GetAddon() == nil then
        return
    end
    self._wnListening = true
    local owner = self._eventOwner
    for message, kind in pairs(WN_MESSAGES) do
        owner:RegisterMessage(message, function()
            QueueRelay(kind)
        end)
    end
    owner:UnregisterEvent("ADDON_LOADED")
end

--- Call once from AN OnEnable. Safe when WN is absent or loads after AN.
function WarbandNexusBridge:Init()
    if not self._eventOwner then
        self._eventOwner = ns.NewEventOwner("WarbandNexusBridge")
    end
    if self:GetAddon() ~= nil then
        self:AttachListeners()
        return
    end
    if self._wnListening then
        return
    end
    self._eventOwner:RegisterEvent("ADDON_LOADED", function(_, addonName)
        if addonName == "WarbandNexus" then
            WarbandNexusBridge:AttachListeners()
        end
    end)
end

--- Query detailed item counts across the Warband (Warband bank + all tracked characters).
--- Wraps WarbandNexus:GetDetailedItemCountsFast(itemID) (ItemsCacheService.lua:3025) ->
--- { warbandBank, personalBankTotal, guilds, characters = { {charName, classFile, bagCount, bankCount, total, isLiveSession} } }.
--- @param itemID number
--- @return table|nil { warbandBank = number, altTotal = number, altBags = number, altBanks = number, altDetails = table }
function WarbandNexusBridge:GetDetailedItemCounts(itemID)
    if not itemID or not self:IsAvailable() then
        return nil
    end
    local wn = self:GetAddon()
    if not wn or not wn.GetDetailedItemCountsFast then
        return nil
    end

    local ok, res = pcall(wn.GetDetailedItemCountsFast, wn, itemID)
    if not ok or type(res) ~= "table" then
        return nil
    end

    local altTotal = 0
    local altBags = 0
    local altBanks = 0
    local chars = res.characters or {}
    local altDetails = {}

    for i = 1, #chars do
        local c = chars[i]
        if c and not c.isLiveSession then
            local bCount = c.bagCount or 0
            local bkCount = c.bankCount or 0
            local tot = bCount + bkCount
            if tot > 0 then
                altTotal = altTotal + tot
                altBags = altBags + bCount
                altBanks = altBanks + bkCount
                altDetails[#altDetails + 1] = {
                    name = c.charName or "Alt",
                    classFile = c.classFile,
                    bagCount = bCount,
                    bankCount = bkCount,
                    total = tot,
                }
            end
        end
    end

    return {
        warbandBank = res.warbandBank or 0,
        personalBankTotal = res.personalBankTotal or 0,
        altTotal = altTotal,
        altBags = altBags,
        altBanks = altBanks,
        altDetails = altDetails,
        raw = res,
    }
end

--- Query concentration data for all tracked characters.
--- Wraps WarbandNexus:GetAllConcentrationData() (ProfessionService.lua:2823) -> { [professionName] = {
--- {charKey, charName, classFile, current, max, lastUpdate, currencyID} } } and projects passive regen with
--- WarbandNexus:GetEstimatedConcentration(entry) (ProfessionService.lua:3258). WN rows carry no skillLineID,
--- so ns.CharacterData filters non-Midnight pools by currencyID.
--- @return table[]|nil flat list of { charKey, charName, classFile, profession, current, max, lastUpdate, currencyID }
---   max is passed through unchanged (0 = pool never read by WN; callers skip it).
function WarbandNexusBridge:GetAllConcentrationData()
    if not self:IsAvailable() then
        return nil
    end
    local wn = self:GetAddon()
    if not wn or not wn.GetAllConcentrationData then
        return nil
    end
    local ok, res = pcall(wn.GetAllConcentrationData, wn)
    if not ok or type(res) ~= "table" then
        return nil
    end

    local flat = {}
    if res[1] then
        -- Already a flat array
        for i = 1, #res do
            flat[#flat + 1] = res[i]
        end
    else
        -- Dictionary grouped by profession name
        for profName, entries in pairs(res) do
            if type(entries) == "table" then
                for i = 1, #entries do
                    local e = entries[i]
                    if e then
                        local maxVal = tonumber(e.max) or 0
                        local row = {
                            charKey = e.charKey,
                            charName = e.charName,
                            classFile = e.classFile,
                            profession = profName,
                            current = e.current or 0,
                            max = maxVal,
                            lastUpdate = e.lastUpdate or 0,
                            currencyID = e.currencyID,
                        }
                        -- Snapshot is from the last login; project passive regen since then.
                        if maxVal > 0 and wn.GetEstimatedConcentration then
                            local okEst, est = pcall(wn.GetEstimatedConcentration, wn, row)
                            if okEst and type(est) == "number" then
                                row.current = est
                            end
                        end
                        flat[#flat + 1] = row
                    end
                end
            end
        end
    end

    table.sort(flat, function(a, b)
        if a.charName ~= b.charName then
            return (a.charName or "") < (b.charName or "")
        end
        return (a.profession or "") < (b.profession or "")
    end)

    return flat
end

--- Characters who know a recipe.
--- Wraps WarbandNexus:GetCraftersForRecipe(recipeID) (ProfessionService.lua:3182) -> { {charKey, charName,
--- classFile, professionName, skillLevel, maxSkillLevel, concentration, lastScan} } (WN-tracked characters only).
--- UNVERIFIED: that WN knownRecipes keys equal AN's normalized spellIDs (both are TradeSkill recipe spell IDs).
--- @param recipeID number
--- @return table[]|nil
function WarbandNexusBridge:GetCrafters(recipeID)
    if not recipeID or not self:IsAvailable() then
        return nil
    end
    local wn = self:GetAddon()
    if not wn or not wn.GetCraftersForRecipe then
        return nil
    end
    local ok, res = pcall(wn.GetCraftersForRecipe, wn, recipeID)
    if ok and type(res) == "table" then
        return res
    end
    return nil
end

--- WN character roster (tracked and untracked, deduplicated).
--- Wraps WarbandNexus:GetAllCharacters() (DataService.lua:1734), which returns WN's own SavedVariables rows
--- (DataService.lua:790-840: name, realm, classFile, guid?, lastSeen, isTracked, _key = table key). The rows
--- are copied here so AN never holds or mutates WN's tables.
--- @return table[]|nil { {key, guid, name, realm, classFile, lastSeen, isTracked} }
function WarbandNexusBridge:GetCharacters()
    if not self:IsAvailable() then
        return nil
    end
    local wn = self:GetAddon()
    if not wn or not wn.GetAllCharacters then
        return nil
    end
    local ok, res = pcall(wn.GetAllCharacters, wn)
    if not ok or type(res) ~= "table" then
        return nil
    end
    local out = {}
    for i = 1, #res do
        local c = res[i]
        if type(c) == "table" then
            local guid = c.guid
            if type(guid) ~= "string" or guid == "" or (issecretvalue and issecretvalue(guid)) then
                guid = nil
            end
            out[#out + 1] = {
                key = c._key,
                guid = guid,
                name = c.name,
                realm = c.realm,
                classFile = c.classFile,
                lastSeen = c.lastSeen,
                isTracked = c.isTracked == true,
            }
        end
    end
    return out
end

ns.WarbandNexusBridge = WarbandNexusBridge
