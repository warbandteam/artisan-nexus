--[[
    Midnight crafting reagent rank visuals — Blizzard UI atlases (Professions quality tiers).
    Names follow live client UI; multiple fallbacks for patch differences.
    References: Wowhead profession UI, FrameXML Professions, community atlas lists.
]]

local ADDON_NAME, ns = ...

--- Max tier index we try to resolve (Midnight may use up to 5 ranks per reagent line).
ns.PROFESSION_QUALITY_MAX_TIER = 5

--- Tier 1 (e.g. silver star style — client atlas id)
ns.PROFESSION_QUALITY_ATLAS_RANK1 = {
    "Professions-ChatIcon-Quality-Tier1",
    "Professions-Icon-Quality-Tier1",
    "Professions-Crafting-Quality-Icon-Tier1",
}

--- Tier 2
ns.PROFESSION_QUALITY_ATLAS_RANK2 = {
    "Professions-ChatIcon-Quality-Tier2",
    "Professions-Icon-Quality-Tier2",
    "Professions-Crafting-Quality-Icon-Tier2",
}

--- Tier 3
ns.PROFESSION_QUALITY_ATLAS_RANK3 = {
    "Professions-ChatIcon-Quality-Tier3",
    "Professions-Icon-Quality-Tier3",
    "Professions-Crafting-Quality-Icon-Tier3",
}

--- Tier 4
ns.PROFESSION_QUALITY_ATLAS_RANK4 = {
    "Professions-ChatIcon-Quality-Tier4",
    "Professions-Icon-Quality-Tier4",
    "Professions-Crafting-Quality-Icon-Tier4",
}

--- Tier 5
ns.PROFESSION_QUALITY_ATLAS_RANK5 = {
    "Professions-ChatIcon-Quality-Tier5",
    "Professions-Icon-Quality-Tier5",
    "Professions-Crafting-Quality-Icon-Tier5",
}

local TIER_LISTS = {
    ns.PROFESSION_QUALITY_ATLAS_RANK1,
    ns.PROFESSION_QUALITY_ATLAS_RANK2,
    ns.PROFESSION_QUALITY_ATLAS_RANK3,
    ns.PROFESSION_QUALITY_ATLAS_RANK4,
    ns.PROFESSION_QUALITY_ATLAS_RANK5,
}

---@param tex Texture
---@param rank number Tier 1–5 (catalog position / quality tier).
---@param width number|nil
---@param height number|nil
---@return boolean success
function ns.SetProfessionRankAtlas(tex, rank, width, height)
    if not tex or not tex.SetAtlas then
        return false
    end
    local tier = rank
    if type(tier) ~= "number" then
        tier = 1
    end
    tier = math.floor(tier + 0.5)
    if tier < 1 then
        tier = 1
    end
    if tier > #TIER_LISTS then
        tier = #TIER_LISTS
    end
    local list = TIER_LISTS[tier] or TIER_LISTS[1]
    local w = width or 20
    local h = height or 20
    for i = 1, #list do
        local name = list[i]
        local ok = pcall(function()
            tex:SetAtlas(name, false)
            tex:SetSize(w, h)
            tex:Show()
        end)
        if ok then
            return true
        end
    end
    return false
end
