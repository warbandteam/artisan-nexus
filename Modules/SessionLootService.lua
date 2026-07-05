--[[
    Session UI: last N discrete loot events + per–item-ID totals for reference grid.
    Fishing: FIFO newest-first list. Gathering: same, tagged by category (herb/mine/leather/dis).

    Each gathering line stores `cat` from the reference catalog only (`PushGatheringSession` rejects
    itemID/`cat` mismatch) so profession slices never mix in the event list.

    Duplicate suppression: only `SessionLootService:AddFishingEvent` / `AddGatheringEvent` append to
    these lists. Dedupe scans several newest rows so interleaved pickups do not slip past [1]-only checks.
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

--- Non-active tabs pulse briefly when that profession’s **catalog** loot is recorded (multi-tab pickups).
local TAB_ATTENTION_SEC = 5.2

--- Same pickup fired twice in one loot resolution (window + chat or double bridge scan).
--- Must compare several recent rows: if another item was pushed in between, [1] is no longer the duplicate.
local DUPLICATE_GATHERING_EVENT_SEC = 1.5
--- Fishing: collapse window + CHAT_MSG_LOOT for the same catch (often 0.5–2s apart; 0.55 was too narrow — double `sess_pushed`).
--- Two distinct 1× catches of the same species faster than this may merge one line (rare).
--- Fishing uses `CHAT_MSG_LOOT` + short raw-message dedup; no itemID+qty time suppression (that hid back-to-back catches).
local DUPLICATE_FISHING_EVENT_SEC = 0
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
    ---@type table[] { itemID = number, qty = number, t = number, spellID = number|nil, profession = string|nil }
    craftedEvents = {},
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
        SessionLootService:ResetSession()
    end
end)

--- Stamp persisted overall rows with character GUID (`ck`) and unit copper at
--- record time (`v`) — earnings stay attributable and computable after prices
--- move or the character is renamed/transferred (GUID is the stable key).
local function StampOverallRow(row, itemID)
    local u = ns.Utilities
    local guid = u and u.GetCharacterGUID and u:GetCharacterGUID()
    if guid then
        row.ck = guid
    end
    if ns.GetLootUnitPriceCopper then
        local v = tonumber((ns.GetLootUnitPriceCopper(itemID)))
        if v and v > 0 then
            row.v = v
        end
    end
    return row
end

--- Trim newest-first overall lists per character: each `ck` bucket keeps up to
--- `cap` rows, so one active character can no longer evict offline characters'
--- records. Legacy unkeyed rows share the "unknown" bucket.
local function TrimOverallPerChar(odb, cap)
    if #odb <= cap then
        return
    end
    local counts = {}
    local i = 1
    while i <= #odb do
        local row = odb[i]
        local key = (row and row.ck) or "unknown"
        local c = (counts[key] or 0) + 1
        counts[key] = c
        if c > cap then
            table.remove(odb, i)
        else
            i = i + 1
        end
    end
end

--- In-memory event lists keep extra tail rows for duplicate scans (newest-first).
function SessionLootService:GetSessionListBufferCap()
    return math.max(40, self:GetMaxRecentLoot() + DUPLICATE_SCAN_DEPTH + 10)
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
    for i = 1, #GATHER_KEYS do
        self.gatheringTotals[GATHER_KEYS[i]] = {}
    end
    if ArtisanNexus and ArtisanNexus.SendMessage then
        ArtisanNexus:SendMessage(E.SESSION_LOOT_UPDATED)
        ArtisanNexus:SendMessage(E.LOOT_HISTORY_UPDATED)
    end
end

--- Clear in-memory session data for one tab only (fishing or one gathering profession).
---@param tabKey "fishing"|"herb"|"mine"|"leather"|"disenchant"|"others"|"crafted"
function SessionLootService:ResetSessionForTab(tabKey)
    if tabKey == "fishing" then
        wipe(self.fishingEvents)
        wipe(self.fishingTotals)
        if self.referenceGlow then
            self.referenceGlow["fishing"] = nil
        end
    elseif tabKey == "crafted" then
        wipe(self.craftedEvents)
        wipe(self.craftedTotals)
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
    if not windowSec or windowSec <= 0 then
        return false
    end
    itemID = tonumber(itemID) or itemID
    qty = tonumber(qty) or qty
    local limit = math.min(DUPLICATE_SCAN_DEPTH, #events)
    for i = 1, limit do
        local e = events[i]
        local eid = e and tonumber(e.itemID)
        local eq = e and tonumber(e.qty)
        if e and eid and eid == itemID and eq == qty and e.rt and (now - e.rt) < windowSec then
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
    itemID = tonumber(itemID)
    qty = tonumber(qty)
    if not itemID or not qty or qty < 1 then
        return
    end
    if not (ns.IsFishingCatalogItem and ns.IsFishingCatalogItem(itemID)) then
        return
    end
    opts = opts or {}
    self:AddFishingEvent(itemID, qty, opts.quiet)
end

--- True when `RecordItem` would duplicate the newest pickup line (DB must not increment before this check).
---@param itemID number
---@param qty number
---@return boolean
function SessionLootService:IsDuplicateFishingPickup(itemID, qty)
    itemID = tonumber(itemID)
    qty = tonumber(qty)
    if not itemID or not qty or qty < 1 then
        return true
    end
    return IsDuplicateFishingLine(self.fishingEvents, itemID, qty, GetTime(), DUPLICATE_FISHING_EVENT_SEC)
end

function SessionLootService:AddFishingEvent(itemID, qty, quiet)
    itemID = tonumber(itemID)
    qty = tonumber(qty)
    if not itemID or not qty or qty < 1 then
        return
    end
    local now = GetTime()
    if self:IsDuplicateFishingPickup(itemID, qty) then
        return
    end
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
            table.insert(odb, 1, StampOverallRow({ itemID = itemID, qty = qty, t = wallT }, itemID))
            TrimOverallPerChar(odb, self:GetOverallEventsCap())
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
---@return boolean accepted false when validated out or dedup-dropped — callers
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
    return self:AddGatheringEvent(itemID, qty, cat, opts.quiet)
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
    if IsDuplicateGatheringLine(self.gatheringEvents, itemID, qty, cat, now, DUPLICATE_GATHERING_EVENT_SEC) then
        return false
    end
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
            table.insert(odb, 1, StampOverallRow({ itemID = itemID, qty = qty, t = wallT, cat = cat }, itemID))
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

local function IsDuplicateCraftedLine(events, itemID, qty, now, windowSec)
    itemID = tonumber(itemID)
    qty = tonumber(qty)
    if not itemID or not qty then
        return true
    end
    local limit = math.min(DUPLICATE_SCAN_DEPTH, #events)
    for i = 1, limit do
        local e = events[i]
        if e and tonumber(e.itemID) == itemID and tonumber(e.qty) == qty and e.rt and (now - e.rt) < windowSec then
            return true
        end
    end
    return false
end

---@param itemID number
---@param qty number
---@param meta table|nil `{ spellID, profession, quality, isCrit }`
---@param opts table|nil `{ quiet = true }`
function SessionLootService:PushCraftedSession(itemID, qty, meta, opts)
    itemID = tonumber(itemID)
    qty = tonumber(qty)
    if not itemID or not qty or qty < 1 then
        return
    end
    opts = opts or {}
    self:AddCraftedEvent(itemID, qty, meta, opts.quiet)
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
    if IsDuplicateCraftedLine(self.craftedEvents, itemID, qty, now, DUPLICATE_GATHERING_EVENT_SEC) then
        return
    end
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
            }, itemID))
            TrimOverallPerChar(odb, self:GetOverallEventsCap())
        end
        local hist = ArtisanNexus.db.global.craftedLootHistory
        if type(hist) == "table" then
            local row = hist[itemID]
            if type(row) ~= "table" then
                row = { count = 0, lastAt = wallT }
                hist[itemID] = row
            end
            row.count = (row.count or 0) + qty
            row.lastAt = wallT
        end
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

--- Per-character earnings computed from persisted overall event rows.
--- Legacy rows without `ck` group under the "unknown" bucket; rows without a
--- recorded `v` fall back to the current unit price estimate.
---@return table[] rows sorted by copper desc: { guid|nil, label, copper, qty }
function SessionLootService:GetPerCharacterEarnings()
    local out, byKey = {}, {}
    local db = ArtisanNexus and ArtisanNexus.db
    if not db or not db.global then
        return out
    end
    local g = db.global
    local lists = { g.overallFishingEvents, g.overallGatheringEvents, g.overallCraftedEvents }
    for li = 1, #lists do
        local odb = lists[li]
        if type(odb) == "table" then
            for i = 1, #odb do
                local row = odb[i]
                local qty = row and tonumber(row.qty)
                if row and row.itemID and qty and qty > 0 then
                    local key = row.ck or "unknown"
                    local rec = byKey[key]
                    if not rec then
                        rec = { guid = row.ck, copper = 0, qty = 0 }
                        byKey[key] = rec
                        out[#out + 1] = rec
                    end
                    local unit = tonumber(row.v)
                    if not unit and ns.GetLootUnitPriceCopper then
                        unit = tonumber((ns.GetLootUnitPriceCopper(row.itemID)))
                    end
                    rec.qty = rec.qty + qty
                    rec.copper = rec.copper + ((unit or 0) * qty)
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
            rec.label = (ns.L and ns.L["CHAR_UNKNOWN"]) or "Unknown"
        end
    end
    table.sort(out, function(a, b)
        return a.copper > b.copper
    end)
    return out
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

---@deprecated Kept for accidental callers — returns empty (UI uses GetRecentEvents).
function SessionLootService:GetTable(kind)
    return {}
end

ns.SessionLootService = SessionLootService
