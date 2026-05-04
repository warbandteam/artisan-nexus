--[[
    Artisan Nexus — Hub UI (Profitability / Shopping List / Crafting Queue).

    Single themed window with three tabs powered by:
      * ProfitabilityService:ListRecipes
      * ShoppingListService:Aggregate
      * CraftingQueueService:GetQueue

    Each tab refreshes when its source SendMessage fires:
      AH_PRICES_UPDATED         -> Profitability + Shopping
      AN_SHOPPING_LIST_UPDATED  -> Shopping
      AN_CRAFT_QUEUE_UPDATED    -> Queue

    Slash: /an hub  (registered in Core after this file loads).
]]

local ADDON_NAME, ns = ...

local ArtisanHubUI = {}
local FRAME = nil
local CURRENT_TAB = "profit"

local function Apply(frame, bg, border)
    if ns.UI_ApplyVisuals then
        ns.UI_ApplyVisuals(frame, bg, border)
    else
        if frame.SetBackdrop then
            frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
            frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
        end
    end
end

local function Colors() return ns.UI_COLORS or {} end

local function FormatCopper(c)
    if not c or c <= 0 then return nil end
    local g = math.floor(c / 10000)
    local s = math.floor((c / 100) % 100)
    local cu = c % 100
    if g > 0 then return string.format("%dg %ds", g, s) end
    if s > 0 then return string.format("%ds %dc", s, cu) end
    return string.format("%dc", cu)
end

local function ItemName(itemID)
    if not itemID then return "?" end
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    local name = (GetItemInfo and select(1, GetItemInfo(itemID))) or ("item:" .. itemID)
    return name
end

local function ItemIcon(itemID)
    if not itemID then return 134400 end
    if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(itemID) end
    return select(10, GetItemInfo(itemID)) or 134400
end

-- ─────────────────────────────────────────────────────────────────
-- Window chrome
-- ─────────────────────────────────────────────────────────────────
local function BuildChrome()
    local f = CreateFrame("Frame", "ArtisanNexusHub", UIParent, "BackdropTemplate")
    f:SetSize(720, 500)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:Hide()
    Apply(f, (Colors().bg or {0.11, 0.105, 0.125, 0.98}), { (Colors().accent or {0.52,0.40,0.66,1})[1],
        (Colors().accent or {0.52,0.40,0.66,1})[2],
        (Colors().accent or {0.52,0.40,0.66,1})[3], 0.85 })
    tinsert(UISpecialFrames, "ArtisanNexusHub")

    local header = CreateFrame("Frame", nil, f)
    header:SetHeight(40)
    header:SetPoint("TOPLEFT", 2, -2)
    header:SetPoint("TOPRIGHT", -2, -2)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    Apply(header, Colors().accentDark or {0.38,0.28,0.50,1}, Colors().accent or {0.52,0.40,0.66,1})

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 14, 0)
    title:SetText("Artisan Hub")
    title:SetTextColor(1, 1, 1)

    local close = CreateFrame("Button", nil, header)
    close:SetSize(28, 28)
    close:SetPoint("RIGHT", -8, 0)
    Apply(close, {0.15, 0.15, 0.15, 0.9}, Colors().accent or {0.52,0.40,0.66,1})
    local x = close:CreateTexture(nil, "ARTWORK")
    x:SetSize(16, 16); x:SetPoint("CENTER")
    x:SetAtlas("uitools-icon-close"); x:SetVertexColor(0.9, 0.3, 0.3)
    close:SetScript("OnClick", function() f:Hide() end)
    close:SetScript("OnEnter", function() x:SetVertexColor(1, 0.2, 0.2) end)
    close:SetScript("OnLeave", function() x:SetVertexColor(0.9, 0.3, 0.3) end)

    -- Tabs
    local tabBar = CreateFrame("Frame", nil, f)
    tabBar:SetHeight(28)
    tabBar:SetPoint("TOPLEFT", 8, -46)
    tabBar:SetPoint("TOPRIGHT", -8, -46)

    f.tabs = {}
    local tabDefs = {
        { key = "profit", label = "Profitability" },
        { key = "shop",   label = "Shopping List" },
        { key = "queue",  label = "Crafting Queue" },
    }
    local x0 = 0
    for _, td in ipairs(tabDefs) do
        local btn = CreateFrame("Button", nil, tabBar)
        btn:SetSize(140, 26)
        btn:SetPoint("LEFT", x0, 0)
        Apply(btn, Colors().tabInactive or {0.115,0.108,0.128,1}, Colors().border or {0.40,0.36,0.48,1})
        local lbl = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("CENTER")
        lbl:SetText(td.label)
        lbl:SetTextColor(1, 1, 1)
        btn._lbl = lbl
        btn:SetScript("OnClick", function()
            CURRENT_TAB = td.key
            ArtisanHubUI:Refresh()
        end)
        f.tabs[td.key] = btn
        x0 = x0 + 144
    end

    -- Body (scrollframe with content)
    local body = CreateFrame("Frame", nil, f)
    body:SetPoint("TOPLEFT", 8, -78)
    body:SetPoint("BOTTOMRIGHT", -8, 8)
    Apply(body, Colors().bgCard or {0.125,0.118,0.138,1}, Colors().border or {0.40,0.36,0.48,1})
    f.body = body

    local scroll = CreateFrame("ScrollFrame", nil, body, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -28, 6)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    f.scroll = scroll
    f.content = content
    f._rows = {}

    -- Status footer
    local status = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -10, 4)
    status:SetTextColor(0.7, 0.7, 0.75)
    f.status = status

    return f
end

local function ApplyTabState()
    if not FRAME then return end
    for key, btn in pairs(FRAME.tabs) do
        local active = key == CURRENT_TAB
        Apply(btn,
            active and (Colors().tabActive or {0.22,0.175,0.30,1}) or (Colors().tabInactive or {0.115,0.108,0.128,1}),
            Colors().accent or {0.52,0.40,0.66,1})
        btn._lbl:SetTextColor(1, active and 1 or 0.85, active and 1 or 0.9)
    end
end

local function ClearRows()
    if not FRAME then return end
    for _, r in ipairs(FRAME._rows) do r:Hide() end
    FRAME._rows = {}
end

local function NewRow(yOffset)
    local row = CreateFrame("Frame", nil, FRAME.content)
    row:SetSize(FRAME.scroll:GetWidth() - 8, 26)
    row:SetPoint("TOPLEFT", 4, -yOffset)
    Apply(row, {0.05, 0.05, 0.07, 0.85}, {0, 0, 0, 0.4})
    table.insert(FRAME._rows, row)
    return row
end

-- ─────────────────────────────────────────────────────────────────
-- Tab: Profitability
-- ─────────────────────────────────────────────────────────────────
local function RenderProfitability()
    ClearRows()
    local svc = ns.ProfitabilityService
    if not svc then
        FRAME.status:SetText("ProfitabilityService not loaded")
        return
    end
    local rows = svc:ListRecipes({ useAverage = true })
    FRAME.content:SetSize(FRAME.scroll:GetWidth() - 8, math.max(40, #rows * 28))
    local y = 4

    -- Header
    local hdr = NewRow(y); y = y + 28
    local h1 = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h1:SetPoint("LEFT", 8, 0); h1:SetText("Recipe"); h1:SetTextColor(0.85,0.85,0.9)
    local h2 = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h2:SetPoint("LEFT", 280, 0); h2:SetWidth(80); h2:SetJustifyH("RIGHT")
    h2:SetText("Cost"); h2:SetTextColor(0.85,0.85,0.9)
    local h3 = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h3:SetPoint("LEFT", 380, 0); h3:SetWidth(80); h3:SetJustifyH("RIGHT")
    h3:SetText("Value"); h3:SetTextColor(0.85,0.85,0.9)
    local h4 = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h4:SetPoint("LEFT", 480, 0); h4:SetWidth(120); h4:SetJustifyH("RIGHT")
    h4:SetText("Profit"); h4:SetTextColor(0.85,0.85,0.9)

    local profitable, breakeven, losses, nodata = 0, 0, 0, 0

    for _, r in ipairs(rows) do
        local row = NewRow(y); y = y + 28

        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20); icon:SetPoint("LEFT", 6, 0)
        icon:SetTexture(ItemIcon(r.outputItem) or 134400)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        name:SetWidth(220); name:SetJustifyH("LEFT"); name:SetWordWrap(false)
        local profTag = r.profession and ("|cff888888" .. r.profession .. "|r ") or ""
        name:SetText(profTag .. (r.name or ("Recipe " .. r.spellID)))

        local costFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        costFS:SetPoint("LEFT", 280, 0); costFS:SetWidth(80); costFS:SetJustifyH("RIGHT")
        costFS:SetText(FormatCopper(r.cost) or "|cff888888-|r")

        local valFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        valFS:SetPoint("LEFT", 380, 0); valFS:SetWidth(80); valFS:SetJustifyH("RIGHT")
        local valTxt = FormatCopper(r.value) or "|cff888888-|r"
        if r.hasHistory then valTxt = valTxt .. " |cff8888aa~|r" end
        valFS:SetText(valTxt)

        local pFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pFS:SetPoint("LEFT", 480, 0); pFS:SetWidth(120); pFS:SetJustifyH("RIGHT")
        if r.margin and r.cost and r.cost > 0 then
            local color = (r.margin >= 0) and "|cff66ff66" or "|cffff6666"
            pFS:SetText(string.format("%s%s (%+d%%)|r",
                color, FormatCopper(r.margin) or "0", math.floor((r.marginPct or 0) + 0.5)))
            if r.margin > 0 then profitable = profitable + 1
            elseif r.margin == 0 then breakeven = breakeven + 1
            else losses = losses + 1 end
        else
            pFS:SetText("|cff888888no data|r")
            nodata = nodata + 1
        end

        -- Click → add to crafting queue +1
        row:EnableMouse(true)
        row:SetScript("OnMouseUp", function(_, btn)
            if btn == "LeftButton" and ns.CraftingQueueService then
                ns.CraftingQueueService:Add(r.spellID, 1)
                if ns.ArtisanNexus and ns.ArtisanNexus.Print then
                    ns.ArtisanNexus:Print(string.format("|cffd4af37+1 to queue:|r %s", r.name or ""))
                end
            elseif btn == "RightButton" and ns.ShoppingListService then
                ns.ShoppingListService:Add(r.spellID, 1)
                if ns.ArtisanNexus and ns.ArtisanNexus.Print then
                    ns.ArtisanNexus:Print(string.format("|cffd4af37+1 to shopping:|r %s", r.name or ""))
                end
            end
        end)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(r.name or ("Recipe " .. r.spellID), 1, 1, 1)
            if r.outputItem then GameTooltip:AddLine("Item: " .. ItemName(r.outputItem), 0.7, 0.7, 0.7) end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffaaaaaaLeft-click: add to crafting queue|r")
            GameTooltip:AddLine("|cffaaaaaaRight-click: add to shopping list|r")
            GameTooltip:Show()
            -- Price history sparkline for the output item (when available).
            if r.outputItem and ns.PriceHistoryUI then
                ns.PriceHistoryUI:ShowPopup(r.outputItem, self, "TOPLEFT")
            end
        end)
        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
            if ns.PriceHistoryUI then ns.PriceHistoryUI:HidePopup() end
        end)
    end

    FRAME.status:SetText(string.format("|cff66ff66%d profitable|r · |cffd4af37%d break-even|r · |cffff6666%d losses|r · |cff888888%d no data|r",
        profitable, breakeven, losses, nodata))
end

-- ─────────────────────────────────────────────────────────────────
-- Tab: Shopping List
-- ─────────────────────────────────────────────────────────────────
local function RenderShopping()
    ClearRows()
    local svc = ns.ShoppingListService
    if not svc then FRAME.status:SetText("ShoppingListService not loaded"); return end
    local entries = svc:GetEntries()
    local agg = svc:Aggregate({ subtractBags = true })

    local y = 4

    -- Section: queued recipes
    local hdr = NewRow(y); y = y + 28
    local h1 = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    h1:SetPoint("LEFT", 8, 0); h1:SetText("Recipes to craft")
    h1:SetTextColor(0.85, 0.85, 0.9)

    local rs = ns.RecipeService
    if #entries == 0 then
        local empty = NewRow(y); y = y + 28
        local fs = empty:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("LEFT", 12, 0); fs:SetText("|cff888888List empty — left-click recipes on Profitability tab to add.|r")
    else
        for _, e in ipairs(entries) do
            local row = NewRow(y); y = y + 28
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(20, 20); icon:SetPoint("LEFT", 6, 0)
            local outID = rs and rs:GetOutputItem(e.spellID) or nil
            icon:SetTexture(ItemIcon(outID))
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            name:SetPoint("LEFT", icon, "RIGHT", 6, 0); name:SetWidth(380)
            name:SetWordWrap(false); name:SetJustifyH("LEFT")
            name:SetText((rs and rs:GetRecipeName(e.spellID)) or ("Recipe " .. e.spellID))

            local count = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            count:SetPoint("RIGHT", -80, 0); count:SetText("x" .. (e.count or 1))

            local removeBtn = CreateFrame("Button", nil, row)
            removeBtn:SetSize(60, 18)
            removeBtn:SetPoint("RIGHT", -8, 0)
            Apply(removeBtn, {0.20, 0.10, 0.10, 0.9}, {0.6, 0.2, 0.2, 0.7})
            local rl = removeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            rl:SetPoint("CENTER"); rl:SetText("Remove")
            removeBtn:SetScript("OnClick", function()
                svc:Remove(e.spellID)
            end)
        end
    end

    -- Section: aggregated reagents
    y = y + 6
    local rhdr = NewRow(y); y = y + 28
    local rh = rhdr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rh:SetPoint("LEFT", 8, 0); rh:SetText("Reagents to acquire (after bags)")
    rh:SetTextColor(0.85, 0.85, 0.9)

    local sortedAgg = {}
    for _, row in pairs(agg) do
        if (row.short or 0) > 0 then sortedAgg[#sortedAgg + 1] = row end
    end
    table.sort(sortedAgg, function(a, b)
        local ac, bc = a.cost or -1, b.cost or -1
        if ac ~= bc then return ac > bc end
        return (a.itemID or 0) < (b.itemID or 0)
    end)

    local total, missing = svc:TotalCost()
    if #sortedAgg == 0 then
        local none = NewRow(y); y = y + 28
        local nfs = none:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nfs:SetPoint("LEFT", 12, 0)
        nfs:SetText("|cff66ff66All reagents already in bags.|r")
    else
        for _, row in ipairs(sortedAgg) do
            local r = NewRow(y); y = y + 28
            local icon = r:CreateTexture(nil, "ARTWORK")
            icon:SetSize(20, 20); icon:SetPoint("LEFT", 6, 0)
            icon:SetTexture(ItemIcon(row.itemID))
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local name = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            name:SetPoint("LEFT", icon, "RIGHT", 6, 0); name:SetWidth(280)
            name:SetWordWrap(false); name:SetJustifyH("LEFT")
            name:SetText(ItemName(row.itemID))
            local need = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            need:SetPoint("LEFT", 320, 0); need:SetWidth(120)
            need:SetJustifyH("LEFT")
            need:SetText(string.format("|cffff8866need %d|r |cff666666(have %d)|r", row.short, row.have or 0))
            local cost = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            cost:SetPoint("RIGHT", -8, 0); cost:SetWidth(150); cost:SetJustifyH("RIGHT")
            cost:SetText(FormatCopper(row.cost) or "|cff888888no price|r")
        end
    end

    FRAME.content:SetSize(FRAME.scroll:GetWidth() - 8, math.max(40, y))
    FRAME.status:SetText(string.format("Total: %s%s",
        FormatCopper(total) or "0", missing > 0 and string.format(" |cff888888(%d unpriced)|r", missing) or ""))
end

-- ─────────────────────────────────────────────────────────────────
-- Tab: Crafting Queue
-- ─────────────────────────────────────────────────────────────────
local function RenderQueue()
    ClearRows()
    local svc = ns.CraftingQueueService
    if not svc then FRAME.status:SetText("CraftingQueueService not loaded"); return end
    local q = svc:GetQueue()
    local rs = ns.RecipeService
    local y = 4

    if #q == 0 then
        local row = NewRow(y); y = y + 28
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("LEFT", 12, 0)
        fs:SetText("|cff888888Queue empty — left-click recipes on Profitability tab to add.|r")
    else
        for i, e in ipairs(q) do
            local row = NewRow(y); y = y + 28
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetSize(20, 20); icon:SetPoint("LEFT", 6, 0)
            local outID = rs and rs:GetOutputItem(e.spellID) or nil
            icon:SetTexture(ItemIcon(outID))
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            name:SetPoint("LEFT", icon, "RIGHT", 6, 0); name:SetWidth(340)
            name:SetWordWrap(false); name:SetJustifyH("LEFT")
            name:SetText((rs and rs:GetRecipeName(e.spellID)) or ("Recipe " .. e.spellID))

            local progress = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            progress:SetPoint("LEFT", 380, 0); progress:SetWidth(80)
            local pColor = (e.progress >= e.target) and "|cff66ff66" or "|cffd4af37"
            progress:SetText(string.format("%s%d/%d|r", pColor, e.progress, e.target))

            -- Up / Down / Remove buttons
            local function SmallBtn(label, dx, fn, dangerous)
                local b = CreateFrame("Button", nil, row)
                b:SetSize(28, 18)
                b:SetPoint("RIGHT", dx, 0)
                local bg = dangerous and {0.20, 0.10, 0.10, 0.9} or {0.15, 0.15, 0.18, 0.9}
                local bd = dangerous and {0.6, 0.2, 0.2, 0.7} or (Colors().accent or {0.52,0.40,0.66,1})
                Apply(b, bg, bd)
                local lbl = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                lbl:SetPoint("CENTER"); lbl:SetText(label)
                b:SetScript("OnClick", fn)
                return b
            end
            SmallBtn("X", -8, function() svc:Remove(e.spellID) end, true)
            SmallBtn("v", -40, function() svc:Move(e.spellID, 1) end)
            SmallBtn("^", -72, function() svc:Move(e.spellID, -1) end)
            SmallBtn("+1", -110, function() svc:Add(e.spellID, 1) end)
        end
    end

    FRAME.content:SetSize(FRAME.scroll:GetWidth() - 8, math.max(40, y))
    local sum = svc:GetSummary()
    FRAME.status:SetText(string.format("%d recipes · %d / %d crafted (%d remaining)",
        sum.recipes, sum.completed, sum.total, sum.remaining))
end

-- ─────────────────────────────────────────────────────────────────
-- Refresh + lifecycle
-- ─────────────────────────────────────────────────────────────────
function ArtisanHubUI:Refresh()
    if not FRAME or not FRAME:IsShown() then return end
    ApplyTabState()
    if CURRENT_TAB == "profit" then RenderProfitability()
    elseif CURRENT_TAB == "shop" then RenderShopping()
    elseif CURRENT_TAB == "queue" then RenderQueue() end
end

function ArtisanHubUI:Toggle()
    if not FRAME then FRAME = BuildChrome() end
    if FRAME:IsShown() then FRAME:Hide() else FRAME:Show(); self:Refresh() end
end

function ArtisanHubUI:Show()
    if not FRAME then FRAME = BuildChrome() end
    FRAME:Show(); self:Refresh()
end

-- Subscribe to live updates
local listener = CreateFrame("Frame")
local function HookMessages()
    if not ns.ArtisanNexus or not ns.ArtisanNexus.RegisterMessage then return end
    ns.ArtisanNexus:RegisterMessage("AH_PRICES_UPDATED", function() ArtisanHubUI:Refresh() end)
    ns.ArtisanNexus:RegisterMessage("AN_SHOPPING_LIST_UPDATED", function() ArtisanHubUI:Refresh() end)
    ns.ArtisanNexus:RegisterMessage("AN_CRAFT_QUEUE_UPDATED", function() ArtisanHubUI:Refresh() end)
end
listener:RegisterEvent("PLAYER_LOGIN")
listener:SetScript("OnEvent", function() C_Timer.After(2, HookMessages) end)

ns.ArtisanHubUI = ArtisanHubUI
