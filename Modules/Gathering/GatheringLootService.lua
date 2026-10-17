--[[
    Gathering loot: CHAT_MSG_LOOT (self-loot lines only) is the single recorder.

    Attribution (a catalog item alone is never enough):
      1) a gathering loot-window token from LootWindowBridge (window opened from a node, a
         skinned corpse or a disenchant, right after a player gathering cast), or
      2) a recent successful player gathering cast (UNIT_SPELLCAST_SUCCEEDED with a spell
         from GatheringSpellData) for lines pushed straight to the bags without a window.
         Any non-gathering loot window (mob, container, fishing) closes this fallback.
    Vendor buys, quest rewards, containers, mob drops and AH deliveries have neither and
    are not recorded.

    De-duplication is exact: the chat lineID (one per line, identical on re-dispatch) and
    one consumed token per looted slot. No time-window filters, so two identical pickups
    (two slots, two corpses) both count.
]]

local ADDON_NAME, ns = ...

-- 12.1.5 removed the global item/coin fallbacks; bind the namespaced APIs.
local GetItemInfo = C_Item.GetItemInfo

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS
local GatheringSpellData = ns.GatheringSpellData

---@class GatheringLootService
local GatheringLootService = {
    --- Deferred session tab UI signals during batched chat processing.
    _deferGatheringSessionTabSignals = false,
    _pendingCategory = nil,
    _pendingCategoryUntil = 0,
    --- Last successful player gathering cast (category, GetTime()).
    _lastCastCategory = nil,
    _lastCastAt = nil,
    --- UNIT_SPELLCAST_START of the current gather (active-time clock seeds a new bout here).
    _lastCastStartAt = nil,
    --- Cast fallback (2) stays open until GATHER_CAST_CONTEXT_SEC or a non-gathering window.
    _castContextOpen = false,
    _enabled = false,
}

local eventFrame = CreateFrame("Frame")

--- Bags-pushed gather lines arrive right after the cast; keep the fallback short so a
--- vendor/quest/mailbox item shortly after gathering is not attributed.
local GATHER_CAST_CONTEXT_SEC = 10
local PENDING_CATEGORY_SEC = 50

local chatLines = ns.Utilities.CreateChatLineDeduper(120)

local function IsSecret(v)
    return v ~= nil and issecretvalue and issecretvalue(v)
end

--- Session tab routing (simple model):
--- 1) If player just cast a gathering spell and item exists on that tab, use it.
--- 2) Otherwise use catalog primary tab.
local function ResolveGatheringSessionCategory(itemID, batchHintCategory)
    if not itemID then
        return nil
    end
    local now = GetTime()
    local pend = GatheringLootService._pendingCategory
    local pendUntil = GatheringLootService._pendingCategoryUntil or 0
    if pend and now < pendUntil then
        if ns.ItemListedInGatheringTab and ns.ItemListedInGatheringTab(itemID, pend) then
            return pend
        end
    end

    local fromCatalog = ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID)
    if fromCatalog then
        if batchHintCategory and ns.ItemListedInGatheringTab and ns.ItemListedInGatheringTab(itemID, batchHintCategory) then
            return batchHintCategory
        end
        return fromCatalog
    end
    return nil
end

local function BuildBatchHintCategory(counts)
    local votes = {}
    for itemID in pairs(counts or {}) do
        if ns.IsGatheringCatalogItem and ns.IsGatheringCatalogItem(itemID) then
            local herb = ns.ItemListedInGatheringTab and ns.ItemListedInGatheringTab(itemID, "herb")
            local mine = ns.ItemListedInGatheringTab and ns.ItemListedInGatheringTab(itemID, "mine")
            local leather = ns.ItemListedInGatheringTab and ns.ItemListedInGatheringTab(itemID, "leather")
            local disenchant = ns.ItemListedInGatheringTab and ns.ItemListedInGatheringTab(itemID, "disenchant")
            local n = (herb and 1 or 0) + (mine and 1 or 0) + (leather and 1 or 0) + (disenchant and 1 or 0)
            if n == 1 then
                if herb then votes.herb = (votes.herb or 0) + 1 end
                if mine then votes.mine = (votes.mine or 0) + 1 end
                if leather then votes.leather = (votes.leather or 0) + 1 end
                if disenchant then votes.disenchant = (votes.disenchant or 0) + 1 end
            end
        end
    end
    local bestCat, bestN = nil, 0
    for cat, n in pairs(votes) do
        if n > bestN then
            bestCat, bestN = cat, n
        end
    end
    return bestCat
end

--- Saved totals for Overall / catalog (`db.global.gatheringLootHistory`, uncapped, with a
--- per-character `byChar` split maintained by SessionLootService:CreditLootHistory).
local function IncrementGatheringLootHistoryDb(itemID, qty, itemName)
    if not itemID or itemID < 1 then
        return
    end
    if not (ns.IsGatheringCatalogItem and ns.IsGatheringCatalogItem(itemID)) then
        return
    end
    if not itemName or itemName == "" or IsSecret(itemName) then
        local name = GetItemInfo(itemID)
        itemName = (name and not IsSecret(name)) and name or nil
    end
    local svc = ns.SessionLootService
    if svc and svc.CreditLootHistory then
        svc:CreditLootHistory("gatheringLootHistory", itemID, math.max(1, qty or 1), itemName)
    end
end

---@return boolean recorded true if this call committed the item
local function RecordItem(itemID, qty, cat)
    if not itemID or itemID < 1 or not cat then
        return false
    end
    qty = math.max(1, qty or 1)
    --- Session push first: tab switch (SESSION_LOOT_UPDATED) must happen before history signals
    --- so RefreshIfVisible renders on the correct tab. History only when the session accepted.
    local svc = ns.SessionLootService
    if not (svc and svc.PushGatheringSession) then
        return false
    end
    local accepted = svc:PushGatheringSession(itemID, qty, cat, {
        quiet = GatheringLootService._deferGatheringSessionTabSignals,
        boutStartAt = GatheringLootService._lastCastStartAt,
    })
    if not accepted then
        return false
    end

    IncrementGatheringLootHistoryDb(itemID, qty, nil)

    ArtisanNexus:SendMessage(E.GATHERING_LOOT_RECORDED, itemID, qty)
    if not GatheringLootService._deferGatheringSessionTabSignals then
        ArtisanNexus:SendMessage(E.GATHERING_HISTORY_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
    return true
end

local function EmitGatheringTabPolicyForTabs(tabs)
    local n, first = 0, nil
    for k in pairs(tabs) do
        n = n + 1
        first = first or k
    end
    if n < 1 or not (ns.SessionLootService and ns.SessionLootService.EmitGatheringLootTabSignal) then
        return
    end
    if n == 1 then
        if first == "others" then
            ns.SessionLootService:EmitGatheringTabSwitchOrAttention("others")
        else
            ns.SessionLootService:EmitGatheringLootTabSignal({ singleTab = first })
        end
    else
        ns.SessionLootService:EmitGatheringLootTabSignal({ multi = true, tabs = tabs })
    end
end

local function HasCastContext()
    local s = GatheringLootService
    return s._castContextOpen and s._lastCastAt ~= nil and (GetTime() - s._lastCastAt) <= GATHER_CAST_CONTEXT_SEC
end

--- True when this pickup belongs to a gathering action (consumes one window token if any).
---@param itemID number
---@param qty number
---@return boolean
function GatheringLootService:ClaimGatheringPickup(itemID, qty)
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return false
    end
    local bridge = ns.LootWindowBridge
    if bridge and bridge.ConsumeToken and bridge:ConsumeToken("gathering", itemID, qty) then
        return true
    end
    return HasCastContext()
end

---@return string|nil category of the last successful player gathering cast
---@return number|nil castAt GetTime() of that cast
function GatheringLootService:GetLastGatherCast()
    return self._lastCastCategory, self._lastCastAt
end

local function ProcessChatLoot(msg, lineID)
    if not msg or IsSecret(msg) then
        return
    end
    --- Group/raid: other players' lines also arrive on CHAT_MSG_LOOT; only our own loot.
    if not (ns.IsSelfLootChatMessage and ns.IsSelfLootChatMessage(msg)) then
        return
    end
    if chatLines:Seen(lineID) then
        return
    end
    local counts = (ns.ParseChatLootItemQuantities and ns.ParseChatLootItemQuantities(msg)) or {}
    local batchHintCategory = BuildBatchHintCategory(counts)
    --- Batch: multiple items in one chat message fire a single UI update.
    GatheringLootService._deferGatheringSessionTabSignals = true
    local recordedTabs, recorded = {}, false
    for itemID, qty in pairs(counts) do
        if ns.IsGatheringCatalogItem and ns.IsGatheringCatalogItem(itemID)
            and GatheringLootService:ClaimGatheringPickup(itemID, qty) then
            local cat = ResolveGatheringSessionCategory(itemID, batchHintCategory)
            if cat and RecordItem(itemID, qty, cat) then
                recorded = true
                recordedTabs[cat] = true
            end
        end
    end
    GatheringLootService._deferGatheringSessionTabSignals = false
    if recorded then
        ArtisanNexus:SendMessage(E.GATHERING_HISTORY_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
        EmitGatheringTabPolicyForTabs(recordedTabs)
    end
end

local function OnPlayerGatheringSpellCast(spellID, phase)
    if not spellID or IsSecret(spellID) or not GatheringSpellData.IsGatheringSpell(spellID) then
        return
    end
    local s = GatheringLootService
    local now = GetTime()
    local c = GatheringSpellData.GetCategory(spellID) or GatheringSpellData.InferGatheringCategoryFromSpell(spellID)
    if c then
        s._pendingCategory = c
        s._pendingCategoryUntil = now + PENDING_CATEGORY_SEC
    end
    if phase == "start" then
        s._lastCastStartAt = now
        return
    end
    --- Only SUCCEEDED opens the attribution context (a START may be cancelled).
    s._lastCastCategory = c
    s._lastCastAt = now
    s._castContextOpen = true
    if not s._lastCastStartAt or (now - s._lastCastStartAt) > GATHER_CAST_CONTEXT_SEC then
        s._lastCastStartAt = now
    end
end

--- Called by LootWindowBridge after it classified a LOOT_OPENED.
---@param kind "gathering"|"fishing"|nil
---@param counts table<number, number> itemID -> qty in the window (empty when kind is nil)
function GatheringLootService:OnLootWindowClassified(kind, counts)
    if not self._enabled then
        return
    end
    if kind ~= "gathering" then
        --- Mob corpse, container or fishing window: the cast fallback must not claim its lines.
        self._castContextOpen = false
        return
    end
    --- Tab hint from the window when the spell hint expired: majority of catalog/inferred rows.
    if self._pendingCategory and GetTime() <= (self._pendingCategoryUntil or 0) then
        return
    end
    local votes = {}
    for itemID in pairs(counts or {}) do
        local cat = GatheringSpellData.InferCategoryFromItemId(itemID)
        if cat then
            votes[cat] = (votes[cat] or 0) + 1
        end
    end
    local bestCat, bestN = nil, 0
    for cat, n in pairs(votes) do
        if n > bestN then
            bestN = n
            bestCat = cat
        end
    end
    if bestCat then
        self._pendingCategory = bestCat
        self._pendingCategoryUntil = GetTime() + PENDING_CATEGORY_SEC
    end
end

function GatheringLootService:Enable()
    self._enabled = true
    eventFrame:RegisterEvent("CHAT_MSG_LOOT")
    --- Player-only: unfiltered UNIT_SPELLCAST_* fires for every nearby unit (same as FishingService).
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if ns.IsOpenWorld and not ns.IsOpenWorld() then
            return
        end
        if event == "CHAT_MSG_LOOT" then
            -- verified 2026-10-15, ChatInfoDocumentation.lua 12.1.5: arg 1 text, arg 11 lineID.
            local text, _, _, _, _, _, _, _, _, _, lineID = ...
            ProcessChatLoot(text, lineID)
        elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unitTarget, castGUID, spellID = ...
            if unitTarget == "player" then
                OnPlayerGatheringSpellCast(spellID, event == "UNIT_SPELLCAST_SUCCEEDED" and "succeeded" or "start")
            end
        end
    end)
end

function GatheringLootService:Disable()
    eventFrame:UnregisterAllEvents()
    eventFrame:SetScript("OnEvent", nil)
    self._enabled = false
    self._pendingCategory = nil
    self._pendingCategoryUntil = 0
    self._lastCastCategory = nil
    self._lastCastAt = nil
    self._lastCastStartAt = nil
    self._castContextOpen = false
end

ns.GatheringLootService = GatheringLootService
