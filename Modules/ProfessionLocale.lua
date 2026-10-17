--[[
    Localized profession / gathering tab labels: prefer C_Profession (client language),
    then AceLocale, with safe fallbacks.
    ns.GetProfessionDisplayName(key): catalog key ("Alchemy") -> client-language profession name.
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

--- Catalog key -> client-language name, cached once resolved.
local professionDisplayNames = {}

--- Standard primary profession icons keyed by the English profession key (copied from Warband Nexus
--- Modules/DataService.lua KNOWN_PROFESSION_ICONS; Hub Crafting group headers).
ns.KNOWN_PROFESSION_ICONS = {
    ["Alchemy"]        = "Interface\\Icons\\Trade_Alchemy",
    ["Blacksmithing"]  = "Interface\\Icons\\Trade_BlackSmithing",
    ["Enchanting"]     = "Interface\\Icons\\Trade_Engraving",
    ["Engineering"]    = "Interface\\Icons\\Trade_Engineering",
    ["Herbalism"]      = "Interface\\Icons\\Trade_Herbalism",
    ["Inscription"]    = "Interface\\Icons\\INV_Inscription_Tradeskill01",
    ["Jewelcrafting"]  = "Interface\\Icons\\INV_Misc_Gem_01",
    ["Leatherworking"] = "Interface\\Icons\\Trade_LeatherWorking",
    ["Mining"]         = "Interface\\Icons\\Trade_Mining",
    ["Skinning"]       = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
    ["Tailoring"]      = "Interface\\Icons\\Trade_Tailoring",
    ["Cooking"]        = "Interface\\Icons\\INV_Misc_Food_15",
    ["Fishing"]        = "Interface\\Icons\\Trade_Fishing",
}

--- Client-language name of a craft profession catalog key ("Alchemy", ...; ns.MidnightRecipeCatalog).
--- Stored filters keep the English key; only the label is localized. C_TradeSkillUI.GetTradeSkillDisplayName
--- (skillLineID) -> professionDisplayName, verified 2026-10-15 in TradeSkillUIDocumentation 12.1.5;
--- called on the catalog's base profession skill line. Falls back to the key.
---@param key string
---@return string
function ns.GetProfessionDisplayName(key)
    key = ns.CoerceUiString(key, "")
    if key == "" then
        return ""
    end
    local cached = professionDisplayNames[key]
    if cached then
        return cached
    end
    local cat = ns.MidnightRecipeCatalog
    local data = type(cat) == "table" and cat[key]
    local slid = type(data) == "table" and (data.parentSkillLineID or data.skillLineID)
    if slid and C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName then
        local ok, disp = pcall(C_TradeSkillUI.GetTradeSkillDisplayName, slid)
        disp = ok and ns.CoerceUiString(disp, "") or ""
        if disp ~= "" then
            professionDisplayNames[key] = disp
            return disp
        end
    end
    return key
end
