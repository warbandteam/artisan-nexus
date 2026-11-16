--[[
    Artisan Nexus - Capabilities  [port of Warband Nexus Modules/Capabilities.lua]

    One place that answers "does this client actually have system X?".

    WoW Forever (game type camelot/forever, interface 16001) runs the Mainline UI, so a retail-only
    namespace can still EXIST there while the system behind it does not: C_CraftingOrders,
    C_ProfSpecs and C_TradeSkillUI.GetConcentrationCurrencyID are all present in the Forever API
    documentation. Branching on `if C_CraftingOrders then` would therefore open an empty Orders tab
    instead of hiding it. Callers ask `ns.Capabilities:Supports(key)` (or
    `ArtisanNexus:SupportsFeature(key)`); nothing else reads WOW_PROJECT_ID for feature gating.

    Retail is the client the addon was built for, so every capability is true there and the
    Forever table only applies on Forever.
]]

local ADDON_NAME, ns = ...

local M = {}
ns.Capabilities = M

local pcall, type, select, pairs, tostring = pcall, type, select, pairs, tostring

--- Feature keys, all true on retail.
local FEATURES = {
    "concentration",       -- concentration currency, planner tab, overflow alerts
    "professionKnowledge", -- Dragonflight-style knowledge points / specialization trees (C_ProfSpecs)
    "craftingOrders",      -- crafter orders (C_CraftingOrders), Orders tab
    "warbandBank",         -- account bank tabs and account money
    "overload",            -- Midnight gathering node overload (node templates, HUD, secure button)
}

local caps = {}
local resolved = false
local warnedUnknown = {}

--- True when this client is WoW Forever. WOW_PROJECT_CAMELOT is 18 (added in build 70170); the
--- interface-version band is the fallback for a build that predates the constant.
local function IsForeverClient()
    if WOW_PROJECT_ID and WOW_PROJECT_CAMELOT and WOW_PROJECT_ID == WOW_PROJECT_CAMELOT then
        return true
    end
    -- `local a = cond and GetBuildInfo()` would drop everything past the first return value.
    local ok, iv = pcall(function() return (select(4, GetBuildInfo())) end)
    if ok and type(iv) == "string" then iv = tonumber(iv) end
    return (ok and type(iv) == "number" and iv >= 16000 and iv < 20000) or false
end
M.IsForeverClient = IsForeverClient

--[[
    What Forever has, from Warband Nexus' measurements on the live client (build 1.60.1.70790,
    interface 16001; WN docs/forever-api-reference.md). Static on purpose: several of these calls
    answer from CHARACTER state, so a live probe at an unlucky moment would switch a feature off.
    Re-check with `/an caps` after a Forever patch.
]]
local FOREVER_SUPPORT = {
    concentration       = false, -- GetConcentrationCurrencyID raised
    professionKnowledge = false, -- GetChildProfessionInfos table(0): no spec tree
    craftingOrders      = false, -- GetCrafterOrders table(0)
    warbandBank         = false, -- C_Bank.CanViewBank(Account) false
    -- Overload is a Midnight gathering mechanic keyed by Midnight node object templates
    -- (Data/GatheringNodeOverloadRegistry); Forever's world is Kalimdor + Eastern Kingdoms.
    overload            = false,
}

local function ResolveForever()
    for key, supported in pairs(FOREVER_SUPPORT) do
        caps[key] = supported
    end
end

--- Resolve once. `force` re-resolves.
function M:Resolve(force)
    if resolved and not force then return end
    local forever = IsForeverClient()
    M.isForever = forever
    for i = 1, #FEATURES do
        caps[FEATURES[i]] = true
    end
    if forever then
        local ok = pcall(ResolveForever)
        if not ok and ns.DebugPrint then
            ns.DebugPrint("|cffffff00[AN]|r capability resolve failed")
        end
    end
    resolved = true
end

--- The question every caller asks. Unknown keys answer true: a capability nobody declared is not a
--- reason to hide working UI.
function M:Supports(key)
    if not resolved then M:Resolve() end
    local v = caps[key]
    if v == nil then
        if ns.DebugPrint and not warnedUnknown[key] then
            warnedUnknown[key] = true
            ns.DebugPrint("|cffffff00[AN]|r capability not declared, defaulting to on: " .. tostring(key))
        end
        return true
    end
    return v
end

--- Service-side shorthand (no addon object needed): `ns.SupportsFeature("warbandBank")`.
function ns.SupportsFeature(key)
    return M:Supports(key)
end

--- Snapshot for `/an caps`, ordered so the output is stable.
function M:Snapshot()
    if not resolved then M:Resolve() end
    local out = {}
    for i = 1, #FEATURES do
        out[i] = { key = FEATURES[i], value = caps[FEATURES[i]] and true or false }
    end
    return out, M.isForever and true or false
end

--[[
    Deep probe (`/an caps`). A present namespace is not a present system on Forever, so this walks
    the real calls once and prints what they RETURN. Read-only, pcall around every call, run by
    hand -- never on the login path. It also covers the facts the Forever build relies on that
    still need an in-game check (bag indices, GetProfessions shape, commodity AH).
]]
local function Count(v)
    if type(v) ~= "table" then return nil end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    return n
end

local function Try(label, fn)
    local ok, a, b = pcall(fn)
    if not ok then return label, "|cffff6060error|r" end
    if a == nil then return label, "|cffaaaaaanil|r" end
    local c = Count(a)
    if c ~= nil then
        return label, (c > 0 and "|cff40ff40" or "|cffff6060") .. "table(" .. c .. ")|r"
    end
    if type(a) == "boolean" then
        return label, (a and "|cff40ff40true|r" or "|cffff6060false|r")
    end
    return label, "|cff40ff40" .. tostring(a) .. "|r" .. (b ~= nil and (" , " .. tostring(b)) or "")
end

--- Returns an ordered {label, text} list. Nothing here is cached or acted on.
function M:DeepProbe()
    local rows = {}
    local function add(label, fn) local l, v = Try(label, fn); rows[#rows + 1] = { l, v } end

    add("interface", function() return (select(4, GetBuildInfo())) end)
    add("projectID", function() return WOW_PROJECT_ID end)
    add("maxPlayerLevel", function() return GetMaxPlayerLevel() end)
    add("prof.numReturns", function() return select("#", GetProfessions()) end)
    add("prof.returns", function()
        local t = { GetProfessions() }
        local parts = {}
        for i = 1, select("#", GetProfessions()) do parts[i] = tostring(t[i]) end
        return table.concat(parts, ", ")
    end)
    add("prof.childInfos", function() return C_TradeSkillUI.GetChildProfessionInfos() end)
    add("prof.concentration", function() return C_TradeSkillUI.GetConcentrationCurrencyID() end)
    add("prof.inventorySlots", function() return C_TradeSkillUI.GetProfessionInventorySlots() end)
    add("craftingOrders", function() return C_CraftingOrders.GetCrafterOrders() end)
    add("bag.keyring", function() return Enum.BagIndex.Keyring end)
    add("bag.reagentBag", function() return Enum.BagIndex.ReagentBag end)
    add("bag.charBankTab1", function() return Enum.BagIndex.CharacterBankTab_1 end)
    add("bag.accountBankTab1", function() return Enum.BagIndex.AccountBankTab_1 end)
    add("bag.reagentBagSlots", function() return C_Container.GetContainerNumSlots(5) end)
    add("bank.canViewAccount", function() return C_Bank.CanViewBank(Enum.BankType.Account) end)
    add("ah.copperValues", function() return C_AuctionHouse.SupportsCopperValues() end)
    add("loot.sourceInfo", function() return type(GetLootSourceInfo) == "function" end)
    add("secretValues", function() return type(issecretvalue) == "function" end)
    return rows
end
