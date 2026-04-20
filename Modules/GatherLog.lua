--[[
    Loot logger: Mining / Herbalism / Skinning / Disenchanting / Fishing.

    Flow:
      UNIT_SPELLCAST_SUCCEEDED  -> identify profession + note target GUID
      LOOT_READY                -> snapshot loot slots, run anti-dupe, commit

    Anti-duplicate:
      Gathering: UnitGUID("target") per-node cooldown (GUID_COOLDOWN sec).
      Fishing:   time-based throttle (FISH_THROTTLE sec) — no stable target GUID.

    No CHAT_MSG_LOOT dependency; no localization risk.
]]

local ADDON_NAME, ns = ...

GatherLogDB = GatherLogDB or {}

-- ── State ────────────────────────────────────────────────────────────────────

local _pending = nil    -- { profession, guid, t }  set on spell succeeded
local _guidLog = {}     -- guid -> GetTime() of last commit
local _lastFishTime = 0

-- ── Constants ────────────────────────────────────────────────────────────────

local PENDING_TTL   = 6     -- max seconds between spell cast and LOOT_READY
local GUID_COOLDOWN = 30    -- same node/corpse suppression window (sec)
local FISH_THROTTLE = 1.0   -- fishing: minimum seconds between commits

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function GetCurrentZone()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if mapID then
        local info = C_Map.GetMapInfo(mapID)
        if info and info.name and info.name ~= "" then
            return info.name
        end
    end
    return GetZoneText() or ""
end

--- Returns {[itemID] = quantity, ...} from the current loot window.
local function SnapshotLoot()
    local counts = {}
    local n = GetNumLootItems and GetNumLootItems() or 0
    for i = 1, n do
        local itemID, qty

        -- Midnight C_Loot API (table return).
        if C_Loot and C_Loot.GetLootSlotInfo then
            local ok, info = pcall(C_Loot.GetLootSlotInfo, i)
            if ok and type(info) == "table" then
                itemID = info.itemID
                qty    = info.quantity
            end
        end

        -- Fallback: legacy globals still present in Midnight.
        if not itemID then
            local link = GetLootSlotLink and GetLootSlotLink(i)
            if link and not (issecretvalue and issecretvalue(link)) then
                if C_Item and C_Item.GetItemInfoInstant then
                    itemID = C_Item.GetItemInfoInstant(link)
                end
                if not itemID and GetItemInfoInstant then
                    itemID = GetItemInfoInstant(link)
                end
                if not itemID then
                    itemID = tonumber(link:match("|Hitem:(%d+)"))
                end
            end
        end

        if not qty and GetLootSlotInfo then
            local _, _, quantity = GetLootSlotInfo(i)
            qty = (type(quantity) == "number" and quantity >= 1) and math.floor(quantity) or 1
        end

        if itemID and type(itemID) == "number" and itemID > 0 then
            counts[itemID] = (counts[itemID] or 0) + math.max(1, qty or 1)
        end
    end
    return counts
end

local function Commit(profession, sourceGUID)
    local loot = SnapshotLoot()
    if not next(loot) then return end

    local zone = GetCurrentZone()
    local ts   = time()

    for itemID, quantity in pairs(loot) do
        GatherLogDB[#GatherLogDB + 1] = {
            profession = profession,
            itemID     = itemID,
            quantity   = quantity,
            zone       = zone,
            timestamp  = ts,
            sourceGUID = sourceGUID,
        }
    end
end

-- ── Spell → Profession ───────────────────────────────────────────────────────

local function ProfessionFromSpell(spellID)
    -- Delegate to existing GatheringSpellData when available.
    local gsd = ns.GatheringSpellData
    if gsd and gsd.GetCategory then
        local cat = gsd.GetCategory(spellID)
        if cat then return cat end
    end
    if gsd and gsd.InferGatheringCategoryFromSpell then
        local cat = gsd.InferGatheringCategoryFromSpell(spellID)
        if cat then return cat end
    end
    -- Fishing: delegate to FishingSpellData when available.
    local fsd = ns.FishingSpellData
    if fsd and fsd.IsFishingSpell and fsd.IsFishingSpell(spellID) then
        return "fishing"
    end
    return nil
end

-- ── Event Handler ────────────────────────────────────────────────────────────

local frame = CreateFrame("Frame")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("LOOT_READY")

frame:SetScript("OnEvent", function(_, event, ...)
    -- ── Spell succeeded ────────────────────────────────────────────────────
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit ~= "player" then return end
        if issecretvalue and issecretvalue(spellID) then return end

        local prof = ProfessionFromSpell(spellID)
        if not prof then return end

        local guid = (prof ~= "fishing") and UnitGUID("target") or nil

        _pending = { profession = prof, guid = guid, t = GetTime() }
        return
    end

    -- ── Loot window ready ──────────────────────────────────────────────────
    if event == "LOOT_READY" then
        if not _pending then return end

        local now = GetTime()
        if (now - _pending.t) > PENDING_TTL then
            _pending = nil
            return
        end

        local prof = _pending.profession
        local guid = _pending.guid
        _pending = nil

        -- Fishing: time-based throttle (no stable node GUID).
        if prof == "fishing" then
            if (now - _lastFishTime) < FISH_THROTTLE then return end
            _lastFishTime = now
            Commit("fishing", nil)
            return
        end

        -- Gathering: GUID-based node cooldown.
        if guid then
            local last = _guidLog[guid]
            if last and (now - last) < GUID_COOLDOWN then return end
            _guidLog[guid] = now
        end
        Commit(prof, guid)
    end
end)

-- Expose for debugging / external query.
ns.GatherLog = {
    DB     = function() return GatherLogDB end,
    Clear  = function() wipe(GatherLogDB) end,
    Flush  = function() _pending = nil; wipe(_guidLog); _lastFishTime = 0 end,
}
