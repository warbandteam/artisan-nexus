--[[
    Midnight gathering node overload detection — **authoritative** sources:

    1) **GameObject / Creature template IDs** — hover the node, then e.g.
         /dump UnitGUID("mouseover")
       Hyphen-separated GUID; field [6] is usually the template id for GameObject/Creature.
       Add entries to OBJECT_TEMPLATE_IDS below (no guesswork in code paths).

    2) **Exact in-game names** — lowercased strings as they appear on the tooltip / mouseover
       title (built from GatheringCatalog + Wild/Infused/Empowered prefixes + mine “…Ore” strips).

    GatheringOverloadService consults this table **before** fuzzy substring matching.
]]

local ADDON_NAME, ns = ...

---@class GatheringNodeOverloadRegistry
local GatheringNodeOverloadRegistry = {}

--- [templateId] = { cat = "herb"|"mine", mod = "wild"|"infused"|"empowered"|nil }
--- Fill from in-game GUID dumps when you want a hard guarantee for a specific node.
local OBJECT_TEMPLATE_IDS = {
    -- Example (fake id): [452198] = { cat = "mine", mod = "wild" },
}

local EXACT_NAME_MAP = {}
local exactBuilt = false

local function GetTemplateIdFromGUID(guid)
    if not guid or type(guid) ~= "string" then
        return nil, nil
    end
    if issecretvalue and issecretvalue(guid) then
        return nil, nil
    end
    local parts = {}
    for part in string.gmatch(guid, "[^-]+") do
        parts[#parts + 1] = part
    end
    if #parts < 6 then
        return nil, nil
    end
    local typ = parts[1]
    local id = tonumber(parts[6])
    if not id then
        return nil, nil
    end
    if typ == "GameObject" or typ == "Creature" or typ == "Vehicle" then
        return typ, id
    end
    return nil, nil
end

local function MineNodeNameAlias(low)
    if not low or low == "" then
        return nil
    end
    local stripped = low
        :gsub("%s+ore%s*$", "")
        :gsub("%s+deposit%s*$", "")
        :gsub("%s+vein%s*$", "")
        :gsub("%s+seam%s*$", "")
    stripped = stripped:match("^%s*(.-)%s*$") or stripped
    if stripped == "" or stripped == low then
        return nil
    end
    if #stripped < 8 then
        return nil
    end
    return stripped
end

local function BuildExactNameMap()
    if exactBuilt then
        return
    end
    exactBuilt = true
    local seen = {}
    local function addKeys(baseNote, cat)
        if not baseNote or baseNote == "" then
            return
        end
        local b = baseNote:lower():gsub("^%s+", ""):gsub("%s+$", "")
        if b == "" then
            return
        end
        local variants = { b }
        if cat == "mine" then
            local alias = MineNodeNameAlias(b)
            if alias then
                variants[#variants + 1] = alias
            end
        end
        local prefixes = {
            { "", nil },
            { "wild ", "wild" },
            { "infused ", "infused" },
            { "empowered ", "empowered" },
        }
        for vi = 1, #variants do
            local v = variants[vi]
            for pi = 1, #prefixes do
                local pref, mod = prefixes[pi][1], prefixes[pi][2]
                local key = pref .. v
                if not seen[key] then
                    seen[key] = true
                    EXACT_NAME_MAP[key] = { cat = cat, mod = mod }
                end
            end
        end
    end

    for _, cat in ipairs({ "herb", "mine" }) do
        local entries = ns.GetGatheringCatalogByCategory and ns.GetGatheringCatalogByCategory(cat) or {}
        for i = 1, #entries do
            local note = entries[i] and entries[i].note
            if type(note) == "string" then
                addKeys(note, cat)
            end
        end
    end
end

--- Returns category, modifier, source where source is `"id"`, `"name"`, or nil.
---@param lines string[]|nil lowercased detection lines (tooltip + mouseover name)
---@return string|nil cat
---@return string|nil mod
---@return string|nil source
function GatheringNodeOverloadRegistry.Resolve(lines)
    BuildExactNameMap()

    for ui = 1, 2 do
        local unit = ui == 1 and "mouseover" or "target"
        if UnitExists and UnitExists(unit) and UnitGUID then
            local guid = UnitGUID(unit)
            local _, tid = GetTemplateIdFromGUID(guid)
            if tid and OBJECT_TEMPLATE_IDS[tid] then
                local d = OBJECT_TEMPLATE_IDS[tid]
                return d.cat, d.mod, "id"
            end
        end
    end

    if type(lines) == "table" then
        for i = 1, #lines do
            local key = lines[i]
            if type(key) == "string" and key ~= "" then
                local d = EXACT_NAME_MAP[key]
                if d then
                    return d.cat, d.mod, "name"
                end
            end
        end
    end

    return nil, nil, nil
end

--- For options / debug: expose read-only counts (optional).
function GatheringNodeOverloadRegistry.GetExactNameCount()
    BuildExactNameMap()
    local n = 0
    for _ in pairs(EXACT_NAME_MAP) do
        n = n + 1
    end
    return n
end

ns.GatheringNodeOverloadRegistry = GatheringNodeOverloadRegistry
