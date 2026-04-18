--[[
    Fishing spell IDs for cast/channel detection (Retail / Midnight).
    Passive rank-unlock spells that never fire UNIT_SPELLCAST_* are NOT listed.
    Source: warcraft.wiki.gg + in-game verification; cross-check with Warband TryCounterService when updating.
]]

local ADDON_NAME, ns = ...

---@class FishingSpellData
local FishingSpellData = {}

---@type table<number, boolean>
local FISHING_SPELLS = {
    [7620] = true,
    [131474] = true,
    [110412] = true,
    [271616] = true,
    [271990] = true,
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
function FishingSpellData.IsFishingSpell(spellId)
    if not spellId then
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
