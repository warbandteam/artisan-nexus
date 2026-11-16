--[[
    Artisan Nexus — Character data provider (ns.CharacterData).
    Hand-written (not a generated data table, unlike the other Modules/Data files).

    One interface over per-character data, two backends chosen PER CAPABILITY:
      "wn"     Warband Nexus (optional addon) through ns.WarbandNexusBridge
      "native" AN's own collectors (ProfessionSnapshotService pools, CooldownService, RecipeService
               learnedBy, the Utilities charRegistry, and the reagent item snapshot in this file)

    A capability reads WN when the bridge is available, WN exposes the public method in WN_METHOD and
    WN tracks the logged-in character (WN collects profession / item data only for tracked characters,
    warband-nexus ProfessionService.lua:20 IsCurrentCharacterTracked). The native collectors ALWAYS
    write the logged-in character's GUID rows (they are cheap), whatever the backend: a character WN
    does not track, or every character after WN is removed, still has AN's own data. Reads merge:
    WN rows first, then native rows for every GUID WN does not track (WnTrackedGuids). Consumers read
    through this module only. The current character's concentration is always read live.

    Native rows not refreshed for STALE_SEC (30 days) are pruned on enable (professionSnapshots,
    itemSnapshots; recipeCooldowns prunes itself). PurgeCharacter(guid) forgets one character in every
    per-character store (Overview > Characters, right-click).

    Public API (all reads; never mutate returned tables):
      IsUsingWarbandNexus() -> boolean                 any capability served by WN
      GetBackend(capability) -> "wn"|"native"
      UsesNative(capability) -> boolean               collectors gate event wiring / SV writes on this
      GetCharacters() -> { [guid] = {guid, name, realm, surname, classFile, lastSeen, source} }
      GetCharacter(guid) -> row|nil
      GetCharacterProfessions(guid) -> { at, list = { {skillLine, name, icon, rank, maxRank} } }|nil
      GetRecipeCountForCharacter(guid) -> number      recipes recorded as learned (learnedBy)
      PurgeCharacter(guid) -> boolean                 never the logged-in character
      GetConcentrationPools() -> { {guid, charKey, charName, classFile, profession, professionName,
          skillLineID, currencyID, current, max, ratePerHour, secondsToCap, capped, source = "an"|"wn",
          live, at} }
      GetRecipeCooldowns() -> CooldownService row list (see CooldownService:ReadStoredCooldowns)
      GetRecipeKnowers(spellID) -> { {guid?, charKey?, charName, classFile, isMe} }
      GetKnownByCount(spellID) -> number
      IsKnownByMe(spellID) -> boolean|nil             nil = no data for this character yet
      IsKnownByAny(spellID) -> boolean|nil
      GetItemCountsAcrossCharacters(itemID) -> { total, bags, banks, chars = { {guid?, name, classFile,
          bagCount, bankCount, total} }, warbandBank, source }   other characters only (the current
          character's live counts come from RecipeService:GetBagCounts)
    Messages: Constants.EVENTS.CHARACTER_DATA_SOURCE_CHANGED { [capability] = backend } on every switch;
      CHARACTER_PROFESSIONS_UPDATED guid when the logged-in character's professions changed;
      CHARACTER_PURGED guid after PurgeCharacter.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS

local CharacterData = {
    _backend = {},
    _evaluated = false,
    _knowers = {},
    _bankOpen = false,
}
ns.CharacterData = CharacterData

local CAPABILITIES = { "characters", "concentration", "recipes", "items", "cooldowns" }

--- Public WarbandNexus method each capability needs (warband-nexus v3.6.0 c121ec5).
local WN_METHOD = {
    characters = "GetAllCharacters",           -- DataService.lua:1734
    concentration = "GetAllConcentrationData", -- ProfessionService.lua:2823
    recipes = "GetCraftersForRecipe",          -- ProfessionService.lua:3182
    items = "GetDetailedItemCountsFast",       -- ItemsCacheService.lua:3025
    -- TODO(WN): cooldowns stay native until WN exposes WarbandNexus:GetAllProfessionCooldowns()
    -- (WN stores characters[k].professionCooldowns, ProfessionService.lua:2169, without a public getter).
    cooldowns = nil,
}

local STALE_SEC = 30 * 24 * 3600
local SECONDS_PER_HOUR = 3600
--- Memo window for pools / roster reads (several UI panels ask in the same frame burst).
local MEMO_SEC = 2
--- Characters kept in the native item snapshot (oldest dropped first).
local MAX_ITEM_CHARS = 60
local ITEM_CAPTURE_DEBOUNCE_SEC = 2

local function Global()
    return ns.db and ns.db.global
end

local function MyGUID()
    return ns.Utilities:GetCharacterGUID()
end

local function Notify(message, payload)
    if ns.ArtisanNexus and message then
        ns.ArtisanNexus:SendMessage(message, payload)
    end
end

--==========================================================================
-- Backend selection
--==========================================================================

--- WN roster row of the logged-in character (GUID first, then name + realm).
local function FindMeInRoster(roster, guid)
    if type(roster) ~= "table" then
        return nil
    end
    local name, nameSecond = UnitName("player")
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if issecretvalue and (issecretvalue(name) or issecretvalue(realm) or issecretvalue(nameSecond)) then
        name, realm, nameSecond = nil, nil, nil
    end
    --- WoW Forever: first names repeat on a realm, so a name match also needs the surname, and a row
    --- that carries another character's GUID is never "me" [WN CharacterService OwnedByLivePlayer].
    local forever = ns.Constants and ns.Constants.IS_FOREVER_BUILD
    local surname = forever and type(nameSecond) == "string" and nameSecond ~= "" and nameSecond or nil
    local byName
    for i = 1, #roster do
        local c = roster[i]
        if guid and (c.guid == guid or c.key == guid) then
            return c
        end
        if name and c.name == name and (c.realm == realm or c.realm == nil)
            and (not forever or (c.guid == nil and c.surname == surname)) then
            byName = byName or c
        end
    end
    return byName
end

--- GUIDs Warband Nexus collects data for (tracked characters). Native rows of every other GUID are
--- merged into the reads, so a character WN does not track is never hidden behind the WN backend.
---@return table<string, boolean>
function CharacterData:WnTrackedGuids()
    local memo = self._wnGuidMemo
    if memo and GetTime() - memo.t < MEMO_SEC then
        return memo.set
    end
    local set = {}
    local bridge = ns.WarbandNexusBridge
    local roster = bridge and bridge:IsAvailable() and bridge:GetCharacters() or nil
    if type(roster) == "table" then
        for i = 1, #roster do
            local c = roster[i]
            if c.guid and c.isTracked then
                set[c.guid] = true
            end
        end
    end
    self._wnGuidMemo = { t = GetTime(), set = set }
    return set
end

--- Re-pick the backend of every capability. Sends CHARACTER_DATA_SOURCE_CHANGED when one switched
--- after the first evaluation (collectors evaluate lazily before they wire events).
function CharacterData:Reevaluate()
    local bridge = ns.WarbandNexusBridge
    local available = bridge and bridge:IsAvailable()
    local roster = available and bridge:GetCharacters() or nil
    local me = FindMeInRoster(roster, MyGUID())
    self._wnMe = me
    local tracked = me ~= nil and me.isTracked
    local changed = false
    for i = 1, #CAPABILITIES do
        local cap = CAPABILITIES[i]
        local method = WN_METHOD[cap]
        local useWN = tracked and method ~= nil and bridge:HasMethod(method)
        --- WN stores a GUID only once tracking was confirmed; GUID-keyed AN records need it.
        if cap == "characters" and not (me and me.guid) then
            useWN = false
        end
        local backend = useWN and "wn" or "native"
        if self._backend[cap] ~= backend then
            self._backend[cap] = backend
            changed = true
        end
    end
    self:InvalidateCaches()
    local first = not self._evaluated
    self._evaluated = true
    if changed and not first then
        local payload = {}
        for cap, backend in pairs(self._backend) do
            payload[cap] = backend
        end
        Notify(E.CHARACTER_DATA_SOURCE_CHANGED, payload)
        self:ApplyNativeCollectors()
    end
end

---@param capability string
---@return string "wn"|"native"
function CharacterData:GetBackend(capability)
    if not self._evaluated then
        self:Reevaluate()
    end
    return self._backend[capability] or "native"
end

--- Should AN's own collector for `capability` run? Always: the native rows of the logged-in character
--- are written whatever the read backend is, so no character depends on Warband Nexus alone.
---@param capability string
---@return boolean
function CharacterData:UsesNative(capability)
    local _ = capability
    return true
end

---@return boolean true when at least one capability is served by Warband Nexus
function CharacterData:IsUsingWarbandNexus()
    for i = 1, #CAPABILITIES do
        if self:GetBackend(CAPABILITIES[i]) == "wn" then
            return true
        end
    end
    return false
end

function CharacterData:InvalidateCaches()
    self._rosterMemo = nil
    self._poolsMemo = nil
    self._wnGuidMemo = nil
    wipe(self._knowers)
end

--==========================================================================
-- Characters
--==========================================================================

---@return table<string, table> [guid] = { guid, name, realm, classFile, lastSeen, source = "an"|"wn" }
function CharacterData:GetCharacters()
    local memo = self._rosterMemo
    if memo and GetTime() - memo.t < MEMO_SEC then
        return memo.list
    end
    local out = {}
    --- Native registry first: AN's own GUID-keyed records (ledgers, loot) stay resolvable even for
    --- characters WN does not know; WN rows override with fresher display data.
    local g = Global()
    local reg = g and g.charRegistry
    if type(reg) == "table" then
        for guid, rec in pairs(reg) do
            if type(rec) == "table" then
                out[guid] = {
                    guid = guid,
                    name = rec.name,
                    realm = rec.realm,
                    surname = rec.surname,
                    classFile = rec.class,
                    lastSeen = rec.lastSeen,
                    source = "an",
                }
            end
        end
    end
    if self:GetBackend("characters") == "wn" then
        local roster = ns.WarbandNexusBridge:GetCharacters() or {}
        for i = 1, #roster do
            local c = roster[i]
            if c.guid and c.name then
                out[c.guid] = {
                    guid = c.guid,
                    name = c.name,
                    realm = c.realm,
                    surname = c.surname,
                    classFile = c.classFile,
                    lastSeen = c.lastSeen,
                    source = "wn",
                }
            end
        end
    end
    self._rosterMemo = { t = GetTime(), list = out }
    return out
end

---@param guid string|nil
---@return table|nil
function CharacterData:GetCharacter(guid)
    if not guid then
        return nil
    end
    return self:GetCharacters()[guid]
end

local function CharName(guid)
    return ns.Utilities:GetCharacterDisplayName(guid)
end

--==========================================================================
-- Concentration
--==========================================================================

local function FallbackRatePerHour()
    return ns.Constants.CONCENTRATION_REGEN_PER_HOUR or 10
end

--- Recharge per hour from CurrencyInfo cycle fields; nil when unusable.
--- rechargingCycleDurationMS / rechargingAmountPerCycle verified 2026-10-14,
--- CurrencyInfoDocumentation.lua (12.1.5.70391).
local function RateFromCycle(cycleMS, perCycle)
    local ms, per = tonumber(cycleMS), tonumber(perCycle)
    if ms and per and ms > 0 and per > 0 then
        return per * (SECONDS_PER_HOUR * 1000 / ms)
    end
    return nil
end

local function Project(current, max, ratePerHour, at, now)
    current = tonumber(current) or 0
    max = tonumber(max) or 0
    if max <= 0 then
        return current, nil
    end
    local elapsed = math.max(0, now - (tonumber(at) or now))
    local projected = math.min(max, current + elapsed * ratePerHour / SECONDS_PER_HOUR)
    local secondsToCap = 0
    if projected < max and ratePerHour > 0 then
        secondsToCap = (max - projected) / ratePerHour * SECONDS_PER_HOUR
    end
    return projected, secondsToCap
end

--- English catalog key for a base or child skill line.
local function CatalogKeyForSkillLine(skillLineID)
    local rs = ns.RecipeService
    return skillLineID and rs and rs:GetProfessionForSkillLine(skillLineID) or nil
end

--- Localized trade skill name -> catalog key (WN groups pools by the client's localized name).
local localizedToKey
local function CatalogKeyForName(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local cat = ns.MidnightRecipeCatalog
    if type(cat) ~= "table" then
        return nil
    end
    if cat[name] then
        return name
    end
    if not localizedToKey then
        localizedToKey = {}
        if C_TradeSkillUI.GetTradeSkillDisplayName then
            for key, data in pairs(cat) do
                if type(data) == "table" then
                    for _, slid in ipairs({ data.parentSkillLineID, data.skillLineID }) do
                        local ok, disp = pcall(C_TradeSkillUI.GetTradeSkillDisplayName, slid)
                        if ok and type(disp) == "string" and disp ~= "" then
                            localizedToKey[disp] = key
                        end
                    end
                end
            end
        end
    end
    local hit = localizedToKey[name]
    if next(localizedToKey) == nil then
        --- Display names were not resolvable yet; retry on the next call.
        localizedToKey = nil
    end
    return hit
end

--- Midnight concentration currency per catalog key, learned from live / persisted reads and a
--- one-time probe of every catalog child skill line. UNVERIFIED: that GetConcentrationCurrencyID
--- answers for professions the character does not have (pcall-guarded; 0/nil is ignored).
local midnightCurrency = {}
local rateByCurrency = {}
local probed = false
local function LearnCurrency(catalogKey, currencyID, cycleMS, perCycle)
    currencyID = tonumber(currencyID)
    if not currencyID or currencyID == 0 then
        return
    end
    if catalogKey then
        midnightCurrency[catalogKey] = currencyID
    end
    local rate = RateFromCycle(cycleMS, perCycle)
    if rate then
        rateByCurrency[currencyID] = rate
    end
end

local function ProbeMidnightCurrencies()
    if probed then
        return
    end
    probed = true
    local cat = ns.MidnightRecipeCatalog
    if type(cat) ~= "table" or not C_TradeSkillUI.GetConcentrationCurrencyID then
        return
    end
    for key, data in pairs(cat) do
        if type(data) == "table" and data.skillLineID and not midnightCurrency[key] then
            local ok, cid = pcall(C_TradeSkillUI.GetConcentrationCurrencyID, data.skillLineID)
            if ok then
                LearnCurrency(key, cid)
            end
        end
    end
end

local function PoolRow(fields, now)
    local rate = fields.ratePerHour or FallbackRatePerHour()
    local cur, toCap = Project(fields.current, fields.max, rate, fields.at, now)
    local max = tonumber(fields.max) or 0
    fields.current = math.floor(cur)
    fields.max = max
    fields.ratePerHour = rate
    fields.secondsToCap = toCap
    fields.capped = cur >= max
    return fields
end

--- All tracked pools, projected to now. The current character is read live; alts come from WN
--- (when it covers concentration) or from AN's persisted snapshots.
---@return table[]
function CharacterData:GetConcentrationPools()
    local memo = self._poolsMemo
    if memo and GetTime() - memo.t < MEMO_SEC then
        return memo.list
    end
    local now = time()
    local out = {}
    local myGuid = MyGUID()
    local mineLive = {}
    local me = myGuid and self:GetCharacter(myGuid)

    local pss = ns.ProfessionSnapshotService
    local live = pss and pss:ReadOwnedPools() or {}
    for i = 1, #live do
        local r = live[i]
        LearnCurrency(r.catalogKey, r.currencyID, r.cycleMS, r.perCycle)
        if r.catalogKey and r.max and r.max > 0 then
            mineLive[r.catalogKey] = true
            out[#out + 1] = PoolRow({
                guid = myGuid,
                charName = CharName(myGuid),
                classFile = me and me.classFile or nil,
                profession = r.catalogKey,
                professionName = r.professionName or r.catalogKey,
                skillLineID = r.childSkillLineID,
                currencyID = r.currencyID,
                current = r.current,
                max = r.max,
                ratePerHour = RateFromCycle(r.cycleMS, r.perCycle),
                source = "an",
                live = true,
                at = now,
            }, now)
        end
    end

    local g = Global()
    local snaps = g and g.professionSnapshots
    local concFromWN = self:GetBackend("concentration") == "wn"
    local wnGuids = concFromWN and self:WnTrackedGuids() or nil
    if type(snaps) == "table" then
        for guid, store in pairs(snaps) do
            if type(store) == "table" then
                for baseSL, row in pairs(store) do
                    if type(row) == "table" then
                        local profKey = row.catalogKey or CatalogKeyForSkillLine(baseSL)
                        LearnCurrency(profKey, row.concCurrencyID, row.concCycleMS, row.concPerCycle)
                        local max = tonumber(row.concMax)
                        local isMine = guid == myGuid
                        --- Persisted rows feed every alt WN does not cover; the current character's row
                        --- is a fallback when the live read returned nothing for that profession.
                        local wanted = (isMine and not mineLive[profKey])
                            or (not isMine and not (wnGuids and wnGuids[guid]))
                        if wanted and max and max > 0 then
                            local rec = self:GetCharacter(guid)
                            out[#out + 1] = PoolRow({
                                guid = guid,
                                charName = CharName(guid),
                                classFile = rec and rec.classFile or nil,
                                profession = profKey or row.professionName or row.profession,
                                professionName = row.professionName or row.profession or profKey,
                                skillLineID = row.childSkillLineID or baseSL,
                                currencyID = row.concCurrencyID,
                                current = row.concCurrent,
                                max = max,
                                ratePerHour = RateFromCycle(row.concCycleMS, row.concPerCycle),
                                source = "an",
                                at = row.concAt or row.at,
                            }, now)
                            if isMine and profKey then
                                mineLive[profKey] = true
                            end
                        end
                    end
                end
            end
        end
    end

    if self:GetBackend("concentration") == "wn" then
        ProbeMidnightCurrencies()
        local wnMe = self._wnMe
        local rows = ns.WarbandNexusBridge:GetAllConcentrationData() or {}
        --- WN rows carry no skillLineID and WN keeps every expansion's pool under the base profession
        --- name: keep the row whose currency is the known Midnight one, else the highest currencyID
        --- (newest expansion; heuristic) per character x profession.
        local best = {}
        for i = 1, #rows do
            local e = rows[i]
            local profKey = CatalogKeyForName(e.profession)
            local isMine = (wnMe and e.charKey == wnMe.key) or (myGuid and e.charKey == myGuid)
            local known = profKey and midnightCurrency[profKey]
            local cid = tonumber(e.currencyID) or 0
            if profKey and (tonumber(e.max) or 0) > 0 and not (isMine and mineLive[profKey])
                and (not known or known == cid) then
                local k = tostring(e.charKey) .. "|" .. profKey
                local prev = best[k]
                if not prev or cid > (tonumber(prev.e.currencyID) or 0) then
                    best[k] = { e = e, profKey = profKey }
                end
            end
        end
        local roster = self:GetCharacters()
        local keyToGuid = {}
        local wnRoster = ns.WarbandNexusBridge:GetCharacters() or {}
        for i = 1, #wnRoster do
            if wnRoster[i].key and wnRoster[i].guid then
                keyToGuid[wnRoster[i].key] = wnRoster[i].guid
            end
        end
        for _, hit in pairs(best) do
            local e = hit.e
            local guid = (e.charKey and roster[e.charKey] and e.charKey) or keyToGuid[e.charKey]
            local cid = tonumber(e.currencyID)
            --- WN already projected `current` to now (bridge, GetEstimatedConcentration).
            out[#out + 1] = PoolRow({
                guid = guid,
                charKey = e.charKey,
                charName = (guid and CharName(guid)) or e.charName or e.charKey or "?",
                classFile = e.classFile,
                profession = hit.profKey,
                professionName = e.profession,
                currencyID = cid,
                current = math.min(tonumber(e.max) or 0, tonumber(e.current) or 0),
                max = e.max,
                ratePerHour = cid and rateByCurrency[cid] or nil,
                source = "wn",
                at = now,
            }, now)
            out[#out].at = tonumber(e.lastUpdate) or now
        end
    end

    table.sort(out, function(a, b)
        if (a.charName or "") ~= (b.charName or "") then
            return (a.charName or "") < (b.charName or "")
        end
        return tostring(a.profession) < tostring(b.profession)
    end)
    self._poolsMemo = { t = GetTime(), list = out }
    return out
end

--==========================================================================
-- Recipe cooldowns
--==========================================================================

---@return table[] see CooldownService:ReadStoredCooldowns
function CharacterData:GetRecipeCooldowns()
    -- TODO(WN): when WN_METHOD.cooldowns exists, map WarbandNexus:GetAllProfessionCooldowns() rows here.
    local cs = ns.CooldownService
    return cs and cs:ReadStoredCooldowns() or {}
end

--==========================================================================
-- Recipe knowledge
--==========================================================================

local function NormalizeSpellID(spellID)
    return tonumber(spellID) or spellID
end

---@param spellID number
---@return table[] { {guid?, charKey?, charName, classFile, isMe} }
function CharacterData:GetRecipeKnowers(spellID)
    spellID = NormalizeSpellID(spellID)
    if not spellID then
        return {}
    end
    local hit = self._knowers[spellID]
    if hit then
        return hit
    end
    local out = {}
    local myGuid = MyGUID()
    if self:GetBackend("recipes") == "wn" then
        local wnMe = self._wnMe
        local rows = ns.WarbandNexusBridge:GetCrafters(spellID) or {}
        for i = 1, #rows do
            local r = rows[i]
            local isMe = (wnMe and r.charKey == wnMe.key) or (myGuid ~= nil and r.charKey == myGuid)
            out[#out + 1] = {
                guid = isMe and myGuid or nil,
                charKey = r.charKey,
                charName = r.charName,
                classFile = r.classFile,
                isMe = isMe == true,
            }
        end
    end
    --- Native learnedBy: every knower on the native backend; on WN, the GUIDs WN does not track.
    local fromWN = self:GetBackend("recipes") == "wn"
    local wnGuids = fromWN and self:WnTrackedGuids() or nil
    local meListed = false
    for i = 1, #out do
        if out[i].isMe then meListed = true end
    end
    local rs = ns.RecipeService
    local sch = rs and rs:GetSchematic(spellID)
    if sch and type(sch.learnedBy) == "table" then
        for guid in pairs(sch.learnedBy) do
            local isMe = guid == myGuid
            -- The logged-in character's own harvest is fresh: use it whenever WN did not list it.
            if (isMe and not meListed) or (not isMe and not (wnGuids and wnGuids[guid])) then
                local rec = self:GetCharacter(guid)
                out[#out + 1] = {
                    guid = guid,
                    charName = CharName(guid),
                    classFile = rec and rec.classFile or nil,
                    isMe = isMe,
                }
            end
        end
    end
    self._knowers[spellID] = out
    return out
end

---@param spellID number
---@return number
function CharacterData:GetKnownByCount(spellID)
    return #self:GetRecipeKnowers(spellID)
end

---@param spellID number
---@return boolean|nil known by the logged-in character; nil when there is no data for it yet
function CharacterData:IsKnownByMe(spellID)
    local knowers = self:GetRecipeKnowers(spellID)
    for i = 1, #knowers do
        if knowers[i].isMe then
            return true
        end
    end
    local rs = ns.RecipeService
    local sch = rs and rs:GetSchematic(spellID)
    local guid = MyGUID()
    --- Persisted native flag: authoritative on the native backend, stale-readable fallback on WN.
    if sch and guid and type(sch.learnedBy) == "table" and sch.learnedBy[guid] then
        return true
    end
    if self:GetBackend("recipes") == "wn" then
        return false
    end
    if not sch or not guid or type(sch.learnedBy) ~= "table" then
        return nil
    end
    return false
end

---@param spellID number
---@return boolean|nil known by any tracked character (nil = unknown)
function CharacterData:IsKnownByAny(spellID)
    local rs = ns.RecipeService
    local sch = rs and rs:GetSchematic(spellID)
    if self:GetKnownByCount(spellID) > 0 then
        return true
    end
    if not sch then
        return nil
    end
    return sch.learned
end

--- Harvest hook (RecipeService): record whether the current character knows `row`'s recipe.
--- `learnedBy[guid]` is always kept (whatever the read backend); `learned` = known by someone, from
--- learnedBy plus Warband Nexus' crafter list when WN covers recipes.
---@param row table schematic row
---@param spellID number
---@param learned boolean
function CharacterData:RecordLearned(row, spellID, learned)
    local guid = MyGUID()
    -- Knower list is derived from learnedBy / WN; drop the cached copy so counts follow the harvest.
    self._knowers[NormalizeSpellID(spellID)] = nil
    if guid then
        row.learnedBy = row.learnedBy or {}
        row.learnedBy[guid] = learned and true or nil
    end
    local anyNative = type(row.learnedBy) == "table" and next(row.learnedBy) ~= nil
    if self:GetBackend("recipes") == "wn" then
        row.learned = learned or anyNative or self:GetKnownByCount(spellID) > 0
    elseif guid then
        row.learned = anyNative
    else
        row.learned = learned
    end
end

--==========================================================================
-- Item counts across characters
--==========================================================================

local trackedItems
--- Catalog itemIDs the native snapshot counts: Midnight reagents/outputs + gathering + fishing.
local function TrackedItemSet()
    if trackedItems then
        return trackedItems
    end
    local set = {}
    local rs = ns.RecipeService
    local ids = rs and rs:GetCatalogReagentItemIDs() or {}
    for i = 1, #ids do
        set[ids[i]] = true
    end
    local function addEntries(entries)
        for _, entry in ipairs(entries or {}) do
            for _, itemID in ipairs(ns.ResolveCatalogEntryRanks(entry) or {}) do
                set[itemID] = true
            end
        end
    end
    for _, cat in ipairs({ "herb", "mine", "leather", "disenchant", "others" }) do
        addEntries(ns.GetGatheringCatalogByCategory(cat))
    end
    addEntries(ns.GetFishingCatalogEntries())
    trackedItems = set
    return set
end

--- Enum.BagIndex values verified 2026-10-15, BagIndexConstantsDocumentation.lua (12.1.5.70391):
--- Backpack 0 .. ReagentBag 5, CharacterBankTab_1..6, AccountBankTab_1..5.
local function BagList(prefix, first, last)
    local out = {}
    local BI = Enum.BagIndex
    for i = first, last do
        local bag = BI[prefix .. i]
        if bag then
            out[#out + 1] = bag
        end
    end
    return out
end

local function ScanContainers(bags, set)
    local counts = {}
    for b = 1, #bags do
        local bag = bags[b]
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            local id = info and info.itemID
            if id and set[id] then
                counts[id] = (counts[id] or 0) + (info.stackCount or 1)
            end
        end
    end
    return counts
end

local function ItemStore()
    local g = Global()
    if not g then
        return nil
    end
    if type(g.itemSnapshots) ~= "table" then
        g.itemSnapshots = {}
    end
    local s = g.itemSnapshots
    s.chars = type(s.chars) == "table" and s.chars or {}
    return s
end

--- Native collector: snapshot the current character's catalog reagents (bags always; character bank
--- and warband bank only while the bank is open, otherwise the previous bank snapshot is kept).
function CharacterData:CaptureItems()
    local guid = MyGUID()
    local store = ItemStore()
    if not guid or not store then
        return
    end
    local set = TrackedItemSet()
    local row = store.chars[guid] or {}
    if not self._carriedBags then
        local BI = Enum.BagIndex
        self._carriedBags = { BI.Backpack, BI.Bag_1, BI.Bag_2, BI.Bag_3, BI.Bag_4, BI.ReagentBag }
    end
    row.bags = ScanContainers(self._carriedBags, set)
    if self._bankOpen then
        row.bank = ScanContainers(BagList("CharacterBankTab_", 1, 6), set)
        if not ns.SupportsFeature or ns.SupportsFeature("warbandBank") then
            store.warband = { at = time(), counts = ScanContainers(BagList("AccountBankTab_", 1, 5), set) }
        end
    end
    row.bank = row.bank or {}
    row.at = time()
    store.chars[guid] = row
end

function CharacterData:ScheduleItemCapture()
    if self._capturePending then
        return
    end
    self._capturePending = true
    C_Timer.After(ITEM_CAPTURE_DEBOUNCE_SEC, function()
        CharacterData._capturePending = false
        if CharacterData._itemsWired then
            CharacterData:CaptureItems()
        end
    end)
end

---@param itemID number
---@return table|nil { total, bags, banks, chars, warbandBank, source }
function CharacterData:GetItemCountsAcrossCharacters(itemID)
    if not itemID then
        return nil
    end
    local store = ItemStore()
    local fromWN = self:GetBackend("items") == "wn"
    local wnGuids
    local res
    if fromWN then
        local c = ns.WarbandNexusBridge:GetDetailedItemCounts(itemID)
        res = {
            total = c and c.altTotal or 0,
            bags = c and c.altBags or 0,
            banks = c and c.altBanks or 0,
            chars = {},
            warbandBank = c and c.warbandBank or 0,
            source = "wn",
        }
        local details = c and c.altDetails or {}
        for i = 1, #details do
            res.chars[i] = details[i]
        end
        wnGuids = self:WnTrackedGuids()
    else
        res = { total = 0, bags = 0, banks = 0, chars = {}, warbandBank = 0, source = "an" }
    end
    if not store then
        return fromWN and res or nil
    end
    local myGuid = MyGUID()
    for guid, row in pairs(store.chars) do
        if guid ~= myGuid and type(row) == "table" and not (wnGuids and wnGuids[guid]) then
            local bag = type(row.bags) == "table" and row.bags[itemID] or 0
            local bank = type(row.bank) == "table" and row.bank[itemID] or 0
            if bag + bank > 0 then
                local rec = self:GetCharacter(guid)
                res.total = res.total + bag + bank
                res.bags = res.bags + bag
                res.banks = res.banks + bank
                res.chars[#res.chars + 1] = {
                    guid = guid,
                    name = CharName(guid),
                    classFile = rec and rec.classFile or nil,
                    bagCount = bag,
                    bankCount = bank,
                    total = bag + bank,
                }
            end
        end
    end
    if not fromWN then
        local wb = store.warband
        res.warbandBank = (type(wb) == "table" and type(wb.counts) == "table" and wb.counts[itemID]) or 0
    end
    table.sort(res.chars, function(a, b) return (a.total or 0) > (b.total or 0) end)
    return res
end

--==========================================================================
-- Professions per character (native, every login)
--==========================================================================

--- GetProfessionInfo returns (name, texture, rank, maxRank, numSpells, spellOffset, skillLine, ...):
--- Blizzard_ProfessionsBook.lua:125 (retail) and Camelot/Blizzard_ProfessionsBook.lua:57 (Forever).
---@return table[] { {skillLine, name, icon, rank, maxRank} } sorted by skillLine
local function ReadLiveProfessions()
    local out = {}
    if not GetProfessionInfo or not ns.Utilities.GetProfessionIndices then
        return out
    end
    local idxs = ns.Utilities.GetProfessionIndices()
    for i = 1, #idxs do
        local ok, name, icon, rank, maxRank, _, _, skillLine = pcall(GetProfessionInfo, idxs[i])
        if ok and not (issecretvalue and (issecretvalue(name) or issecretvalue(rank) or issecretvalue(skillLine))) then
            skillLine = tonumber(skillLine)
            if skillLine and type(name) == "string" and name ~= "" then
                out[#out + 1] = {
                    skillLine = skillLine,
                    name = name,
                    icon = icon,
                    rank = tonumber(rank) or 0,
                    maxRank = tonumber(maxRank) or 0,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.skillLine < b.skillLine end)
    return out
end

local function SameProfessions(a, b)
    if type(a) ~= "table" or #a ~= #b then
        return false
    end
    for i = 1, #b do
        local x, y = a[i], b[i]
        if x.skillLine ~= y.skillLine or x.rank ~= y.rank or x.maxRank ~= y.maxRank or x.name ~= y.name then
            return false
        end
    end
    return true
end

--- Native collector: persist the logged-in character's professions into charProfessions[guid].
--- Sends CHARACTER_PROFESSIONS_UPDATED only when a profession, rank or cap actually changed.
---@return boolean changed
function CharacterData:CaptureProfessions()
    local guid = MyGUID()
    local g = Global()
    if not guid or not g then
        return false
    end
    local list = ReadLiveProfessions()
    if type(g.charProfessions) ~= "table" then
        g.charProfessions = {}
    end
    local prev = g.charProfessions[guid]
    local changed = not (prev and SameProfessions(prev.list, list))
    g.charProfessions[guid] = { at = time(), list = list }
    if changed then
        Notify(E.CHARACTER_PROFESSIONS_UPDATED, guid)
    end
    return changed
end

function CharacterData:ScheduleProfessionCapture()
    if self._profPending then
        return
    end
    self._profPending = true
    C_Timer.After(ITEM_CAPTURE_DEBOUNCE_SEC, function()
        CharacterData._profPending = false
        if CharacterData._profWired then
            CharacterData:CaptureProfessions()
        end
    end)
end

--- SKILL_LINES_CHANGED (SkillInfoDocumentation) and LEARNED_SPELL_IN_SKILL_LINE
--- (SpellBookDocumentation) exist in both the retail and the Forever API documentation.
function CharacterData:WireProfessionCollector()
    if self._profWired then
        return
    end
    self._profWired = true
    local owner = self._profOwner or ns.NewEventOwner("CharacterDataProfessions")
    self._profOwner = owner
    owner:RegisterEvent("SKILL_LINES_CHANGED", function()
        CharacterData:ScheduleProfessionCapture()
    end)
    owner:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE", function()
        CharacterData:ScheduleProfessionCapture()
    end)
    -- GetProfessions can answer empty right at login; read once the client has settled.
    self:ScheduleProfessionCapture()
end

---@param guid string|nil
---@return table|nil { at, list = { {skillLine, name, icon, rank, maxRank} } }
function CharacterData:GetCharacterProfessions(guid)
    local g = Global()
    local row = guid and g and type(g.charProfessions) == "table" and g.charProfessions[guid]
    return type(row) == "table" and row or nil
end

--- Recipes this character is recorded as knowing (native learnedBy; filled when its profession
--- windows were opened).
---@param guid string|nil
---@return number
function CharacterData:GetRecipeCountForCharacter(guid)
    local g = Global()
    local sch = g and g.recipeSchematics
    if not guid or type(sch) ~= "table" then
        return 0
    end
    local n = 0
    for _, row in pairs(sch) do
        if type(row) == "table" and type(row.learnedBy) == "table" and row.learnedBy[guid] then
            n = n + 1
        end
    end
    return n
end

--==========================================================================
-- Forget a character
--==========================================================================

--- Remove one character from every per-character store AN keeps by GUID: registry, professions,
--- concentration snapshots, item snapshot, recipe cooldowns, learnedBy, gold series and owned
--- auctions. Event history (loot, craft and sales ledgers) is kept: those are past events, and the
--- rows fall back to "Unknown character" for the name. Never the logged-in character (its rows
--- would be rewritten at once). Sends CHARACTER_PURGED after the write.
---@param guid string
---@return boolean removed
function CharacterData:PurgeCharacter(guid)
    local g = Global()
    if type(guid) ~= "string" or guid == "" or not g or guid == MyGUID() then
        return false
    end
    local function drop(tbl)
        if type(tbl) == "table" and tbl[guid] ~= nil then
            tbl[guid] = nil
        end
    end
    drop(g.charRegistry)
    drop(g.charProfessions)
    drop(g.professionSnapshots)
    drop(g.recipeCooldowns)
    if type(g.itemSnapshots) == "table" then
        drop(g.itemSnapshots.chars)
    end
    if type(g.salesLedger) == "table" and type(g.salesLedger.gold) == "table" then
        drop(g.salesLedger.gold.chars)
    end
    if type(g.ownedAuctions) == "table" then
        drop(g.ownedAuctions.chars)
    end
    if type(g.recipeSchematics) == "table" then
        for _, row in pairs(g.recipeSchematics) do
            if type(row) == "table" and type(row.learnedBy) == "table" and row.learnedBy[guid] then
                row.learnedBy[guid] = nil
                row.learned = next(row.learnedBy) ~= nil
            end
        end
    end
    self:InvalidateCaches()
    Notify(E.CHARACTER_PURGED, guid)
    return true
end

--==========================================================================
-- Native collectors wiring + pruning
--==========================================================================

--- Drop native rows not refreshed for STALE_SEC and bound the item snapshot.
function CharacterData:PruneStale()
    local g = Global()
    if not g then
        return
    end
    local cutoff = time() - STALE_SEC
    if type(g.professionSnapshots) == "table" then
        for guid, store in pairs(g.professionSnapshots) do
            if type(store) == "table" then
                for sl, row in pairs(store) do
                    if type(row) ~= "table" or (tonumber(row.at) or 0) < cutoff then
                        store[sl] = nil
                    end
                end
            end
            if type(store) ~= "table" or next(store) == nil then
                g.professionSnapshots[guid] = nil
            end
        end
    end
    --- charProfessions is the roster's profession list: kept as long as the character is in the
    --- registry (PurgeCharacter removes both), so an alt not played for a month keeps its row.
    local items = g.itemSnapshots
    if type(items) == "table" and type(items.chars) == "table" then
        local list = {}
        for guid, row in pairs(items.chars) do
            if type(row) ~= "table" or (tonumber(row.at) or 0) < cutoff then
                items.chars[guid] = nil
            else
                list[#list + 1] = { guid = guid, at = row.at }
            end
        end
        if #list > MAX_ITEM_CHARS then
            table.sort(list, function(a, b) return a.at > b.at end)
            for i = MAX_ITEM_CHARS + 1, #list do
                items.chars[list[i].guid] = nil
            end
        end
        if type(items.warband) == "table" and (tonumber(items.warband.at) or 0) < cutoff then
            items.warband = nil
        end
    end
end

--- (Un)wire the collectors owned by this module for the current backend selection, and tell the
--- other native collectors to do the same.
function CharacterData:ApplyNativeCollectors()
    if not self._enabled then
        return
    end
    --- Every login refreshes the GUID row (name / realm / surname / class / lastSeen), WN or not, so
    --- AN's ledgers and loot rows always resolve a name.
    ns.Utilities:TouchCharRegistry()
    self:WireProfessionCollector()
    local owner = self._itemOwner or ns.NewEventOwner("CharacterDataItems")
    self._itemOwner = owner
    local wantItems = true
    if wantItems and not self._itemsWired then
        self._itemsWired = true
        --- BAG_UPDATE_DELAYED / BANKFRAME_OPENED / BANKFRAME_CLOSED / PLAYERBANKSLOTS_CHANGED /
        --- PLAYER_LOGOUT verified 2026-10-15, ContainerDocumentation / BankDocumentation /
        --- SystemDocumentation (12.1.5.70391).
        owner:RegisterEvent("BAG_UPDATE_DELAYED", function()
            CharacterData:ScheduleItemCapture()
        end)
        owner:RegisterEvent("BANKFRAME_OPENED", function()
            CharacterData._bankOpen = true
            CharacterData:ScheduleItemCapture()
        end)
        owner:RegisterEvent("BANKFRAME_CLOSED", function()
            CharacterData._bankOpen = false
        end)
        owner:RegisterEvent("PLAYERBANKSLOTS_CHANGED", function()
            CharacterData:ScheduleItemCapture()
        end)
        owner:RegisterEvent("PLAYER_LOGOUT", function()
            CharacterData:CaptureItems()
        end)
        self:ScheduleItemCapture()
    elseif not wantItems and self._itemsWired then
        self._itemsWired = false
        owner:UnregisterAllEvents()
    end
    local pss = ns.ProfessionSnapshotService
    if pss and pss.ApplySource then
        pss:ApplySource()
    end
    local cs = ns.CooldownService
    if cs and cs.ApplySource then
        cs:ApplySource()
    end
end

--- Core OnEnable, after WarbandNexusBridge:Init and before the services that collect.
function CharacterData:Enable()
    if self._enabled then
        return
    end
    self._enabled = true
    self:Reevaluate()
    if not self._pruned then
        self._pruned = true
        self:PruneStale()
    end
    local owner = self._eventOwner or ns.NewEventOwner("CharacterData")
    self._eventOwner = owner
    owner:RegisterMessage(E.WN_DATA_UPDATED, function()
        CharacterData:Reevaluate()
    end)
    self:ApplyNativeCollectors()
end

function CharacterData:Disable()
    if not self._enabled then
        return
    end
    self._enabled = false
    self._itemsWired = false
    self._profWired = false
    if self._profOwner then
        self._profOwner:UnregisterAllEvents()
    end
    if self._eventOwner then
        self._eventOwner:UnregisterAllMessages()
    end
    if self._itemOwner then
        self._itemOwner:UnregisterAllEvents()
    end
end
