--[[
    Localized profession / gathering tab labels: prefer C_Profession (client language),
    then AceLocale, with safe fallbacks.
]]

local ADDON_NAME, ns = ...

local TAB_TO_LKEY = {
    fishing = "LOOT_TAB_FISHING",
    herb = "LOOT_GATHER_HERB",
    mine = "LOOT_GATHER_MINE",
    leather = "LOOT_GATHER_LEATHER",
    disenchant = "LOOT_GATHER_DE",
    others = "LOOT_GATHER_OTHERS",
    crafted = "LOOT_TAB_CRAFTED",
}

local TAB_FALLBACKS = {
    fishing = "Fishing",
    herb = "Herbalism",
    mine = "Mining",
    leather = "Leatherworking",
    disenchant = "Enchanting",
    others = "Others",
    crafted = "Crafted",
}

--- Safe AceLocale read: rawget only (never L[variable] on API/user strings).
---@param key string|nil
---@param fallback string|nil
---@return string|nil
function ns.SafeLocaleString(key, fallback)
    if type(key) ~= "string" or key == "" then
        return fallback
    end
    local Ltab = ns.L
    if not Ltab then
        return fallback
    end
    local s = rawget(Ltab, key)
    if type(s) ~= "string" or s == "" then
        return fallback
    end
    if issecretvalue and issecretvalue(s) then
        return fallback
    end
    return s
end

---@param val any
---@param fallback string|nil
---@return string
function ns.CoerceUiString(val, fallback)
    fallback = fallback or ""
    if val == nil then
        return fallback
    end
    if type(val) ~= "string" then
        return fallback
    end
    if val == "" then
        return fallback
    end
    if issecretvalue and issecretvalue(val) then
        return fallback
    end
    return val
end

--- Tab label for Session loot: L[key] via rawget, else ASCII fallback, else raw key.
---@param tabKey string
---@return string
function ns.GetGatheringTabDisplayName(tabKey)
    tabKey = ns.CoerceUiString(tabKey, "")
    if tabKey == "" then
        return ""
    end
    local lk = TAB_TO_LKEY[tabKey]
    if lk then
        local s = ns.SafeLocaleString(lk, nil)
        if s then
            return s
        end
    end
    local fb = TAB_FALLBACKS[tabKey]
    if fb then
        return fb
    end
    return tabKey
end
