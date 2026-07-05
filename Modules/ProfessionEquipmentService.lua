--[[
    Profession equipment advisor — empty slots and bag upgrades for craft professions.
    Persists db.char.professionEquipmentHints; emits AN_PROFESSION_EQUIPMENT_UPDATED.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants and ns.Constants.EVENTS
local ProfessionEquipmentService = { _enabled = false, _lastHints = nil }

local function L(key, fallback)
    local loc = ns.L
    if loc and loc[key] then
        return loc[key]
    end
    return fallback
end

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
    if REAGENTBANK_CONTAINER then
        bags[#bags + 1] = REAGENTBANK_CONTAINER
    end
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

    local bestUpgrade
    for i = 1, #bagGear do
        local g = bagGear[i]
        if g.ilvl > maxEquipped then
            if not bestUpgrade or g.ilvl > bestUpgrade.ilvl then
                bestUpgrade = g
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

    if ns.ArtisanNexus and ns.ArtisanNexus.SendMessage and E and E.PROFESSION_EQUIPMENT_UPDATED then
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
    local function schedule()
        if addon.ScheduleTimer then
            addon:ScheduleTimer(function()
                ProfessionEquipmentService:Refresh()
            end, 0.3)
        else
            ProfessionEquipmentService:Refresh()
        end
    end
    local owner = ns.NewEventOwner("ProfessionEquipmentService")
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
    self._enabled = false
end

ns.ProfessionEquipmentService = ProfessionEquipmentService
