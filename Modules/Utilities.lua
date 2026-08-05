--[[
    Artisan Nexus — shared helpers (character key, etc.).
]]

local ADDON_NAME, ns = ...

---@class Utilities
local Utilities = {}
ns.Utilities = Utilities

--- CallbackHandler keeps ONE callback per (event, owner); modules sharing the
--- ArtisanNexus object as owner silently clobber each other. Every module that
--- listens must own its registrations via a dedicated AceEvent owner.
---@param name string debug label
---@return table owner with RegisterMessage/RegisterEvent/Unregister* (AceEvent-3.0)
function ns.NewEventOwner(name)
    local owner = { _anEventOwner = name or "?" }
    LibStub("AceEvent-3.0"):Embed(owner)
    return owner
end

--- Stable character identity. GUID survives renames and realm transfers,
--- so ALL per-character persistent records key by GUID — never by name-realm.
---@return string|nil guid nil when unavailable or secret
function Utilities:GetCharacterGUID()
    local guid = UnitGUID and UnitGUID("player")
    if not guid or (issecretvalue and issecretvalue(guid)) then return nil end
    return guid
end

--- Upsert the current character into `db.global.charRegistry[guid]` (display
--- metadata only — name/realm/class refresh on every login; GUID stays stable).
---@return string|nil guid
function Utilities:TouchCharRegistry()
    local guid = self:GetCharacterGUID()
    local g = ns.db and ns.db.global
    if not guid or not g then return guid end
    g.charRegistry = g.charRegistry or {}
    local rec = g.charRegistry[guid]
    if not rec then
        rec = {}
        g.charRegistry[guid] = rec
    end
    local name = UnitName("player")
    if name and not (issecretvalue and issecretvalue(name)) then
        rec.name = name
    end
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if type(realm) == "string" and realm ~= "" and not (issecretvalue and issecretvalue(realm)) then
        rec.realm = realm
    end
    --- `X and f()` truncates to one value; call outside the `and` to keep the
    --- second return (classFilename, e.g. "MAGE").
    local classFile
    if UnitClass then
        _, classFile = UnitClass("player")
    end
    if classFile and not (issecretvalue and issecretvalue(classFile)) then
        rec.class = classFile
    end
    rec.lastSeen = time()
    return guid
end

--- Display label for a registry GUID: "Name-Realm", "Name", or localized Unknown.
---@param guid string|nil
---@return string
function Utilities:GetCharacterDisplayName(guid)
    local name, realm = self:GetCharacterNameAndRealm(guid)
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

--- Split display fields for column layouts (name | realm).
---@param guid string|nil
---@return string name, string realm
function Utilities:GetCharacterNameAndRealm(guid)
    local g = ns.db and ns.db.global
    local rec = guid and g and g.charRegistry and g.charRegistry[guid]
    if rec and rec.name then
        local realm = rec.realm
        if realm and realm ~= "" and not (issecretvalue and issecretvalue(realm)) then
            return rec.name, realm
        end
        return rec.name, ""
    end
    return (ns.L and ns.L["CHAR_UNKNOWN"]) or "Unknown", ""
end

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
    if issecretvalue and issecretvalue(msg) then
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
    if not msg or type(msg) ~= "string" then
        return false
    end
    if issecretvalue and issecretvalue(msg) then
        return false
    end
    if not msg:find("|Hitem:", 1, true) then
        return false
    end
    local function prefixMatch(globalFmt)
        if not globalFmt or type(globalFmt) ~= "string" or (issecretvalue and issecretvalue(globalFmt)) then
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
    --- Loot pushed straight to bags ("You receive item:") — e.g. auto-loot
    --- overflow / some gather flows — is still self loot.
    if LOOT_ITEM_PUSHED_SELF and prefixMatch(LOOT_ITEM_PUSHED_SELF) then
        return true
    end
    if LOOT_ITEM_PUSHED_SELF_MULTIPLE and prefixMatch(LOOT_ITEM_PUSHED_SELF_MULTIPLE) then
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
    --- Rare: `C_Spell.GetSpellCooldown` returns **milliseconds** (duration/start huge). WoW normal path uses **seconds**.
    --- Only rescale when values are clearly not second-scale (avoids breaking 27h+ CDs expressed in seconds).
    if type(st) == "number" and type(dur) == "number" then
        if dur >= 10000000 or st >= 1e12 then
            st = st / 1000
            dur = dur / 1000
        end
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

--- Map itemID → first `GetLootSourceInfo` GUID for that slot while loot is listed (collapses chat + window for one pickup).
---@return table<number, string>
function Utilities.BuildLootItemIDToFirstSourceGUIDMap()
    local map = {}
    if not GetNumLootItems or not GetLootSlotLink or GetNumLootItems() < 1 then
        return map
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
    local n = GetNumLootItems()
    for slot = 1, n do
        local has = true
        if LootSlotHasItem then
            has = LootSlotHasItem(slot)
        end
        if has and GetLootSourceInfo then
            local link = GetLootSlotLink(slot)
            local id = ItemIDFromLink(link)
            if id and not map[id] then
                local ok, packed = pcall(function()
                    return { GetLootSourceInfo(slot) }
                end)
                if ok and packed and packed[1] and type(packed[1]) == "string" and packed[1] ~= "" then
                    if not (issecretvalue and issecretvalue(packed[1])) then
                        map[id] = packed[1]
                    end
                end
            end
        end
    end
    return map
end

ns.BuildLootItemIDToFirstSourceGUIDMap = Utilities.BuildLootItemIDToFirstSourceGUIDMap

--- Blizzard money display: amount + gold/silver/copper icons (embedded |T textures).
--- Shared by all UI money columns (catalog AH column, session value, Hub tables, popups).
---@param copper number|nil
---@param iconHeight number|nil embedded coin icon height (match font size, e.g. 12 catalog, 14 session row)
---@return string|nil nil when copper is nil or <= 0 (call sites append their own em dash / "-" fallback)
function Utilities.FormatCopper(copper, iconHeight)
    if not copper or copper <= 0 then
        return nil
    end
    iconHeight = tonumber(iconHeight) or 12
    if GetCoinTextureString then
        local ok, s = pcall(function()
            return GetCoinTextureString(copper, iconHeight)
        end)
        if ok and s and s ~= "" then
            return s
        end
        ok, s = pcall(GetCoinTextureString, copper)
        if ok and s and s ~= "" then
            return s
        end
    end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then
        return string.format("%dg %ds", g, s)
    end
    if s > 0 then
        return string.format("%ds %dc", s, c)
    end
    return string.format("%dc", c)
end

ns.FormatCopper = Utilities.FormatCopper

--- Prefer cached AH buyout (`ahPrices` after sync). If none (never scanned, no listings, commodity miss), fall back to vendor sell (`GetItemInfo` 11) so rows rarely stay empty. Em dash only when both are absent or zero.
---@param itemID number
---@return number|nil unitCopper
---@return string|nil source `"ah"` | `"vendor"`
function Utilities.GetLootUnitPriceCopper(itemID)
    if not itemID or type(itemID) ~= "number" or itemID < 1 then
        return nil, nil
    end
    local AH = ns.AHPriceService
    if AH and AH.GetPrice then
        local p = AH:GetPrice(itemID)
        if p and p > 0 then
            return p, "ah"
        end
    end
    if GetItemInfo then
        local sell = select(11, GetItemInfo(itemID))
        if type(sell) == "number" and sell > 0 then
            return sell, "vendor"
        end
    end
    return nil, nil
end

ns.GetLootUnitPriceCopper = Utilities.GetLootUnitPriceCopper

--- Loot row / total pricing with a last-chance AH cache probe. Single source
--- for LootHistoryUI header totals AND LootHistoryUI_Draw rows so both always
--- price identically (previously Draw skipped the AH fallback and catalog
--- values could show an em dash while the header Total counted them).
---@param itemID number|string|nil
---@return number|nil unitCopper single value (source tag intentionally dropped)
function Utilities.GetLootUnitCopperWithFallback(itemID)
    itemID = tonumber(itemID)
    if not itemID or itemID < 1 then
        return nil
    end
    local u = Utilities.GetLootUnitPriceCopper(itemID)
    if u and u > 0 then
        return u
    end
    local AH = ns.AHPriceService
    if AH and AH.GetPrice then
        local p = AH:GetPrice(itemID)
        if p and p > 0 then
            return p
        end
    end
    return nil
end

ns.GetLootUnitCopperWithFallback = Utilities.GetLootUnitCopperWithFallback

--- Item display name for table rows (Hub / Price History popups). Requests an
--- async load so a later refresh can show the real name; guards secret values.
---@param itemID number|nil
---@return string
function Utilities.GetItemDisplayName(itemID)
    if not itemID then
        return "?"
    end
    if C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(itemID)
    end
    local name = (GetItemInfo and select(1, GetItemInfo(itemID))) or ("item:" .. itemID)
    if name and issecretvalue and issecretvalue(name) then
        return "?"
    end
    return name
end

ns.GetItemDisplayName = Utilities.GetItemDisplayName

--- Icon fileID for an item (question-mark fileID 134400 fallback).
---@param itemID number|nil
---@return number|nil
function Utilities.GetItemIconFileID(itemID)
    if not itemID then
        return 134400
    end
    if C_Item and C_Item.GetItemIconByID then
        return C_Item.GetItemIconByID(itemID)
    end
    return select(10, GetItemInfo(itemID)) or 134400
end

ns.GetItemIconFileID = Utilities.GetItemIconFileID

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
    if entry.itemID then
        return { entry.itemID }
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
        if not (issecretvalue and issecretvalue(g)) then
            return g
        end
    end
    return "Q" .. tostring(quality)
end

--- Return first trusted GlobalString value (localized client text) from candidate global names.
--- Skips empty strings and secret values.
---@param ... string|nil global names tried in order
---@return string|nil
function Utilities.TryGlobalString(...)
    local n = select("#", ...)
    for i = 1, n do
        local name = select(i, ...)
        if type(name) == "string" and name ~= "" then
            local v = _G[name]
            if type(v) == "string" and v ~= "" then
                if not (issecretvalue and issecretvalue(v)) then
                    return v
                end
            end
        end
    end
    return nil
end

--- Prefer a Blizzard GlobalString when listed, else AceLocale `locKey` from ns.L (e.g. LOOT_GATHER_HERB).
---@param locKey string
---@param ... string|nil additional global names for TryGlobalString
---@return string|nil
function Utilities.LocWithGlobal(locKey, ...)
    if type(locKey) ~= "string" or locKey == "" then
        return nil
    end
    local g = Utilities.TryGlobalString(...)
    if g then
        return g
    end
    local Ltab = ns.L
    local loc = Ltab and rawget(Ltab, locKey)
    if type(loc) == "string" and loc ~= "" then
        if not (issecretvalue and issecretvalue(loc)) then
            return loc
        end
    end
    return nil
end

ns.TryGlobalString = Utilities.TryGlobalString
ns.LocWithGlobal = Utilities.LocWithGlobal
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

--- Skill line IDs (Retail / Midnight): Session loot tab visibility + overload tracker (herb/mine).
local SKILL_LINE_HERBALISM = 182
local SKILL_LINE_MINING = 186
local SKILL_LINE_FISHING = 356
local SKILL_LINE_SKINNING = 393
local SKILL_LINE_LEATHERWORKING = 165
local SKILL_LINE_ENCHANTING = 333

--- Fallback for clients where `GetProfessions` omits secondary lines: scan skill list by localized Fishing name.
---@return boolean
local function FallbackOwnsFishingBySkillList()
    if not GetNumSkillLines or not GetSkillLineInfo then
        return false
    end
    local fishA = GetSpellInfo and GetSpellInfo(7620) or nil
    local fishB = _G and _G.PROFESSIONS_FISHING or nil
    local fishC = _G and _G.SKILL_FISHING or nil
    local targets = {}
    local function pushName(v)
        if type(v) == "string" and v ~= "" and not (issecretvalue and issecretvalue(v)) then
            targets[#targets + 1] = string.lower(v)
        end
    end
    pushName(fishA)
    pushName(fishB)
    pushName(fishC)
    pushName("fishing")
    if #targets < 1 then
        return false
    end
    local n = GetNumSkillLines() or 0
    for i = 1, n do
        local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
        if not isHeader and type(name) == "string" and name ~= "" and not (issecretvalue and issecretvalue(name)) then
            local key = string.lower(name)
            for j = 1, #targets do
                if key == targets[j] then
                    local r = tonumber(rank) or 0
                    local mr = tonumber(maxRank) or 0
                    if r > 0 or mr > 0 then
                        return true
                    end
                end
            end
        end
    end
    return false
end

--- Match `skillLineID` against any numeric return from `GetProfessionInfo` (Retail builds vary; 7th is not always reliable).
---@param skillLineID number|nil
---@return boolean
function Utilities.PlayerOwnsProfessionSkillLine(skillLineID)
    skillLineID = tonumber(skillLineID)
    if not skillLineID then
        return false
    end
    --- Midnight/modern clients: `GetProfessions()` may omit some secondary lines (observed: Fishing),
    --- so use direct skill-line lookup first when available.
    if C_SkillInfo and C_SkillInfo.GetSkillLineInfo then
        local okInfo, info = pcall(C_SkillInfo.GetSkillLineInfo, skillLineID)
        if okInfo and type(info) == "table" then
            local infoID = tonumber(info.skillLineID) or tonumber(info.id) or tonumber(info.professionID)
            if infoID == skillLineID then
                local rank = tonumber(info.skillLineRank) or tonumber(info.currentLevel) or tonumber(info.rank) or 0
                local maxRank = tonumber(info.skillLineMaxRank) or tonumber(info.maxLevel) or tonumber(info.maxRank) or 0
                if rank > 0 or maxRank > 0 then
                    return true
                end
            end
        end
    end
    if skillLineID == SKILL_LINE_FISHING and FallbackOwnsFishingBySkillList() then
        return true
    end
    if not GetProfessions or not GetProfessionInfo then
        return false
    end
    local p1, p2, p3, p4, p5 = GetProfessions()
    for _, profIdx in ipairs({ p1, p2, p3, p4, p5 }) do
        if profIdx then
            local ok, a, b, c, d, e, f, g, h, i, j, k, l = pcall(GetProfessionInfo, profIdx)
            if ok then
                local pack = { a, b, c, d, e, f, g, h, i, j, k, l }
                for idx = 1, 12 do
                    if tonumber(pack[idx]) == skillLineID then
                        return true
                    end
                end
            end
        end
    end
    return false
end

---@return boolean
function Utilities.PlayerOwnsHerbalism()
    return Utilities.PlayerOwnsProfessionSkillLine(SKILL_LINE_HERBALISM)
end

---@return boolean
function Utilities.PlayerOwnsMining()
    return Utilities.PlayerOwnsProfessionSkillLine(SKILL_LINE_MINING)
end

---@return boolean
function Utilities.PlayerOwnsFishing()
    return Utilities.PlayerOwnsProfessionSkillLine(SKILL_LINE_FISHING)
end

---@return boolean
function Utilities.PlayerOwnsSkinning()
    return Utilities.PlayerOwnsProfessionSkillLine(SKILL_LINE_SKINNING)
end

---@return boolean
function Utilities.PlayerOwnsLeatherworking()
    return Utilities.PlayerOwnsProfessionSkillLine(SKILL_LINE_LEATHERWORKING)
end

--- Leather tab: Skinning (gather) and/or Leatherworking (crafted) — same UX as herb vs mine tabs.
---@return boolean
function Utilities.PlayerOwnsLeatherTabProfessions()
    return Utilities.PlayerOwnsSkinning() or Utilities.PlayerOwnsLeatherworking()
end

--- Disenchant tab: Enchanting (disenchant materials).
---@return boolean
function Utilities.PlayerOwnsEnchanting()
    return Utilities.PlayerOwnsProfessionSkillLine(SKILL_LINE_ENCHANTING)
end

--- Overload cooldown tracker applies to herbalism and mining skill lines only.
---@return boolean
function Utilities.PlayerOwnsAnyOverloadTrackerProfession()
    return Utilities.PlayerOwnsHerbalism() or Utilities.PlayerOwnsMining()
end

ns.PlayerOwnsHerbalism = Utilities.PlayerOwnsHerbalism
ns.PlayerOwnsMining = Utilities.PlayerOwnsMining
ns.PlayerOwnsFishing = Utilities.PlayerOwnsFishing
ns.PlayerOwnsSkinning = Utilities.PlayerOwnsSkinning
ns.PlayerOwnsLeatherworking = Utilities.PlayerOwnsLeatherworking
ns.PlayerOwnsLeatherTabProfessions = Utilities.PlayerOwnsLeatherTabProfessions
ns.PlayerOwnsEnchanting = Utilities.PlayerOwnsEnchanting
ns.PlayerOwnsAnyOverloadTrackerProfession = Utilities.PlayerOwnsAnyOverloadTrackerProfession
