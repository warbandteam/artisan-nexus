--[[
    Profession snapshot cache (concentration / knowledge) while the trade skill window is open.
    Emits AN_PROFESSION_SNAPSHOT_UPDATED after refresh.

    Also the AN-native concentration collector behind ns.CharacterData: the current character's pools
    are always read live (ReadOwnedPools); they are persisted to db.global.professionSnapshots[guid]
    and refreshed out of the window (login, CURRENCY_DISPLAY_UPDATE) only while
    ns.CharacterData:UsesNative("concentration") — with Warband Nexus covering alts nothing is written.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS
local ProfessionSnapshotService = { _last = nil, _refreshPending = false, _lastSig = nil }

--- TRADE_SKILL_LIST_UPDATE fires in bursts while the profession frame is open.
local REFRESH_COALESCE_SEC = 0.25

local function Ready()
    if not C_TradeSkillUI then
        return false
    end
    if C_TradeSkillUI.IsTradeSkillReady then
        return C_TradeSkillUI.IsTradeSkillReady() == true
    end
    return true
end

--- Concentration pool + recharge rate for a (Midnight child) skill line.
--- CurrencyInfo.quantity / maxQuantity / rechargingCycleDurationMS / rechargingAmountPerCycle
--- verified 2026-10-14, Blizzard_APIDocumentationGenerated CurrencyInfoDocumentation.lua (12.1.5.70391).
--- GetConcentrationCurrencyID takes the child skill line (Blizzard passes GetChildProfessionInfo().professionID);
--- verified 2026-10-14, TradeSkillUIDocumentation.lua (12.1.5.70391) + Blizzard_Professions call site.
---@return table|nil { currencyID, current, max, cycleMS, perCycle }
local function ReadConcentration(skillLineID)
    if not skillLineID or not C_TradeSkillUI or not C_TradeSkillUI.GetConcentrationCurrencyID then
        return nil
    end
    local ok, currencyID = pcall(C_TradeSkillUI.GetConcentrationCurrencyID, skillLineID)
    if not ok or not currencyID or currencyID == 0 then
        return nil
    end
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyInfo then
        return nil
    end
    local ok2, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    if not ok2 or type(info) ~= "table" then
        return nil
    end
    local cur = tonumber(info.quantity) or 0
    local max = tonumber(info.maxQuantity) or cur
    return {
        currencyID = currencyID,
        current = cur,
        max = max,
        cycleMS = tonumber(info.rechargingCycleDurationMS),
        perCycle = tonumber(info.rechargingAmountPerCycle),
    }
end

--- Midnight child skill line + English catalog key for a base profession skill line.
---@return number|nil childSkillLineID, string|nil catalogKey
local function MidnightChildFor(baseSkillLineID)
    local cat = ns.MidnightRecipeCatalog
    if type(cat) ~= "table" or not baseSkillLineID then
        return nil, nil
    end
    for key, data in pairs(cat) do
        if type(data) == "table" and (data.parentSkillLineID == baseSkillLineID or data.skillLineID == baseSkillLineID) then
            return data.skillLineID, key
        end
    end
    return nil, nil
end

local function ReadKnowledge(skillLineID)
    --- `GetStateForTab(specTabID, configID)` returns an enum, not a table — the
    --- old table-shaped read never resolved. Unspent knowledge comes from the
    --- spec currency instead.
    if not skillLineID or not C_ProfSpecs or not C_ProfSpecs.GetCurrencyInfoForSkillLine then
        return nil
    end
    local ok, info = pcall(C_ProfSpecs.GetCurrencyInfoForSkillLine, skillLineID)
    if ok and type(info) == "table" and info.numAvailable ~= nil then
        return tonumber(info.numAvailable)
    end
    return nil
end

--- Merge fields into professionSnapshots[guid][baseSkillLineID] (additive: keeps fields the
--- caller did not read, e.g. knowledge when only the pool was refreshed out of the window).
local function PersistRow(baseSkillLineID, fields)
    if not ns.CharacterData:UsesNative("concentration") then
        return
    end
    local g = ns.db and ns.db.global
    local guid = ns.Utilities and ns.Utilities.GetCharacterGUID and ns.Utilities:GetCharacterGUID()
    if not g or not guid or not baseSkillLineID then
        return
    end
    g.professionSnapshots = g.professionSnapshots or {}
    local store = g.professionSnapshots[guid]
    if type(store) ~= "table" then
        store = {}
        g.professionSnapshots[guid] = store
    end
    local row = store[baseSkillLineID]
    if type(row) ~= "table" then
        row = {}
        store[baseSkillLineID] = row
    end
    for k, v in pairs(fields) do
        row[k] = v
    end
end

function ProfessionSnapshotService:Refresh()
    local snap = { at = time() }
    if not Ready() then
        self._last = snap
        return
    end
    local pinfo
    if C_TradeSkillUI.GetBaseProfessionInfo then
        local ok, pi = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
        if ok and type(pi) == "table" then
            pinfo = pi
        end
    end
    if pinfo then
        snap.profession = pinfo.professionName
        snap.skillLineID = pinfo.professionID or pinfo.skillLineID
    end
    if snap.skillLineID then
        --- Concentration lives on the expansion child line. Prefer the Midnight child from the
        --- catalog (stable even when another expansion tab is selected), then the open child.
        local child, catKey = MidnightChildFor(snap.skillLineID)
        if not child and C_TradeSkillUI.GetChildProfessionInfo then
            local okC, ci = pcall(C_TradeSkillUI.GetChildProfessionInfo)
            if okC and type(ci) == "table" and ci.professionID then
                child = ci.professionID
            end
        end
        snap.childSkillLineID = child
        snap.catalogKey = catKey
        local conc = ReadConcentration(child) or ReadConcentration(snap.skillLineID)
        if conc then
            snap.concCurrent, snap.concMax = conc.current, conc.max
            snap.concCurrencyID = conc.currencyID
            snap.concCycleMS, snap.concPerCycle = conc.cycleMS, conc.perCycle
            self._concCurrencyIDs = self._concCurrencyIDs or {}
            self._concCurrencyIDs[conc.currencyID] = true
        end
        snap.knowledgeUnspent = ReadKnowledge(snap.skillLineID)
    end
    self._last = snap
    --- Persist per character (GUID key) so offline alts' concentration /
    --- knowledge state survives logout and stays queryable account-wide.
    if snap.skillLineID then
        local prof = snap.profession
        if prof and issecretvalue and issecretvalue(prof) then
            prof = nil
        end
        PersistRow(snap.skillLineID, {
            profession = prof,
            professionName = prof,
            catalogKey = snap.catalogKey,
            childSkillLineID = snap.childSkillLineID,
            concCurrent = snap.concCurrent,
            concMax = snap.concMax,
            concCurrencyID = snap.concCurrencyID,
            concCycleMS = snap.concCycleMS,
            concPerCycle = snap.concPerCycle,
            --- Pool timestamp only moves when the pool was actually read (merge keeps old values).
            concAt = snap.concCurrent ~= nil and snap.at or nil,
            knowledgeUnspent = snap.knowledgeUnspent,
            at = snap.at,
        })
    end
    --- Only broadcast when a listener-visible field changed (first send always goes).
    local sig = table.concat({
        tostring(snap.skillLineID), tostring(snap.concCurrent),
        tostring(snap.concMax), tostring(snap.knowledgeUnspent),
    }, "|")
    if sig == self._lastSig then
        return
    end
    self._lastSig = sig
    ns.ArtisanNexus:SendMessage(E.PROFESSION_SNAPSHOT_UPDATED, snap)
end

--- Live pools of the current character's Midnight professions (no persistence).
--- GetProfessions + GetProfessionInfo return 7 = skillLine (RecipeService:GetOwnedCraftProfessions).
--- UNVERIFIED: that GetConcentrationCurrencyID answers while the profession window is closed;
--- every call is pcall-guarded and a 0/nil answer simply yields no row.
---@return table[] { skillLineID (base), childSkillLineID, catalogKey, professionName, currencyID, current, max, cycleMS, perCycle }
function ProfessionSnapshotService:ReadOwnedPools()
    local out = {}
    local p1, p2, p3, p4, p5 = GetProfessions()
    local idxs = { p1, p2, p3, p4, p5 }
    self._concCurrencyIDs = self._concCurrencyIDs or {}
    for i = 1, 5 do
        local profIdx = idxs[i]
        if profIdx then
            local ok, name, _, _, _, _, _, skillLine = pcall(GetProfessionInfo, profIdx)
            skillLine = ok and tonumber(skillLine) or nil
            local child, catKey = MidnightChildFor(skillLine)
            local conc = child and ReadConcentration(child)
            if conc then
                if name and issecretvalue and issecretvalue(name) then
                    name = nil
                end
                self._concCurrencyIDs[conc.currencyID] = true
                out[#out + 1] = {
                    skillLineID = skillLine,
                    childSkillLineID = child,
                    catalogKey = catKey,
                    professionName = type(name) == "string" and name or nil,
                    currencyID = conc.currencyID,
                    current = conc.current,
                    max = conc.max,
                    cycleMS = conc.cycleMS,
                    perCycle = conc.perCycle,
                }
            end
        end
    end
    return out
end

--- Native collector: persist the live pools out of the window (login / currency change).
function ProfessionSnapshotService:RefreshOwnedPools()
    if not ns.CharacterData:UsesNative("concentration") then
        return
    end
    local rows = self:ReadOwnedPools()
    local now = time()
    for i = 1, #rows do
        local r = rows[i]
        PersistRow(r.skillLineID, {
            profession = r.professionName,
            professionName = r.professionName,
            catalogKey = r.catalogKey,
            childSkillLineID = r.childSkillLineID,
            concCurrent = r.current,
            concMax = r.max,
            concCurrencyID = r.currencyID,
            concCycleMS = r.cycleMS,
            concPerCycle = r.perCycle,
            concAt = now,
            at = now,
        })
    end
    if #rows > 0 and ns.ArtisanNexus and E then
        ns.ArtisanNexus:SendMessage(E.PROFESSION_SNAPSHOT_UPDATED, self._last)
    end
end

--- Coalesced Refresh: one read per burst of list/queue updates.
function ProfessionSnapshotService:ScheduleRefresh()
    if self._refreshPending then
        return
    end
    self._refreshPending = true
    C_Timer.After(REFRESH_COALESCE_SEC, function()
        ProfessionSnapshotService._refreshPending = false
        if ProfessionSnapshotService._enabled then
            ProfessionSnapshotService:Refresh()
        end
    end)
end

function ProfessionSnapshotService:GetSnapshot()
    return self._last
end

function ProfessionSnapshotService:GetChipText()
    local s = self._last
    if not s then
        return nil
    end
    local parts = {}
    if s.concCurrent ~= nil and s.concMax ~= nil then
        parts[#parts + 1] = string.format("Conc %d/%d", s.concCurrent, s.concMax)
    end
    if s.knowledgeUnspent ~= nil and s.knowledgeUnspent > 0 then
        parts[#parts + 1] = string.format("Know +%d", s.knowledgeUnspent)
    end
    if #parts < 1 and s.profession then
        parts[#parts + 1] = s.profession
    end
    if #parts < 1 then
        return nil
    end
    return table.concat(parts, " | ")
end

function ProfessionSnapshotService:Enable()
    if self._enabled then
        return
    end
    self._enabled = true
    local owner = self._eventOwner or ns.NewEventOwner("ProfessionSnapshotService")
    self._eventOwner = owner
    owner:RegisterEvent("TRADE_SKILL_SHOW", function()
        ProfessionSnapshotService:Refresh()
    end)
    owner:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function()
        ProfessionSnapshotService:ScheduleRefresh()
    end)
    if E and E.CRAFT_QUEUE_UPDATED then
        owner:RegisterMessage(E.CRAFT_QUEUE_UPDATED, function()
            if Ready() then
                ProfessionSnapshotService:ScheduleRefresh()
            end
        end)
    end
    self._currencyWired = false
    self:ApplySource()
end

--- Native-only wiring: out-of-window pool refresh. Called on Enable and by ns.CharacterData when the
--- concentration backend switches (Warband Nexus already listens to CURRENCY_DISPLAY_UPDATE itself).
function ProfessionSnapshotService:ApplySource()
    local owner = self._eventOwner
    if not self._enabled or not owner then
        return
    end
    local native = ns.CharacterData:UsesNative("concentration")
    if native and not self._currencyWired then
        self._currencyWired = true
        --- CURRENCY_DISPLAY_UPDATE (currencyType?, ...) verified 2026-10-14, CurrencyInfoDocumentation.lua.
        --- Only concentration currencies seen before trigger a (coalesced) out-of-window pool read.
        owner:RegisterEvent("CURRENCY_DISPLAY_UPDATE", function(_, currencyType)
            local ids = ProfessionSnapshotService._concCurrencyIDs
            if not currencyType or not ids or not ids[currencyType] then
                return
            end
            if Ready() then
                ProfessionSnapshotService:ScheduleRefresh()
            elseif not ProfessionSnapshotService._poolPending then
                ProfessionSnapshotService._poolPending = true
                C_Timer.After(2, function()
                    ProfessionSnapshotService._poolPending = false
                    if ProfessionSnapshotService._enabled then
                        ProfessionSnapshotService:RefreshOwnedPools()
                    end
                end)
            end
        end)
        C_Timer.After(3, function()
            if ProfessionSnapshotService._enabled then
                ProfessionSnapshotService:RefreshOwnedPools()
            end
        end)
    elseif not native and self._currencyWired then
        self._currencyWired = false
        owner:UnregisterEvent("CURRENCY_DISPLAY_UPDATE")
    end
end

function ProfessionSnapshotService:Disable()
    if not self._enabled then
        return
    end
    self._enabled = false
    self._currencyWired = false
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
        self._eventOwner:UnregisterAllMessages()
    end
end

ns.ProfessionSnapshotService = ProfessionSnapshotService
