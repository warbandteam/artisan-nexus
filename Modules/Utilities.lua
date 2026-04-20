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

--- Remove |T|t / |A|a / |K|k so "x6" after an inline rank icon is visible to stack parsers.
local function StripInlineLootDecorators(s)
    if not s or s == "" then
        return ""
    end
    s = s:gsub("|T[^|]-|t", "")
    s = s:gsub("|A[^|]-|a", "")
    s = s:gsub("|K[^|]-|k", "")
    return s
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
            chunk = StripInlineLootDecorators(chunk)

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
            if not x then
                x = trimmed:match("([%d]+)%s*[xX×]%s*$")
            end
            if not x then
                x = trimmed:match("[xX]%s*(%d+)")
            end
            if not x then
                x = trimmed:match("×%s*(%d+)")
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

--- True if this CHAT_MSG_LOOT line is for the local player (Blizzard global LOOT_ITEM_SELF* — works localized).
---@param msg string|nil
---@return boolean
function Utilities.IsSelfLootChatMessage(msg)
    if not msg or type(msg) ~= "string" or not msg:find("|Hitem:", 1, true) then
        return false
    end
    local function prefixMatch(globalFmt)
        if not globalFmt or type(globalFmt) ~= "string" then
            return false
        end
        local prefix = globalFmt:match("^(.*)%%s")
        if not prefix or #prefix < 1 then
            return false
        end
        return msg:sub(1, #prefix) == prefix
    end
    if LOOT_ITEM_SELF and prefixMatch(LOOT_ITEM_SELF) then
        return true
    end
    if LOOT_ITEM_SELF_MULTIPLE and prefixMatch(LOOT_ITEM_SELF_MULTIPLE) then
        return true
    end
    return false
end

ns.IsSelfLootChatMessage = Utilities.IsSelfLootChatMessage

--- start, duration, isEnabled for own spell; used by UI (overload tracker, etc.).
--- `C_Spell.GetSpellCooldown` may return **secret** values in combat; `GetSpellCooldown(id|name)` is the usual fallback.
---@return number|nil startTime
---@return number|nil duration
---@return any|nil isEnabled
function Utilities.GetPlayerSpellCooldownValues(spellID)
    if not spellID or type(spellID) ~= "number" or spellID < 1 then
        return nil, nil, nil
    end
    local function anySecret(st, dur, en)
        if st ~= nil and issecretvalue and issecretvalue(st) then
            return true
        end
        if dur ~= nil and issecretvalue and issecretvalue(dur) then
            return true
        end
        if en ~= nil and issecretvalue and issecretvalue(en) then
            return true
        end
        return false
    end
    local st, dur, en
    if C_Spell and C_Spell.GetSpellCooldown then
        local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
        if ok and type(info) == "table" then
            local a = info.startTime or info.start or 0
            local b = info.duration or 0
            local c = info.isEnabled
            if not anySecret(a, b, c) then
                st, dur, en = a, b, c
            end
        end
    end
    if GetSpellCooldown then
        if st == nil or anySecret(st, dur, en) then
            local a, b, c = GetSpellCooldown(spellID)
            if not anySecret(a, b, c) then
                st, dur, en = a or 0, b or 0, c
            end
        end
        if st == nil or anySecret(st, dur, en) then
            local name
            if C_Spell and C_Spell.GetSpellName then
                local ok, n = pcall(C_Spell.GetSpellName, spellID)
                if ok and type(n) == "string" and n ~= "" and not (issecretvalue and issecretvalue(n)) then
                    name = n
                end
            end
            if name then
                local a, b, c = GetSpellCooldown(name)
                if not anySecret(a, b, c) then
                    st, dur, en = a or 0, b or 0, c
                end
            end
        end
    end
    if st == nil or anySecret(st, dur, en) then
        return nil, nil, nil
    end
    return st, dur, en
end

ns.GetPlayerSpellCooldownValues = Utilities.GetPlayerSpellCooldownValues

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

    --- Mainline LootFrame: texture, itemName, quantity, currencyID, itemQuality, …
    --- Do not scan arbitrary indices — index 4 is currencyID and index 5 is quality (misread as stack in old code).
    local function QuantityForSlot(index)
        if not GetLootSlotInfo then
            return 1
        end
        local texture, itemName, quantity, currencyID, itemQuality, locked, isQuestItem, questID, isActive, isCoin =
            GetLootSlotInfo(index)
        if type(quantity) == "number" and quantity >= 1 and quantity <= 10000 then
            return math.floor(quantity)
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

--- Open world only (not party/raid/arena/pvp/scenario instances).
---@return boolean
function Utilities.IsOpenWorld()
    if not IsInInstance then
        return true
    end
    local ok, inInstance, instanceType = pcall(IsInInstance)
    if not ok then
        return true
    end
    if issecretvalue and inInstance and issecretvalue(inInstance) then
        return false
    end
    if issecretvalue and instanceType and issecretvalue(instanceType) then
        return false
    end
    if inInstance == true then
        return false
    end
    if type(instanceType) == "string" and instanceType ~= "" and instanceType ~= "none" then
        return false
    end
    return true
end

ns.IsOpenWorld = Utilities.IsOpenWorld
