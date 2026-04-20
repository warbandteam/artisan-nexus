--[[
    Session UI: last N discrete loot events + per–item-ID totals for reference grid.
    Fishing: FIFO newest-first list. Gathering: same, tagged by category (herb/mine/leather/dis).

    Each gathering line stores `cat` from the reference catalog only (`PushGatheringSession` rejects
    itemID/`cat` mismatch) so profession slices never mix in the event list.

    Duplicate suppression: only `SessionLootService:AddFishingEvent` / `AddGatheringEvent` append to
    these lists (plus `Reconcile*FromChat` which updates an existing row).  Dedupe scans several
    newest rows so interleaved pickups do not let a second window/chat copy slip past [1]-only checks.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS

--- Shown rows in Loot History “Last N pickups” (FIFO: oldest dropped when newer arrives).
local MAX_RECENT_LOOT = 15
local BUFFER = 40
--- Overall event list cap (persisted across sessions in db.global).
local OVERALL_EVENTS_CAP = 200

local GATHER_KEYS = { "herb", "mine", "leather", "disenchant", "others" }

--- Session totals / glow only for these tabs — never default to herb.
local VALID_GATHER_CAT = { herb = true, mine = true, leather = true, disenchant = true, others = true }

local REFERENCE_GLOW_SEC = 1.5

--- Non-active tabs pulse briefly when that profession’s **catalog** loot is recorded (multi-tab pickups).
local TAB_ATTENTION_SEC = 5.2

--- Same pickup fired twice in one loot resolution (window + chat or double bridge scan).
--- Must compare several recent rows: if another item was pushed in between, [1] is no longer the duplicate.
local DUPLICATE_GATHERING_EVENT_SEC = 1.5
local DUPLICATE_FISHING_EVENT_SEC = 0.85
local DUPLICATE_SCAN_DEPTH = 18

---@class SessionLootService
local SessionLootService = {
    ---@type table[] { itemID = number, qty = number, t = number }
    fishingEvents = {},
    ---@type table[] { itemID = number, qty = number, t = number, cat = string }
    gatheringEvents = {},
    ---@type table<number, number> itemID -> qty this session
    fishingTotals = {},
    ---@type table<string, table<number, number>>
    gatheringTotals = {},
    --- Reference grid glows: [tabKey][itemID] = expireAt (GetTime). Multiple reagents can glow at once.
    referenceGlow = {},
    _referenceGlowTicker = nil,
    --- [tabKey] = GetTime() expiry for “other tab got loot” highlight (LootHistoryUI).
    tabAttentionUntil = {},
    _tabAttentionRefreshTimer = nil,
    --- Exposed for Loot History UI (must match GetRecentEvents cap).
    MAX_RECENT_LOOT = MAX_RECENT_LOOT,
}

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        SessionLootService:ResetSession()
    end
end)

function SessionLootService:ClearReferenceGlowTicker()
    if self._referenceGlowTicker then
        if self._referenceGlowTicker.Cancel then
            pcall(function()
                self._referenceGlowTicker:Cancel()
            end)
        end
        self._referenceGlowTicker = nil
    end
end

function SessionLootService:_HasAnyActiveReferenceGlow()
    if not self.referenceGlow then
        return false
    end
    local now = GetTime()
    for _, items in pairs(self.referenceGlow) do
        for _, exp in pairs(items) do
            if exp and now <= exp then
                return true
            end
        end
    end
    return false
end

function SessionLootService:_EnsureReferenceGlowTicker()
    if self._referenceGlowTicker or not (C_Timer and C_Timer.NewTicker) then
        return
    end
    self._referenceGlowTicker = C_Timer.NewTicker(0.12, function()
        local pruned = self:PruneReferenceGlows()
        local hasGlow = self:_HasAnyActiveReferenceGlow()
        --- While any catalog highlight is fading, repaint Loot History so border alpha tracks time.
        if pruned or hasGlow then
            if ArtisanNexus and ArtisanNexus.SendMessage then
                ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
            end
        end
        if not hasGlow then
            self:ClearReferenceGlowTicker()
        end
    end)
end

--- Remove expired glow entries; @return true if anything was removed
function SessionLootService:PruneReferenceGlows()
    if not self.referenceGlow then
        return false
    end
    local now = GetTime()
    local changed = false
    for tabKey, items in pairs(self.referenceGlow) do
        for itemID, exp in pairs(items) do
            if not exp or now > exp then
                items[itemID] = nil
                changed = true
            end
        end
        if not next(items) then
            self.referenceGlow[tabKey] = nil
        end
    end
    if self.referenceGlow and not next(self.referenceGlow) then
        self.referenceGlow = {}
    end
    return changed
end

---@param itemID number
---@param tabKey string
function SessionLootService:AddReferenceGlow(itemID, tabKey)
    if not itemID or not tabKey then
        return
    end
    self.referenceGlow[tabKey] = self.referenceGlow[tabKey] or {}
    self.referenceGlow[tabKey][itemID] = GetTime() + REFERENCE_GLOW_SEC
    self:_EnsureReferenceGlowTicker()
end

--- Remaining glow strength for one item on a tab (1 = just added, 0 = expired).
---@param itemID number
---@param tabKey string
---@return number
function SessionLootService:GetReferenceGlowStrength(itemID, tabKey)
    if not itemID or not tabKey then
        return 0
    end
    local items = self.referenceGlow and self.referenceGlow[tabKey]
    if not items then
        return 0
    end
    local exp = items[itemID]
    if not exp then
        return 0
    end
    local now = GetTime()
    if now >= exp then
        return 0
    end
    local remain = exp - now
    return math.max(0, math.min(1, remain / REFERENCE_GLOW_SEC))
end

---@param tabKey string
---@return table<number, boolean> itemID -> true (active glow for this tab)
function SessionLootService:GetReferenceGlowSet(tabKey)
    local set = {}
    if not tabKey or not self.referenceGlow or not self.referenceGlow[tabKey] then
        return set
    end
    local now = GetTime()
    for itemID, exp in pairs(self.referenceGlow[tabKey]) do
        if exp and now <= exp then
            set[itemID] = true
        end
    end
    return set
end

function SessionLootService:ClearTabAttentionRefreshTimer()
    if self._tabAttentionRefreshTimer then
        if self._tabAttentionRefreshTimer.Cancel then
            pcall(function()
                self._tabAttentionRefreshTimer:Cancel()
            end)
        end
        self._tabAttentionRefreshTimer = nil
    end
end

function SessionLootService:ClearTabAttention()
    wipe(self.tabAttentionUntil or {})
    self.tabAttentionUntil = {}
    self:ClearTabAttentionRefreshTimer()
end

---@param tabKey string|nil
function SessionLootService:ClearTabAttentionForTab(tabKey)
    if not tabKey or not self.tabAttentionUntil then
        return
    end
    self.tabAttentionUntil[tabKey] = nil
end

---@param tabKey string|nil
function SessionLootService:IsTabAttentionActive(tabKey)
    if not tabKey or not self.tabAttentionUntil then
        return false
    end
    local t = self.tabAttentionUntil[tabKey]
    if not t or GetTime() > t then
        if self.tabAttentionUntil then
            self.tabAttentionUntil[tabKey] = nil
        end
        return false
    end
    return true
end

--- Switch UI to `cat` when it is the only profession in a batch, except **others** (shared bucket):
--- never auto-switch to Others — use attention glow instead (same as multi-tab batches).
---@param cat string
function SessionLootService:EmitGatheringTabSwitchOrAttention(cat)
    if not cat or not VALID_GATHER_CAT[cat] then
        return
    end
    if cat == "others" then
        self:EmitGatheringLootTabSignal({ multi = true, tabs = { others = true } })
    else
        self:EmitGatheringLootTabSignal({ singleTab = cat })
    end
end

--- One UI signal after a loot **batch** (window delta or one chat line): switch tab if single profession, else tab glows only.
---@param policy table|nil `{ singleTab = "herb" }` or `{ multi = true, tabs = { herb = true, mine = true } }`
function SessionLootService:EmitGatheringLootTabSignal(policy)
    if not ArtisanNexus or not ArtisanNexus.SendMessage then
        return
    end
    if type(policy) ~= "table" then
        return
    end
    if policy.multi and type(policy.tabs) == "table" then
        for tabKey in pairs(policy.tabs) do
            if tabKey == "fishing" or VALID_GATHER_CAT[tabKey] then
                self:BumpTabAttention(tabKey)
            end
        end
    elseif policy.singleTab and (policy.singleTab == "fishing" or VALID_GATHER_CAT[policy.singleTab]) then
        self:ClearTabAttention()
    end
    ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED, policy)
    ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
end

--- Fishing window batch: always one profession tab.
function SessionLootService:EmitFishingLootTabSignal()
    if not ArtisanNexus or not ArtisanNexus.SendMessage then
        return
    end
    self:ClearTabAttention()
    ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED, { singleTab = "fishing" })
    ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
end

function SessionLootService:BumpTabAttention(tabKey)
    if tabKey ~= "fishing" and (not tabKey or not VALID_GATHER_CAT[tabKey]) then
        return
    end
    self.tabAttentionUntil = self.tabAttentionUntil or {}
    self.tabAttentionUntil[tabKey] = GetTime() + TAB_ATTENTION_SEC
    if not (C_Timer and C_Timer.NewTimer) or not (ArtisanNexus and ArtisanNexus.SendMessage) then
        return
    end
    self:ClearTabAttentionRefreshTimer()
    self._tabAttentionRefreshTimer = C_Timer.NewTimer(TAB_ATTENTION_SEC + 0.08, function()
        self._tabAttentionRefreshTimer = nil
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end)
end

function SessionLootService:ResetSession()
    self:ClearReferenceGlowTicker()
    self:ClearTabAttention()
    wipe(self.referenceGlow)
    wipe(self.fishingEvents)
    wipe(self.gatheringEvents)
    wipe(self.fishingTotals)
    wipe(self.gatheringTotals)
    for i = 1, #GATHER_KEYS do
        self.gatheringTotals[GATHER_KEYS[i]] = {}
    end
    if ArtisanNexus and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
end

--- Clear in-memory session data for one tab only (fishing or one gathering profession).
---@param tabKey "fishing"|"herb"|"mine"|"leather"|"disenchant"|"others"
function SessionLootService:ResetSessionForTab(tabKey)
    if tabKey == "fishing" then
        wipe(self.fishingEvents)
        wipe(self.fishingTotals)
        if self.referenceGlow then
            self.referenceGlow["fishing"] = nil
        end
    elseif tabKey and VALID_GATHER_CAT[tabKey] then
        local kept = {}
        for i = 1, #(self.gatheringEvents or {}) do
            local e = self.gatheringEvents[i]
            if e and e.cat ~= tabKey then
                kept[#kept + 1] = e
            end
        end
        self.gatheringEvents = kept
        if not self.gatheringTotals[tabKey] then
            self.gatheringTotals[tabKey] = {}
        else
            wipe(self.gatheringTotals[tabKey])
        end
        if self.referenceGlow then
            self.referenceGlow[tabKey] = nil
        end
    else
        return
    end
    self:ClearTabAttentionForTab(tabKey)
    if ArtisanNexus and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
end

local function PushFront(list, entry)
    table.insert(list, 1, entry)
    while #list > BUFFER do
        table.remove(list)
    end
end

--- True if an equivalent line already exists in the first rows (newest-first), within `windowSec` of `now`.
local function IsDuplicateGatheringLine(events, itemID, qty, cat, now, windowSec)
    local limit = math.min(DUPLICATE_SCAN_DEPTH, #events)
    for i = 1, limit do
        local e = events[i]
        if e and e.itemID == itemID and e.qty == qty and e.cat == cat and e.rt and (now - e.rt) < windowSec then
            return true
        end
    end
    return false
end

local function IsDuplicateFishingLine(events, itemID, qty, now, windowSec)
    local limit = math.min(DUPLICATE_SCAN_DEPTH, #events)
    for i = 1, limit do
        local e = events[i]
        if e and e.itemID == itemID and e.qty == qty and e.rt and (now - e.rt) < windowSec then
            return true
        end
    end
    return false
end

---@param itemID number
---@param qty number
--- Prefer this from loot services so chat+window do not duplicate Last Loot / session totals.
---@param itemID number
---@param qty number
---@param opts table|nil `{ quiet = true }` defers tab signals (caller emits one batch via `EmitFishingLootTabSignal`).
function SessionLootService:PushFishingSession(itemID, qty, opts)
    if not itemID or not qty or qty < 1 then
        return
    end
    if not (ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID)) then
        return
    end
    opts = opts or {}
    self:AddFishingEvent(itemID, qty, opts.quiet)
end

function SessionLootService:AddFishingEvent(itemID, qty, quiet)
    if not itemID or not qty or qty < 1 then
        return
    end
    local now = GetTime()
    if IsDuplicateFishingLine(self.fishingEvents, itemID, qty, now, DUPLICATE_FISHING_EVENT_SEC) then
        return
    end
    self.fishingTotals[itemID] = (self.fishingTotals[itemID] or 0) + qty
    local wallT = time()
    PushFront(self.fishingEvents, {
        itemID = itemID,
        qty = qty,
        t = wallT,
        rt = now,
    })
    if ArtisanNexus and ArtisanNexus.db then
        local odb = ArtisanNexus.db.global.overallFishingEvents
        if type(odb) == "table" then
            table.insert(odb, 1, { itemID = itemID, qty = qty, t = wallT })
            while #odb > OVERALL_EVENTS_CAP do
                table.remove(odb)
            end
        end
    end
    self:AddReferenceGlow(itemID, "fishing")
    if quiet then
        return
    end
    self:EmitFishingLootTabSignal()
end

---@param itemID number
---@param qty number
---@param cat "herb"|"mine"|"leather"|"disenchant"|"others"|string
--- Prefer this from loot services so chat+window do not duplicate Last Loot / session totals.
---@param itemID number
---@param qty number
---@param cat string|nil
---@param opts table|nil `{ quiet = true }` during window/chat batch (caller calls `EmitGatheringLootTabSignal`).
function SessionLootService:PushGatheringSession(itemID, qty, cat, opts)
    if not itemID or not qty or qty < 1 then
        return
    end
    if not cat or not VALID_GATHER_CAT[cat] then
        return
    end
    if not (ns.IsGatheringCatalogItem and ns.IsGatheringCatalogItem(itemID)) then
        return
    end
    if ns.ItemListedInGatheringTab then
        if not ns.ItemListedInGatheringTab(itemID, cat) then
            return
        end
    elseif ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID) ~= cat then
        return
    end
    opts = opts or {}
    self:AddGatheringEvent(itemID, qty, cat, opts.quiet)
end

--- If CHAT_MSG_LOOT reports a larger stack than the last window-derived line (same item, same tab), fix totals + history.
---@param itemID number
---@param chatQty number
---@param cat string
---@param opts table|nil `{ quietTab = true }` — skip tab emit + `GATHERING_HISTORY_UPDATED` (caller batches one chat line).
function SessionLootService:ReconcileGatheringFromChat(itemID, chatQty, cat, opts)
    opts = opts or {}
    if not itemID or not chatQty or chatQty < 1 or not cat or not VALID_GATHER_CAT[cat] then
        return
    end
    if not (ns.IsGatheringCatalogItem and ns.IsGatheringCatalogItem(itemID)) then
        return
    end
    if ns.ItemListedInGatheringTab then
        if not ns.ItemListedInGatheringTab(itemID, cat) then
            return
        end
    elseif ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID) ~= cat then
        return
    end
    local nowWall = time()
    local ev = nil
    for i = 1, math.min(12, #(self.gatheringEvents or {})) do
        local e = self.gatheringEvents[i]
        if e and e.itemID == itemID and e.cat == cat and (nowWall - (e.t or 0)) <= 8 then
            ev = e
            break
        end
    end
    if not ev then
        return
    end
    local prev = math.max(1, ev.qty or 1)
    if chatQty <= prev then
        return
    end
    local delta = chatQty - prev
    ev.qty = chatQty
    ev.rt = GetTime()
    if not self.gatheringTotals[cat] then
        self.gatheringTotals[cat] = {}
    end
    local gt = self.gatheringTotals[cat]
    gt[itemID] = (gt[itemID] or 0) + delta

    local db = ArtisanNexus.db.global.gatheringLootHistory
    if type(db) == "table" then
        if not db[itemID] then
            db[itemID] = { count = 0, lastAt = 0, name = nil }
        end
        local row = db[itemID]
        row.count = (row.count or 0) + delta
        row.lastAt = time()
    end

    self:AddReferenceGlow(itemID, cat)
    if opts.quietTab then
        return
    end
    ArtisanNexus:SendMessage(E.GATHERING_HISTORY_UPDATED)
    self:EmitGatheringTabSwitchOrAttention(cat)
end

--- Same as ReconcileGatheringFromChat for fishing session + fishingLootHistory.
---@param itemID number
---@param chatQty number
---@param opts table|nil `{ quietTab = true }` — skip tab emit + `FISHING_HISTORY_UPDATED` (caller batches).
function SessionLootService:ReconcileFishingFromChat(itemID, chatQty, opts)
    opts = opts or {}
    if not itemID or not chatQty or chatQty < 1 then
        return
    end
    if not (ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID)) then
        return
    end
    local nowWall = time()
    local ev = nil
    for i = 1, math.min(12, #(self.fishingEvents or {})) do
        local e = self.fishingEvents[i]
        if e and e.itemID == itemID and (nowWall - (e.t or 0)) <= 8 then
            ev = e
            break
        end
    end
    if not ev then
        return
    end
    local prev = math.max(1, ev.qty or 1)
    if chatQty <= prev then
        return
    end
    local delta = chatQty - prev
    ev.qty = chatQty
    ev.rt = GetTime()
    self.fishingTotals[itemID] = (self.fishingTotals[itemID] or 0) + delta

    local db = ArtisanNexus.db.global.fishingLootHistory
    if type(db) == "table" then
        if not db[itemID] then
            db[itemID] = { count = 0, lastAt = 0, name = nil }
        end
        local row = db[itemID]
        row.count = (row.count or 0) + delta
        row.lastAt = time()
    end

    self:AddReferenceGlow(itemID, "fishing")
    if opts.quietTab then
        return
    end
    ArtisanNexus:SendMessage(E.FISHING_HISTORY_UPDATED)
    self:EmitFishingLootTabSignal()
end

---@param quiet boolean|nil when true, no tab bump / `SESSION_LOOT_UPDATED` (batched emit by caller).
function SessionLootService:AddGatheringEvent(itemID, qty, cat, quiet)
    if not itemID or not qty or qty < 1 then
        return
    end
    if not cat or not VALID_GATHER_CAT[cat] then
        return
    end
    local now = GetTime()
    if IsDuplicateGatheringLine(self.gatheringEvents, itemID, qty, cat, now, DUPLICATE_GATHERING_EVENT_SEC) then
        return
    end
    if not self.gatheringTotals[cat] then
        self.gatheringTotals[cat] = {}
    end
    local gt = self.gatheringTotals[cat]
    gt[itemID] = (gt[itemID] or 0) + qty
    local wallT = time()
    PushFront(self.gatheringEvents, {
        itemID = itemID,
        qty = qty,
        t = wallT,
        cat = cat,
        rt = now,
    })
    if ArtisanNexus and ArtisanNexus.db then
        local odb = ArtisanNexus.db.global.overallGatheringEvents
        if type(odb) == "table" then
            table.insert(odb, 1, { itemID = itemID, qty = qty, t = wallT, cat = cat })
            while #odb > OVERALL_EVENTS_CAP do
                table.remove(odb)
            end
        end
    end
    self:AddReferenceGlow(itemID, cat)
    if quiet then
        return
    end
    self:EmitGatheringTabSwitchOrAttention(cat)
end

--- Legacy hook (aggregated totals) — no longer used by UI; keep no-op for older callers.
---@deprecated
function SessionLootService:Add(kind, itemID, qty)
    if kind == "gathering" then
        return
    else
        self:AddFishingEvent(itemID, qty, false)
    end
end

---@param kind "fishing"|"gathering"
---@param gatherCategory string|nil
---@param overall boolean|nil true = read from persistent db.global lists
---@return table[] events (newest first, capped for UI)
function SessionLootService:GetRecentEvents(kind, gatherCategory, overall)
    if overall then
        if not ArtisanNexus or not ArtisanNexus.db then return {} end
        if kind == "fishing" then
            local odb = ArtisanNexus.db.global.overallFishingEvents or {}
            local out = {}
            for i = 1, math.min(MAX_RECENT_LOOT, #odb) do
                out[i] = odb[i]
            end
            return out
        end
        local odb = ArtisanNexus.db.global.overallGatheringEvents or {}
        local out = {}
        for i = 1, #odb do
            local e = odb[i]
            if e and e.cat == gatherCategory then
                out[#out + 1] = e
                if #out >= MAX_RECENT_LOOT then break end
            end
        end
        return out
    end
    if kind == "fishing" then
        local out = {}
        for i = 1, math.min(MAX_RECENT_LOOT, #self.fishingEvents) do
            out[i] = self.fishingEvents[i]
        end
        return out
    end
    local out = {}
    for i = 1, #self.gatheringEvents do
        local e = self.gatheringEvents[i]
        if e and e.cat == gatherCategory then
            out[#out + 1] = e
            if #out >= MAX_RECENT_LOOT then
                break
            end
        end
    end
    return out
end

--- Per–item-ID quantities (for reference totals). Not split by event.
---@param kind "fishing"|"gathering"
---@param gatherCategory string|nil herb / mine / … when kind is gathering
---@param overall boolean|nil true = read from persistent db.global totals
---@return table<number, number>
function SessionLootService:GetItemTotals(kind, gatherCategory, overall)
    if overall then
        if not ArtisanNexus or not ArtisanNexus.db then return {} end
        if kind == "fishing" then
            local db = ArtisanNexus.db.global.fishingLootHistory or {}
            local out = {}
            for itemID, row in pairs(db) do
                if type(row) == "table" and (row.count or 0) > 0 then
                    out[itemID] = row.count
                end
            end
            return out
        end
        if not gatherCategory or not VALID_GATHER_CAT[gatherCategory] then return {} end
        local db = ArtisanNexus.db.global.gatheringLootHistory or {}
        local out = {}
        for itemID, row in pairs(db) do
            if type(row) == "table" and (row.count or 0) > 0 then
                local okTab
                if ns.ItemListedInGatheringTab then
                    okTab = ns.ItemListedInGatheringTab(itemID, gatherCategory)
                else
                    okTab = ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID) == gatherCategory
                end
                if okTab then
                    out[itemID] = row.count
                end
            end
        end
        return out
    end
    if kind == "fishing" then
        return self.fishingTotals or {}
    end
    if not gatherCategory or not VALID_GATHER_CAT[gatherCategory] then
        return {}
    end
    if not self.gatheringTotals[gatherCategory] then
        self.gatheringTotals[gatherCategory] = {}
    end
    return self.gatheringTotals[gatherCategory]
end

---@param kind "fishing"|"gathering"
---@param gatherCategory string|nil required when kind is gathering
function SessionLootService:ResetOverall(kind, gatherCategory)
    if not ArtisanNexus or not ArtisanNexus.db then return end
    local g = ArtisanNexus.db.global
    if kind == "fishing" then
        wipe(g.overallFishingEvents or {})
        g.overallFishingEvents = {}
        wipe(g.fishingLootHistory or {})
        g.fishingLootHistory = {}
    elseif kind == "gathering" then
        if gatherCategory and VALID_GATHER_CAT[gatherCategory] then
            local gh = g.gatheringLootHistory or {}
            for itemID in pairs(gh) do
                if ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID) == gatherCategory then
                    gh[itemID] = nil
                end
            end
            local oe = g.overallGatheringEvents or {}
            for i = #oe, 1, -1 do
                if oe[i] and oe[i].cat == gatherCategory then
                    table.remove(oe, i)
                end
            end
        end
    end
    if ArtisanNexus and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
end

--- Wipe all persisted overall loot (every profession). Use from Options only.
function SessionLootService:ResetAllOverallData()
    if not ArtisanNexus or not ArtisanNexus.db then
        return
    end
    local g = ArtisanNexus.db.global
    wipe(g.overallFishingEvents or {})
    g.overallFishingEvents = {}
    wipe(g.fishingLootHistory or {})
    g.fishingLootHistory = {}
    wipe(g.overallGatheringEvents or {})
    g.overallGatheringEvents = {}
    wipe(g.gatheringLootHistory or {})
    g.gatheringLootHistory = {}
    if ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
end

---@deprecated Kept for accidental callers — returns empty (UI uses GetRecentEvents).
function SessionLootService:GetTable(kind)
    return {}
end

ns.SessionLootService = SessionLootService
