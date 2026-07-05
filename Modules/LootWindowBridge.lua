--[[
    Loot window lifecycle hook — resets per-open dedup snapshots only.
    Gathering and fishing loot are recorded from CHAT_MSG_LOOT (see *LootService).
]]

local ADDON_NAME, ns = ...

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

local bridge = CreateFrame("Frame")
bridge:RegisterEvent("LOOT_OPENED")
bridge:SetScript("OnEvent", function(_, event)
    if event == "LOOT_OPENED" then
        ResetLootWindowSnapshots()
    end
end)

ns.LootWindowBridge = bridge
