--[[
    Artisan Nexus — Vendor buy prices.
    The client exposes vendor BUY prices only while a merchant is open, so prices are
    captured on MERCHANT_SHOW / MERCHANT_UPDATE and persisted account-wide:
      db.global.vendorPrices[itemID] = { p = copperPerUnit, t = unix }

    API (verified 2026-10-14, Blizzard_APIDocumentationGenerated 12.1.5.70391 MerchantFrameDocumentation):
      C_MerchantFrame.GetItemInfo(index) -> MerchantItemInfo { price, stackCount, hasExtendedCost, currencyID?, ... }
      GetMerchantNumItems(), GetMerchantItemID(index) (globals, present in 12.1.5 GlobalAPI)
    Items bought with currencies / extended costs are skipped (not a gold price).
    Limited-supply items are skipped too: MerchantItemInfo.numAvailable is -1 for unlimited stock, 0 sold
    out, >0 units left (verified 2026-10-15, MerchantFrame.lua:293/366 + ItemButtonTemplate.lua
    SetItemButtonStock shows a count only when > 0); a few restocking units are not a buy price.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS

local VendorPriceService = { _enabled = false }

local function Store()
    local g = ns.db and ns.db.global
    if not g then return nil end
    g.vendorPrices = g.vendorPrices or {}
    return g.vendorPrices
end

--- Per-unit vendor buy price in copper, or nil when never seen at a gold vendor.
---@param itemID number
---@return number|nil
function VendorPriceService:GetBuyPrice(itemID)
    local store = Store()
    local row = store and itemID and store[itemID]
    local p = row and tonumber(row.p)
    if p and p > 0 then return p end
    return nil
end

function VendorPriceService:CaptureMerchant()
    if not (C_MerchantFrame and C_MerchantFrame.GetItemInfo and GetMerchantNumItems and GetMerchantItemID) then
        return 0
    end
    local store = Store()
    if not store then return 0 end
    local n = tonumber(GetMerchantNumItems()) or 0
    local now, recorded = time(), 0
    for i = 1, n do
        local okI, info = pcall(C_MerchantFrame.GetItemInfo, i)
        local itemID = GetMerchantItemID(i)
        if okI and type(info) == "table" and itemID
            and not info.hasExtendedCost and not info.currencyID
            and (tonumber(info.numAvailable) or -1) < 0 then
            local price = tonumber(info.price) or 0
            local stack = math.max(1, tonumber(info.stackCount) or 1)
            if price > 0 then
                store[itemID] = { p = price / stack, t = now }
                recorded = recorded + 1
            end
        end
    end
    if recorded > 0 and ns.ArtisanNexus and ns.ArtisanNexus.SendMessage and E and E.VENDOR_PRICES_UPDATED then
        ns.ArtisanNexus:SendMessage(E.VENDOR_PRICES_UPDATED, recorded)
    end
    return recorded
end

function VendorPriceService:Enable()
    if self._enabled then return end
    self._enabled = true
    local owner = self._eventOwner or ns.NewEventOwner("VendorPriceService")
    self._eventOwner = owner
    -- MERCHANT_UPDATE fires per slot refresh; coalesce to one pass.
    local pending = false
    local function Queue()
        if pending then return end
        pending = true
        C_Timer.After(0.2, function()
            pending = false
            if VendorPriceService._enabled then
                VendorPriceService:CaptureMerchant()
            end
        end)
    end
    owner:RegisterEvent("MERCHANT_SHOW", Queue)
    owner:RegisterEvent("MERCHANT_UPDATE", Queue)
end

function VendorPriceService:Disable()
    if not self._enabled then return end
    self._enabled = false
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
    end
end

ns.VendorPriceService = VendorPriceService
