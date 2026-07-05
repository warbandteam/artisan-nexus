--[[
    Profession snapshot cache (concentration / knowledge) while the trade skill window is open.
    Emits AN_PROFESSION_SNAPSHOT_UPDATED after refresh.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants and ns.Constants.EVENTS
local ProfessionSnapshotService = { _last = nil }

local function Ready()
    if not C_TradeSkillUI then
        return false
    end
    if C_TradeSkillUI.IsTradeSkillReady then
        return C_TradeSkillUI.IsTradeSkillReady() == true
    end
    return true
end

local function ReadConcentration(skillLineID)
    if not skillLineID or not C_TradeSkillUI or not C_TradeSkillUI.GetConcentrationCurrencyID then
        return nil, nil
    end
    local ok, currencyID = pcall(C_TradeSkillUI.GetConcentrationCurrencyID, skillLineID)
    if not ok or not currencyID or currencyID == 0 then
        return nil, nil
    end
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyInfo then
        return nil, nil
    end
    local ok2, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    if not ok2 or type(info) ~= "table" then
        return nil, nil
    end
    local cur = tonumber(info.quantity) or 0
    local max = tonumber(info.maxQuantity) or cur
    return cur, max
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
        snap.concCurrent, snap.concMax = ReadConcentration(snap.skillLineID)
        snap.knowledgeUnspent = ReadKnowledge(snap.skillLineID)
    end
    self._last = snap
    --- Persist per character (GUID key) so offline alts' concentration /
    --- knowledge state survives logout and stays queryable account-wide.
    if snap.skillLineID then
        local g = ns.db and ns.db.global
        local guid = ns.Utilities and ns.Utilities.GetCharacterGUID and ns.Utilities:GetCharacterGUID()
        if g and guid then
            g.professionSnapshots = g.professionSnapshots or {}
            local store = g.professionSnapshots[guid]
            if type(store) ~= "table" then
                store = {}
                g.professionSnapshots[guid] = store
            end
            local prof = snap.profession
            if prof and issecretvalue and issecretvalue(prof) then
                prof = nil
            end
            store[snap.skillLineID] = {
                profession = prof,
                concCurrent = snap.concCurrent,
                concMax = snap.concMax,
                knowledgeUnspent = snap.knowledgeUnspent,
                at = snap.at,
            }
        end
    end
    if ns.ArtisanNexus and ns.ArtisanNexus.SendMessage and E and E.PROFESSION_SNAPSHOT_UPDATED then
        ns.ArtisanNexus:SendMessage(E.PROFESSION_SNAPSHOT_UPDATED, snap)
    end
end

--- All characters' persisted snapshots: [guid][skillLineID] = { profession, concCurrent, ... }.
function ProfessionSnapshotService:GetAllPersistedSnapshots()
    local g = ns.db and ns.db.global
    return (g and g.professionSnapshots) or {}
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
        ProfessionSnapshotService:Refresh()
    end)
    if E and E.CRAFT_QUEUE_UPDATED then
        owner:RegisterMessage(E.CRAFT_QUEUE_UPDATED, function()
            if Ready() then
                ProfessionSnapshotService:Refresh()
            end
        end)
    end
end

function ProfessionSnapshotService:Disable()
    self._enabled = false
end

ns.ProfessionSnapshotService = ProfessionSnapshotService
