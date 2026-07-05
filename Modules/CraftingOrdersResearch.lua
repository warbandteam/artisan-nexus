--[[
    R&D stub for Midnight crafting orders APIs (C_CraftingOrders).
]]

local ADDON_NAME, ns = ...

local CraftingOrdersResearch = {}

function CraftingOrdersResearch:Probe()
    local out = { available = false, apis = {} }
    if not C_CraftingOrders then
        out.note = "C_CraftingOrders namespace missing on this client."
        return out
    end
    out.available = true
    local candidates = {
        "RequestOpenOrders",
        "GetCrafterOrders",
        "GetClaimedOrder",
        "GetPersonalOrdersInfo",
    }
    for i = 1, #candidates do
        local name = candidates[i]
        out.apis[name] = C_CraftingOrders[name] ~= nil
    end
    out.note = "Research stub only — no order UI wired yet."
    return out
end

function CraftingOrdersResearch:PrintProbe()
    local AN = ns.ArtisanNexus
    if not AN or not AN.Print then
        return
    end
    local r = self:Probe()
    AN:Print(string.format("CraftingOrders API: %s", r.available and "present" or "missing"))
    if r.note then
        AN:Print(r.note)
    end
end

ns.CraftingOrdersResearch = CraftingOrdersResearch
