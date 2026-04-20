--[[
    Blizzard loot window → same stacks as on-screen Loot / Fishing Loot.
    Retries: LOOT_READY / LOOT_OPENED / LOOT_CLOSED / LOOT_SLOT_CHANGED fire at different times per client.
]]

local ADDON_NAME, ns = ...

local lastSig
local lastSigTime = 0

local function Signature(counts)
    local keys = {}
    for k in pairs(counts) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local s = ""
    for i = 1, #keys do
        local k = keys[i]
        s = s .. tostring(k) .. "=" .. tostring(counts[k]) .. "&"
    end
    return s
end

local function ResetLootWindowSnapshots()
    local g = ns.GatheringLootService
    if g and g.ResetWindowCountSnapshot then
        g:ResetWindowCountSnapshot()
    end
    local f = ns.FishingLootService
    if f and f.ResetWindowCountSnapshot then
        f:ResetWindowCountSnapshot()
    end
end

local function TryScanFromWindow()
    local get = ns.GetLootSlotItemCounts
    if not get then
        return
    end
    local counts = get()
    if not counts then
        return
    end
    --- Empty {} is required so delta logic sees items leave the window (loot claimed).
    --- Skipping empty snapshots prevented matching chat totals.

    local now = GetTime()
    --- Non-empty: dedupe identical snapshots from multi-timer retries. Empty {} must always run so
    --- gathering delta sees items leave the window (signature is always "" — would block mining after fishing).
    if next(counts) then
        local sig = Signature(counts)
        if sig == lastSig and (now - lastSigTime) < 0.85 then
            return
        end
        lastSig, lastSigTime = sig, now
    end

    local fish = ns.FishingLootService
    if fish and fish.ShouldAttributeLootToFishing and fish:ShouldAttributeLootToFishing() and fish.RecordWindowLootCounts then
        fish.RecordWindowLootCounts(counts)
        return
    end

    local gath = ns.GatheringLootService
    if gath and gath.ShouldAttributeLootWindowScan and gath:ShouldAttributeLootWindowScan() and gath.RecordWindowLootCounts then
        gath.RecordWindowLootCounts(counts)
    end
end

local function ScheduleScans()
    local delays = { 0, 0.04, 0.1, 0.22, 0.45, 0.75, 1.1 }
    for i = 1, #delays do
        C_Timer.After(delays[i], TryScanFromWindow)
    end
end

local bridge = CreateFrame("Frame")
bridge:RegisterEvent("LOOT_READY")
bridge:RegisterEvent("LOOT_OPENED")
bridge:RegisterEvent("LOOT_CLOSED")
bridge:RegisterEvent("LOOT_SLOT_CHANGED")
bridge:SetScript("OnEvent", function(_, event)
    if event == "LOOT_OPENED" then
        ResetLootWindowSnapshots()
    end
    ScheduleScans()
    if event == "LOOT_CLOSED" then
        C_Timer.After(0.02, TryScanFromWindow)
    end
end)

ns.LootWindowBridge = bridge
