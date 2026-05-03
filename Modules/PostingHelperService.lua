--[[
    Artisan Nexus — Auction Posting Helper.

    Suggests a post price for whatever item the player is currently selling
    on the AH, based on:
      * the lowest live commodity / item search result the AH UI shows
      * the 7-day rolling average from PriceHistoryService

    Strategy is configurable via db.profile.posting:
      strategy   = "undercut" | "average" | "max"
      undercutBy = 0.01   (1% under the lowest)
      averageMul = 1.0    (multiplier of the 7d average)
      floorMul   = 0.5    (never post below floorMul * average — anti-self-undercut)

    The actual price-set on the live sell frame is driven by hooking
    Blizzard's CommoditiesSellFrame / ItemSellFrame "PostButton" tooltip
    so the player still confirms; we never auto-post without a click.

    Public API:
      PostingHelperService:SuggestPrice(itemID) -> copperPerUnit, reason
      PostingHelperService:GetConfig() / :SetConfig(cfg)
]]

local ADDON_NAME, ns = ...

local PostingHelperService = {}

local DEFAULT_CFG = {
    strategy   = "undercut",
    undercutBy = 0.01,
    averageMul = 1.0,
    floorMul   = 0.5,
}

local function Cfg()
    local p = ns.ArtisanNexus and ns.ArtisanNexus.db and ns.ArtisanNexus.db.profile
    if not p then return DEFAULT_CFG end
    if type(p.posting) ~= "table" then p.posting = {} end
    for k, v in pairs(DEFAULT_CFG) do
        if p.posting[k] == nil then p.posting[k] = v end
    end
    return p.posting
end

function PostingHelperService:GetConfig() return Cfg() end

function PostingHelperService:SetConfig(cfg)
    local cur = Cfg()
    if type(cfg) ~= "table" then return end
    for k, v in pairs(cfg) do cur[k] = v end
end

--- Lowest live AH unit price for an item, if a search result is currently
--- loaded (i.e. the user is on the AH sell tab for this item).
local function LowestLivePrice(itemID)
    if not C_AuctionHouse or not itemID then return nil end
    local okC, nC = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
    if okC and nC and nC > 0 then
        local ok2, r = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, 1)
        if ok2 and r and r.unitPrice and r.unitPrice > 0 then return r.unitPrice end
    end
    -- Non-commodity fallback
    local key = { itemID = itemID }
    local okI, nI = pcall(C_AuctionHouse.GetNumItemSearchResults, key)
    if okI and nI and nI > 0 then
        local lowest
        for i = 1, nI do
            local ok2, r = pcall(C_AuctionHouse.GetItemSearchResultInfo, key, i)
            if ok2 and r and r.buyoutAmount and r.quantity and r.quantity > 0 then
                local unit = math.floor(r.buyoutAmount / r.quantity)
                if unit > 0 and (not lowest or unit < lowest) then lowest = unit end
            end
        end
        return lowest
    end
    return nil
end

--- Suggested unit price (copper) for an item.
---@param itemID number
---@return number|nil price, string reason
function PostingHelperService:SuggestPrice(itemID)
    if not itemID then return nil, "no item" end
    local cfg = Cfg()
    local lowest = LowestLivePrice(itemID)
    local hist = ns.PriceHistoryService and ns.PriceHistoryService:GetStats(itemID, 7 * 24 * 3600) or nil
    local avg = hist and hist.avg or nil
    local floor = (avg and cfg.floorMul) and math.floor(avg * cfg.floorMul + 0.5) or nil

    local suggested, reason

    if cfg.strategy == "average" and avg then
        suggested = math.floor(avg * (cfg.averageMul or 1) + 0.5)
        reason = string.format("7d avg x %.2f", cfg.averageMul or 1)
    elseif cfg.strategy == "max" and avg and lowest then
        suggested = math.max(lowest - 1, math.floor(avg * cfg.averageMul + 0.5))
        reason = "max(undercut, avg)"
    else
        -- default: undercut
        if lowest then
            suggested = math.max(1, math.floor(lowest * (1 - (cfg.undercutBy or 0.01)) + 0.5))
            reason = string.format("undercut by %.0f%%", (cfg.undercutBy or 0.01) * 100)
        elseif avg then
            suggested = math.floor(avg * (cfg.averageMul or 1) + 0.5)
            reason = "no live price; using 7d avg"
        end
    end

    -- Floor: never sell below a fraction of historical average (avoid races).
    if suggested and floor and suggested < floor then
        suggested = floor
        reason = (reason or "") .. " (clamped to floor)"
    end

    return suggested, reason or "no data"
end

--- Hook the live sell frame OnShow so the suggestion appears in chat
--- (auto-fill of the live edit box requires SecureActionButtonTemplate;
---  we keep it advisory to stay non-protected).
local function HookSellFrame(name)
    local f = _G[name]
    if not f or f.ArtisanNexusPostHook then return end
    f.ArtisanNexusPostHook = true
    f:HookScript("OnShow", function(self)
        local itemID = self.itemKey and self.itemKey.itemID or (self.GetItemID and self:GetItemID()) or nil
        if not itemID and self.itemLocation and C_Item and C_Item.GetItemID then
            itemID = C_Item.GetItemID(self.itemLocation)
        end
        if not itemID then return end
        local price, reason = PostingHelperService:SuggestPrice(itemID)
        if price and ns.ArtisanNexus and ns.ArtisanNexus.Print then
            local g = math.floor(price / 10000)
            local s = math.floor((price / 100) % 100)
            local c = price % 100
            ns.ArtisanNexus:Print(string.format("Posting suggestion: %dg %ds %dc (%s)", g, s, c, reason or ""))
        end
    end)
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("ADDON_LOADED")
hookFrame:SetScript("OnEvent", function(_, _, addonName)
    if addonName == "Blizzard_AuctionHouseUI" then
        HookSellFrame("AuctionHouseFrameCommoditiesSellFrame")
        HookSellFrame("AuctionHouseFrameItemSellFrame")
    end
end)

ns.PostingHelperService = PostingHelperService
