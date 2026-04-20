--[[
    Gathering loot: primary = LootWindowBridge (LOOT_READY/OPENED/CLOSED delta on GetLootSlotItemCounts).
    CHAT_MSG_LOOT = fallback when the window is gone (auto-loot) — gated by a short post-open grace window.
    Only `LOOT_ITEM_SELF*` lines are processed so party members' loot chat is ignored.
    Fishing wins when both claim.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS
local GatheringSpellData = ns.GatheringSpellData

---@class GatheringLootService
local GatheringLootService = {
    --- When true, `RecordItem` defers session tab UI + history broadcasts; window batch ends with one emit.
    _deferGatheringSessionTabSignals = false,
    _gatheringWindowUntil = nil,
    _lootOpenedGatheringHint = false,
    _pendingCategory = nil,
    _pendingCategoryUntil = 0,
    --- Lets CHAT_MSG_LOOT attribute session after LOOT_OPENED even if the 24s window flag flips early.
    _chatGatheringGraceUntil = 0,
    --- Auto-loot: no loot window — self loot lines still need a window for InferCategory (LOOT_ITEM_SELF).
    _selfLootChatGraceUntil = 0,
    --- True between LOOT_OPENED and LOOT_CLOSED; window path owns recording, chat path must not push.
    _lootWindowOpen = false,
}

local eventFrame = CreateFrame("Frame")

local GATHERING_WINDOW_SPELL = 45
local GATHERING_WINDOW_LOOT = 24

--- Last loot-window snapshot (itemID -> qty still in frame); delta vs new scan = picked up qty.
local lastWindowCounts = {}

--- Node GUID captured on UNIT_SPELLCAST_SUCCEEDED (herb/ore/corpse target).
--- Primary dedup key: the SAME physical node cannot legitimately be gathered twice,
--- so once we commit loot for a GUID, any repeat scan / LOOT_READY / Finesse re-open
--- for that same GUID is a duplicate regardless of window/chat timing.
local currentNodeGUID = nil
--- "guid|itemID" -> GetTime() of commit. Keyed by GUID+itemID (not GUID alone) so a
--- single gather can still record multiple distinct items from the same node. Entries
--- expire after NODE_COOLDOWN.
local committedNodeItem = {}
local NODE_COOLDOWN = 30

--- Fallback dedup for scans that arrive without a target GUID (auto-loot while running,
--- LOOT_OPENED fires without the player still targeting the node, etc.). We only suppress
--- true near-immediate echoes (same itemID + same qty in a very short window), otherwise
--- legitimate consecutive gathers of the same item must pass.
local recordedThisEpoch = {}
local recordedThisEpochAt = 0
local EPOCH_DUP_SEC = 0.22
local EPOCH_TTL = 10

--- CHAT_MSG_LOOT duplicate guard: WoW/addons (Fastloot, ElvUI loot, raid sync) can dispatch the
--- same chat line more than once in the same frame or a few frames apart. Keyed by the raw
--- message string + GetTime(); if the exact string repeats within CHAT_MSG_DUP_SEC we drop it.
local lastChatMsgAt = {}
local CHAT_MSG_DUP_SEC = 0.25
local lastChatPayloadSig = nil
local lastChatPayloadAt = 0

--- After a window-derived session line, suppress duplicate CHAT_MSG_LOOT for the same item.
--- Widened from 5.5s: WoW can buffer CHAT_MSG_LOOT for several seconds after LOOT_CLOSED,
--- and the echo suppress must survive long enough that a late chat echo never slips past
--- into Last Loot as a second event. 30s is well above observed chat delay and still
--- below the per-node GUID cooldown, so a genuine re-gather of the same item at a new
--- node still records (window path bypasses this — only chat is suppressed).
local CHAT_SUPPRESS_SEC = 30

--- If chat reports the same item/qty/cat as a line we just pushed from the loot window, ignore chat (echo).
--- Widened from 0.85s for the same reason: chat echo can arrive long after the window closed.
local CHAT_ECHO_IGNORE_SEC = 30

local function LootSourcesAreOnlyGameObjects()
    return ns.LootFrameSourcesAreOnlyGameObjects and ns.LootFrameSourcesAreOnlyGameObjects() or false
end

local function BuildCountsSig(counts)
    local keys = {}
    for itemID in pairs(counts or {}) do
        keys[#keys + 1] = itemID
    end
    table.sort(keys)
    local parts = {}
    for i = 1, #keys do
        local id = keys[i]
        parts[#parts + 1] = tostring(id) .. "=" .. tostring(counts[id] or 0)
    end
    return table.concat(parts, "&")
end

--- True if any loot slot reports a Creature GUID (mob/corpse). Used so chests/nodes without creature stay gathering-eligible.
local function LootFrameHasCreatureSource()
    local n = GetNumLootItems and GetNumLootItems() or 0
    if n < 1 then
        return false
    end
    for i = 1, n do
        local sources = { GetLootSourceInfo(i) }
        for j = 1, #sources, 2 do
            local guid = sources[j]
            if guid and type(guid) == "string" and not (issecretvalue and issecretvalue(guid)) and guid:match("^Creature") then
                return true
            end
        end
    end
    return false
end

function GatheringLootService:ShouldAttributeLootToGathering()
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        return false
    end
    if self._gatheringWindowUntil and GetTime() <= self._gatheringWindowUntil then
        return true
    end
    if self._lootOpenedGatheringHint then
        return true
    end
    return false
end

function GatheringLootService:ShouldAttributeLootWindowScan()
    return false
end

function GatheringLootService:ExtendGatheringWindow(seconds)
    self._gatheringWindowUntil = GetTime() + (seconds or GATHERING_WINDOW_SPELL)
end

--- Reset on LOOT_OPENED (also called from LootWindowBridge) so a new node does not inherit prior stacks.
--- `lastWindowCounts` always resets (delta math needs a clean baseline per window).
--- `recordedThisEpoch` only resets after TTL expiry — this preserves the dedup across
--- Finesse-triggered double LOOT_OPENED for the same gather action.
function GatheringLootService:ResetWindowCountSnapshot()
    wipe(lastWindowCounts)
    if (GetTime() - recordedThisEpochAt) >= EPOCH_TTL then
        wipe(recordedThisEpoch)
    end
    --- Age out stale node commits
    local now = GetTime()
    for key, t in pairs(committedNodeItem) do
        if (now - t) > NODE_COOLDOWN then
            committedNodeItem[key] = nil
        end
    end
end

--- Called from UNIT_SPELLCAST_SUCCEEDED: a new gather action just started. Capture the
--- target GUID (the herb/ore/corpse being gathered) and clear per-epoch dedup so a fresh
--- gather on a different node can record items that match the previous gather.
local function OnNewGatherAction(targetGUID)
    currentNodeGUID = targetGUID
    wipe(recordedThisEpoch)
    recordedThisEpochAt = 0
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

--- Saved totals for Overall / catalog (`db.global.gatheringLootHistory`). Window path uses `RecordItem`;
--- chat-only path must call this too (otherwise Overall grid stays at ×0 while Last pickups shows events).
local function IncrementGatheringLootHistoryDb(itemID, qty, itemName)
    if not itemID or itemID < 1 then
        return
    end
    qty = math.max(1, qty or 1)
    if not (ns.IsGatheringCatalogItem and ns.IsGatheringCatalogItem(itemID)) then
        return
    end
    local db = ArtisanNexus.db.global.gatheringLootHistory
    if type(db) ~= "table" then
        ArtisanNexus.db.global.gatheringLootHistory = {}
        db = ArtisanNexus.db.global.gatheringLootHistory
    end
    if not db[itemID] then
        db[itemID] = { count = 0, lastAt = 0, name = nil }
    end
    local row = db[itemID]
    row.count = (row.count or 0) + qty
    row.lastAt = time()
    if itemName and itemName ~= "" and not (issecretvalue and issecretvalue(itemName)) then
        row.name = itemName
    elseif not row.name or row.name == "" then
        local name = GetItemInfo(itemID)
        if name and not (issecretvalue and issecretvalue(name)) then
            row.name = name
        end
    end
end

---@return boolean recorded true if this call actually committed the item (not dedup-blocked)
local function RecordItem(itemID, qty, itemName)
    if not itemID or itemID < 1 then
        return false
    end
    qty = math.max(1, qty or 1)
    --- Session + history: only reference-catalog items (skip finesse junk like Stone Droppings).
    if not (ns.IsGatheringCatalogItem and ns.IsGatheringCatalogItem(itemID)) then
        return false
    end

    --- GUID+itemID dedup (primary). The same physical node cannot yield the same item
    --- twice within a single gather; if this (GUID, itemID) was already committed within
    --- NODE_COOLDOWN, any repeat scan is a duplicate (Finesse re-open, LOOT_READY retry,
    --- chat echo, server re-send). A new gather targets a new GUID → fresh records.
    if currentNodeGUID then
        local key = currentNodeGUID .. "|" .. itemID
        local t = committedNodeItem[key]
        if t and (GetTime() - t) < NODE_COOLDOWN then
            return false
        end
        committedNodeItem[key] = GetTime()
    else
        --- Fallback: no node GUID captured (spell not detected, or autoloot without
        --- spell cast event). Use itemID+epoch guard so a Finesse-triggered double
        --- LOOT_OPENED still blocks until a new spell cast starts a fresh epoch.
        local prevRec = recordedThisEpoch[itemID]
        local prevT = prevRec and (prevRec.t or recordedThisEpochAt) or 0
        local sameQty = prevRec and prevRec.qty == qty
        local elapsed = GetTime() - prevT
        if prevRec and sameQty and elapsed < EPOCH_DUP_SEC then
            return false
        end
        recordedThisEpoch[itemID] = { qty = qty, t = GetTime() }
        recordedThisEpochAt = GetTime()
    end

    IncrementGatheringLootHistoryDb(itemID, qty, itemName)

    --- Session push first: tab switch (SESSION_LOOT_UPDATED) must happen before history signals
    --- so RefreshIfVisible renders on the correct tab and not the previously-active one.
    local cat = ResolveGatheringSessionCategory(itemID)
    if cat and ns.SessionLootService and ns.SessionLootService.PushGatheringSession then
        GatheringLootService._suppressChatLootUntil = GatheringLootService._suppressChatLootUntil or {}
        GatheringLootService._suppressChatLootUntil[itemID] = GetTime() + CHAT_SUPPRESS_SEC
        GatheringLootService._lastGatheringWindowSession = GatheringLootService._lastGatheringWindowSession or {}
        GatheringLootService._lastGatheringWindowSession[itemID] = {
            t = GetTime(),
            qty = qty,
            cat = cat,
        }
        local quiet = GatheringLootService._deferGatheringSessionTabSignals
        ns.SessionLootService:PushGatheringSession(itemID, qty, cat, { quiet = quiet })
    end

    ArtisanNexus:SendMessage(E.GATHERING_LOOT_RECORDED, itemID, qty)
    if not GatheringLootService._deferGatheringSessionTabSignals then
        ArtisanNexus:SendMessage(E.GATHERING_HISTORY_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
    return true
end

--- Catalog profession keys present in `counts` (CHAT_MSG_LOOT parse or window map).
local function GatheringCatalogTabsInCounts(counts)
    local tabs = {}
    if not counts then
        return tabs
    end
    for itemID in pairs(counts) do
        if ns.IsGatheringCatalogItem and ns.IsGatheringCatalogItem(itemID) then
            local c = ResolveGatheringSessionCategory(itemID)
            if c then
                tabs[c] = true
            end
        end
    end
    return tabs
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

--- Fallback when auto-loot leaves no scannable slots: Last Loot + Overall DB from chat when the window path did not run.
local function ProcessChatSessionOnly(msg)
    if not msg or (issecretvalue and issecretvalue(msg)) then
        return
    end
    --- Grup/raid: başkalarının loot satırları da CHAT_MSG_LOOT ile gelir; sadece kendi lootumuz.
    if not (ns.IsSelfLootChatMessage and ns.IsSelfLootChatMessage(msg)) then
        return
    end
    --- Drop same chat line if it repeats within CHAT_MSG_DUP_SEC (addon/server re-dispatch).
    local now0 = GetTime()
    local prevAt = lastChatMsgAt[msg]
    if prevAt and (now0 - prevAt) < CHAT_MSG_DUP_SEC then
        return
    end
    lastChatMsgAt[msg] = now0
    --- Periodic cleanup (bounded memory).
    if (now0 % 30) < 0.05 then
        for k, t in pairs(lastChatMsgAt) do
            if (now0 - t) > CHAT_MSG_DUP_SEC * 4 then
                lastChatMsgAt[k] = nil
            end
        end
    end
    --- Gathering side: simple model uses loot chat as source of truth.
    --- Keep fishing precedence to avoid cross-attribution.
    if ns.FishingLootService and ns.FishingLootService.ShouldAttributeLootToFishing
        and ns.FishingLootService:ShouldAttributeLootToFishing() then
        return
    end
    --- Do NOT gate on `_lootWindowOpen` — FastLoot closes the window before chat arrives,
    --- and even when the window is open GUID+itemID dedup inside RecordItem prevents double-
    --- recording across window and chat paths. Gating here caused FastLoot to lose all loot.
    local counts = (ns.ParseChatLootItemQuantities and ns.ParseChatLootItemQuantities(msg)) or {}
    local payloadSig = BuildCountsSig(counts)
    if payloadSig ~= "" then
        lastChatPayloadSig = payloadSig
        lastChatPayloadAt = now0
    end
    local batchHintCategory = BuildBatchHintCategory(counts)
    --- Batch: multiple items in one chat message fire a single UI update.
    GatheringLootService._deferGatheringSessionTabSignals = true
    local recorded = false
    for itemID, qty in pairs(counts) do
        if ns.IsGatheringCatalogItem and ns.IsGatheringCatalogItem(itemID) then
            local cat = ResolveGatheringSessionCategory(itemID, batchHintCategory)
            if cat then
                if RecordItem(itemID, qty, nil) then
                    recorded = true
                end
            end
        end
    end
    GatheringLootService._deferGatheringSessionTabSignals = false
    if recorded then
        ArtisanNexus:SendMessage(E.GATHERING_HISTORY_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
        EmitGatheringTabPolicyForTabs(GatheringCatalogTabsInCounts(counts))
    end
end

--- Apply only the delta of items that left the loot window (matches chat quantities; avoids 1+2 vs 3 splits).
---@param counts table<number, number>
function GatheringLootService.RecordWindowLootCounts(counts)
    return
end

local function OnPlayerGatheringSpellCast(spellID, phase)
    if not spellID or not GatheringSpellData.IsGatheringSpell(spellID) then
        return
    end
    local c = GatheringSpellData.GetCategory(spellID)
    if not c then
        c = GatheringSpellData.InferGatheringCategoryFromSpell(spellID)
    end
    if c then
        GatheringLootService._pendingCategory = c
        GatheringLootService._pendingCategoryUntil = GetTime() + 50
    end
    GatheringLootService:ExtendGatheringWindow(GATHERING_WINDOW_SPELL)
    --- A new gather action has started — clear the per-gather dedup map so this action
    --- can record items (including items with the same ID+qty as the previous gather).
    --- Only on SUCCEEDED (cast completed), not on START (channel starts, may be canceled).
    if phase == "succeeded" then
        OnNewGatherAction(UnitGUID("target"))
    end
end

function GatheringLootService:Enable()
    eventFrame:RegisterEvent("CHAT_MSG_LOOT")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    eventFrame:RegisterEvent("LOOT_OPENED")
    eventFrame:RegisterEvent("LOOT_CLOSED")

    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if ns.IsOpenWorld and not ns.IsOpenWorld() then
            if event == "LOOT_CLOSED" then
                GatheringLootService._lootWindowOpen = false
            end
            return
        end
        if event == "CHAT_MSG_LOOT" then
            ProcessChatSessionOnly(select(1, ...))
        elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unitTarget, castGUID, spellID = ...
            if unitTarget == "player" then
                OnPlayerGatheringSpellCast(spellID, event == "UNIT_SPELLCAST_SUCCEEDED" and "succeeded" or "start")
            end
        elseif event == "LOOT_CLOSED" then
            GatheringLootService._lootWindowOpen = false
        elseif event == "LOOT_OPENED" then
            GatheringLootService._lootWindowOpen = true
            GatheringLootService:ResetWindowCountSnapshot()
            if IsFishingLoot and IsFishingLoot() then
                GatheringLootService._lootWindowOpen = false
                GatheringLootService._lootOpenedGatheringHint = false
                return
            end
            local nLoot = GetNumLootItems and GetNumLootItems() or 0
            if nLoot < 1 then
                return
            end
            --- Creature corpses (skinning, mob drops) still count as gathering when a gathering spell was just cast
            --- (pending tab) or the spell window is still open. Otherwise dungeon trash would falsely match.
            local creatureLoot = LootFrameHasCreatureSource()
            local spellGatheringOpen = GatheringLootService._gatheringWindowUntil
                and GetTime() <= (GatheringLootService._gatheringWindowUntil or 0)
            local pendingOk = GatheringLootService._pendingCategory
                and GetTime() < (GatheringLootService._pendingCategoryUntil or 0)
            if creatureLoot and not spellGatheringOpen and not pendingOk then
                GatheringLootService._lootOpenedGatheringHint = false
                return
            end
            local tEnd = GetTime() + GATHERING_WINDOW_LOOT
            local prevUntil = GatheringLootService._gatheringWindowUntil
            if prevUntil and prevUntil > tEnd then
                tEnd = prevUntil
            end
            GatheringLootService._gatheringWindowUntil = tEnd
            GatheringLootService._chatGatheringGraceUntil = GetTime() + 5
            if LootSourcesAreOnlyGameObjects() then
                GatheringLootService._lootOpenedGatheringHint = true
            end
            --- Hint tab from loot slots when spell hint expired: majority of catalog/inferred rows (not first itemID sort).
            if (not GatheringLootService._pendingCategory or GetTime() > (GatheringLootService._pendingCategoryUntil or 0))
                and ns.GetLootSlotItemCounts then
                local counts = ns.GetLootSlotItemCounts()
                if counts then
                    local votes = {}
                    for itemID in pairs(counts) do
                        local cat = ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID)
                        if not cat then
                            cat = GatheringSpellData.InferCategoryFromItemId(itemID)
                        end
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
                        GatheringLootService._pendingCategory = bestCat
                        GatheringLootService._pendingCategoryUntil = GetTime() + 50
                    end
                end
            end
        end
    end)
end

function GatheringLootService:Disable()
    eventFrame:UnregisterAllEvents()
    eventFrame:SetScript("OnEvent", nil)
    self._gatheringWindowUntil = nil
    self._lootWindowOpen = false
    self._lootOpenedGatheringHint = false
    self._pendingCategory = nil
    self._pendingCategoryUntil = 0
    self._chatGatheringGraceUntil = 0
    self._selfLootChatGraceUntil = 0
end

ns.GatheringLootService = GatheringLootService
