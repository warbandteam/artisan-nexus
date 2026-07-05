--[[
    Fishing spell IDs for cast/channel detection (Retail / Midnight).
    Passive rank-unlock spells that never fire UNIT_SPELLCAST_* are NOT listed.
    Source: warcraft.wiki.gg + in-game verification; cross-check with Warband TryCounterService when updating.
]]

local ADDON_NAME, ns = ...

---@class FishingSpellData
local FishingSpellData = {}

--- Spell IDs that are fishing-related but NOT the water line cast (e.g. open Journal UI).
---@type table<number, boolean>
local FISHING_NON_WATER_CAST_IDS = {
    [271990] = true, -- Fishing Journal (profession panel); /use would never cast the line
}

--- Prefer higher-tier / newer fishing casts when multiple ranks are known.
--- Never prefer Journal (271990) over real cast IDs like 131474.
---@type number[]
local FISHING_CAST_SPELL_PRIORITY = {
    1281824,
    1281823,
    --- Midnight / 12.x bobber channel + cast (in-game verification; was missing → channeling=false while UnitChannel active).
    131476,
    1257770,
    1239227,
    1239033,
    463743,
    389234,
    384481,
    --- Canonical retail "Fishing" line cast — prefer before alternate spellbook IDs (e.g. 271616)
    --- that may not execute correctly via SecureActionButton `spell` from programmatic :Click().
    131474,
    271991,
    271616,
    110412,
    7620,
}

---@type table<number, boolean>
local FISHING_SPELLS = {
    [7620] = true,
    [131476] = true,
    [131474] = true,
    [110412] = true,
    [271616] = true,
    [271991] = true,
    [384481] = true,
    [389234] = true,
    [463743] = true,
    [1239033] = true,
    [1239227] = true,
    [1257770] = true,
    [1281823] = true,
    [1281824] = true,
}

--- Primary fishing spell art (pole) — matches unknown Midnight spell IDs when not yet listed above.
local FISHING_SPELL_ICON = 136245

---@param spellId number|nil
---@return boolean
local function PlayerKnowsFishingSpell(spellId)
    if not spellId then
        return false
    end
    if IsPlayerSpell and IsPlayerSpell(spellId) then
        return true
    end
    if IsSpellKnownOrOverridesKnown and IsSpellKnownOrOverridesKnown(spellId) then
        return true
    end
    if C_SpellBook and C_SpellBook.IsSpellInSpellBook then
        local ok, inBook = pcall(C_SpellBook.IsSpellInSpellBook, spellId)
        if ok and inBook then
            return true
        end
    end
    return false
end

--- Non-passive fishing casts only (spellbook can list rank/passive entries we must not "cast").
---@param spellId number|nil
---@return boolean
local function IsCastableFishingSpell(spellId)
    if not spellId or type(spellId) ~= "number" then
        return false
    end
    if FISHING_NON_WATER_CAST_IDS[spellId] then
        return false
    end
    if not FishingSpellData.IsFishingSpell(spellId) then
        return false
    end
    if not PlayerKnowsFishingSpell(spellId) then
        return false
    end
    if C_Spell and C_Spell.IsSpellPassive then
        local ok, passive = pcall(C_Spell.IsSpellPassive, spellId)
        if ok and passive then
            return false
        end
    end
    return true
end

--- Midnight / unlisted rank: discover the player's fishing cast from the spellbook by icon + passive filter.
--- Iterates skill-line ranges (incl. profession tabs); a linear index scan can terminate early on holes.
---@return number|nil
local function ScanSpellBookForFishingCastSpellId()
    if not (C_SpellBook and C_SpellBook.GetSpellBookItemType and Enum and Enum.SpellBookSpellBank) then
        return nil
    end
    local bank = Enum.SpellBookSpellBank.Player
    local candidates = {}
    local seen = {}

    local function considerSlot(slotIndex)
        local okType, spellBookItemInfo = pcall(C_SpellBook.GetSpellBookItemInfo, slotIndex, bank)
        local sid = nil
        if okType and type(spellBookItemInfo) == "table" and spellBookItemInfo.spellID then
            sid = spellBookItemInfo.spellID
        else
            local okT, a, b = pcall(C_SpellBook.GetSpellBookItemType, slotIndex, bank)
            if okT and type(b) == "number" then
                sid = b
            elseif okT and type(a) == "number" then
                sid = a
            end
        end
        sid = tonumber(sid)
        if sid and IsCastableFishingSpell(sid) and not seen[sid] then
            seen[sid] = true
            candidates[#candidates + 1] = sid
        end
    end

    local function scanLineRange(itemIndexOffset, numSpellBookItems)
        local off = tonumber(itemIndexOffset) or 0
        local n = tonumber(numSpellBookItems) or 0
        for j = off + 1, off + n do
            considerSlot(j)
        end
    end

    if C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookSkillLineInfo then
        local okNum, numLines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
        if okNum and type(numLines) == "number" then
            for lineIdx = 1, numLines do
                local okLi, skillLineInfo = pcall(C_SpellBook.GetSpellBookSkillLineInfo, lineIdx)
                if okLi and type(skillLineInfo) == "table" then
                    scanLineRange(skillLineInfo.itemIndexOffset, skillLineInfo.numSpellBookItems)
                end
            end
        end
    end

    if GetProfessions and C_SpellBook.GetSpellBookSkillLineInfo then
        local pr = { GetProfessions() }
        for i = 1, 5 do
            local profIdx = pr[i]
            if profIdx then
                local okLi, skillLineInfo = pcall(C_SpellBook.GetSpellBookSkillLineInfo, profIdx)
                if okLi and type(skillLineInfo) == "table" then
                    scanLineRange(skillLineInfo.itemIndexOffset, skillLineInfo.numSpellBookItems)
                end
            end
        end
    end

    if #candidates == 0 then
        return nil
    end
    for i = 1, #FISHING_CAST_SPELL_PRIORITY do
        local want = FISHING_CAST_SPELL_PRIORITY[i]
        for c = 1, #candidates do
            if candidates[c] == want then
                return want
            end
        end
    end
    return candidates[1]
end

--- Localized spell name for macros / debug (never use for string ops on secret values).
---@param spellId number|nil
---@return string|nil
function FishingSpellData.GetFishingCastLocalizedName(spellId)
    if not spellId or type(spellId) ~= "number" then
        return nil
    end
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellId)
        if ok and type(name) == "string" and name ~= "" and not (issecretvalue and issecretvalue(name)) then
            return name
        end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
        if ok and type(info) == "table" and info.name then
            local name = info.name
            if type(name) == "string" and name ~= "" and not (issecretvalue and issecretvalue(name)) then
                return name
            end
        end
    end
    if C_Spell and C_Spell.GetSpellLink then
        local ok, link = pcall(C_Spell.GetSpellLink, spellId)
        if ok and type(link) == "string" and link ~= "" and not (issecretvalue and issecretvalue(link)) then
            local parsed = link:match("%[(.-)%]")
            if type(parsed) == "string" and parsed ~= "" and not (issecretvalue and issecretvalue(parsed)) then
                return parsed
            end
        end
    end
    return nil
end

--- Best spell ID for fishing cast (priority list → static table → spellbook scan for unlisted Midnight ranks).
--- @return number|nil
function FishingSpellData.GetKnownPlayerCastSpellId()
    for i = 1, #FISHING_CAST_SPELL_PRIORITY do
        local sid = FISHING_CAST_SPELL_PRIORITY[i]
        if FISHING_SPELLS[sid] and IsCastableFishingSpell(sid) then
            return sid
        end
    end
    for sid in pairs(FISHING_SPELLS) do
        if IsCastableFishingSpell(sid) then
            return sid
        end
    end
    return ScanSpellBookForFishingCastSpellId()
end

function FishingSpellData.IsFishingSpell(spellId)
    if not spellId then
        return false
    end
    if FISHING_NON_WATER_CAST_IDS[spellId] then
        return false
    end
    if FISHING_SPELLS[spellId] then
        return true
    end
    if issecretvalue and issecretvalue(spellId) then
        return false
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
        if ok and info and info.iconID and not (issecretvalue and issecretvalue(info.iconID)) then
            if info.iconID == FISHING_SPELL_ICON then
                FISHING_SPELLS[spellId] = true
                return true
            end
        end
    end
    return false
end

ns.FishingSpellData = FishingSpellData
