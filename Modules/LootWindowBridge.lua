--[[
    Loot window classification + per-pickup tokens.

    CHAT_MSG_LOOT stays the only recorder for gathering and fishing loot (it is the line
    that proves the item reached the bags, and it works with fast-loot addons that close
    the window early). This bridge decides, per LOOT_OPENED, whether the window is a
    gathering or fishing pickup and issues one token per loot slot. A chat line is
    attributed only by consuming a matching token (or by the services' own short
    cast/channel fallback), so:
      - vendor buys, quest rewards, containers, mob drops and AH deliveries never get a
        token and are not recorded;
      - a pickup is credited once: the token is consumed by the first chat line for it,
        and re-dispatched chat lines are dropped by lineID in the services.

    verified 2026-10-15, LootDocumentation.lua 12.1.5: LOOT_OPENED payload (autoLoot, isFromItem).
    verified 2026-10-15, GlobalAPI 12.1.5 / LootFrame.lua: IsFishingLoot(); GetLootSlotLink;
    GetLootSlotInfo order. GetLootSourceInfo(lootSlot) -> guid1, quantity1, guid2, quantity2, ...
    (verified 2026-10-15, warcraft.wiki.gg API_GetLootSourceInfo; listed in GlobalAPI 12.1.5,
    not in the generated docs). GUIDs are "Creature-…", "Vehicle-…", "GameObject-…", "Item-…".
]]

local ADDON_NAME, ns = ...

---@class LootWindowBridge
local LootWindowBridge = {
    --- "gathering" | "fishing" | nil for the most recent LOOT_OPENED.
    _kind = nil,
    _openedAt = 0,
}

--- Tokens never expire while their window is open (a manual looter may wait minutes).
--- LOOT_CLOSED starts a short grace for chat lines that lag the close; tokens still
--- unclaimed after it (slot left in the window, bags full) are dropped so they cannot
--- claim an unrelated later line for the same item.
local TOKEN_CLOSE_GRACE = 3
--- A skinned corpse (or a disenchant / unreadable-source window) is a gather only right
--- after the gather cast: the cast succeeds, then the loot opens.
local CAST_TO_LOOT_SEC = 5
--- GameObject-only windows (herb/ore node, overload ground spawns) within this window of
--- the last herb/mine cast count as gathering. Treasure chests are GameObjects too; the
--- cast requirement keeps them out unless opened right after gathering.
local GATHER_FOLLOWUP_SEC = 60

---@type table[] { kind, itemID, qty, exp } (exp = math.huge while the window is open)
local tokens = {}

--- Start the close grace on every still-open token.
local function CloseOpenTokens(now)
    local cutoff = now + TOKEN_CLOSE_GRACE
    for i = 1, #tokens do
        if tokens[i].exp > cutoff then
            tokens[i].exp = cutoff
        end
    end
end

local function PruneTokens(now)
    for i = #tokens, 1, -1 do
        if tokens[i].exp <= now then
            table.remove(tokens, i)
        end
    end
end

local function IsSecret(v)
    return v ~= nil and issecretvalue and issecretvalue(v)
end

--- Source GUID kinds across all slots: hasCreature, hasGameObject, hasOther (item /
--- player / any other readable GUID), readable (at least one GUID could be read).
local function ScanLootSources(n)
    local hasCreature, hasGO, hasOther, readable = false, false, false, false
    if not GetLootSourceInfo then
        return false, false, false, false
    end
    for i = 1, n do
        local sources = { GetLootSourceInfo(i) }
        for j = 1, #sources, 2 do
            local guid = sources[j]
            if type(guid) == "string" and not IsSecret(guid) then
                readable = true
                if guid:find("^Creature") or guid:find("^Vehicle") then
                    hasCreature = true
                elseif guid:find("^GameObject") then
                    hasGO = true
                else
                    hasOther = true
                end
            end
        end
    end
    return hasCreature, hasGO, hasOther, readable
end

---@param isFromItem boolean|nil
---@return "gathering"|"fishing"|nil
local function ClassifyWindow(isFromItem, n)
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return nil
    end
    if IsFishingLoot and IsFishingLoot() then
        return "fishing"
    end
    local g = ns.GatheringLootService
    local cat, castAt = nil, nil
    if g and g.GetLastGatherCast then
        cat, castAt = g:GetLastGatherCast()
    end
    local age = castAt and (GetTime() - castAt) or math.huge
    if isFromItem then
        -- Disenchanting loots "from an item"; any other item loot is a container.
        return (cat == "disenchant" and age <= CAST_TO_LOOT_SEC) and "gathering" or nil
    end
    if not cat or cat == "disenchant" then
        return nil
    end
    local hasCreature, hasGO, hasOther, readable = ScanLootSources(n)
    if not readable then
        -- No readable source GUID (API missing / secret): keep the tight cast window only.
        return (age <= CAST_TO_LOOT_SEC) and "gathering" or nil
    end
    if hasOther then
        return nil
    end
    if hasCreature then
        -- A corpse is a gather only when the cast was skinning. Known gap: Herbalism /
        -- Mining on a gatherable creature corpse is not credited (UNIT_SPELLCAST_* has no
        -- target GUID to tell it from a mob kill looted right after a node).
        return (cat == "leather" and age <= CAST_TO_LOOT_SEC) and "gathering" or nil
    end
    if cat == "leather" then
        -- Skinning "Opening" (Dragonflight treasures) loots a GameObject: tight window only.
        return (age <= CAST_TO_LOOT_SEC) and "gathering" or nil
    end
    return (age <= GATHER_FOLLOWUP_SEC) and "gathering" or nil
end

local function OnLootOpened(isFromItem)
    local now = GetTime()
    -- A re-open (Finesse) or a missed LOOT_CLOSED: the previous window's tokens get the
    -- close grace instead of living forever.
    CloseOpenTokens(now)
    PruneTokens(now)
    local n = (GetNumLootItems and GetNumLootItems()) or 0
    local kind = (n > 0) and ClassifyWindow(isFromItem == true, n) or nil
    LootWindowBridge._kind = kind
    LootWindowBridge._openedAt = now
    local counts = {}
    if kind and GetLootSlotLink then
        for i = 1, n do
            if not LootSlotHasItem or LootSlotHasItem(i) then
                local link = GetLootSlotLink(i)
                local id = (type(link) == "string" and not IsSecret(link)) and tonumber(link:match("|Hitem:(%d+)")) or nil
                if id then
                    local qty = 1
                    if GetLootSlotInfo then
                        local _, _, quantity = GetLootSlotInfo(i)
                        if type(quantity) == "number" and not IsSecret(quantity) and quantity >= 1 then
                            qty = math.floor(quantity)
                        end
                    end
                    tokens[#tokens + 1] = { kind = kind, itemID = id, qty = qty, exp = math.huge }
                    counts[id] = (counts[id] or 0) + qty
                end
            end
        end
    end
    local g = ns.GatheringLootService
    if g and g.OnLootWindowClassified then
        g:OnLootWindowClassified(kind, counts)
    end
end

local function OnLootClosed()
    local now = GetTime()
    CloseOpenTokens(now)
    PruneTokens(now)
end

--- Consume one pickup token. Prefers a token with the same quantity, else any for the item.
---@param kind "gathering"|"fishing"
---@param itemID number
---@param qty number|nil
---@return boolean consumed
function LootWindowBridge:ConsumeToken(kind, itemID, qty)
    local now = GetTime()
    PruneTokens(now)
    local fallback
    for i = 1, #tokens do
        local t = tokens[i]
        if t.kind == kind and t.itemID == itemID then
            if t.qty == qty then
                table.remove(tokens, i)
                return true
            end
            fallback = fallback or i
        end
    end
    if fallback then
        table.remove(tokens, fallback)
        return true
    end
    return false
end

---@param kind "gathering"|"fishing"
---@param itemID number
---@return boolean
function LootWindowBridge:HasToken(kind, itemID)
    PruneTokens(GetTime())
    for i = 1, #tokens do
        local t = tokens[i]
        if t.kind == kind and t.itemID == itemID then
            return true
        end
    end
    return false
end

local bridge = CreateFrame("Frame")
bridge:RegisterEvent("LOOT_OPENED")
bridge:RegisterEvent("LOOT_CLOSED")
bridge:SetScript("OnEvent", function(_, event, autoLoot, isFromItem)
    if event == "LOOT_OPENED" then
        OnLootOpened(isFromItem)
    elseif event == "LOOT_CLOSED" then
        OnLootClosed()
    end
end)

ns.LootWindowBridge = LootWindowBridge
