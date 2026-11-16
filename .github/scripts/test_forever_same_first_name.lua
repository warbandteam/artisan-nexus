#!/usr/bin/env lua5.1
--[[
    [port of Warband Nexus test_forever_same_first_name.lua]

    WoW Forever first names are not unique on a realm: "Elementalist Vhorzen" and "Elementalist
    Ashford" share the Name-Realm key Elementalist-<realm>, and GetRealmName can answer "PvE"
    instead of the realm. Artisan Nexus keys every per-character record by GUID; this suite checks
    the pieces that carry the Forever identity rules:

      1. Constants switches to the Forever version and changelog prefix on a Forever client.
      2. Capabilities hides concentration / knowledge / orders / warband bank / overload on Forever
         and keeps everything on retail.
      3. TouchCharRegistry writes one GUID row per character and stores the surname on Forever, so
         two same-first-name characters never share or overwrite a row.
      4. GetCharacterKey puts the surname into the Name-Realm key on Forever (live and row calls) and
         leaves retail keys unchanged; display names carry the surname.
      5. GetProfessionIndices reads every GetProfessions return, holes included.

    Loads the shipped Modules/Constants.lua, Modules/Capabilities.lua and Modules/Utilities.lua
    over a minimal global stub.
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

-- Minimal WoW globals the three files touch at load / in the tested calls.
C_Item = { GetItemInfo = function() end, GetItemInfoInstant = function() end }
C_CurrencyInfo = { GetCoinTextureString = function() return "" end }
issecretvalue = function() return false end
time = os.time
UnitClass = function() return "Shaman", "SHAMAN" end

local cur = {}
UnitGUID = function(u) if u == "player" then return cur.guid end end
UnitName = function() return cur.name, cur.surname end
GetNormalizedRealmName = function() return cur.realm end
GetRealmName = function() return cur.realm end

local function LoadFile(rel, ns)
    local fh = assert(io.open(ROOT .. "/" .. rel, "rb"), "missing " .. rel)
    local src = fh:read("*a"):gsub("^\239\187\191", "")
    fh:close()
    local chunk = assert(loadstring(src, "@" .. rel))
    chunk("ArtisanNexus", ns)
end

--- Fresh namespace per client type: Constants and Capabilities resolve the client at load.
local function NewAddon(forever)
    if forever then
        WOW_PROJECT_CAMELOT = 18
        WOW_PROJECT_ID = 18
        GetBuildInfo = function() return "1.60.1", "70790", "Nov 1 2026", 16001 end
    else
        WOW_PROJECT_CAMELOT = 18
        WOW_PROJECT_ID = 1
        GetBuildInfo = function() return "12.1.5", "70391", "Oct 1 2026", 120105 end
    end
    local ns = { DebugPrint = function() end }
    LoadFile("Modules/Constants.lua", ns)
    LoadFile("Modules/Capabilities.lua", ns)
    LoadFile("Modules/Utilities.lua", ns)
    ns.db = { global = {}, profile = {} }
    -- CharacterDataProvider stand-in: the native registry rows, as GetCharacters exposes them.
    ns.CharacterData = {
        GetCharacter = function(_, guid)
            local rec = ns.db.global.charRegistry and ns.db.global.charRegistry[guid]
            if not rec then return nil end
            return { guid = guid, name = rec.name, realm = rec.realm, surname = rec.surname }
        end,
    }
    return ns
end

local REALM = "CAMWOWEU4Realm5PvE"
local A = { guid = "Player-4001-0A000001", name = "Elementalist", surname = "Vhorzen", realm = REALM }
local B = { guid = "Player-4001-0A000002", name = "Elementalist", surname = "Ashford", realm = REALM }

local function LogIn(c)
    cur.guid, cur.name, cur.surname, cur.realm = c.guid, c.name, c.surname, c.realm
end

print("Phase 1: Forever version switch")
local ns = NewAddon(true)
local C = ns.Constants
check(C.IS_FOREVER_BUILD == true, "Forever client detected")
check(C.ADDON_VERSION == C.FOREVER_ADDON_VERSION, "ADDON_VERSION is the Forever version")
check(C.RETAIL_ADDON_VERSION ~= nil and C.RETAIL_ADDON_VERSION ~= C.ADDON_VERSION, "retail version kept aside")
check(C.CHANGELOG_KEY_PREFIX == "CHANGELOG_FOREVER_V", "changelog prefix is CHANGELOG_FOREVER_V")

print("Phase 2: capabilities")
for _, key in ipairs({ "concentration", "professionKnowledge", "craftingOrders", "warbandBank", "overload" }) do
    check(ns.Capabilities:Supports(key) == false, "Forever hides " .. key)
end
check(ns.Capabilities:Supports("someUndeclaredKey") == true, "undeclared key defaults to on")

print("Phase 3: same first name, two GUID rows")
LogIn(A)
check(ns.Utilities:TouchCharRegistry() == A.guid, "A registers under its GUID")
LogIn(B)
check(ns.Utilities:TouchCharRegistry() == B.guid, "B registers under its own GUID")
local reg = ns.db.global.charRegistry
check(reg[A.guid] and reg[A.guid].surname == "Vhorzen", "A keeps its surname")
check(reg[B.guid] and reg[B.guid].surname == "Ashford", "B keeps its surname")
check(reg[A.guid] ~= reg[B.guid], "A and B never share a row")

print("Phase 4: Name-Realm keys and display names")
LogIn(A)
local keyA = ns.Utilities:GetCharacterKey()
LogIn(B)
local keyB = ns.Utilities:GetCharacterKey()
check(keyA == "ElementalistVhorzen-" .. REALM, "live key carries the surname (" .. tostring(keyA) .. ")")
check(keyA ~= keyB, "same first name, different keys")
check(ns.Utilities:GetCharacterKey("Elementalist", REALM, "Ashford") == keyB, "row call with surname matches live key")
check(ns.Utilities:GetCharacterKey("Elementalist", REALM, nil) == "Elementalist-" .. REALM, "no surname: key unchanged")
check(ns.Utilities:GetCharacterDisplayName(A.guid) == "Elementalist Vhorzen-" .. REALM, "display name shows the surname")

print("Phase 5: retail stays unchanged")
local rns = NewAddon(false)
check(rns.Constants.IS_FOREVER_BUILD == false, "retail client detected")
check(rns.Constants.CHANGELOG_KEY_PREFIX == "CHANGELOG_V", "retail changelog prefix")
check(rns.Constants.ADDON_VERSION == rns.Constants.RETAIL_ADDON_VERSION, "retail version kept")
for _, key in ipairs({ "concentration", "professionKnowledge", "craftingOrders", "warbandBank", "overload" }) do
    check(rns.Capabilities:Supports(key) == true, "retail keeps " .. key)
end
-- Retail UnitName's second value is a realm, never a surname.
cur.guid, cur.name, cur.surname, cur.realm = "Player-1-01", "Superluminal", "OtherRealm", "TwistingNether"
rns.Utilities:TouchCharRegistry()
check(rns.db.global.charRegistry["Player-1-01"].surname == nil, "retail stores no surname")
check(rns.Utilities:GetCharacterKey() == "Superluminal-TwistingNether", "retail live key unchanged")

print("Phase 6: GetProfessions holes")
GetProfessions = function() return 1, nil, 5, nil, 9 end
local idx = ns.Utilities.GetProfessionIndices()
check(#idx == 3 and idx[1] == 1 and idx[2] == 5 and idx[3] == 9, "all non-nil slots, no holes")
GetProfessions = function() return nil, nil, 3, 4, 5, 6, 7 end
idx = ns.Utilities.GetProfessionIndices()
check(#idx == 5 and idx[5] == 7, "more than five returns are read")

print(string.format("Forever same-first-name suite: %d passed, %d failed.", passed, failed))
if failed > 0 then
    error("Forever same-first-name suite failed with " .. failed .. " failure(s).")
end
print("Forever same-first-name suite: ALL TESTS PASSED.")
