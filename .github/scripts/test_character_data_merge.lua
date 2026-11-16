#!/usr/bin/env lua5.1
--[[
    Every character's data, Warband Nexus or not (Modules/Data/CharacterDataProvider.lua).

      1. The native collectors always write the logged-in character's GUID rows, even while Warband
         Nexus serves the reads (registry refresh, item snapshot, learnedBy).
      2. Reads merge: WN rows first, then native rows for every GUID WN does not track, so an alt WN
         does not track is never hidden behind the WN backend (items, recipe knowers).
      3. CaptureProfessions persists charProfessions[guid] and sends CHARACTER_PROFESSIONS_UPDATED only
         when a profession, rank or cap changed.
      4. PurgeCharacter removes one character from every per-character store, keeps the others,
         refuses the logged-in character and sends CHARACTER_PURGED.

    Loads the shipped Constants, Capabilities, Utilities and CharacterDataProvider over a minimal
    global stub with a fake Warband Nexus bridge.
]]

local loadstring = loadstring or load
local ROOT = os.getenv("AN_ROOT") or "."

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then
        passed = passed + 1
        print("  ok   " .. msg)
    else
        failed = failed + 1
        print("  FAIL " .. msg)
    end
end

-- Minimal WoW globals.
C_Item = { GetItemInfo = function() end, GetItemInfoInstant = function() end }
C_CurrencyInfo = { GetCoinTextureString = function() return "" end }
issecretvalue = function() return false end
time = os.time
local clock = 1000
GetTime = function() clock = clock + 10; return clock end -- every read is past the memo window
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
UnitClass = function() return "Mage", "MAGE" end
WOW_PROJECT_ID, WOW_PROJECT_CAMELOT = 1, 18
GetBuildInfo = function() return "12.1.5", "70391", "Oct 1 2026", 120105 end
local timers = {}
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function RunTimers()
    local list = timers
    timers = {}
    for i = 1, #list do list[i]() end
end

local ME, ALT_TRACKED, ALT_UNTRACKED = "Player-1-AAAA", "Player-1-BBBB", "Player-1-CCCC"
UnitGUID = function(u) if u == "player" then return ME end end
UnitName = function() return "Me", nil end
GetNormalizedRealmName = function() return "Realm" end
GetRealmName = GetNormalizedRealmName

local profs = { { "Mining", 186, 50, 75 }, { "Herbalism", 182, 30, 75 } }
GetProfessions = function() return 1, 2 end
GetProfessionInfo = function(i)
    local p = profs[i]
    if not p then return nil end
    return p[1], 134708, p[3], p[4], 0, 0, p[2]
end

Enum = { BagIndex = { Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5,
    CharacterBankTab_1 = 6 } }
local bagItems = { [0] = { { itemID = 1001, stackCount = 7 } } }
C_Container = {
    GetContainerNumSlots = function(bag) return bagItems[bag] and #bagItems[bag] or 0 end,
    GetContainerItemInfo = function(bag, slot) return bagItems[bag] and bagItems[bag][slot] end,
}

local function LoadFile(rel, ns)
    local fh = assert(io.open(ROOT .. "/" .. rel, "rb"), "missing " .. rel)
    local src = fh:read("*a"):gsub("^\239\187\191", "")
    fh:close()
    assert(loadstring(src, "@" .. rel))("ArtisanNexus", ns)
end

local ns = { DebugPrint = function() end }
local sent = {}
ns.ArtisanNexus = { SendMessage = function(_, msg, payload) sent[#sent + 1] = { msg = msg, payload = payload } end }
LoadFile("Modules/Constants.lua", ns)
LoadFile("Modules/Capabilities.lua", ns)
LoadFile("Modules/Utilities.lua", ns)
ns.NewEventOwner = function()
    return {
        RegisterEvent = function() end, RegisterMessage = function() end,
        UnregisterAllEvents = function() end, UnregisterAllMessages = function() end,
    }
end
-- Catalog reads the item snapshot uses (TrackedItemSet).
ns.ResolveCatalogEntryRanks = function() return {} end
ns.GetGatheringCatalogByCategory = function() return {} end
ns.GetFishingCatalogEntries = function() return {} end
ns.db = { global = { recipeSchematics = {} }, profile = {} }
ns.RecipeService = {
    GetCatalogReagentItemIDs = function() return { 1001 } end,
    GetSchematic = function(_, id) return ns.db.global.recipeSchematics[id] end,
}

-- Fake Warband Nexus: tracks ME and ALT_TRACKED, not ALT_UNTRACKED.
ns.WarbandNexusBridge = {
    IsAvailable = function() return true end,
    HasMethod = function() return true end,
    GetCharacters = function()
        return {
            { key = ME, guid = ME, name = "Me", realm = "Realm", isTracked = true },
            { key = ALT_TRACKED, guid = ALT_TRACKED, name = "Tracked", realm = "Realm", isTracked = true },
        }
    end,
    GetDetailedItemCounts = function()
        return { altTotal = 3, altBags = 3, altBanks = 0, warbandBank = 0,
            altDetails = { { name = "Tracked", bagCount = 3, bankCount = 0, total = 3 } } }
    end,
    GetCrafters = function()
        return { { charKey = ALT_TRACKED, charName = "Tracked" } }
    end,
    GetAllConcentrationData = function() return {} end,
}

LoadFile("Modules/Data/CharacterDataProvider.lua", ns)
local CD = ns.CharacterData
local E = ns.Constants.EVENTS
local function SentCount(msg)
    local n = 0
    for i = 1, #sent do if sent[i].msg == msg then n = n + 1 end end
    return n
end

print("Phase 1: native rows are written while Warband Nexus serves the reads")
CD:Enable()
check(CD:GetBackend("items") == "wn", "items read from Warband Nexus")
check(CD:UsesNative("items") and CD:UsesNative("concentration"), "native collectors always run")
check(ns.db.global.charRegistry and ns.db.global.charRegistry[ME] ~= nil, "registry row refreshed on the WN backend")
RunTimers()
local snap = ns.db.global.itemSnapshots
check(snap and snap.chars[ME] and snap.chars[ME].bags[1001] == 7, "item snapshot written on the WN backend")
local row = {}
ns.db.global.recipeSchematics[5001] = row
CD:RecordLearned(row, 5001, true)
check(row.learnedBy and row.learnedBy[ME] == true and row.learned == true, "learnedBy written on the WN backend")

print("Phase 2: untracked alts merged into WN reads")
snap.chars[ALT_TRACKED] = { at = time(), bags = { [1001] = 99 }, bank = {} }
snap.chars[ALT_UNTRACKED] = { at = time(), bags = { [1001] = 4 }, bank = {} }
ns.db.global.charRegistry[ALT_UNTRACKED] = { name = "Untracked", realm = "Realm", lastSeen = time() }
local counts = CD:GetItemCountsAcrossCharacters(1001)
check(counts.total == 7, "WN alt total + untracked native alt (3 + 4), tracked native row not doubled")
local names = {}
for i = 1, #counts.chars do names[counts.chars[i].name] = true end
check(names["Tracked"] and names["Untracked-Realm"], "both alts listed")
check(#counts.chars == 2, "logged-in character not listed as an alt")
row.learnedBy[ALT_UNTRACKED] = true
row.learnedBy[ALT_TRACKED] = true
CD:InvalidateCaches()
local knowers = CD:GetRecipeKnowers(5001)
local byName = {}
for i = 1, #knowers do byName[knowers[i].charName] = (byName[knowers[i].charName] or 0) + 1 end
check(byName["Tracked"] == 1, "WN knower listed once (native row of a tracked GUID skipped)")
check(byName["Untracked-Realm"] == 1, "untracked native knower merged")
check(byName["Me-Realm"] == 1, "logged-in knower from native learnedBy")

print("Phase 3: professions per character")
RunTimers()
local p = CD:GetCharacterProfessions(ME)
check(p and #p.list == 2 and p.list[1].name == "Herbalism" and p.list[2].rank == 50, "professions stored, sorted by skill line")
local before = SentCount(E.CHARACTER_PROFESSIONS_UPDATED)
check(before == 1, "first capture announced")
CD:CaptureProfessions()
check(SentCount(E.CHARACTER_PROFESSIONS_UPDATED) == before, "unchanged capture sends nothing")
profs[1][3] = 51
CD:CaptureProfessions()
check(SentCount(E.CHARACTER_PROFESSIONS_UPDATED) == before + 1, "rank change announced")
check(CD:GetRecipeCountForCharacter(ME) == 1, "recipe count for the logged-in character")

print("Phase 4: forget a character")
local g = ns.db.global
g.charProfessions[ALT_UNTRACKED] = { at = time(), list = {} }
g.professionSnapshots = { [ALT_UNTRACKED] = { [186] = { at = time() } }, [ME] = { [186] = { at = time() } } }
g.recipeCooldowns = { [ALT_UNTRACKED] = { [1] = {} } }
g.salesLedger = { gold = { chars = { [ALT_UNTRACKED] = {}, [ME] = {} } } }
g.ownedAuctions = { chars = { [ALT_UNTRACKED] = {} } }
check(CD:PurgeCharacter(ME) == false and g.charRegistry[ME] ~= nil, "logged-in character is never purged")
check(CD:PurgeCharacter(ALT_UNTRACKED) == true, "untracked alt purged")
check(g.charRegistry[ALT_UNTRACKED] == nil and g.charProfessions[ALT_UNTRACKED] == nil, "registry + professions gone")
check(g.professionSnapshots[ALT_UNTRACKED] == nil and g.professionSnapshots[ME] ~= nil, "snapshots: alt gone, me kept")
check(g.itemSnapshots.chars[ALT_UNTRACKED] == nil and g.itemSnapshots.chars[ALT_TRACKED] ~= nil, "item snapshot: only the alt gone")
check(g.recipeCooldowns[ALT_UNTRACKED] == nil and g.ownedAuctions.chars[ALT_UNTRACKED] == nil, "cooldowns + auctions gone")
check(g.salesLedger.gold.chars[ALT_UNTRACKED] == nil and g.salesLedger.gold.chars[ME] ~= nil, "gold series: only the alt gone")
check(row.learnedBy[ALT_UNTRACKED] == nil and row.learnedBy[ME] == true, "learnedBy: only the alt gone")
check(SentCount(E.CHARACTER_PURGED) == 1, "CHARACTER_PURGED sent once")

print(string.format("Character data merge suite: %d passed, %d failed.", passed, failed))
if failed > 0 then
    error("Character data merge suite failed with " .. failed .. " failure(s).")
end
print("Character data merge suite: ALL TESTS PASSED.")
