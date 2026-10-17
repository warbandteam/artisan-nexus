--[[
    Artisan Nexus — Sales ledger (realized income / expense, cost basis, gold history).

    Sources:
      - Mailbox (MAIL_SHOW / MAIL_INBOX_UPDATE, coalesced): AH invoices and outcome mails. Each
        mail is booked once via a stable signature; re-reading the inbox never double counts.
      - AH purchases: StartCommoditiesPurchase/PlaceBid post-hooks + COMMODITY_PRICE_UPDATED
        (quote) + COMMODITY_PURCHASED / COMMODITY_PURCHASE_SUCCEEDED / AUCTION_HOUSE_PURCHASE_COMPLETED.
        A later "buyer" invoice for the same purchase is matched, not booked twice.
      - Postings: PostCommodity/PostItem (+Confirm*) post-hooks, booked on AUCTION_HOUSE_AUCTION_CREATED
        with the deposit from CalculateCommodityDeposit / CalculateItemDeposit.
      - CHAT_MSG_SYSTEM ERR_AUCTION_SOLD_S: only flags "sold, invoice pending".
      - CRAFTINGORDERS_DISPLAY_CRAFTER_FULFILLED_MSG: crafting-order tips.
      - PLAYER_MONEY / ACCOUNT_MONEY: daily gold points per character and for the warband bank.

    db.global.salesLedger = {
      sales  = { { t, guid?, sig, kind = "invoice"|"header", itemID?, name?, qty, bid?, buyout?,
                   deposit?, cut?, net, buyer?, commodity? }, ... }      -- oldest first, capped
      buys   = { { t, guid?, itemID, qty, total, src = "ah"|"mail", est?, mailed? }, ... }
      posts  = { { t, guid?, itemID, qty, unitPrice?, deposit?, duration, commodity? }, ... }
      orders = { { t, guid?, item, customer?, tip, qty, orderType? }, ... }
      seen   = { [base|bucket] = { t, n } },  pendingSold = { { t, name, src = "chat"|"mail", paired? } },
      basis  = { [itemID] = { q, c, t, n } },          -- decayed weighted average buy price
      gold   = { chars = { [guid] = { {d, t, m}, ... } }, warband = { {d, t, m}, ... } },
    }

    Facts (verified 2026-10-14):
      GetInboxInvoiceInfo(i) -> invoiceType ("buyer"|"seller"|"seller_temp_invoice"|nil), itemName,
        playerName, bid, buyout, deposit, consignment, moneyDelay, etaHour, etaMin, count,
        commerceAuction; seller receives bid + deposit - consignment (Blizzard_MailFrame/MailFrame.lua).
      GetInboxHeaderInfo(i) -> ..., sender, subject, money, CODAmount, daysLeft, hasItem, wasRead,
        wasReturned, textCreated, canReply, isGM, firstItemQuantity, firstItemLink (MailFrame.lua:214).
      GetInboxItem(i, j) -> name, itemID, texture, count, quality, canUse, isCurrency (MailFrame.lua:476).
      Mail subjects AUCTION_SOLD/EXPIRED/REMOVED/WON_MAIL_SUBJECT, AUCTION_MAIL_ITEM_STACK,
        ERR_AUCTION_SOLD_S (Ketho GlobalStrings enUS, 12.1.5).
      AH events/payloads and C_AuctionHouse signatures: AuctionHouseDocumentation.lua 12.1.5.70391.
      CRAFTINGORDERS_DISPLAY_CRAFTER_FULFILLED_MSG(orderTypeString, itemNameString, playerNameString,
        tipAmount, quantityCrafted): CraftingOrderUIDocumentation.lua 12.1.5.70391.
      C_Bank.FetchDepositedMoney(Enum.BankType.Account) on ACCOUNT_MONEY: BankDocumentation.lua and
        Blizzard_MoneyFrame/Shared/MoneyFrame.lua.
      CHAT_MSG_SYSTEM text is secret during chat lockdown (ChatInfoDocumentation) -> issecretvalue guard.
    UNVERIFIED: invoice data may be nil until the mail body was fetched (Blizzard reads it after
      GetInboxText); such mails are booked from the header (money only) and upgraded later.
      Whether tipAmount is gross or net of the consortium cut. Whether PlaceBid's amount for a stacked
      item auction is per unit (booked as an estimate until the invoice). Whether the item location is
      still readable in the post-hook.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS
local GetItemNameByID = C_Item.GetItemNameByID
local GetItemInfoInstant = C_Item.GetItemInfoInstant

local SalesLedgerService = { _enabled = false }

local CAP_SALES, CAP_BUYS, CAP_POSTS, CAP_ORDERS = 5000, 5000, 3000, 2000
local TRIM_SLACK = 100
local SEEN_TTL = 45 * 86400
local GOLD_POINTS_CAP = 400
local BASIS_HALF_LIFE = 14 * 86400
--- Mail expiry is derived from daysLeft; bucket it so float jitter maps to one signature.
local EXPIRY_BUCKET = 120
local QUOTE_TTL = 120
local CUT_WINDOW = 90 * 86400

local function Store()
    local g = ns.db and ns.db.global
    if not g then return nil end
    local s = g.salesLedger
    if type(s) ~= "table" then
        s = {}
        g.salesLedger = s
    end
    for _, k in ipairs({ "sales", "buys", "posts", "orders", "seen", "pendingSold", "basis" }) do
        if type(s[k]) ~= "table" then s[k] = {} end
    end
    if type(s.gold) ~= "table" then s.gold = {} end
    if type(s.gold.chars) ~= "table" then s.gold.chars = {} end
    if type(s.gold.warband) ~= "table" then s.gold.warband = {} end
    return s
end

local function Guid()
    return ns.Utilities and ns.Utilities:GetCharacterGUID() or nil
end

local cutMemo = nil

local notifyPending = false
local function Notify(reason)
    cutMemo = nil
    if notifyPending then return end
    notifyPending = true
    C_Timer.After(0.1, function()
        notifyPending = false
        ns.ArtisanNexus:SendMessage(E.SALES_LEDGER_UPDATED, reason)
    end)
end

local function Trim(list, cap)
    if #list <= cap + TRIM_SLACK then return end
    local drop = #list - cap
    local keep = {}
    for i = drop + 1, #list do keep[#keep + 1] = list[i] end
    wipe(list)
    for i = 1, #keep do list[i] = keep[i] end
end

local function Append(list, row, cap)
    list[#list + 1] = row
    Trim(list, cap)
end

---------------------------------------------------------------------------
-- Global-string patterns
---------------------------------------------------------------------------

--- "Auction successful: %s" -> "^Auction successful: (.+)$" (handles %1$s positional forms).
local function PatternFromFormat(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    fmt = fmt:gsub("%%%d%$([sd])", "%%%1")
    local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
    return "^" .. p .. "$"
end

local patterns = nil
local function Patterns()
    if patterns then return patterns end
    patterns = {
        sold = PatternFromFormat(_G.AUCTION_SOLD_MAIL_SUBJECT),
        expired = PatternFromFormat(_G.AUCTION_EXPIRED_MAIL_SUBJECT),
        removed = PatternFromFormat(_G.AUCTION_REMOVED_MAIL_SUBJECT),
        won = PatternFromFormat(_G.AUCTION_WON_MAIL_SUBJECT),
        pending = PatternFromFormat(_G.AUCTION_INVOICE_MAIL_SUBJECT),
        stack = PatternFromFormat(_G.AUCTION_MAIL_ITEM_STACK),
        chatSold = PatternFromFormat(_G.ERR_AUCTION_SOLD_S),
    }
    return patterns
end

local function ClassifySubject(subject)
    if type(subject) ~= "string" then return nil end
    local P = Patterns()
    for _, kind in ipairs({ "sold", "expired", "removed", "won", "pending" }) do
        local pat = P[kind]
        local name = pat and subject:match(pat)
        if name then
            if P.stack then
                local base = name:match(P.stack)
                if base then name = base end
            end
            return kind, name
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Item name -> itemID
---------------------------------------------------------------------------

local nameIndex = nil       -- [name] = { itemID, ... }
local nameIndexAt = 0

local function AddName(idx, itemID)
    itemID = tonumber(itemID)
    if not itemID then return end
    local name = GetItemNameByID(itemID)
    if type(name) ~= "string" or name == "" then return end
    local list = idx[name]
    if not list then
        idx[name] = { itemID }
        return
    end
    for i = 1, #list do
        if list[i] == itemID then return end
    end
    list[#list + 1] = itemID
end

local function BuildNameIndex()
    local idx = {}
    local store = Store()
    if store then
        for i = #store.posts, math.max(1, #store.posts - 500), -1 do AddName(idx, store.posts[i].itemID) end
        for i = #store.buys, math.max(1, #store.buys - 500), -1 do AddName(idx, store.buys[i].itemID) end
    end
    local oas = ns.OwnedAuctionsService
    if oas and oas.GetKnownItems then
        for itemID in pairs(oas:GetKnownItems()) do AddName(idx, itemID) end
    end
    local g = ns.db and ns.db.global
    if g and type(g.ahPrices) == "table" then
        for itemID in pairs(g.ahPrices) do AddName(idx, itemID) end
    end
    if g and type(g.recipeSchematics) == "table" then
        for _, sch in pairs(g.recipeSchematics) do
            if type(sch) == "table" then
                if sch.output then AddName(idx, sch.output.itemID) end
                if type(sch.qualityItemIDs) == "table" then
                    for i = 1, #sch.qualityItemIDs do AddName(idx, sch.qualityItemIDs[i]) end
                end
            end
        end
    end
    nameIndex, nameIndexAt = idx, GetTime()
end

--- Resolve an invoice item name. Quality tiers share one name; the posted unit price closest
--- to the sale unit price breaks the tie, else the name stays unresolved.
---@param name string
---@param unitPrice number|nil
---@return number|nil itemID
function SalesLedgerService:ResolveItemName(name, unitPrice)
    if type(name) ~= "string" or name == "" then return nil end
    if not nameIndex or (not nameIndex[name] and GetTime() - nameIndexAt > 300) then
        BuildNameIndex()
    end
    local list = nameIndex and nameIndex[name]
    if not list then return nil end
    if #list == 1 then return list[1] end
    local store = Store()
    if not store or not unitPrice then return nil end
    local bestID, bestDiff
    for i = #store.posts, math.max(1, #store.posts - 300), -1 do
        local p = store.posts[i]
        for j = 1, #list do
            if p.itemID == list[j] and p.unitPrice then
                local diff = math.abs(p.unitPrice - unitPrice)
                if not bestDiff or diff < bestDiff then bestID, bestDiff = p.itemID, diff end
            end
        end
    end
    return bestID
end

---------------------------------------------------------------------------
-- Cost basis
---------------------------------------------------------------------------

local function DecayFactor(dt)
    if not dt or dt <= 0 then return 1 end
    return 0.5 ^ (dt / BASIS_HALF_LIFE)
end

local function AddToBasis(store, itemID, qty, total)
    if not itemID or qty <= 0 or total <= 0 then return end
    local b = store.basis[itemID]
    local now = time()
    if type(b) ~= "table" then
        b = { q = 0, c = 0, t = now, n = 0 }
        store.basis[itemID] = b
    end
    local f = DecayFactor(now - (tonumber(b.t) or now))
    b.q = (tonumber(b.q) or 0) * f + qty
    b.c = (tonumber(b.c) or 0) * f + total
    b.t = now
    b.n = (tonumber(b.n) or 0) + 1
end

local function RecordBuy(itemID, qty, total, src, est)
    local store = Store()
    itemID, qty, total = tonumber(itemID), tonumber(qty) or 0, tonumber(total) or 0
    if not store or not itemID or qty <= 0 or total <= 0 then return end
    Append(store.buys, {
        t = time(), guid = Guid(), itemID = itemID, qty = qty, total = total, src = src,
        est = est or nil,
    }, CAP_BUYS)
    if not est then
        AddToBasis(store, itemID, qty, total)
    end
    Notify("buy")
end

---------------------------------------------------------------------------
-- Mail
---------------------------------------------------------------------------

--- Seen store: seen[base .. "|" .. bucket] = { t, n } where n is how many identical mails with that
--- signature were booked. The scan-order occurrence alone is not stable (taking the newer of two
--- identical mails renumbers the older one), so booking compares the per-scan count with n.
--- Returns the canonical key (an existing +-1 bucket neighbour, else this bucket) and n.
--- Rows of older builds (`base#k|bucket` = t) still count as booked.
local function SeenCount(seen, base, bucket)
    local canon, n = nil, 0
    for d = 0, 2 do
        local b = (d == 0) and bucket or ((d == 1) and bucket - 1 or bucket + 1)
        local key = base .. "|" .. b
        local v = seen[key]
        if v ~= nil then
            canon = canon or key
            local c = type(v) == "table" and (tonumber(v.n) or 1) or 1
            if c > n then n = c end
        end
    end
    -- Legacy k was numbered across the whole inbox, so the set can have gaps: count every hit.
    local legacy = 0
    for k = 1, 20 do
        local key = base .. "#" .. k .. "|"
        if seen[key .. bucket] or seen[key .. (bucket - 1)] or seen[key .. (bucket + 1)] then
            legacy = legacy + 1
        end
    end
    if legacy > n then n = legacy end
    return canon or (base .. "|" .. bucket), n
end

local function MarkSeen(seen, key, occ, now)
    local v = seen[key]
    local n = type(v) == "table" and (tonumber(v.n) or 0) or (v ~= nil and 1 or 0)
    seen[key] = { t = now, n = math.max(n, occ) }
end

local function SeenTime(v)
    if type(v) == "table" then return tonumber(v.t) or 0 end
    return tonumber(v) or 0
end

--- Match a buyer invoice against an AH-event purchase already booked. A commodity buy filled by
--- several sellers arrives as several invoices: those are matched partially (mq/mt accumulate the
--- invoiced quantity and copper) until the booked quantity is covered.
local function MatchAHBuy(store, itemID, qty, total)
    local cutoff = time() - 14 * 86400
    for i = #store.buys, 1, -1 do
        local b = store.buys[i]
        if (tonumber(b.t) or 0) < cutoff then break end
        if b.src == "ah" and not b.mailed and b.itemID == itemID then
            local bq, bt = tonumber(b.qty) or 0, tonumber(b.total) or 0
            local mq = tonumber(b.mq) or 0
            if bq == qty and mq == 0 then
                local tol = math.max(100, bt * 0.01)
                if math.abs(bt - total) <= tol or b.est then
                    b.mailed = true
                    if b.est then
                        -- Estimated AH buy: the invoice is authoritative.
                        b.total, b.est = total, nil
                        AddToBasis(store, itemID, qty, total)
                    end
                    return true
                end
            elseif qty < bq - mq and bq > 0 or qty == bq - mq and mq > 0 then
                -- Partial fill: unit price must be plausible for this purchase (book walk spread).
                local unit, avg = total / qty, bt / bq
                if b.est or (unit <= avg * 2 and unit >= avg * 0.5) then
                    b.mq = mq + qty
                    b.mt = (tonumber(b.mt) or 0) + total
                    if b.mq >= bq then
                        b.mailed, b.mq = true, nil
                        if b.est then
                            b.total, b.est = b.mt, nil
                            AddToBasis(store, itemID, bq, b.total)
                        end
                        b.mt = nil
                    end
                    return true
                end
            end
        end
    end
    return false
end

--- "Sold, invoice pending" flag. The chat line and the "Sale Pending" mail describe the same sale:
--- an entry from the other source with the same name inside the window is paired, not duplicated.
local PENDING_PAIR_WINDOW = 2 * 3600
local function AddPendingSold(store, name, src, now)
    if not name then return false end
    for i = #store.pendingSold, 1, -1 do
        local e = store.pendingSold[i]
        if now - (tonumber(e.t) or 0) > PENDING_PAIR_WINDOW then break end
        if e.name == name and not e.paired and e.src ~= src then
            e.paired = true
            return false
        end
    end
    Append(store.pendingSold, { t = now, name = name, src = src }, 100)
    return true
end

local function ClearPendingSold(store, name)
    if not name then return end
    for i = #store.pendingSold, 1, -1 do
        if store.pendingSold[i].name == name then
            table.remove(store.pendingSold, i)
            return
        end
    end
end

--- Newest header-only sale booked for this header signature (hk; legacy rows: sig prefix "base#").
local function FindHeaderSale(store, headBase)
    local prefix = headBase .. "#"
    for i = #store.sales, math.max(1, #store.sales - 300), -1 do
        local r = store.sales[i]
        if r.kind == "header" and (r.hk == headBase
            or (type(r.sig) == "string" and r.sig:sub(1, #prefix) == prefix)) then
            return r
        end
    end
    return nil
end

local function BookMail(store, i, occurrences)
    local _, _, sender, subject, money, _, daysLeft, hasItem, _, _, _, _, _, firstItemQuantity, firstItemLink =
        GetInboxHeaderInfo(i)
    local kind, subjName = ClassifySubject(subject)
    local invoiceType, itemName, playerName, bid, buyout, deposit, consignment, _, _, _, count, commerceAuction
    if GetInboxInvoiceInfo then
        invoiceType, itemName, playerName, bid, buyout, deposit, consignment, _, _, _, count, commerceAuction =
            GetInboxInvoiceInfo(i)
    end
    if not kind and not invoiceType then return false end

    local expiry = time() + (tonumber(daysLeft) or 0) * 86400
    local bucket = math.floor(expiry / EXPIRY_BUCKET)
    local headBase = table.concat({ "h", tostring(kind), tostring(subject), tostring(sender), tostring(money or 0) }, "|")
    local invBase = invoiceType and table.concat({
        "i", invoiceType, tostring(itemName), tostring(bid or 0), tostring(deposit or 0),
        tostring(consignment or 0), tostring(count or 0), tostring(subject),
    }, "|") or nil
    local seen = store.seen
    local now = time()
    -- Identical mails in one inbox are counted per signature; each one beyond the booked count is new.
    local headKey, headN = SeenCount(seen, headBase, bucket)
    occurrences[headKey] = (occurrences[headKey] or 0) + 1
    local headOcc = occurrences[headKey]
    local headSeen = headOcc <= headN
    local invKey, invOcc
    if invBase then
        local invN
        invKey, invN = SeenCount(seen, invBase, bucket)
        occurrences[invKey] = (occurrences[invKey] or 0) + 1
        invOcc = occurrences[invKey]
        if invOcc <= invN then return false end
    elseif headSeen then
        return false
    end

    local changed = false
    if invoiceType == "seller" then
        bid, deposit, consignment = tonumber(bid) or 0, tonumber(deposit) or 0, tonumber(consignment) or 0
        local qty = math.max(1, tonumber(count) or 1)
        local net = bid + deposit - consignment
        local itemID = SalesLedgerService:ResolveItemName(itemName, bid / qty)
        local existing = headSeen and FindHeaderSale(store, headBase)
        if existing then
            -- Upgrade a header-only booking with the invoice details.
            existing.kind, existing.itemID, existing.name = "invoice", itemID, itemName
            existing.qty, existing.bid, existing.buyout = qty, bid, tonumber(buyout)
            existing.deposit, existing.cut, existing.net = deposit, consignment, net
            existing.buyer, existing.commodity = playerName, commerceAuction and true or nil
        elseif not headSeen then
            Append(store.sales, {
                t = now, guid = Guid(), sig = invKey .. "#" .. invOcc, kind = "invoice", itemID = itemID,
                name = itemName, qty = qty, bid = bid, buyout = tonumber(buyout), deposit = deposit,
                cut = consignment, net = net, buyer = playerName, commodity = commerceAuction and true or nil,
            }, CAP_SALES)
            if ns.OwnedAuctionsService and ns.OwnedAuctionsService.RecordOutcome then
                ns.OwnedAuctionsService:RecordOutcome({
                    itemID = itemID, name = itemName, qty = qty, outcome = "sold", src = "mail",
                    unitPrice = bid / qty,
                })
            end
        end
        -- headSeen without a findable header row: it was booked and has since been trimmed from the
        -- search window; never book the same sale a second time.
        MarkSeen(seen, invKey, invOcc, now)
        ClearPendingSold(store, itemName)
        changed = true
    elseif invoiceType == "buyer" then
        local itemID, qty
        if GetInboxItem and hasItem then
            local _, id, _, c = GetInboxItem(i, 1)
            itemID, qty = tonumber(id), tonumber(c)
        end
        if not itemID and firstItemLink then
            itemID = GetItemInfoInstant(firstItemLink)
        end
        qty = math.max(1, tonumber(count) or qty or tonumber(firstItemQuantity) or 1)
        bid = tonumber(bid) or 0
        if not itemID then
            -- Attachment already taken: fall back to the invoice item name.
            itemID = SalesLedgerService:ResolveItemName(itemName, bid / qty)
        end
        if itemID and bid > 0 and not MatchAHBuy(store, itemID, qty, bid) then
            RecordBuy(itemID, qty, bid, "mail")
        end
        MarkSeen(seen, invKey, invOcc, now)
        changed = true
    elseif invoiceType == "seller_temp_invoice" then
        -- "Sale Pending": the money mail follows; only flag it (its own signature only, so the
        -- final "seller" invoice is still booked).
        AddPendingSold(store, itemName, "mail", now)
        MarkSeen(seen, invKey, invOcc, now)
        changed = true
    elseif kind == "sold" then
        if not headSeen then
            local net = tonumber(money) or 0
            Append(store.sales, {
                t = now, guid = Guid(), sig = headKey .. "#" .. headOcc, hk = headBase, kind = "header",
                name = subjName, itemID = SalesLedgerService:ResolveItemName(subjName, nil), qty = 1, net = net,
            }, CAP_SALES)
            MarkSeen(seen, headKey, headOcc, now)
            ClearPendingSold(store, subjName)
            if ns.OwnedAuctionsService and ns.OwnedAuctionsService.RecordOutcome then
                ns.OwnedAuctionsService:RecordOutcome({
                    itemID = store.sales[#store.sales].itemID, name = subjName, qty = 1, qtyUnknown = true,
                    outcome = "sold", src = "mail",
                })
            end
            changed = true
        end
    elseif kind == "expired" or kind == "removed" then
        if not headSeen then
            local itemID = firstItemLink and GetItemInfoInstant(firstItemLink) or nil
            if ns.OwnedAuctionsService and ns.OwnedAuctionsService.RecordOutcome then
                ns.OwnedAuctionsService:RecordOutcome({
                    itemID = itemID, name = subjName,
                    qty = tonumber(firstItemQuantity) or 1,
                    outcome = (kind == "expired") and "expired" or "cancelled", src = "mail",
                })
            end
            MarkSeen(seen, headKey, headOcc, now)
            changed = true
        end
    end
    return changed
end

function SalesLedgerService:ScanInbox()
    if not (GetInboxNumItems and GetInboxHeaderInfo) then return end
    local store = Store()
    if not store then return end
    local n = tonumber((GetInboxNumItems())) or 0
    local occurrences, changed = {}, false
    for i = 1, n do
        local ok, res = pcall(BookMail, store, i, occurrences)
        if ok and res then changed = true end
    end
    if changed then
        local cutoff = time() - SEEN_TTL
        for sig, v in pairs(store.seen) do
            if SeenTime(v) < cutoff then store.seen[sig] = nil end
        end
        Notify("mail")
    end
end

---------------------------------------------------------------------------
-- AH hooks (post-hooks only; protected functions are never called from here)
---------------------------------------------------------------------------

local quote = nil            -- { unit, total, t }
local pendingCommodity = nil -- { itemID, qty, t, booked }
local pendingBids = {}       -- [auctionID] = { amount, itemID, t }
local pendingPost = nil      -- { itemID, qty, unitPrice, deposit, duration, commodity, t, awaitConfirm? }
local postWarnAt = nil       -- GetTime() of the last AUCTION_HOUSE_POST_WARNING (event may precede the post-hook)

local function ItemIDFromLocation(loc)
    if not loc or not C_Item or not C_Item.GetItemID then return nil end
    if C_Item.DoesItemExist then
        local okE, exists = pcall(C_Item.DoesItemExist, loc)
        if not okE or not exists then return nil end
    end
    local ok, id = pcall(C_Item.GetItemID, loc)
    return ok and tonumber(id) or nil
end

local function OnPostCommodity(item, duration, quantity, unitPrice)
    if not SalesLedgerService._enabled then return end
    local itemID = ItemIDFromLocation(item)
    if not itemID then return end
    local dep
    if C_AuctionHouse.CalculateCommodityDeposit then
        local ok, d = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, duration, quantity)
        dep = ok and tonumber(d) or nil
    end
    pendingPost = {
        itemID = itemID, qty = tonumber(quantity) or 1, unitPrice = tonumber(unitPrice),
        deposit = dep, duration = tonumber(duration), commodity = true, t = GetTime(),
        awaitConfirm = (postWarnAt and GetTime() - postWarnAt < 1) or nil,
    }
end

local function OnPostItem(item, duration, quantity, bid, buyout)
    if not SalesLedgerService._enabled then return end
    local itemID = ItemIDFromLocation(item)
    if not itemID then return end
    local dep
    if C_AuctionHouse.CalculateItemDeposit then
        local ok, d = pcall(C_AuctionHouse.CalculateItemDeposit, item, duration, quantity)
        dep = ok and tonumber(d) or nil
    end
    pendingPost = {
        itemID = itemID, qty = tonumber(quantity) or 1, unitPrice = tonumber(buyout) or tonumber(bid),
        deposit = dep, duration = tonumber(duration), t = GetTime(),
        awaitConfirm = (postWarnAt and GetTime() - postWarnAt < 1) or nil,
    }
end

local function BookPendingPost()
    local p = pendingPost
    pendingPost = nil
    local store = Store()
    -- awaitConfirm: the post asked for confirmation (AUCTION_HOUSE_POST_WARNING) and was not confirmed;
    -- the Confirm* hook replaces pendingPost when it is.
    if not p or not store or p.awaitConfirm or GetTime() - p.t > 60 then return end
    Append(store.posts, {
        t = time(), guid = Guid(), itemID = p.itemID, qty = p.qty, unitPrice = p.unitPrice,
        deposit = p.deposit, duration = p.duration, commodity = p.commodity,
    }, CAP_POSTS)
    Notify("post")
end

local function OnStartCommoditiesPurchase(itemID, quantity)
    if not SalesLedgerService._enabled then return end
    pendingCommodity = { itemID = tonumber(itemID), qty = tonumber(quantity) or 1, t = GetTime() }
    quote = nil
end

--- Quantity of an item auction from the loaded item search results (AuctionInfo has no quantity;
--- ItemSearchResultInfo { auctionID, quantity } verified 2026-10-15, AuctionHouseDocumentation.lua).
local function ItemAuctionQuantity(itemKey, auctionID)
    if not (C_AuctionHouse.GetNumItemSearchResults and C_AuctionHouse.GetItemSearchResultInfo) then return nil end
    local okN, n = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
    n = okN and tonumber(n) or 0
    for i = 1, math.min(n, 500) do
        local ok, r = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
        if not ok or type(r) ~= "table" then break end
        if r.auctionID == auctionID then return tonumber(r.quantity) end
    end
    return nil
end

local function OnPlaceBid(auctionID, bidAmount)
    if not SalesLedgerService._enabled then return end
    auctionID = tonumber(auctionID)
    if not auctionID then return end
    local itemID, qty
    if C_AuctionHouse.GetAuctionInfoByID then
        local ok, info = pcall(C_AuctionHouse.GetAuctionInfoByID, auctionID)
        if ok and type(info) == "table" and type(info.itemKey) == "table" then
            itemID = tonumber(info.itemKey.itemID)
            qty = ItemAuctionQuantity(info.itemKey, auctionID)
        end
    end
    pendingBids[auctionID] = { amount = tonumber(bidAmount), itemID = itemID, qty = qty, t = GetTime() }
end

local function BookCommodityPurchase(itemID, qty)
    local pc = pendingCommodity
    if not pc or pc.booked then return end
    itemID = tonumber(itemID) or pc.itemID
    qty = tonumber(qty) or pc.qty
    if not itemID or itemID ~= pc.itemID then return end
    pc.booked = true
    local total, est
    if quote and GetTime() - quote.t <= QUOTE_TTL then
        if qty == pc.qty and quote.total then
            total = quote.total
        elseif quote.unit then
            total = quote.unit * qty
        end
    end
    if not total then
        -- No quote seen: book at the scanned price and let the buyer invoice correct it.
        local econ = ns.Economy
        total = econ and econ.BuyCost and econ:BuyCost(itemID, qty)
        est = true
    end
    if total then RecordBuy(itemID, qty, total, "ah", est) end
end

local hooksInstalled = false
local function InstallHooks()
    if hooksInstalled or not C_AuctionHouse or not hooksecurefunc then return end
    hooksInstalled = true
    if C_AuctionHouse.PostCommodity then hooksecurefunc(C_AuctionHouse, "PostCommodity", OnPostCommodity) end
    if C_AuctionHouse.ConfirmPostCommodity then
        hooksecurefunc(C_AuctionHouse, "ConfirmPostCommodity", function(...) postWarnAt = nil; OnPostCommodity(...) end)
    end
    if C_AuctionHouse.PostItem then hooksecurefunc(C_AuctionHouse, "PostItem", OnPostItem) end
    if C_AuctionHouse.ConfirmPostItem then
        hooksecurefunc(C_AuctionHouse, "ConfirmPostItem", function(...) postWarnAt = nil; OnPostItem(...) end)
    end
    if C_AuctionHouse.StartCommoditiesPurchase then
        hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", OnStartCommoditiesPurchase)
    end
    if C_AuctionHouse.PlaceBid then hooksecurefunc(C_AuctionHouse, "PlaceBid", OnPlaceBid) end
end

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------

local function DayIndex(t)
    local d = date("*t", t)
    return d.year * 10000 + d.month * 100 + d.day
end

local function PushGoldPoint(list, money)
    money = tonumber(money)
    if not money or money < 0 then return end
    local now = time()
    local d = DayIndex(now)
    local last = list[#list]
    if last and last.d == d then
        last.m, last.t = money, now
    else
        list[#list + 1] = { d = d, t = now, m = money }
        Trim(list, GOLD_POINTS_CAP)
    end
end

local function SnapshotMoney()
    local store = Store()
    local guid = Guid()
    if not store or not guid or not GetMoney then return end
    store.gold.chars[guid] = store.gold.chars[guid] or {}
    PushGoldPoint(store.gold.chars[guid], GetMoney())
end

local function SnapshotWarband()
    local store = Store()
    if not store or not (C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType and Enum.BankType.Account) then
        return
    end
    local ok, m = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
    if ok and tonumber(m) then
        PushGoldPoint(store.gold.warband, m)
    end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- House cut observed on seller invoices of the last 90 days.
---@return number|nil rate consignment / bid
---@return number samples invoices used
function SalesLedgerService:GetObservedCutRate()
    -- The 90-day window slides: the memo also expires by time, not only on ledger changes.
    if cutMemo and time() - cutMemo.at < 3600 then return cutMemo.rate, cutMemo.n end
    local store = Store()
    local sumBid, sumCut, n = 0, 0, 0
    if store then
        local cutoff = time() - CUT_WINDOW
        for i = #store.sales, 1, -1 do
            local s = store.sales[i]
            if (tonumber(s.t) or 0) < cutoff then break end
            if s.kind == "invoice" and (tonumber(s.bid) or 0) > 0 and s.cut then
                sumBid = sumBid + s.bid
                sumCut = sumCut + s.cut
                n = n + 1
            end
        end
    end
    local rate = sumBid > 0 and (sumCut / sumBid) or nil
    cutMemo = { rate = rate, n = n, at = time() }
    return rate, n
end

---@param itemID number
---@return table|nil { avg, qty, buys, lastAt } decayed weighted average (14-day half-life)
function SalesLedgerService:GetCostBasis(itemID)
    local store = Store()
    local b = store and itemID and store.basis[tonumber(itemID)]
    if type(b) ~= "table" or (tonumber(b.q) or 0) <= 0 then return nil end
    local f = DecayFactor(time() - (tonumber(b.t) or time()))
    return { avg = b.c / b.q, qty = b.q * f, buys = b.n, lastAt = b.t }
end

---@param itemID number
---@return number|nil copper per unit
function SalesLedgerService:GetAvgBuyPrice(itemID)
    local b = self:GetCostBasis(itemID)
    return b and b.avg or nil
end

local function Since(list, days)
    local out = {}
    local cutoff = time() - (tonumber(days) or 30) * 86400
    for i = #list, 1, -1 do
        local r = list[i]
        if (tonumber(r.t) or 0) < cutoff then break end
        out[#out + 1] = r
    end
    return out
end

--- Sale rows newest first (stored tables; read-only). Unresolved names are re-resolved lazily.
---@param days number|nil default 30
---@return table[]
function SalesLedgerService:GetSales(days)
    local store = Store()
    if not store then return {} end
    local rows = Since(store.sales, days)
    for i = 1, #rows do
        local r = rows[i]
        if not r.itemID and r.name then
            r.itemID = self:ResolveItemName(r.name, r.bid and r.qty and r.bid / r.qty or nil)
        end
    end
    return rows
end

--- Realized totals for the last `days`.
---@param days number|nil default 30
---@return table { revenue, cut, deposits, depositsPaid, depositsRefunded, buys, orderTips, net,
---   sales, purchases, byItem = { [itemID|name] = { itemID?, name?, sold, revenue, cut, net,
---   bought, spent, avgSell?, avgBuy? } } }
function SalesLedgerService:GetSummary(days)
    local sum = {
        revenue = 0, cut = 0, deposits = 0, depositsPaid = 0, depositsRefunded = 0, buys = 0,
        orderTips = 0, net = 0, sales = 0, purchases = 0, byItem = {},
    }
    local store = Store()
    if not store then return sum end
    local function Bucket(itemID, name)
        local key = itemID or name or "?"
        local b = sum.byItem[key]
        if not b then
            b = { itemID = itemID, name = name, sold = 0, revenue = 0, cut = 0, net = 0, bought = 0, spent = 0 }
            sum.byItem[key] = b
        end
        return b
    end
    local saleNet = 0
    for _, s in ipairs(self:GetSales(days)) do
        sum.sales = sum.sales + 1
        local b = Bucket(s.itemID, s.name)
        if s.kind == "invoice" then
            sum.revenue = sum.revenue + (s.bid or 0)
            sum.cut = sum.cut + (s.cut or 0)
            sum.depositsRefunded = sum.depositsRefunded + (s.deposit or 0)
            saleNet = saleNet + (s.bid or 0) - (s.cut or 0)
            b.revenue = b.revenue + (s.bid or 0)
            b.cut = b.cut + (s.cut or 0)
            b.net = b.net + (s.bid or 0) - (s.cut or 0)
        else
            -- Header-only: the mailed amount (refunded deposit included, unknown split).
            sum.revenue = sum.revenue + (s.net or 0)
            saleNet = saleNet + (s.net or 0)
            b.revenue = b.revenue + (s.net or 0)
            b.net = b.net + (s.net or 0)
        end
        b.sold = b.sold + (s.qty or 1)
    end
    for _, p in ipairs(Since(store.posts, days)) do
        sum.depositsPaid = sum.depositsPaid + (p.deposit or 0)
    end
    for _, r in ipairs(Since(store.buys, days)) do
        sum.purchases = sum.purchases + 1
        sum.buys = sum.buys + (r.total or 0)
        local b = Bucket(r.itemID, nil)
        b.bought = b.bought + (r.qty or 0)
        b.spent = b.spent + (r.total or 0)
    end
    for _, o in ipairs(Since(store.orders, days)) do
        sum.orderTips = sum.orderTips + (o.tip or 0)
    end
    for _, b in pairs(sum.byItem) do
        if b.sold > 0 then b.avgSell = b.revenue / b.sold end
        if b.bought > 0 then b.avgBuy = b.spent / b.bought end
    end
    -- Deposits lost = paid - refunded; untracked posts would make this negative, so clamp.
    sum.deposits = math.max(0, sum.depositsPaid - sum.depositsRefunded)
    sum.net = saleNet - sum.deposits - sum.buys + sum.orderTips
    return sum
end

--- Daily gold points.
---@param days number|nil default 90
---@return table { chars = { [guid] = { {d, t, m}, ... } }, warband = { ... }, total = { {d, m}, ... } }
function SalesLedgerService:GetGoldHistory(days)
    local out = { chars = {}, warband = {}, total = {} }
    local store = Store()
    if not store then return out end
    local cutoff = time() - (tonumber(days) or 90) * 86400
    local function Clip(list)
        local r = {}
        for i = 1, #list do
            if (tonumber(list[i].t) or 0) >= cutoff then r[#r + 1] = list[i] end
        end
        return r
    end
    local daySet = {}
    for guid, list in pairs(store.gold.chars) do
        out.chars[guid] = Clip(list)
        for _, pt in ipairs(out.chars[guid]) do daySet[pt.d] = true end
    end
    out.warband = Clip(store.gold.warband)
    for _, pt in ipairs(out.warband) do daySet[pt.d] = true end
    local days_ = {}
    for d in pairs(daySet) do days_[#days_ + 1] = d end
    table.sort(days_)
    -- Total per day = last known value of every series on or before that day.
    local series = {}
    for _, list in pairs(store.gold.chars) do series[#series + 1] = list end
    series[#series + 1] = store.gold.warband
    for _, d in ipairs(days_) do
        local m = 0
        for _, list in ipairs(series) do
            local v
            for i = #list, 1, -1 do
                if list[i].d <= d then v = list[i].m break end
            end
            m = m + (v or 0)
        end
        out.total[#out.total + 1] = { d = d, m = m }
    end
    return out
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function SalesLedgerService:Enable()
    if self._enabled then return end
    self._enabled = true
    InstallHooks()
    local owner = self._eventOwner or ns.NewEventOwner("SalesLedgerService")
    self._eventOwner = owner

    local mailPending = false
    local function QueueMailScan()
        if mailPending then return end
        mailPending = true
        C_Timer.After(0.5, function()
            mailPending = false
            if SalesLedgerService._enabled then SalesLedgerService:ScanInbox() end
        end)
    end
    owner:RegisterEvent("MAIL_SHOW", QueueMailScan)
    owner:RegisterEvent("MAIL_INBOX_UPDATE", QueueMailScan)

    owner:RegisterEvent("COMMODITY_PRICE_UPDATED", function(_, unit, total)
        quote = { unit = tonumber(unit), total = tonumber(total), t = GetTime() }
    end)
    owner:RegisterEvent("COMMODITY_PURCHASED", function(_, itemID, quantity)
        BookCommodityPurchase(itemID, quantity)
    end)
    owner:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED", function()
        -- COMMODITY_PURCHASED normally books it; this is the fallback when it did not fire.
        C_Timer.After(1, function()
            if SalesLedgerService._enabled then BookCommodityPurchase(nil, nil) end
        end)
    end)
    owner:RegisterEvent("COMMODITY_PURCHASE_FAILED", function()
        pendingCommodity, quote = nil, nil
    end)
    owner:RegisterEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", function(_, auctionID)
        auctionID = tonumber(auctionID)
        local pb = auctionID and pendingBids[auctionID]
        if pb then
            pendingBids[auctionID] = nil
            if pb.itemID and pb.amount and GetTime() - pb.t < 300 then
                local qty = math.max(1, tonumber(pb.qty) or 1)
                if qty == 1 then
                    RecordBuy(pb.itemID, 1, pb.amount, "ah")
                else
                    -- UNVERIFIED: whether PlaceBid's amount for a stack is per unit (buyoutAmount is per
                    -- unit) or the stack total. Book an estimate; the buyer invoice replaces it.
                    RecordBuy(pb.itemID, qty, pb.amount * qty, "ah", true)
                end
            end
        end
    end)
    owner:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED", BookPendingPost)
    owner:RegisterEvent("AUCTION_HOUSE_POST_ERROR", function() pendingPost = nil end)
    --- AUCTION_HOUSE_POST_WARNING (no payload; verified 2026-10-15, AuctionHouseDocumentation.lua):
    --- the post needs confirmation and nothing is created unless Confirm* follows.
    owner:RegisterEvent("AUCTION_HOUSE_POST_WARNING", function()
        postWarnAt = GetTime()
        if pendingPost then pendingPost.awaitConfirm = true end
    end)
    owner:RegisterEvent("AUCTION_HOUSE_CLOSED", function()
        pendingPost, pendingCommodity, quote = nil, nil, nil
        wipe(pendingBids)
    end)

    owner:RegisterEvent("CHAT_MSG_SYSTEM", function(_, text)
        if type(text) ~= "string" or (issecretvalue and issecretvalue(text)) then return end
        local pat = Patterns().chatSold
        local name = pat and text:match(pat)
        if not name then return end
        local store = Store()
        if store and AddPendingSold(store, name, "chat", time()) then
            Notify("chatSold")
        end
    end)

    owner:RegisterEvent("CRAFTINGORDERS_DISPLAY_CRAFTER_FULFILLED_MSG",
        function(_, orderTypeString, itemNameString, playerNameString, tipAmount, quantityCrafted)
            local store = Store()
            if not store then return end
            Append(store.orders, {
                t = time(), guid = Guid(), item = itemNameString, customer = playerNameString,
                tip = tonumber(tipAmount) or 0, qty = tonumber(quantityCrafted) or 1,
                orderType = orderTypeString,
            }, CAP_ORDERS)
            Notify("order")
        end)

    local moneyPending = false
    owner:RegisterEvent("PLAYER_MONEY", function()
        if moneyPending then return end
        moneyPending = true
        C_Timer.After(2, function()
            moneyPending = false
            if SalesLedgerService._enabled then SnapshotMoney() end
        end)
    end)
    owner:RegisterEvent("ACCOUNT_MONEY", SnapshotWarband)
    owner:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        SnapshotMoney()
        SnapshotWarband()
    end)
    SnapshotMoney()
    SnapshotWarband()
end

function SalesLedgerService:Disable()
    if not self._enabled then return end
    -- Post-hooks stay installed (cannot be removed) and no-op while disabled.
    self._enabled = false
    pendingPost, pendingCommodity, quote = nil, nil, nil
    wipe(pendingBids)
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
    end
end

ns.SalesLedgerService = SalesLedgerService
