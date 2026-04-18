--[[
    Artisan Nexus — shared helpers (character key, etc.).
]]

local ADDON_NAME, ns = ...

---@class Utilities
local Utilities = {}
ns.Utilities = Utilities

---@param name string|nil
---@param realm string|nil
---@return string|nil
function Utilities:GetCharacterKey(name, realm)
    name = name or UnitName("player")
    if not name or (issecretvalue and issecretvalue(name)) then return nil end
    if not realm then
        local norm = GetNormalizedRealmName and GetNormalizedRealmName()
        if type(norm) == "string" and not (issecretvalue and issecretvalue(norm)) and norm ~= "" then
            realm = norm
        else
            realm = GetRealmName and GetRealmName() or ""
        end
    end
    if not realm or (issecretvalue and issecretvalue(realm)) then return nil end
    name = name:gsub("%s+", "")
    realm = realm:gsub("%s+", "")
    return name .. "-" .. realm
end

--- Parse self-loot chat lines: each |Hitem:ID:…|h…|h|r hyperlink may be followed by xN / ×N stack count.
--- Counting raw "item:(%d+)" occurrences undercounts stacked loot (one link, quantity in text).
---@param msg string|nil
---@return table<number, number> itemID -> total quantity for this message
function Utilities.ParseChatLootItemQuantities(msg)
    local totals = {}
    if not msg or type(msg) ~= "string" or msg == "" then
        return totals
    end

    local pos = 1
    local len = #msg
    while pos <= len do
        local hStart, hEnd, itemIDStr = msg:find("|Hitem:(%d+):", pos, false)
        if not hStart or not itemIDStr then
            break
        end
        local itemID = tonumber(itemIDStr)
        local linkEnd = msg:find("|r", hEnd, true)
        if not linkEnd or not itemID then
            pos = hEnd + 1
        else
            local after = msg:sub(linkEnd + 1)
            -- Text belonging to this loot chunk (until next colored link)
            local nextColor = after:find("|c", 1, true)
            local chunk = nextColor and after:sub(1, nextColor - 1) or after

            local qty = 1
            -- Stack size usually follows the link: " x5", " ×5" (Unicode multiply), " 5x"
            local trimmed = chunk:match("^%s*(.-)%s*$") or chunk
            local x = trimmed:match("^[xX]%s*(%d+)")
            if not x then
                x = trimmed:match("^×%s*(%d+)") -- U+00D7 multiply sign
            end
            if not x then
                x = trimmed:match("^%s*(%d+)%s*[xX×]%s*$")
            end
            if x then
                qty = tonumber(x) or 1
            end
            if qty < 1 then qty = 1 end
            if qty > 10000 then qty = 1 end

            totals[itemID] = (totals[itemID] or 0) + qty
            pos = linkEnd + 1
        end
    end

    if not next(totals) then
        for idStr in msg:gmatch("item:(%d+)") do
            local id = tonumber(idStr)
            if id then
                totals[id] = (totals[id] or 0) + 1
            end
        end
    end

    return totals
end

ns.ParseChatLootItemQuantities = Utilities.ParseChatLootItemQuantities

--- Loot frame: only GameObject sources (herb/ore node), no creature — gathering-style window.
---@return boolean
function Utilities.LootFrameSourcesAreOnlyGameObjects()
    local n = GetNumLootItems and GetNumLootItems() or 0
    if n <= 0 then
        return false
    end
    local hasCreature = false
    local hasGO = false
    for i = 1, n do
        local sources = { GetLootSourceInfo(i) }
        for j = 1, #sources, 2 do
            local guid = sources[j]
            if guid and type(guid) == "string" and not (issecretvalue and issecretvalue(guid)) then
                if guid:match("^Creature") then
                    hasCreature = true
                elseif guid:match("^GameObject") then
                    hasGO = true
                end
            end
        end
    end
    if hasCreature then
        return false
    end
    return hasGO
end

--- Snapshot Blizzard loot slots (same stacks as the Loot / Fishing Loot windows).
---@return table<number, number> itemID -> stack quantity
function Utilities.GetLootSlotItemCounts()
    local counts = {}
    if not GetNumLootItems or not GetLootSlotLink then
        return counts
    end
    local n = GetNumLootItems()
    if not n or n < 1 then
        return counts
    end

    local function ItemIDFromLink(link)
        if not link or (issecretvalue and issecretvalue(link)) then
            return nil
        end
        if C_Item and C_Item.GetItemInfoInstant then
            local id = C_Item.GetItemInfoInstant(link)
            if id and id > 0 then
                return id
            end
        end
        if GetItemInfoInstant then
            local id = GetItemInfoInstant(link)
            if id and id > 0 then
                return id
            end
        end
        local hex = link:match("|Hitem:(%d+)")
        return hex and tonumber(hex) or nil
    end

    local function QuantityForSlot(index)
        if not GetLootSlotInfo then
            return 1
        end
        local t = { GetLootSlotInfo(index) }
        for _, idx in ipairs({ 3, 4, 2 }) do
            local v = t[idx]
            if type(v) == "number" and v >= 1 and v <= 10000 then
                return math.floor(v)
            end
        end
        return 1
    end

    for i = 1, n do
        local has = true
        if LootSlotHasItem then
            has = LootSlotHasItem(i)
        end
        if has then
            local link = GetLootSlotLink(i)
            local id = ItemIDFromLink(link)
            if id then
                local qty = QuantityForSlot(i)
                counts[id] = (counts[id] or 0) + qty
            end
        end
    end
    return counts
end

ns.LootFrameSourcesAreOnlyGameObjects = Utilities.LootFrameSourcesAreOnlyGameObjects
ns.GetLootSlotItemCounts = Utilities.GetLootSlotItemCounts

--- Catalog row: prefer ranks[] { R1, R2, … }; legacy id → single rank.
---@param entry table|nil
---@return number[]
function Utilities.ResolveCatalogEntryRanks(entry)
    if not entry then
        return {}
    end
    if entry.ranks and type(entry.ranks) == "table" and #entry.ranks > 0 then
        return entry.ranks
    end
    if entry.id then
        return { entry.id }
    end
    return {}
end

ns.ResolveCatalogEntryRanks = Utilities.ResolveCatalogEntryRanks

--- Which rank index (1 = first tier, 2 = second, …) this item ID is in the catalog grid.
---@param itemID number
---@param entries table[]|nil
---@return number
function Utilities.GetCatalogRankIndexForItem(itemID, entries)
    if not itemID or not entries then
        return 1
    end
    for _, entry in ipairs(entries) do
        local ranks = Utilities.ResolveCatalogEntryRanks(entry)
        for idx, rid in ipairs(ranks) do
            if rid == itemID then
                return idx
            end
        end
    end
    return 1
end

ns.GetCatalogRankIndexForItem = Utilities.GetCatalogRankIndexForItem

--- RGB from ITEM_QUALITY_COLORS (0–8).
---@param quality number|nil
---@return number r, number g, number b
function Utilities.GetQualityRGB(quality)
    if quality == nil then
        return 1, 1, 1
    end
    local qc = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if qc then
        return qc.r, qc.g, qc.b
    end
    return 1, 1, 1
end

--- Localized short quality name (e.g. Rare, Epic).
---@param quality number|nil
---@return string
function Utilities.GetQualityLabel(quality)
    if quality == nil then
        return ""
    end
    local key = "ITEM_QUALITY" .. tostring(quality) .. "_DESC"
    local g = _G[key]
    if type(g) == "string" and g ~= "" then
        return g
    end
    return "Q" .. tostring(quality)
end

ns.GetQualityRGB = Utilities.GetQualityRGB
ns.GetQualityLabel = Utilities.GetQualityLabel
