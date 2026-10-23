--[[
    Profession equipment advisor — empty slots and bag upgrades for craft professions.
    Persists db.char.professionEquipmentHints; emits AN_PROFESSION_EQUIPMENT_UPDATED.
]]

local ADDON_NAME, ns = ...

-- 12.1.5 removed the global item/coin fallbacks; bind the namespaced APIs.
local GetItemInfo = C_Item.GetItemInfo
local GetItemInfoInstant = C_Item.GetItemInfoInstant

local E = ns.Constants.EVENTS
local ProfessionEquipmentService = { _enabled = false, _lastHints = nil }

local L = ns.SafeLocaleString

local function CharStore()
    if not ns.db or not ns.db.char then
        return nil
    end
    ns.db.char.professionEquipmentHints = ns.db.char.professionEquipmentHints or {}
    return ns.db.char.professionEquipmentHints
end

local function IsProfessionEquipLoc(equipLoc)
    if not equipLoc or equipLoc == "" then
        return false
    end
    if issecretvalue and issecretvalue(equipLoc) then
        return false
    end
    if equipLoc == "INVTYPE_PROFESSION_TOOL" or equipLoc == "INVTYPE_PROFESSION_GEAR" then
        return true
    end
    if INVTYPE_PROFESSION_TOOL and equipLoc == INVTYPE_PROFESSION_TOOL then
        return true
    end
    if INVTYPE_PROFESSION_GEAR and equipLoc == INVTYPE_PROFESSION_GEAR then
        return true
    end
    return equipLoc:find("Profession", 1, true) ~= nil
end

local function ItemIlvl(itemID)
    if not itemID then
        return 0
    end
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        local ok, ilvl = pcall(C_Item.GetDetailedItemLevelInfo, itemID)
        if ok and ilvl then
            return tonumber(ilvl) or 0
        end
    end
    local _, _, _, ilvl = GetItemInfo(itemID)
    return tonumber(ilvl) or 0
end

local function SlotItem(slotID)
    if not slotID then
        return nil
    end
    local link = GetInventoryItemLink("player", slotID)
    if not link or (issecretvalue and issecretvalue(link)) then
        return nil
    end
    local itemID = GetItemInfoInstant(link)
    if not itemID then
        return nil
    end
    local _, name, _, _, _, _, _, _, equipLoc = GetItemInfo(itemID)
    return {
        itemID = itemID,
        name = name,
        ilvl = ItemIlvl(itemID),
        equipLoc = equipLoc,
        slotID = slotID,
    }
end

local function ProfessionInventorySlots()
    local slots = {}
    if C_TradeSkillUI and C_TradeSkillUI.GetProfessionInventorySlots then
        local ok, result = pcall(C_TradeSkillUI.GetProfessionInventorySlots)
        if ok and type(result) == "table" then
            for i = 1, #result do
                local s = tonumber(result[i])
                if s then
                    slots[#slots + 1] = s + 1
                end
            end
        end
    end
    if #slots < 1 then
        for s = 20, 25 do
            slots[#slots + 1] = s
        end
    end
    return slots
end

local function CollectEquippedProfessionItems()
    local bySlot = {}
    local slots = ProfessionInventorySlots()
    for i = 1, #slots do
        local slotID = slots[i]
        local item = SlotItem(slotID)
        if item then
            bySlot[slotID] = item
        end
    end
    return bySlot
end

local function ScanBagProfessionGear()
    local candidates = {}
    if not C_Container or not C_Container.GetContainerNumSlots then
        return candidates
    end
    local bags = { 0, 1, 2, 3, 4, 5 }
    for b = 1, #bags do
        local bag = bags[b]
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        for slot = 1, slots do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                local itemID = info.itemID
                local _, name, _, _, _, _, _, _, equipLoc = GetItemInfo(itemID)
                if IsProfessionEquipLoc(equipLoc) then
                    candidates[#candidates + 1] = {
                        itemID = itemID,
                        name = name,
                        ilvl = ItemIlvl(itemID),
                        equipLoc = equipLoc,
                        bag = bag,
                        slot = slot,
                    }
                end
            end
        end
    end
    return candidates
end

local function MaxEquippedIlvl(equipped)
    local maxIlvl = 0
    for _, item in pairs(equipped) do
        if item.ilvl and item.ilvl > maxIlvl then
            maxIlvl = item.ilvl
        end
    end
    return maxIlvl
end

--- Base profession skill line of a profession gear item (C_TradeSkillUI.GetSkillLineForGear,
--- verified 2026-10-14 in TradeSkillUIDocumentation 12.1.5). The returned line may be an
--- expansion variant, so normalize through ProfessionInfo.parentProfessionID.
local function GearBaseSkillLine(itemRef)
    if not (itemRef and C_TradeSkillUI and C_TradeSkillUI.GetSkillLineForGear) then
        return nil
    end
    local ok, sl = pcall(C_TradeSkillUI.GetSkillLineForGear, itemRef)
    if not ok or not sl then return nil end
    if C_TradeSkillUI.GetProfessionInfoBySkillLineID then
        local okI, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, sl)
        if okI and type(info) == "table" and info.parentProfessionID and info.parentProfessionID > 0 then
            return info.parentProfessionID
        end
    end
    return sl
end

--- Base skill lines of the character's professions (GetProfessions / GetProfessionInfo return 7).
local function OwnedBaseSkillLines()
    local set = {}
    if not (GetProfessions and GetProfessionInfo) then return set end
    local idxs = { GetProfessions() }
    for i = 1, 5 do
        local profIdx = idxs[i]
        if profIdx then
            local ok, _, _, _, _, _, _, skillLine = pcall(GetProfessionInfo, profIdx)
            if ok and skillLine then set[skillLine] = true end
        end
    end
    return set
end

function ProfessionEquipmentService:BuildHints()
    local rs = ns.RecipeService
    local owned = (rs and rs.GetOwnedCraftProfessions and rs:GetOwnedCraftProfessions()) or {}
    local equipped = CollectEquippedProfessionItems()
    local bagGear = ScanBagProfessionGear()
    local maxEquipped = MaxEquippedIlvl(equipped)
    local hints = {}
    local equippedCount = 0
    for _ in pairs(equipped) do
        equippedCount = equippedCount + 1
    end

    if equippedCount < 1 and #owned > 0 then
        for i = 1, math.min(2, #owned) do
            hints[#hints + 1] = {
                kind = "empty",
                profession = owned[i],
                message = string.format(
                    L("PROF_EQUIP_EMPTY_FMT", "Equip profession gear for %s (tool slot empty)."),
                    owned[i]),
            }
        end
    end

    -- Compare like with like: same profession and same gear kind (tool vs accessory).
    -- An accessory competes with the weakest equipped accessory of that profession;
    -- a kind with nothing equipped is an "empty slot" upgrade at any ilvl.
    local ownedLines = OwnedBaseSkillLines()
    local equippedByKey = {}
    for _, item in pairs(equipped) do
        item.skillLine = item.skillLine or GearBaseSkillLine(item.itemID)
        local key = tostring(item.skillLine) .. "|" .. tostring(item.equipLoc)
        local cur = equippedByKey[key]
        if not cur or (item.ilvl or 0) < cur then
            equippedByKey[key] = item.ilvl or 0
        end
    end
    local bestUpgrade, bestGain
    for i = 1, #bagGear do
        local g = bagGear[i]
        g.skillLine = GearBaseSkillLine(g.itemID)
        local relevant = (g.skillLine == nil) or ownedLines[g.skillLine] or next(ownedLines) == nil
        if relevant then
            local key = tostring(g.skillLine) .. "|" .. tostring(g.equipLoc)
            local baseline = equippedByKey[key]
            if g.skillLine == nil then
                baseline = maxEquipped -- unknown profession: legacy ilvl-only comparison
            end
            local gain = (g.ilvl or 0) - (baseline or 0)
            if (baseline == nil or gain > 0) and (not bestGain or gain > bestGain) then
                bestUpgrade, bestGain = g, gain
            end
        end
    end
    if bestUpgrade then
        hints[#hints + 1] = {
            kind = "upgrade",
            itemID = bestUpgrade.itemID,
            name = bestUpgrade.name,
            ilvl = bestUpgrade.ilvl,
            message = string.format(
                L("PROF_EQUIP_UPGRADE_FMT", "Bag upgrade: %s (iLvl %d) beats equipped profession gear."),
                bestUpgrade.name or ("Item " .. tostring(bestUpgrade.itemID)),
                bestUpgrade.ilvl or 0),
        }
    end

    local store = CharStore()
    if store then
        store.updatedAt = time()
        store.hints = hints
        store.equippedCount = equippedCount
    end
    self._lastHints = hints

    --- Only broadcast when the hint set changed (every Hub tab and the sidecar repaint on it).
    local parts = {}
    for i = 1, #hints do
        parts[i] = tostring(hints[i].kind) .. ":" .. tostring(hints[i].itemID) .. ":" .. tostring(hints[i].message)
    end
    local sig = table.concat(parts, "|")
    if sig ~= self._lastHintSig then
        self._lastHintSig = sig
        ns.ArtisanNexus:SendMessage(E.PROFESSION_EQUIPMENT_UPDATED, hints)
    end
    return hints
end

function ProfessionEquipmentService:GetHints()
    if self._lastHints then
        return self._lastHints
    end
    local store = CharStore()
    return store and store.hints
end

function ProfessionEquipmentService:Refresh()
    return self:BuildHints()
end

function ProfessionEquipmentService:Enable()
    if self._enabled then
        return
    end
    self._enabled = true
    local addon = ns.ArtisanNexus
    if not addon or not addon.RegisterEvent then
        return
    end
    --- One pending rebuild per burst (login + SHOW + snapshot often coincide).
    local function schedule()
        if ProfessionEquipmentService._refreshPending then
            return
        end
        if addon.ScheduleTimer then
            ProfessionEquipmentService._refreshPending = true
            addon:ScheduleTimer(function()
                ProfessionEquipmentService._refreshPending = false
                if ProfessionEquipmentService._enabled then
                    ProfessionEquipmentService:Refresh()
                end
            end, 0.3)
        else
            ProfessionEquipmentService:Refresh()
        end
    end
    local owner = self._eventOwner or ns.NewEventOwner("ProfessionEquipmentService")
    self._eventOwner = owner
    owner:RegisterEvent("PLAYER_ENTERING_WORLD", schedule)
    owner:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", function(_, slotID)
        slotID = tonumber(slotID)
        if not slotID then
            return
        end
        if slotID >= 20 and slotID <= 25 then
            schedule()
        end
    end)
    if E and E.PROFESSION_SNAPSHOT_UPDATED then
        owner:RegisterMessage(E.PROFESSION_SNAPSHOT_UPDATED, schedule)
    end
    -- Not a confirmed retail event; RegisterEvent on an unknown name errors.
    pcall(owner.RegisterEvent, owner, "PROFESSION_EQUIPMENT_CHANGED", schedule)
    owner:RegisterEvent("TRADE_SKILL_SHOW", schedule)
end

function ProfessionEquipmentService:Disable()
    if not self._enabled then
        return
    end
    self._enabled = false
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
        self._eventOwner:UnregisterAllMessages()
    end
end

ns.ProfessionEquipmentService = ProfessionEquipmentService
