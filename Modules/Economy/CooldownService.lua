--[[
    Artisan Nexus — Recipe cooldown / charge tracker.
    While the player's own profession window is open, reads C_TradeSkillUI.GetRecipeCooldown for
    the learned recipes of that profession and keeps only those with a cooldown or charges, per
    character (GUID), so alts' daily crafts stay visible account-wide.

    GetRecipeCooldown is not in the generated docs; the call-site signature
    `cooldown, isDayCooldown, charges, maxCharges = GetRecipeCooldown(recipeID)` (cooldown = seconds
    until the next use/charge, nil when ready) is verified 2026-10-14 from Blizzard UI 12.1.5.70391
    (Blizzard_Professions.lua:1521 IsRecipeOnCooldown, Blizzard_ProfessionsRecipeSchematicForm.lua:554).
    The recharge duration of further charges is not exposed, so only "next ready at" is projected.

    Storage: db.global.recipeCooldowns[guid][spellID] =
      { spellID, name, profession, readyAt, charges, maxCharges, isDayCooldown, recordedAt }

    AN-native "cooldowns" collector behind ns.CharacterData. Warband Nexus exposes no public cooldown
    getter yet, so this collector stays active even when WN is installed.
    TODO(WN): switch to WarbandNexus:GetAllProfessionCooldowns() once it exists (see CharacterDataProvider).
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS

local CooldownService = { _scanToken = 0 }

local SCAN_CHUNK = 40
local MAX_PER_CHAR = 60
--- Entries not refreshed for this long (and already ready) are dropped.
local STALE_SEC = 30 * 24 * 3600

local L = ns.SafeLocaleString

local function Store()
    local g = ns.db and ns.db.global
    if not g then
        return nil
    end
    if type(g.recipeCooldowns) ~= "table" then
        g.recipeCooldowns = {}
    end
    return g.recipeCooldowns
end

--- Own, live profession data only (linked / guild / NPC views describe someone else).
local function OwnTradeSkillReady()
    local T = C_TradeSkillUI
    if not T or not T.GetRecipeCooldown then
        return false
    end
    if T.IsTradeSkillReady and not T.IsTradeSkillReady() then
        return false
    end
    if T.IsTradeSkillLinked and T.IsTradeSkillLinked() then
        return false
    end
    if T.IsTradeSkillGuild and T.IsTradeSkillGuild() then
        return false
    end
    if T.IsNPCCrafting and T.IsNPCCrafting() then
        return false
    end
    return true
end

--- @return boolean ok, number|nil cooldown, boolean isDay, number|nil charges, number|nil maxCharges
--- ok = false when the call errored: the state is unknown, not "ready".
local function ReadCooldown(recipeID)
    local ok, cooldown, isDay, charges, maxCharges = pcall(C_TradeSkillUI.GetRecipeCooldown, recipeID)
    if not ok then
        return false
    end
    return true, tonumber(cooldown), isDay == true, tonumber(charges), tonumber(maxCharges)
end

local function Prune(charStore, now)
    local list = {}
    for spellID, row in pairs(charStore) do
        if type(row) ~= "table" then
            charStore[spellID] = nil
        elseif (row.recordedAt or 0) < now - STALE_SEC and (row.readyAt or 0) <= now then
            charStore[spellID] = nil
        else
            list[#list + 1] = row
        end
    end
    if #list > MAX_PER_CHAR then
        -- Every row touched by one ScanOpenProfession pass shares the same `recordedAt` (one
        -- time() per chunk step), so sorting on it alone left the comparator returning false for
        -- most pairs and the evicted row effectively random -- a five-day cooldown with real gold
        -- on it could go while a long-ready row stayed. Keep the furthest-future cooldown, which
        -- is the one we cannot re-derive by looking at the profession window.
        table.sort(list, function(a, b)
            local ar, br = tonumber(a.readyAt) or 0, tonumber(b.readyAt) or 0
            if ar ~= br then return ar > br end
            local arec, brec = tonumber(a.recordedAt) or 0, tonumber(b.recordedAt) or 0
            if arec ~= brec then return arec > brec end
            return (tonumber(a.spellID) or 0) < (tonumber(b.spellID) or 0)
        end)
        for i = MAX_PER_CHAR + 1, #list do
            charStore[list[i].spellID] = nil
        end
    end
end

--- Record (or clear) one recipe for the current character. Returns true when the stored row changed.
local function Record(charStore, recipeID, profession, now)
    local ok, cooldown, isDay, charges, maxCharges = ReadCooldown(recipeID)
    if not ok then
        return false -- unreadable right now: keep the stored row untouched
    end
    local hasCharges = maxCharges and maxCharges > 0
    if not cooldown and not hasCharges then
        if charStore[recipeID] then
            --- Was tracked: now ready with no charge system -> keep a ready row so it stays listed.
            local row = charStore[recipeID]
            if (row.readyAt or 0) > now then
                row.readyAt = now
                row.recordedAt = now
                return true
            end
        end
        return false
    end
    local row = charStore[recipeID]
    local changed = row == nil
    if not row then
        row = { spellID = recipeID }
        charStore[recipeID] = row
    end
    local readyAt = cooldown and (now + cooldown) or now
    if math.abs((row.readyAt or 0) - readyAt) > 5 or row.charges ~= charges or row.maxCharges ~= maxCharges then
        changed = true
    end
    row.readyAt = readyAt
    row.charges = charges
    row.maxCharges = maxCharges
    row.isDayCooldown = isDay
    row.recordedAt = now
    row.profession = profession or row.profession
    if not row.name and C_TradeSkillUI.GetRecipeInfo then
        local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
        if ok and type(info) == "table" and type(info.name) == "string" then
            row.name = info.name
        end
    end
    return changed
end

local function OpenProfessionName()
    if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
        local ok, pi = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
        if ok and type(pi) == "table" and type(pi.professionName) == "string" then
            if not (issecretvalue and issecretvalue(pi.professionName)) then
                return pi.professionName
            end
        end
    end
    return nil
end

local function Notify()
    ns.ArtisanNexus:SendMessage(E.COOLDOWNS_UPDATED)
end

--- Chunked scan of every learned recipe of the open profession.
--- GetAllRecipeIDs: learned + unlearned of the open trade skill (warcraft.wiki.gg API_C_TradeSkillUI.GetAllRecipeIDs).
function CooldownService:ScanOpenProfession()
    if not OwnTradeSkillReady() or not C_TradeSkillUI.GetAllRecipeIDs then
        return
    end
    local guid = ns.Utilities and ns.Utilities:GetCharacterGUID()
    local store = Store()
    if not guid or not store then
        return
    end
    local okIDs, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not okIDs or type(ids) ~= "table" or #ids == 0 then
        return
    end
    store[guid] = store[guid] or {}
    local charStore = store[guid]
    local profession = OpenProfessionName()
    self._scannedThisOpen = true
    self._scanToken = self._scanToken + 1
    local token = self._scanToken
    local idx, changed = 1, false
    local function step()
        if token ~= CooldownService._scanToken or not CooldownService._enabled or not OwnTradeSkillReady() then
            return
        end
        local now = time()
        local stop = math.min(#ids, idx + SCAN_CHUNK - 1)
        for i = idx, stop do
            local recipeID = ids[i]
            local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
            if okInfo and type(info) == "table" and info.learned then
                if Record(charStore, recipeID, profession, now) then
                    changed = true
                end
            end
        end
        idx = stop + 1
        if idx <= #ids then
            C_Timer.After(0, step)
        else
            Prune(charStore, now)
            if changed then
                Notify()
            end
        end
    end
    step()
end

--- Re-read only recipes already tracked for this character (cheap; after crafts / list updates).
function CooldownService:RefreshTracked(onlySpellID)
    if not OwnTradeSkillReady() then
        return
    end
    local guid = ns.Utilities and ns.Utilities:GetCharacterGUID()
    local store = Store()
    if not guid or not store then
        return
    end
    local charStore = store[guid]
    if type(charStore) ~= "table" then
        charStore = nil
    end
    local now = time()
    local changed = false
    if onlySpellID then
        if not charStore then
            store[guid] = {}
            charStore = store[guid]
        end
        changed = Record(charStore, onlySpellID, charStore[onlySpellID] and charStore[onlySpellID].profession or OpenProfessionName(), now)
    elseif charStore then
        for spellID, row in pairs(charStore) do
            if Record(charStore, spellID, row.profession, now) then
                changed = true
            end
        end
    end
    if changed then
        Notify()
    end
end

--- All characters' tracked cooldowns, projected to now (served through ns.CharacterData).
---@return table[] { guid, charName, spellID, name, profession, readyAt, ready, charges, maxCharges,
---   isDayCooldown, recordedAt } sorted by readyAt
function CooldownService:GetCooldowns()
    return ns.CharacterData:GetRecipeCooldowns()
end

--- Native backend read of db.global.recipeCooldowns (shape as GetCooldowns).
---@return table[]
function CooldownService:ReadStoredCooldowns()
    local store = Store()
    local out = {}
    if not store then
        return out
    end
    local now = time()
    local U = ns.Utilities
    for guid, charStore in pairs(store) do
        if type(charStore) == "table" then
            local charName = (U and U.GetCharacterDisplayName and U:GetCharacterDisplayName(guid)) or "?"
            for _, row in pairs(charStore) do
                if type(row) == "table" and row.spellID then
                    local ready = (row.readyAt or 0) <= now
                    local charges = row.charges
                    --- At least the pending charge has come back once readyAt passed.
                    if ready and charges and row.maxCharges and row.recordedAt and row.recordedAt < (row.readyAt or 0) then
                        charges = math.min(row.maxCharges, charges + 1)
                    end
                    out[#out + 1] = {
                        guid = guid,
                        charName = charName,
                        spellID = row.spellID,
                        name = row.name,
                        profession = row.profession,
                        readyAt = row.readyAt,
                        ready = ready or (charges ~= nil and charges > 0),
                        charges = charges,
                        maxCharges = row.maxCharges,
                        isDayCooldown = row.isDayCooldown,
                        recordedAt = row.recordedAt,
                    }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.readyAt or 0) ~= (b.readyAt or 0) then
            return (a.readyAt or 0) < (b.readyAt or 0)
        end
        return (a.spellID or 0) < (b.spellID or 0)
    end)
    return out
end

---@return table[] subset of GetCooldowns() that can be crafted now
function CooldownService:GetReady()
    local all = self:GetCooldowns()
    local out = {}
    for i = 1, #all do
        if all[i].ready then
            out[#out + 1] = all[i]
        end
    end
    return out
end

--- Login reminder: one chat line per day listing ready cooldowns (profile toggle, default on).
function CooldownService:RemindReady()
    local p = ns.db and ns.db.profile
    if p and p.cooldownReadyReminder == false then
        return
    end
    local g = ns.db and ns.db.global
    if not g then
        return
    end
    -- Anchored on the realm daily reset, not the local client day.
    local today = ns.Utilities:GetResetPeriodKey()
    g.cooldownReminder = g.cooldownReminder or {}
    if g.cooldownReminder.lastDay == today then
        return
    end
    local ready = self:GetReady()
    if #ready == 0 then
        return
    end
    local parts = {}
    for i = 1, math.min(#ready, 8) do
        local r = ready[i]
        parts[#parts + 1] = string.format("%s (%s)", r.name or tostring(r.spellID), r.charName or "?")
    end
    if #ready > 8 then
        parts[#parts + 1] = string.format("+%d", #ready - 8)
    end
    g.cooldownReminder.lastDay = today
    local AN = ns.ArtisanNexus
    if AN and AN.Print then
        AN:Print(string.format(L("COOLDOWN_READY_LINE", "Cooldowns ready: %s"), table.concat(parts, ", ")))
    end
end

function CooldownService:Enable()
    if self._enabled then
        return
    end
    self._enabled = true
    self._eventOwner = self._eventOwner or ns.NewEventOwner("CooldownService")
    self._wired = false
    self:ApplySource()
    C_Timer.After(10, function()
        if CooldownService._enabled then
            CooldownService:RemindReady()
        end
    end)
end

--- Native-only event wiring; re-run by ns.CharacterData when the cooldowns backend switches.
function CooldownService:ApplySource()
    local owner = self._eventOwner
    if not self._enabled or not owner then
        return
    end
    local native = ns.CharacterData:UsesNative("cooldowns")
    if not native then
        if self._wired then
            self._wired = false
            self._scanToken = self._scanToken + 1
            owner:UnregisterAllEvents()
            if self._castFrame then
                self._castFrame:UnregisterAllEvents()
            end
        end
        return
    end
    if self._wired then
        return
    end
    self._wired = true
    owner:RegisterEvent("TRADE_SKILL_SHOW", function()
        CooldownService._scannedThisOpen = false
        C_Timer.After(1, function()
            if CooldownService._enabled then
                CooldownService:ScanOpenProfession()
            end
        end)
    end)
    --- Profession tab switched inside the open window.
    owner:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", function()
        CooldownService._scannedThisOpen = false
        C_Timer.After(1, function()
            if CooldownService._enabled then
                CooldownService:ScanOpenProfession()
            end
        end)
    end)
    --- The cooldown only starts once the cast completes, so CRAFT_BEGIN just remembers the recipe and
    --- the re-read happens on the cast's success / crafted result.
    --- Verified 2026-10-14, 12.1.5.70391 docs: TRADE_SKILL_CRAFT_BEGIN (recipeSpellID),
    --- TRADE_SKILL_ITEM_CRAFTED_RESULT (data: CraftingItemResultData, no recipe id) — TradeSkillUIDocumentation.lua;
    --- UNIT_SPELLCAST_SUCCEEDED (unitTarget, castGUID, spellID; SecretWhenUnitSpellCastRestricted) — UnitDocumentation.lua.
    local function RefreshPending()
        local recipeID = CooldownService._pendingRecipe
        if not recipeID then
            return
        end
        C_Timer.After(0.5, function()
            if CooldownService._enabled then
                CooldownService:RefreshTracked(recipeID)
            end
        end)
    end
    owner:RegisterEvent("TRADE_SKILL_CRAFT_BEGIN", function(_, recipeSpellID)
        if recipeSpellID and not (issecretvalue and issecretvalue(recipeSpellID)) then
            CooldownService._pendingRecipe = recipeSpellID
        end
    end)
    -- Player-only unit event (AceEvent has no RegisterUnitEvent): an unfiltered registration ran the
    -- handler for every party/raid/nameplate cast.
    local castFrame = CooldownService._castFrame or CreateFrame("Frame")
    CooldownService._castFrame = castFrame
    castFrame:SetScript("OnEvent", function(_, _, unitTarget, _castGUID, spellID)
        if not CooldownService._pendingRecipe then
            return
        end
        if issecretvalue and (issecretvalue(unitTarget) or issecretvalue(spellID)) then
            return
        end
        if unitTarget ~= "player" or spellID ~= CooldownService._pendingRecipe then
            return
        end
        RefreshPending()
    end)
    castFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    owner:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", RefreshPending)
    --- The scan 1 s after SHOW is skipped while IsTradeSkillReady is still false; retry once the list
    --- arrives (TRADE_SKILL_LIST_UPDATE, verified 2026-10-15, TradeSkillUIDocumentation.lua). Coalesced.
    owner:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function()
        if CooldownService._scannedThisOpen or CooldownService._listRetryPending then
            return
        end
        CooldownService._listRetryPending = true
        C_Timer.After(0.5, function()
            CooldownService._listRetryPending = false
            if CooldownService._enabled and not CooldownService._scannedThisOpen then
                CooldownService:ScanOpenProfession()
            end
        end)
    end)
    owner:RegisterEvent("TRADE_SKILL_CLOSE", function()
        CooldownService._scanToken = CooldownService._scanToken + 1
    end)
end

function CooldownService:Disable()
    if not self._enabled then
        return
    end
    self._enabled = false
    self._wired = false
    self._scanToken = self._scanToken + 1
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
        self._eventOwner:UnregisterAllMessages()
    end
    if self._castFrame then
        self._castFrame:UnregisterAllEvents()
    end
end

ns.CooldownService = CooldownService
