--[[
    Session UI: last N discrete loot events + per–item-ID totals for reference grid.
    Fishing: FIFO newest-first list. Gathering: same, tagged by category (herb/mine/leather/dis).

    Each gathering line stores `cat` from the reference catalog only (`PushGatheringSession` rejects
    itemID/`cat` mismatch) so profession slices never mix in the event list.

    No time-window duplicate filters here: the loot services de-duplicate exactly upstream
    (chat lineID + one loot-window token per slot; crafted results per operationID), so two
    identical pickups seconds apart are two real pickups and both count.

    Persistent totals: `db.global.{gathering,fishing,crafted}LootHistory[itemID]` =
    { count, lastAt, name?, byChar = { [characterGUID|"unknown"] = qty } } — uncapped.
    `overall*Events` are capped per character (GetOverallEventsCap) and only feed the
    "last pickups" list, never lifetime totals.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants.EVENTS

--- Defaults match Core.lua profile; clamped when read (see GetMaxRecentLoot / GetOverallEventsCap).
local DEFAULT_SESSION_LOOT_MAX_RECENT = 15
local DEFAULT_SESSION_LOOT_OVERALL_CAP = 200
local SESSION_LOOT_RECENT_MIN = 5
local SESSION_LOOT_RECENT_MAX = 100
local SESSION_LOOT_OVERALL_MIN = 50
local SESSION_LOOT_OVERALL_MAX = 2000

local GATHER_KEYS = { "herb", "mine", "leather", "disenchant", "others" }

--- Session totals / glow only for these tabs — never default to herb.
local VALID_GATHER_CAT = { herb = true, mine = true, leather = true, disenchant = true, others = true }

local REFERENCE_GLOW_SEC = 1.5
local UNKNOWN_CHAR_KEY = "unknown"

--- Non-active tabs pulse briefly when that profession’s **catalog** loot is recorded (multi-tab pickups).
local TAB_ATTENTION_SEC = 5.2

--- Extra in-memory rows kept beyond the visible "last N" list.
local LIST_BUFFER_EXTRA = 28

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
    ---@type table[] { itemID = number, qty = number, t = number, spellID = number|nil, profession = string|nil }
    craftedEvents = {},
    --- Start of the crafted session (time()): the crafted tab lists CraftLedgerService rows since then.
    craftedSince = time(),
    ---@type table<number, number> crafted output itemID -> qty this session
    craftedTotals = {},
    --- Reference grid glows: [tabKey][itemID] = expireAt (GetTime). Multiple reagents can glow at once.
    referenceGlow = {},
    _referenceGlowTicker = nil,
    --- [tabKey] = GetTime() expiry for “other tab got loot” highlight (LootHistoryUI).
    tabAttentionUntil = {},
    _tabAttentionRefreshTimer = nil,
}

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        SessionLootService:MigrateHistoryByChar()
        SessionLootService:ResetSession()
    end
end)

local function CurrentCharKey()
    local u = ns.Utilities
    local guid = u and u.GetCharacterGUID and u:GetCharacterGUID()
    return guid or UNKNOWN_CHAR_KEY
end

--- Stamp persisted overall rows with the character GUID (`ck`). Value is never frozen
--- here: every view prices at the current market (ns.GetLootValueCopper). Legacy rows may
--- still carry `v` (unit copper at record time); it is history only and not read.
local function StampOverallRow(row)
    local key = CurrentCharKey()
    if key ~= UNKNOWN_CHAR_KEY then
        row.ck = key
    end
    return row
end

local HISTORY_TO_EVENTS = {
    gatheringLootHistory = "overallGatheringEvents",
    fishingLootHistory = "overallFishingEvents",
    craftedLootHistory = "overallCraftedEvents",
}

--- One-time (per row) seed of `byChar` for history rows written before the split existed:
--- the capped event tail gives what it can per character, the rest stays "unknown" so the
--- per-character sum always equals the uncapped `count`.
function SessionLootService:MigrateHistoryByChar()
    local g = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.global
    if not g then
        return
    end
    for histKey, eventsKey in pairs(HISTORY_TO_EVENTS) do
        local hist = g[histKey]
        if type(hist) == "table" then
            local tail
            for itemID, row in pairs(hist) do
                if type(row) == "table" and type(row.byChar) ~= "table" then
                    if not tail then
                        tail = {}
                        local ev = g[eventsKey]
                        for i = 1, (type(ev) == "table" and #ev or 0) do
                            local e = ev[i]
                            local id = e and tonumber(e.itemID)
                            local q = e and tonumber(e.qty)
                            if id and q and q > 0 then
                                local per = tail[id] or {}
                                tail[id] = per
                                local k = e.ck or UNKNOWN_CHAR_KEY
                                per[k] = (per[k] or 0) + q
                            end
                        end
                    end
                    local count = tonumber(row.count) or 0
                    local byChar, used = {}, 0
                    for k, q in pairs(tail[tonumber(itemID)] or {}) do
                        q = math.min(q, count - used)
                        if q > 0 then
                            byChar[k] = q
                            used = used + q
                        end
                    end
                    if count - used > 0 then
                        byChar[UNKNOWN_CHAR_KEY] = (byChar[UNKNOWN_CHAR_KEY] or 0) + (count - used)
                    end
                    row.byChar = byChar
                end
            end
        end
    end
end

--- Bump an uncapped history row (`count`, `lastAt`, `name`, `byChar[current character]`).
---@param histKey "gatheringLootHistory"|"fishingLootHistory"|"craftedLootHistory"
---@param itemID number
---@param qty number
---@param itemName string|nil
function SessionLootService:CreditLootHistory(histKey, itemID, qty, itemName)
    local g = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.global
    itemID, qty = tonumber(itemID), tonumber(qty)
    if not g or not HISTORY_TO_EVENTS[histKey] or not itemID or not qty or qty < 1 then
        return
    end
    if type(g[histKey]) ~= "table" then
        g[histKey] = {}
    end
    local row = g[histKey][itemID]
    if type(row) ~= "table" then
        row = { count = 0, lastAt = 0, byChar = {} }
        g[histKey][itemID] = row
    end
    if type(row.byChar) ~= "table" then
        -- Legacy row created before migration ran (should not happen after PLAYER_LOGIN).
        row.byChar = { [UNKNOWN_CHAR_KEY] = tonumber(row.count) or 0 }
    end
    row.count = (tonumber(row.count) or 0) + qty
    row.lastAt = time()
    local key = CurrentCharKey()
    row.byChar[key] = (row.byChar[key] or 0) + qty
    if itemName and itemName ~= "" and not (issecretvalue and issecretvalue(itemName)) then
        row.name = itemName
    end
end

--- Trim newest-first overall lists per character: each `ck` bucket keeps up to
--- `cap` rows, so one active character can no longer evict offline characters'
--- records. Legacy unkeyed rows share the "unknown" bucket.
local function TrimOverallPerChar(odb, cap)
    if #odb <= cap then
        return
    end
    -- Single-pass compaction (table.remove inside the loop was O(n^2) on every pickup).
    local counts = {}
    local n = #odb
    local w = 0
    for r = 1, n do
        local row = odb[r]
        local key = (row and row.ck) or "unknown"
        local c = (counts[key] or 0) + 1
        counts[key] = c
        if c <= cap then
            w = w + 1
            odb[w] = row
        end
    end
    for r = n, w + 1, -1 do
        odb[r] = nil
    end
end

--- In-memory event lists keep extra tail rows for duplicate scans (newest-first).
function SessionLootService:GetSessionListBufferCap()
    return math.max(40, self:GetMaxRecentLoot() + LIST_BUFFER_EXTRA)
end

--- Shown rows in Loot History “Last N pickups” (FIFO cap for UI + persisted overall tail trim).
function SessionLootService:GetMaxRecentLoot()
    local profile = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.profile
    if not profile then
        return DEFAULT_SESSION_LOOT_MAX_RECENT
    end
    local n = tonumber(profile.sessionLootMaxRecent)
    if not n or n ~= n then
        return DEFAULT_SESSION_LOOT_MAX_RECENT
    end
    n = math.floor(n + 0.5)
    return math.max(SESSION_LOOT_RECENT_MIN, math.min(SESSION_LOOT_RECENT_MAX, n))
end

--- Cap for `db.global.overallFishingEvents` / `overallGatheringEvents` tail.
function SessionLootService:GetOverallEventsCap()
    local profile = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.profile
    if not profile then
        return DEFAULT_SESSION_LOOT_OVERALL_CAP
    end
    local n = tonumber(profile.sessionLootOverallCap)
    if not n or n ~= n then
        return DEFAULT_SESSION_LOOT_OVERALL_CAP
    end
    n = math.floor(n + 0.5)
    return math.max(SESSION_LOOT_OVERALL_MIN, math.min(SESSION_LOOT_OVERALL_MAX, n))
end

--- UI / settings: hard clamps for `sessionLootMaxRecent` (keep in sync with `GetMaxRecentLoot`).
function SessionLootService:GetSessionRecentHardLimits()
    return SESSION_LOOT_RECENT_MIN, SESSION_LOOT_RECENT_MAX
end

--- UI / settings: hard clamps for `sessionLootOverallCap` (keep in sync with `GetOverallEventsCap`).
function SessionLootService:GetSessionOverallHardLimits()
    return SESSION_LOOT_OVERALL_MIN, SESSION_LOOT_OVERALL_MAX
end

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
    --- ~3 Hz max while glows fade — enough for smooth reference alpha without rebuilding the whole grid every frame.
    self._referenceGlowTicker = C_Timer.NewTicker(0.32, function()
        local pruned = self:PruneReferenceGlows()
        local hasGlow = self:_HasAnyActiveReferenceGlow()
        --- Fade catalog highlights without rebuilding the whole Loot History grid (~3 Hz).
        if pruned or hasGlow then
            local lh = ns.LootHistoryUI
            if lh and lh.RefreshCatalogGlowsOnly then
                lh:RefreshCatalogGlowsOnly()
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
    elseif policy.singleTab and (policy.singleTab == "fishing" or policy.singleTab == "crafted" or VALID_GATHER_CAT[policy.singleTab]) then
        self:ClearTabAttention()
    end
    ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED, policy)
    ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
end

--- Fishing window batch: always one profession tab.
function SessionLootService:EmitCraftedLootTabSignal()
    if not ArtisanNexus or not ArtisanNexus.SendMessage then
        return
    end
    self:ClearTabAttention()
    ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED, { singleTab = "crafted" })
    ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
end

function SessionLootService:EmitFishingLootTabSignal()
    if not ArtisanNexus or not ArtisanNexus.SendMessage then
        return
    end
    self:ClearTabAttention()
    ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED, { singleTab = "fishing" })
    ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
end

function SessionLootService:BumpTabAttention(tabKey)
    if tabKey ~= "fishing" and tabKey ~= "crafted" and (not tabKey or not VALID_GATHER_CAT[tabKey]) then
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

--- Active-time session clock per tab: gaps longer than SESSION_IDLE_GAP_SEC (travel, AFK,
--- vendor runs) are not counted, so gold/hour reflects time actually spent farming.
--- The first pickup of a bout is credited the time since the bout's cast/channel start
--- (`boutStartAt`), or BOUT_SEED_SEC when the caller has none (crafting) — it used to be 0 s,
--- which overstated short-session rates. Callers tick only for accepted pickups.
local SESSION_IDLE_GAP_SEC = 300
local BOUT_SEED_SEC = 10

---@param tabKey string
---@param boutStartAt number|nil GetTime() the current gather cast / fishing channel started
function SessionLootService:TickSessionClock(tabKey, boutStartAt)
    if not tabKey then return end
    self._sessionClock = self._sessionClock or {}
    local c = self._sessionClock[tabKey]
    local now = GetTime()
    local gap = c and (now - c.last) or math.huge
    local credit
    if gap <= SESSION_IDLE_GAP_SEC then
        credit = math.max(0, gap)
    else
        local since = tonumber(boutStartAt) and (now - boutStartAt) or nil
        if since and since > 0 and since <= SESSION_IDLE_GAP_SEC then
            credit = math.max(1, since)
        else
            credit = BOUT_SEED_SEC
        end
    end
    if not c then
        c = { first = now, last = now, active = 0 }
        self._sessionClock[tabKey] = c
    end
    c.active = c.active + credit
    c.last = now
end

---@param tabKey string
---@return table|nil { first, last, active } GetTime() seconds
function SessionLootService:GetSessionClock(tabKey)
    return self._sessionClock and self._sessionClock[tabKey] or nil
end

function SessionLootService:ResetSession()
    self:ClearReferenceGlowTicker()
    self:ClearTabAttention()
    wipe(self.referenceGlow)
    wipe(self.fishingEvents)
    wipe(self.gatheringEvents)
    wipe(self.fishingTotals)
    wipe(self.gatheringTotals)
    wipe(self.craftedEvents)
    wipe(self.craftedTotals)
    self.craftedSince = time()
    for i = 1, #GATHER_KEYS do
        self.gatheringTotals[GATHER_KEYS[i]] = {}
    end
    self._sessionClock = nil
    if ArtisanNexus and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
end

--- Clear in-memory session data for one tab only (fishing or one gathering profession).
---@param tabKey "fishing"|"herb"|"mine"|"leather"|"disenchant"|"others"|"crafted"
function SessionLootService:ResetSessionForTab(tabKey)
    if self._sessionClock and tabKey then
        self._sessionClock[tabKey] = nil
    end
    if tabKey == "fishing" then
        wipe(self.fishingEvents)
        wipe(self.fishingTotals)
        if self.referenceGlow then
            self.referenceGlow["fishing"] = nil
        end
    elseif tabKey == "crafted" then
        wipe(self.craftedEvents)
        wipe(self.craftedTotals)
        self.craftedSince = time()
        if self.referenceGlow then
            self.referenceGlow["crafted"] = nil
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

local function PushFront(list, maxLen, entry)
    table.insert(list, 1, entry)
    while #list > maxLen do
        table.remove(list)
    end
end

---@param itemID number
---@param qty number
---@param opts table|nil `{ quiet = true, boutStartAt = GetTime() }` quiet defers tab signals
--- (caller emits one batch via `EmitFishingLootTabSignal`).
---@return boolean accepted
function SessionLootService:PushFishingSession(itemID, qty, opts)
    itemID = tonumber(itemID)
    qty = tonumber(qty)
    if not itemID or not qty or qty < 1 then
        return false
    end
    if not (ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID)) then
        return false
    end
    opts = opts or {}
    local accepted = self:AddFishingEvent(itemID, qty, opts.quiet)
    if accepted then
        self:TickSessionClock("fishing", opts.boutStartAt)
    end
    return accepted
end

---@return boolean accepted
function SessionLootService:AddFishingEvent(itemID, qty, quiet)
    itemID = tonumber(itemID)
    qty = tonumber(qty)
    if not itemID or not qty or qty < 1 then
        return false
    end
    local now = GetTime()
    self.fishingTotals[itemID] = (self.fishingTotals[itemID] or 0) + qty
    local wallT = time()
    PushFront(self.fishingEvents, self:GetSessionListBufferCap(), {
        itemID = itemID,
        qty = qty,
        t = wallT,
        rt = now,
    })
    if ArtisanNexus and ArtisanNexus.db then
        local odb = ArtisanNexus.db.global.overallFishingEvents
        if type(odb) == "table" then
            table.insert(odb, 1, StampOverallRow({ itemID = itemID, qty = qty, t = wallT }))
            TrimOverallPerChar(odb, self:GetOverallEventsCap())
        end
    end
    self:AddReferenceGlow(itemID, "fishing")
    if not quiet then
        self:EmitFishingLootTabSignal()
    end
    return true
end

---@param itemID number
---@param qty number
---@param cat "herb"|"mine"|"leather"|"disenchant"|"others"|string
--- Prefer this from loot services so chat+window do not duplicate Last Loot / session totals.
---@param itemID number
---@param qty number
---@param cat string|nil
---@param opts table|nil `{ quiet = true, boutStartAt = GetTime() }` quiet during a chat batch
--- (caller calls `EmitGatheringLootTabSignal`).
---@return boolean accepted false when validated out — callers
--- (GatheringLootService.RecordItem) must NOT bump history DB counts on false,
--- or the Overall grid and the event/earnings rows diverge.
function SessionLootService:PushGatheringSession(itemID, qty, cat, opts)
    if not itemID or not qty or qty < 1 then
        return false
    end
    if not cat or not VALID_GATHER_CAT[cat] then
        return false
    end
    if not (ns.IsGatheringCatalogItem and ns.IsGatheringCatalogItem(itemID)) then
        return false
    end
    if ns.ItemListedInGatheringTab then
        if not ns.ItemListedInGatheringTab(itemID, cat) then
            return false
        end
    elseif ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID) ~= cat then
        return false
    end
    opts = opts or {}
    local accepted = self:AddGatheringEvent(itemID, qty, cat, opts.quiet)
    if accepted then
        self:TickSessionClock(cat, opts.boutStartAt)
    end
    return accepted
end

---@param quiet boolean|nil when true, no tab bump / `SESSION_LOOT_UPDATED` (batched emit by caller).
---@return boolean accepted
function SessionLootService:AddGatheringEvent(itemID, qty, cat, quiet)
    if not itemID or not qty or qty < 1 then
        return false
    end
    if not cat or not VALID_GATHER_CAT[cat] then
        return false
    end
    local now = GetTime()
    if not self.gatheringTotals[cat] then
        self.gatheringTotals[cat] = {}
    end
    local gt = self.gatheringTotals[cat]
    gt[itemID] = (gt[itemID] or 0) + qty
    local wallT = time()
    PushFront(self.gatheringEvents, self:GetSessionListBufferCap(), {
        itemID = itemID,
        qty = qty,
        t = wallT,
        cat = cat,
        rt = now,
    })
    if ArtisanNexus and ArtisanNexus.db then
        local odb = ArtisanNexus.db.global.overallGatheringEvents
        if type(odb) == "table" then
            table.insert(odb, 1, StampOverallRow({ itemID = itemID, qty = qty, t = wallT, cat = cat }))
            TrimOverallPerChar(odb, self:GetOverallEventsCap())
        end
    end
    self:AddReferenceGlow(itemID, cat)
    if quiet then
        return true
    end
    self:EmitGatheringTabSwitchOrAttention(cat)
    return true
end

---@param itemID number
---@param qty number
---@param meta table|nil `{ spellID, profession, quality, isCrit }`
---@param opts table|nil `{ quiet = true }`
--- De-duplication is per operationID upstream (CraftLootService); no time window here, so
--- fast "Craft All" repeats and separate bonusCraft results are all credited.
function SessionLootService:PushCraftedSession(itemID, qty, meta, opts)
    itemID = tonumber(itemID)
    qty = tonumber(qty)
    if not itemID or not qty or qty < 1 then
        return
    end
    opts = opts or {}
    self:AddCraftedEvent(itemID, qty, meta, opts.quiet)
    self:TickSessionClock("crafted", opts.boutStartAt)
end

---@param meta table|nil
---@param quiet boolean|nil
function SessionLootService:AddCraftedEvent(itemID, qty, meta, quiet)
    itemID = tonumber(itemID)
    qty = tonumber(qty)
    if not itemID or not qty or qty < 1 then
        return
    end
    local now = GetTime()
    self.craftedTotals[itemID] = (self.craftedTotals[itemID] or 0) + qty
    local wallT = time()
    local spellID = meta and tonumber(meta.spellID) or nil
    local profession = meta and meta.profession or nil
    PushFront(self.craftedEvents, self:GetSessionListBufferCap(), {
        itemID = itemID,
        qty = qty,
        t = wallT,
        rt = now,
        spellID = spellID,
        profession = profession,
        quality = meta and meta.quality,
        isCrit = meta and meta.isCrit,
    })
    if ArtisanNexus and ArtisanNexus.db then
        local odb = ArtisanNexus.db.global.overallCraftedEvents
        if type(odb) == "table" then
            table.insert(odb, 1, StampOverallRow({
                itemID = itemID,
                qty = qty,
                t = wallT,
                spellID = spellID,
                profession = profession,
            }))
            TrimOverallPerChar(odb, self:GetOverallEventsCap())
        end
        self:CreditLootHistory("craftedLootHistory", itemID, qty, nil)
    end
    self:AddReferenceGlow(itemID, "crafted")
    if quiet then
        return
    end
    self:EmitCraftedLootTabSignal()
    if E and E.CRAFT_LOOT_RECORDED and ArtisanNexus and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.CRAFT_LOOT_RECORDED, {
            itemID = itemID,
            qty = qty,
            spellID = spellID,
            profession = profession,
        })
    end
end

--- Per-character GROSS value of everything recorded on one Loot History tab, from the
--- uncapped history `byChar` split, priced at the CURRENT market (ns.GetLootValueCopper —
--- same helper as the grid, rows and overlay). Crafted value is output value, not profit.
---@param tabKey "fishing"|"crafted"|"herb"|"mine"|"leather"|"disenchant"|"others"
---@return table[] rows sorted by copper desc: { guid|nil, label, copper, qty }
function SessionLootService:GetPerCharacterEarnings(tabKey)
    local out, byKey = {}, {}
    local g = ArtisanNexus and ArtisanNexus.db and ArtisanNexus.db.global
    if not g then
        return out
    end
    local hist, gatherCat
    if tabKey == "fishing" then
        hist = g.fishingLootHistory
    elseif tabKey == "crafted" then
        hist = g.craftedLootHistory
    elseif tabKey and VALID_GATHER_CAT[tabKey] then
        hist, gatherCat = g.gatheringLootHistory, tabKey
    end
    if type(hist) ~= "table" then
        return out
    end
    local valueFn = ns.GetLootValueCopper
    for rawId, row in pairs(hist) do
        local itemID = tonumber(rawId)
        local listed = true
        if gatherCat and itemID then
            if ns.ItemListedInGatheringTab then
                listed = ns.ItemListedInGatheringTab(itemID, gatherCat)
            else
                listed = ns.GetGatheringCategoryForItemId and ns.GetGatheringCategoryForItemId(itemID) == gatherCat
            end
        end
        if itemID and listed and type(row) == "table" then
            local split = row.byChar
            if type(split) ~= "table" then
                split = { [UNKNOWN_CHAR_KEY] = tonumber(row.count) or 0 }
            end
            for key, q in pairs(split) do
                q = tonumber(q) or 0
                if q > 0 then
                    local rec = byKey[key]
                    if not rec then
                        rec = { guid = (key ~= UNKNOWN_CHAR_KEY) and key or nil, copper = 0, qty = 0 }
                        byKey[key] = rec
                        out[#out + 1] = rec
                    end
                    rec.qty = rec.qty + q
                    rec.copper = rec.copper + ((valueFn and (valueFn(itemID, q))) or 0)
                end
            end
        end
    end
    local u = ns.Utilities
    for i = 1, #out do
        local rec = out[i]
        if rec.guid and u and u.GetCharacterDisplayName then
            rec.label = u:GetCharacterDisplayName(rec.guid)
        else
            rec.label = (ns.L and ns.L["CHAR_UNKNOWN"]) or "Unknown character"
        end
    end
    table.sort(out, function(a, b)
        return a.copper > b.copper
    end)
    return out
end

---@param kind "fishing"|"gathering"|"crafted"
---@param gatherCategory string|nil
---@param overall boolean|nil true = read from persistent db.global lists
---@return table[] events (newest first, capped for UI)
function SessionLootService:GetRecentEvents(kind, gatherCategory, overall)
    local cap = self:GetMaxRecentLoot()
    if overall then
        if not ArtisanNexus or not ArtisanNexus.db then return {} end
        if kind == "fishing" then
            local odb = ArtisanNexus.db.global.overallFishingEvents or {}
            local out = {}
            for i = 1, math.min(cap, #odb) do
                out[i] = odb[i]
            end
            return out
        end
        if kind == "crafted" then
            local odb = ArtisanNexus.db.global.overallCraftedEvents or {}
            local out = {}
            for i = 1, math.min(cap, #odb) do
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
                if #out >= cap then break end
            end
        end
        return out
    end
    if kind == "fishing" then
        local out = {}
        for i = 1, math.min(cap, #self.fishingEvents) do
            out[i] = self.fishingEvents[i]
        end
        return out
    end
    if kind == "crafted" then
        local out = {}
        for i = 1, math.min(cap, #(self.craftedEvents or {})) do
            out[i] = self.craftedEvents[i]
        end
        return out
    end
    local out = {}
    for i = 1, #self.gatheringEvents do
        local e = self.gatheringEvents[i]
        if e and e.cat == gatherCategory then
            out[#out + 1] = e
            if #out >= cap then
                break
            end
        end
    end
    return out
end

--- Per–item-ID quantities (for reference totals). Not split by event.
---@param kind "fishing"|"gathering"|"crafted"
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
        if kind == "crafted" then
            local db = ArtisanNexus.db.global.craftedLootHistory or {}
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
    if kind == "crafted" then
        return self.craftedTotals or {}
    end
    if not gatherCategory or not VALID_GATHER_CAT[gatherCategory] then
        return {}
    end
    if not self.gatheringTotals[gatherCategory] then
        self.gatheringTotals[gatherCategory] = {}
    end
    return self.gatheringTotals[gatherCategory]
end

---@param kind "fishing"|"gathering"|"crafted"
---@param gatherCategory string|nil required when kind is gathering
function SessionLootService:ResetOverall(kind, gatherCategory)
    if not ArtisanNexus or not ArtisanNexus.db then return end
    local g = ArtisanNexus.db.global
    if kind == "fishing" then
        wipe(g.overallFishingEvents or {})
        g.overallFishingEvents = {}
        wipe(g.fishingLootHistory or {})
        g.fishingLootHistory = {}
    elseif kind == "crafted" then
        wipe(g.overallCraftedEvents or {})
        g.overallCraftedEvents = {}
        wipe(g.craftedLootHistory or {})
        g.craftedLootHistory = {}
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
    wipe(g.overallCraftedEvents or {})
    g.overallCraftedEvents = {}
    wipe(g.craftedLootHistory or {})
    g.craftedLootHistory = {}
    if ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
end

--- Newest-first session pickups merged across fishing, gathering, and crafted.
--- Each row includes `tabKey` for mixed-tab overlay / list drawing.
---@param maxN number|nil defaults to GetMaxRecentLoot()
---@return table[]
function SessionLootService:GetMergedRecentSessionEvents(maxN)
    maxN = tonumber(maxN)
    if not maxN or maxN < 1 then
        maxN = self:GetMaxRecentLoot()
    else
        maxN = math.floor(maxN + 0.5)
    end
    local scratch = {}
    local function pushEvent(e, tabKey)
        if not e or not e.itemID then
            return
        end
        scratch[#scratch + 1] = {
            itemID = e.itemID,
            qty = e.qty or 1,
            rt = e.rt or 0,
            t = e.t,
            cat = e.cat,
            spellID = e.spellID,
            profession = e.profession,
            tabKey = tabKey or e.cat or "fishing",
        }
    end
    for i = 1, #(self.fishingEvents or {}) do
        pushEvent(self.fishingEvents[i], "fishing")
    end
    for i = 1, #(self.craftedEvents or {}) do
        pushEvent(self.craftedEvents[i], "crafted")
    end
    for i = 1, #(self.gatheringEvents or {}) do
        local e = self.gatheringEvents[i]
        pushEvent(e, e and e.cat)
    end
    table.sort(scratch, function(a, b)
        return (a.rt or 0) > (b.rt or 0)
    end)
    local out = {}
    for i = 1, math.min(maxN, #scratch) do
        out[i] = scratch[i]
    end
    return out
end

ns.SessionLootService = SessionLootService
