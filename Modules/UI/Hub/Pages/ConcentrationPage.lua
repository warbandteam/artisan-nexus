--[[
    Artisan Nexus — Hub tab: Concentration (key "concentration"), drawn as a Warband Nexus main-window tab.

    WN tab pattern (LedgerPage.lua / WN StatisticsUI + CurrencyUI): ArtisanNexus:DrawConcentrationTab(scrollChild)
    returns the body height; UI_TabHost.lua dispatches it, the main window owns header / rail / scroll.

      fixedHeader  UI_BeginTabChromeLayout -> UI_CreateStandardTabTitleCard (subtitle = pools full /
                   cooldowns ready; profession filter flyout on the title toolbar) -> UI_PageStack_Place
                   -> UI_CommitTabFixedHeader
      Body         WN Professions / PvE layout: ONE column strip ([icon] Name | Current / Max | Full /
                   ready in), then one WN collapsible header per character (name in class color,
                   "N full · N ready" on the right; expand state in profile.hubConcentrationExpanded)
                   with that character's rows under it:
                     profession rows  ConcentrationPlannerService:GetPools() (AN snapshots / Warband
                                      Nexus via ns.CharacterData) with the WN Professions concentration
                                      bar (WN ProfessionsUI.lua:1031 PUI.UpdateConcentrationBar, copied
                                      below as UpdateConcentrationBar) and the time until full
                     cooldown rows    CooldownService:GetCooldowns() (charges, ready / ready in)
                   Profession row tooltip: rate, source, and the concentration plan of that profession
                   (ConcentrationPlannerService:GetPlan: budget across all characters, point value,
                   planned crafts); ctrl-click queues the planned crafts (CraftingQueueService:Add).
      Empty        no pool and no cooldown -> one WN tab empty-state card (UI_ShowTabEmptyStateCard)
    Refresh: UI_RefreshRouter.lua routes COOLDOWNS_UPDATED / CONCENTRATION_PLAN_UPDATED / WN_DATA_UPDATED
    (and PROFESSION_SNAPSHOT_UPDATED for the visible tab) to this tab.

    Body kit, toolbar, profession filter and ink: Hub/HubTabKit.lua + Hub/HubData.lua (H.NewTabBody,
    H.ProfessionFilterButton, H.Ink, H.Money, H.Signed).
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local H = ns.HubUI_Internal
assert(H and H.NewTabBody, "Hub/HubTabKit.lua must load before Hub/Pages/ConcentrationPage.lua")

local Factory = ns.UI.Factory
local FontManager = ns.FontManager
local TABLE = ns.UI_LAYOUT.TABLE
local SafeL = H.SafeL
local FormatDuration = H.FormatDuration
local RecipeIconTexture = H.RecipeIconTexture

--- "Full soon" status window.
local SOON_SECONDS = 12 * 3600
local NAME_MIN = H.COL.NAME_MIN
--- Planned crafts listed in a profession row tooltip.
local MAX_PLAN_LINES = 8

local Ink = H.Ink

-- ─────────────────────────────────────────────────────────────────
-- Shared row helpers
-- ─────────────────────────────────────────────────────────────────

local function UiString(v, fallback)
    if ns.CoerceUiString then
        local s = ns.CoerceUiString(v, fallback)
        if s ~= "" then return s end
        return fallback
    end
    if type(v) == "string" and v ~= "" and not (issecretvalue and issecretvalue(v)) then
        return v
    end
    return fallback
end

local function RecipeName(spellID, fallback)
    local name = UiString(fallback, nil)
    local rs = ns.RecipeService
    if not name then
        name = rs and rs:GetRecipeName(spellID)
    end
    if name == nil or name == "" then
        name = H.RecipeFallbackName(spellID)
    end
    return name
end

--- Class color through C_ClassColor (warcraft.wiki.gg API_C_ClassColor.GetClassColor -> ColorMixin).
local function ClassRGB(classFile)
    if classFile and C_ClassColor and C_ClassColor.GetClassColor then
        local ok, cc = pcall(C_ClassColor.GetClassColor, classFile)
        if ok and cc and cc.GetRGB then
            local r, g, b = cc:GetRGB()
            if type(r) == "number" then
                return r, g, b, 1
            end
        end
    end
    return nil
end

local function SpellLink(spellID)
    return spellID and C_Spell.GetSpellLink(spellID) or nil
end

local Money, SignedMoney = H.Money, H.Signed

local function Ago(t)
    return string.format(SafeL("HUB_CONC_UPDATED_FMT", "Updated: %d min ago"), math.floor(math.max(0, time() - t) / 60))
end

local body = H.NewTabBody("concentration", "hubConcentrationExpanded")

-- ─────────────────────────────────────────────────────────────────
-- Pools (WN Professions concentration bar)
-- ─────────────────────────────────────────────────────────────────

local BAR_HEIGHT = 16
local BAR_BORDER = 1

local function ProgressRgb(kind)
    local COLORS = ns.UI_COLORS
    if kind == "complete" then
        if ns.UI_IsLightMode and ns.UI_IsLightMode() then
            return 0.22, 0.55, 0.32
        end
        return 0.3, 0.9, 0.3
    end
    if kind == "partial" then
        local g = COLORS.gold
        return g[1], g[2], g[3]
    end
    local c = COLORS.textBright
    return c[1], c[2], c[3]
end

--- WN ProfessionsUI.lua:1031 PUI.UpdateConcentrationBar (verbatim apart from the AN key / locals).
local function UpdateConcentrationBar(parent, barKey, xOffset, yOffset, barWidth, current, maximum)
    local COLORS = ns.UI_COLORS
    current = current or 0
    maximum = maximum or 0
    local bar = parent[barKey]

    if not bar then
        bar = ns.UI.Factory:CreateContainer(parent, barWidth, BAR_HEIGHT, false)
        if bar then bar:SetFrameLevel(parent:GetFrameLevel() + 2) end

        -- Background
        bar.bg = bar:CreateTexture(nil, "BACKGROUND")
        bar.bg:SetAllPoints()
        local barBg = COLORS.surfaceRowOdd or COLORS.bg
        bar.bg:SetColorTexture(barBg[1], barBg[2], barBg[3], barBg[4] or 0.9)
        bar.bg:SetSnapToPixelGrid(false)
        bar.bg:SetTexelSnappingBias(0)

        -- Fill (inset by border)
        bar.fill = bar:CreateTexture(nil, "ARTWORK")
        bar.fill:SetPoint("TOPLEFT", bar, "TOPLEFT", BAR_BORDER, -BAR_BORDER)
        bar.fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", BAR_BORDER, BAR_BORDER)
        bar.fill:SetTexture("Interface\\Buttons\\WHITE8x8")
        bar.fill:SetSnapToPixelGrid(false)
        bar.fill:SetTexelSnappingBias(0)

        -- Border (OVERLAY so it always covers fill edges)
        local cr, cg, cb, ca = COLORS.accent[1], COLORS.accent[2], COLORS.accent[3], 0.22

        local function Border(p1, p2, w, h)
            local t = bar:CreateTexture(nil, "OVERLAY")
            t:SetTexture("Interface\\Buttons\\WHITE8x8")
            t:SetPoint(p1, bar, p1, 0, 0)
            t:SetPoint(p2, bar, p2, 0, 0)
            -- Whole physical pixels + grid snap (constant thickness at any offset/scale).
            local SetRule = ns.UI_SetRuleThickness
            if w then if SetRule then SetRule(t, "vertical", w) else t:SetWidth(w) end end
            if h then if SetRule then SetRule(t, "horizontal", h) else t:SetHeight(h) end end
            t:SetVertexColor(cr, cg, cb, ca)
            return t
        end

        bar.bTop   = Border("TOPLEFT", "TOPRIGHT", nil, BAR_BORDER)
        bar.bBot   = Border("BOTTOMLEFT", "BOTTOMRIGHT", nil, BAR_BORDER)
        bar.bLeft  = Border("TOPLEFT", "BOTTOMLEFT", BAR_BORDER, nil)
        bar.bRight = Border("TOPRIGHT", "BOTTOMRIGHT", BAR_BORDER, nil)

        -- Value text
        bar.valueText = FontManager:CreateBarOverlayFontString(bar, "OVERLAY")
        if not bar.valueText then
            bar.valueText = FontManager:CreateFontString(bar, "small", "OVERLAY")
            if ns.UI_ApplyFontStyleForRole then
                ns.UI_ApplyFontStyleForRole(bar.valueText, "small", { barOverlay = true })
            end
        end
        bar.valueText:SetPoint("CENTER", 0, 0)
        bar.valueText:SetJustifyH("CENTER")

        parent[barKey] = bar
    end
    if not bar then return nil end

    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, yOffset)
    bar:SetSize(barWidth, BAR_HEIGHT)

    if not maximum or maximum <= 0 then
        bar.fill:SetWidth(0.001)
        bar.fill:Hide()
        bar.valueText:SetText(ns.UI_GetTextRoleHex("Bright") .. "--|r")
        bar:Show()
        return bar
    end

    local contentWidth = barWidth - (BAR_BORDER * 2)
    local progress = math.min(1, math.max(0, current / maximum))
    local fillW = contentWidth * progress
    if fillW < 0.001 then fillW = 0.001 end
    bar.fill:SetWidth(fillW)
    bar.fill:Show()

    if current >= maximum then
        local gr, gg, gb = ProgressRgb("complete")
        bar.fill:SetVertexColor(gr, gg, gb, 1)
    elseif progress >= 0.5 then
        local yr, yg, yb = ProgressRgb("partial")
        bar.fill:SetVertexColor(yr, yg, yb, 1)
    else
        bar.fill:SetVertexColor(0.9, 0.45, 0.2, 1)
    end

    local br, bg, bb = ProgressRgb("neutral")
    bar.valueText:SetText(string.format("|cff%02x%02x%02x%d / %d|r", br * 255, bg * 255, bb * 255, current, maximum))
    bar:Show()
    return bar
end

local COLS = {
    H.IconColumn(),
    { key = "name", label = SafeL("HUB_CONC_COL_NAME", "Profession / cooldown"), flex = 1, min = NAME_MIN },
    { key = "conc", label = SafeL("HUB_COL_CONC_CURRENT_MAX", "Current / Max"), width = 170, align = "CENTER" },
    { key = "when", label = SafeL("HUB_CONC_COL_WHEN", "Full / ready in"), width = 104, align = "RIGHT" },
}
local BAR_CI = 3

-- ─────────────────────────────────────────────────────────────────
-- Row cells (row data: { pool = p } profession row | { cd = c } cooldown row)
-- ─────────────────────────────────────────────────────────────────

local function PoolWhen(p)
    if p.capped then
        return Ink(SafeL("HUB_CONC_FULL", "Full"), "green")
    elseif not p.secondsToCap then
        return Ink("-", "Dim")
    end
    local txt = FormatDuration(p.secondsToCap)
    if p.secondsToCap <= SOON_SECONDS then
        return Ink(txt, "gold")
    end
    return txt, "Bright"
end

local function CooldownWhen(c)
    if c.ready then
        return Ink(SafeL("HUB_CD_READY", "Ready"), "green")
    elseif c.readyAt then
        return string.format(SafeL("HUB_CD_IN_FMT", "in %s"), FormatDuration(c.readyAt - time())), "Muted"
    end
    return Ink("-", "Dim")
end

local function RowValue(col, d)
    local k = col.key
    local p, c = d.pool, d.cd
    if k == "icon" then
        if p then
            local icons = ns.KNOWN_PROFESSION_ICONS
            return (icons and icons[p.profession]) or "Interface\\Icons\\Trade_Engineering"
        end
        return RecipeIconTexture(c.spellID, nil)
    elseif k == "name" then
        if p then
            return UiString(p.professionName, p.profession or "-"), "Bright"
        end
        return RecipeName(c.spellID, c.name), "Normal"
    elseif k == "conc" then
        if p then
            return "" -- WN concentration bar (PaintBars)
        end
        if c.maxCharges and c.maxCharges > 0 then
            return string.format("%d / %d", c.charges or 0, c.maxCharges), "Muted"
        end
        return Ink("-", "Dim")
    end
    if p then
        return PoolWhen(p)
    end
    return CooldownWhen(c)
end

-- ─────────────────────────────────────────────────────────────────
-- Tooltips + clicks
-- ─────────────────────────────────────────────────────────────────

--- The profession's plan exists only for catalog professions; other keys would make GetPlan schedule
--- rebuilds that never produce a plan (refresh loop).
local function PlanFor(profession)
    local cat = ns.MidnightRecipeCatalog
    if not profession or type(cat) ~= "table" or type(cat[profession]) ~= "table"
        or type(cat[profession].recipes) ~= "table" then
        return nil, false
    end
    local planner = ns.ConcentrationPlannerService
    return planner and planner.GetPlan and planner:GetPlan(profession), true
end

local function AddPlanLines(profession)
    local plan, hasCatalog = PlanFor(profession)
    if not hasCatalog then return end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(SafeL("HUB_CONC_PLAN_HEAD", "Concentration plan (all characters)"), 1, 0.82, 0)
    if not plan then
        GameTooltip:AddLine(SafeL("HUB_PLAN_BUILDING", "Building plan..."), 0.7, 0.7, 0.7)
        return
    end
    GameTooltip:AddLine(string.format(SafeL("HUB_PLAN_BUDGET_FMT", "%d concentration over %s"),
        math.floor((plan.pool or 0) + 0.5), FormatDuration((tonumber(plan.horizonDays) or 0) * 86400)), 0.75, 0.75, 0.75)
    GameTooltip:AddLine(string.format(SafeL("HUB_PLAN_POINT_VALUE_FMT", "Value per concentration point: %s"),
        Money(plan.shadowPrice, nil, true)), 0.75, 0.75, 0.75)
    if (plan.unallocated or 0) > 0 then
        GameTooltip:AddLine(string.format(SafeL("HUB_PLAN_UNALLOCATED_FMT", "%d points unallocated"), plan.unallocated),
            0.75, 0.75, 0.75)
    end
    local rows = plan.rows or {}
    if #rows == 0 then
        GameTooltip:AddLine(SafeL("HUB_PLAN_EMPTY", "No recipe gains gold from concentration at current prices."),
            0.7, 0.7, 0.7, true)
        return
    end
    for i = 1, math.min(#rows, MAX_PLAN_LINES) do
        local r = rows[i]
        local name = string.format("%dx %s", r.crafts or 0, RecipeName(r.spellID))
        if r.demandCapped then
            name = name .. " " .. Ink(SafeL("HUB_PLAN_DEMAND_CAP", "[demand cap]"), "orange")
        end
        GameTooltip:AddDoubleLine(name, SignedMoney(r.expectedProfit, true), 0.9, 0.9, 0.9, 1, 1, 1)
    end
    if #rows > MAX_PLAN_LINES then
        GameTooltip:AddLine("...", 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(SafeL("HUB_CONC_TT_CTRL_QUEUE_PLAN", "Ctrl-click: queue the planned crafts"), 0.7, 0.7, 0.7)
end

local function PoolEnter(row, p)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(UiString(p.professionName, p.profession or "?"), 1, 1, 1)
    GameTooltip:AddLine(string.format("%s: %d / %d", p.charName or "?", p.current or 0, p.max or 0), 0.9, 0.8, 0.5)
    if p.ratePerHour and p.ratePerHour > 0 then
        GameTooltip:AddLine(string.format(SafeL("HUB_CONC_RATE_FMT", "+%d per hour"), math.floor(p.ratePerHour + 0.5)), 0.7, 0.7, 0.7)
    end
    if p.at and p.at > 0 then
        GameTooltip:AddLine(Ago(p.at), 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(p.source == "wn" and SafeL("HUB_CONC_SRC_WN", "Source: Warband Nexus")
        or SafeL("HUB_CONC_SRC_AN", "Source: Artisan Nexus snapshot"), 0.6, 0.6, 0.6)
    AddPlanLines(p.profession)
    GameTooltip:Show()
end

local function CooldownEnter(row, c)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(RecipeName(c.spellID, c.name), 1, 1, 1)
    GameTooltip:AddLine(c.charName or "?", 0.9, 0.8, 0.5)
    if not c.ready and c.readyAt then
        GameTooltip:AddLine(string.format(SafeL("HUB_CD_READY_AT_FMT", "Ready at %s"), date("%a %H:%M", c.readyAt)), 0.7, 0.7, 0.7)
    end
    if c.recordedAt then
        GameTooltip:AddLine(Ago(c.recordedAt), 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(SafeL("HUB_CRAFT_TT_SHIFT_SPELL", "Shift-click: link the recipe"), 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function RowEnter(row, d)
    if not d then return end
    if d.pool then
        PoolEnter(row, d.pool)
    else
        CooldownEnter(row, d.cd)
    end
end

local function QueuePlan(profession)
    local plan = PlanFor(profession)
    local qs = ns.CraftingQueueService
    if not plan or not qs or type(plan.rows) ~= "table" then return end
    for i = 1, #plan.rows do
        local r = plan.rows[i]
        if r.spellID and (r.crafts or 0) > 0 then
            qs:Add(r.spellID, r.crafts)
            ArtisanNexus:Print(string.format(SafeL("HUB_PLAN_QUEUED_FMT", "Queued %d x %s"), r.crafts, RecipeName(r.spellID)))
        end
    end
end

local function RowClick(row, d, button)
    if button ~= "LeftButton" or not d then return end
    if d.pool then
        if IsControlKeyDown() then
            QueuePlan(d.pool.profession)
        end
    elseif IsShiftKeyDown() then
        local link = SpellLink(d.cd.spellID)
        if link then HandleModifiedItemClick(link) end
    end
end

-- ─────────────────────────────────────────────────────────────────
-- Character groups
-- ─────────────────────────────────────────────────────────────────

local groupList, groupByKey = {}, {}

local function CharKey(e)
    return e.guid or e.charKey or e.charName or "?"
end

local function Group(e)
    local key = CharKey(e)
    local g = groupByKey[key]
    if not g then
        g = { key = key, rows = {} }
        groupByKey[key] = g
    end
    if not g.used then
        g.used = true
        g.name, g.classFile = e.charName or "?", e.classFile
        g.full, g.ready, g.nPools = 0, 0, 0
        wipe(g.rows)
        groupList[#groupList + 1] = g
    end
    g.classFile = g.classFile or e.classFile
    return g
end

local function ByProfession(a, b)
    return UiString(a.pool.professionName, a.pool.profession or "") < UiString(b.pool.professionName, b.pool.profession or "")
end

local function ByName(a, b)
    return a.name < b.name
end

--- Characters with their profession rows (by name) then cooldown rows (service order: ready first).
local function BuildGroups(pools, cooldowns)
    for _, g in pairs(groupByKey) do
        g.used = false
    end
    wipe(groupList)
    for i = 1, #pools do
        local p = pools[i]
        local g = Group(p)
        g.nPools = g.nPools + 1
        table.insert(g.rows, g.nPools, { pool = p })
        if p.capped then g.full = g.full + 1 end
    end
    for _, g in ipairs(groupList) do
        local profRows = {}
        for i = 1, g.nPools do profRows[i] = g.rows[i] end
        table.sort(profRows, ByProfession)
        for i = 1, g.nPools do g.rows[i] = profRows[i] end
    end
    for i = 1, #cooldowns do
        local c = cooldowns[i]
        local g = Group(c)
        g.rows[#g.rows + 1] = { cd = c }
        if c.ready then g.ready = g.ready + 1 end
    end
    table.sort(groupList, ByName)
    return groupList
end

local function ClassHex(classFile)
    local r, g, b = ClassRGB(classFile)
    if not r then return nil end
    return string.format("%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

--- Bars ride on the painted profession rows of one character table.
local function PaintBars(key, count)
    local rows, widths, offsets = body:TableRows(key)
    if not rows then return end
    local pad = TABLE.CELL_PAD_X
    local x, w = (offsets[BAR_CI] or 0) + pad, math.max(20, (widths[BAR_CI] or 120) - pad * 2)
    for i = 1, count do
        local row = rows[i]
        local d = row and row._anData
        if d and d.pool then
            local rh = row:GetHeight() or TABLE.ROW_H.standard
            UpdateConcentrationBar(row, "_anConcBar", x, -math.floor((rh - BAR_HEIGHT) / 2), w, d.pool.current or 0, d.pool.max or 0)
        elseif row and row._anConcBar then
            row._anConcBar:Hide()
        end
    end
end

local function DrawGroup(g)
    local hex = ClassHex(g.classFile)
    local title = hex and ("|cff" .. hex .. g.name .. "|r") or g.name
    local count = string.format(SafeL("HUB_CONC_CHAR_SUM_FMT", "%d full · %d ready"), g.full, g.ready)
    local key = "char:" .. g.key
    if not body:Section(key, title, { count = count, countRole = (g.full + g.ready > 0) and "Muted" or "Dim",
            gap = 8 }) then
        return
    end
    body:Table(key, COLS, g.rows, RowValue, { header = false, onRowEnter = RowEnter, onRowClick = RowClick })
    PaintBars(key, #g.rows)
end

-- ─────────────────────────────────────────────────────────────────
-- Tab
-- ─────────────────────────────────────────────────────────────────

local pools, cdRows = {}, {}

local function Filtered(list, out, profFilter, profOf)
    local n = 0
    for i = 1, #list do
        local prof = profFilter and profOf(list[i]) or nil
        if not profFilter or not prof or prof == profFilter then
            n = n + 1
            out[n] = list[i]
        end
    end
    for i = n + 1, #out do
        out[i] = nil
    end
    return out
end

local function PoolProfession(p)
    return p.profession
end

--- Stored cooldown profession is the localized name; filter by the catalog key of the recipe.
local function CooldownProfession(c)
    local rs = ns.RecipeService
    return rs and rs:GetProfession(c.spellID) or nil
end

local function Subtitle(list, cds)
    local full, ready = 0, 0
    for i = 1, #list do
        if list[i].capped then full = full + 1 end
    end
    for i = 1, #cds do
        if cds[i].ready then ready = ready + 1 end
    end
    return string.format(SafeL("HUB_CONC_SUB_FMT", "%d of %d pools full · %d cooldowns ready"), full, #list, ready)
end

---@param parent Frame main-window scrollChild
---@return number contentHeight
function ArtisanNexus:DrawConcentrationTab(parent)
    local mf = body:Begin(parent)

    local profFilter = H.ProfessionListOpt(H.GetHubProfessionFilter())
    local planner = ns.ConcentrationPlannerService
    local all = planner and planner.GetPools and planner:GetPools() or {}
    local svc = ns.CooldownService
    local allCds = svc and svc.GetCooldowns and svc:GetCooldowns() or {}
    Filtered(all, pools, profFilter, PoolProfession)
    Filtered(allCds, cdRows, profFilter, CooldownProfession)

    -- Fixed header: WN title card + profession filter on the title toolbar.
    local chrome = ns.UI_BeginTabChromeLayout and ns.UI_BeginTabChromeLayout(mf)
    if chrome then
        local titleCard = select(1, ns.UI_CreateStandardTabTitleCard(chrome.headerParent, {
            tabKey = "concentration",
            titleText = H.AccentTitle(SafeL("HUB_TAB_CONCENTRATION", "Concentration")),
            subtitleText = (#pools + #cdRows > 0) and Subtitle(pools, cdRows) or "",
            showUnderline = false,
            textRightInset = H.TitleToolbarReserve({ 180 }),
        }))
        titleCard:Show()
        local filterBtn = H.ProfessionFilterButton(titleCard, "concentration")
        if filterBtn then
            ns.UI_AnchorTitleToolbarControlRight(titleCard, filterBtn)
        end
        ns.UI_CommitTabFixedHeader(mf, ns.UI_PageStack_Place(chrome, titleCard))
    end

    local bridge = ns.WarbandNexusBridge
    local hasWN = bridge and bridge.IsAvailable and bridge:IsAvailable()
    if #all == 0 and #allCds == 0 then
        --- One card; the Warband Nexus line only when it is not loaded (it syncs alts automatically).
        local desc = hasWN and SafeL("HUB_CONC_NO_DATA", "Log into crafter alts with professions open.")
            or (SafeL("HUB_CONC_NO_POOLS_HINT", "Open each profession once on each character.")
                .. "\n" .. SafeL("HUB_CONC_BRIDGE_DESC", "Warband Nexus syncs alts automatically."))
        body:Empty("an_concentration", SafeL("HUB_CONC_EMPTY_TITLE", "No concentration data yet"), desc,
            "Professions-Icon-Accept-Order")
        return body.y
    end
    if #pools == 0 and #cdRows == 0 then
        body:Line("filtered", string.format(SafeL("HUB_CONC_NO_PROF_DATA", "No characters found with %s."),
            ns.GetProfessionDisplayName(profFilter)))
        return body.y
    end

    body:Strip("cols", COLS)
    local groups = BuildGroups(pools, cdRows)
    for i = 1, #groups do
        DrawGroup(groups[i])
    end
    return body.y
end
