--[[
    Artisan Nexus — Hub tab kit (ns.HubUI_Internal, "H"): the WN-pattern pieces every Hub tab shares.

    Loads after Hub/HubData.lua and before Hub/Pages/*.lua. Nothing here is a widget of its own; each
    helper places Warband Nexus components the way WN tabs place them (WN_PAGE_PATTERN):

      H.Profile()                              ns.db.profile
      H.Refresh(tab)                           UI_MAIN_REFRESH_REQUESTED { tab, instantPopulate = true }
      H.COL                                    column widths shared by the Hub tables (px)
      H.IconColumn()                           unlabeled icon column (WN list rows: FramePoolFactory
                                               ITEM_ROW_COLS icon | name), placed before the name column
      H.ShowTruncatedCells(row, n)             tooltip with the full text of truncated cells (row hover
                                               fallback when the table has no tooltip of its own)
      H.NewTabBody(tabKey, expandProfileKey)   body kit: WN stat cards, collapsible section headers,
                                               TableKit tables (sortable headers), dim lines and the WN tab
                                               empty-state card, cached per tab and re-parented into the
                                               scrollChild on every paint (StatisticsUI / CurrencyUI pattern)
      H.ToolbarButton(titleCard, text, onClick, tooltip, onEnter)
                                               WN title-toolbar text button (UI_CreateTitleToolbarTextButton)
      H.LayoutToolbar(titleCard, textContainer, buttons)
                                               WN toolbar chain, right to left, + title text reserve
      H.TitleToolbarReserve(widths)            UI_ComputeTitleToolbarReserve
      H.ProfessionFilterButton(titleCard, tab) "Profession: X" toolbar button (profile.hubProfessionFilter,
                                               shared by every Hub tab) opening the shared WN dropdown menu
                                               (ns.ArtisanWindow.OpenDropdownMenu) right-aligned under it, like
                                               WN's toolbar flyouts (SharedWidgets_TitleToolbar.lua:195-300)
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local H = ns.HubUI_Internal
assert(H, "Hub/HubData.lua must load before Hub/HubTabKit.lua")

local Factory = ns.UI.Factory
local FontManager = ns.FontManager
local TK = ns.UI_TableKit
local TABLE = ns.UI_LAYOUT.TABLE
local E = ns.Constants.EVENTS
local SafeL = H.SafeL

local COLLAPSE_H = 36
--- Hub pages breathe more than WN's PAGE_STACK.SECTION_GAP (12); WN's own layout table stays untouched.
local HUB_SECTION_GAP = 22
H.SECTION_GAP = HUB_SECTION_GAP
local PROF_MENU_MIN_W = 160
--- WN StatisticsUI stat card height / icon size (STAT_CARD_H, ACH_COLL_ICON_SIZE).
local STAT_CARD_H, STAT_ICON = 90, 36
--- Stat card spacing: icon left inset (WN STAT_CARD_ICON_LEFT), icon-to-text gap, label-to-value gap,
--- value-to-line gap.
local STAT_CARD_ICON_LEFT, STAT_ICON_GAP, STAT_VALUE_GAP, STAT_SUB_GAP = 15, 12, 3, 3
--- Holds the profession flyout frames (the toolbar button is rebuilt on every paint).
local profMenuHost = {}

--- Column widths (px) shared by the Hub tables: icon (WN ROW_ICON_SIZE + pad), name floors, money,
--- exact money (copper precision, e.g. auction prices), count, percent, duration.
H.COL = { ICON = 24, NAME_MIN = 140, NAME_MIN_NARROW = 100, MONEY = 96, MONEY_WIDE = 112, MONEY_EXACT = 132,
    COUNT = 56, PCT = 68, TIME = 72 }

--- Unlabeled icon column placed before the name column (WN list rows: icon | name).
function H.IconColumn()
    return { key = "icon", label = "", width = H.COL.ICON, cell = "icon", align = "CENTER" }
end

--- Row hover fallback: the full text of every truncated text cell of the first `n` columns.
--- Returns true when a tooltip was shown.
function H.ShowTruncatedCells(row, n)
    local shown = false
    for ci = 1, n or 0 do
        local fs = TK.GetTextCell(row, ci)
        if fs and fs:IsShown() and fs:IsTruncated() then
            if not shown then
                GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
                shown = true
            end
            GameTooltip:AddLine(fs:GetText() or "", 1, 1, 1, true)
        end
    end
    if shown then
        GameTooltip:Show()
    end
    return shown
end

-- ─────────────────────────────────────────────────────────────────
-- Viewport culling: rows painted into the scrollChild stay Hidden while they are off screen, so a
-- long table costs only the visible rows on every scroll tick (WN tabs get this from
-- VirtualListModule). Updaters ride the WN dispatcher (mainFrame._virtualScrollUpdaters, called from
-- the shell's OnVerticalScroll); VirtualListModule.ClearVirtualScroll drops them on every populate.
-- ─────────────────────────────────────────────────────────────────

local CULL_BUFFER = 60

--- WN VirtualListModule EnsureVirtualUpdaterDispatcher: same table + dispatcher shape, so Hub culling
--- and WN virtual lists share one updater list.
local function EnsureScrollDispatcher(mf)
    if not mf._virtualScrollUpdaters then
        mf._virtualScrollUpdaters = {}
    end
    if not mf._virtualScrollUpdate then
        mf._virtualScrollUpdate = function()
            local updaters = mf._virtualScrollUpdaters
            if not updaters then return end
            for i = 1, #updaters do
                local fn = updaters[i]
                if type(fn) == "function" then
                    fn()
                end
            end
        end
    end
    return mf._virtualScrollUpdaters
end

--- Shows the rows of `cull` that overlap the scroll viewport (plus CULL_BUFFER px) and hides the rest.
--- cull.rows[i] = frame, cull.tops[i] / cull.heights[i] = its offset / height inside cull.host.
local function ApplyCull(cull)
    local mf = ArtisanNexus.UI and ArtisanNexus.UI.mainFrame
    local scroll = mf and mf.scroll
    local host = cull.host
    if not scroll or not host or not host:IsVisible() then return end
    local child = scroll:GetScrollChild()
    local childTop, hostTop = child and child:GetTop(), host:GetTop()
    if not childTop or not hostTop then return end
    -- Viewport in host coordinates (y grows downward).
    local first = (scroll:GetVerticalScroll() or 0) - (childTop - hostTop) - CULL_BUFFER
    local last = first + (scroll:GetHeight() or 0) + CULL_BUFFER * 2
    local rows, tops, heights = cull.rows, cull.tops, cull.heights
    for i = 1, cull.n do
        local top = tops[i]
        local visible = top + heights[i] >= first and top <= last
        local row = rows[i]
        if visible ~= row:IsShown() then
            row:SetShown(visible)
        end
    end
end

--- Starts a cull list for `host` (re-used table per host); call H.CullAdd per row, then H.CullCommit.
function H.CullBegin(cull, host)
    cull.host, cull.n = host, 0
    cull.rows, cull.tops, cull.heights = cull.rows or {}, cull.tops or {}, cull.heights or {}
    return cull
end

function H.CullAdd(cull, row, top, height)
    local n = cull.n + 1
    cull.n = n
    cull.rows[n], cull.tops[n], cull.heights[n] = row, top, height
end

--- Registers the cull list with the main window's scroll updaters (once per paint) and applies it.
function H.CullCommit(cull)
    for i = cull.n + 1, #cull.rows do
        cull.rows[i] = nil
    end
    local mf = ArtisanNexus.UI and ArtisanNexus.UI.mainFrame
    if not mf then return end
    local updaters = EnsureScrollDispatcher(mf)
    if not cull.fn then
        cull.fn = function() ApplyCull(cull) end
    end
    for i = #updaters, 1, -1 do
        if updaters[i] == cull.fn then
            table.remove(updaters, i)
        end
    end
    updaters[#updaters + 1] = cull.fn
    -- The host is anchored this frame; positions resolve on the next one.
    ApplyCull(cull)
    C_Timer.After(0, cull.fn)
end

local function Profile()
    return ns.db and ns.db.profile
end
H.Profile = Profile

--- Tab title in the theme accent (WN CurrencyUI / ProfessionsUI_DrawTab title cards).
function H.AccentTitle(text)
    local c = ns.UI_COLORS and ns.UI_COLORS.accent
    if not c then return text end
    return string.format("|cff%02x%02x%02x%s|r", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5),
        math.floor(c[3] * 255 + 0.5), text)
end

function H.Refresh(tab)
    ArtisanNexus:SendMessage(E.UI_MAIN_REFRESH_REQUESTED, { tab = tab, instantPopulate = true })
end

-- ─────────────────────────────────────────────────────────────────
-- Body kit (LedgerPage.lua helpers, one cache per tab)
-- ─────────────────────────────────────────────────────────────────

local TabBody = {}
TabBody.__index = TabBody

function H.NewTabBody(tabKey, expandKey)
    return setmetatable({
        tab = tabKey, expandKey = expandKey,
        headers = {}, strips = {}, pools = {}, lines = {}, defs = {}, cards = {},
        sorts = {}, sorted = {}, sortIndex = {}, culls = {},
    }, TabBody)
end

--- Start a paint: metrics, cursor at the scroll body top, every pooled row released.
function TabBody:Begin(parent)
    local mf = ArtisanNexus.UI and ArtisanNexus.UI.mainFrame
    local metrics = ns.UI_GetMainTabLayoutMetrics and ns.UI_GetMainTabLayoutMetrics(mf)
    local pageStack = ns.UI_LAYOUT.PAGE_STACK or {}
    self.parent = parent
    self.side = metrics and metrics.sideMargin or 12
    self.width = ((metrics and metrics.contentWidth) or (parent:GetWidth() or 600)) - self.side * 2
    self.y = (ns.UI_GetTabScrollContentStartY and ns.UI_GetTabScrollContentStartY()) or 8
    self.top = self.y
    self.sectionGap = math.max(pageStack.SECTION_GAP or 12, HUB_SECTION_GAP)
    for _, pool in pairs(self.pools) do
        TK.ReleaseRowsFrom(pool, 1)
    end
    -- A table skipped this paint (collapsed section) must not re-show its released rows.
    for _, cull in pairs(self.culls) do
        cull.n = 0
    end
    -- Blocks not placed again this paint (a character that left a grouped page, a line whose
    -- condition cleared) stay hidden; Section / Table / Line show what they place.
    for _, header in pairs(self.headers) do
        header:Hide()
    end
    for _, strip in pairs(self.strips) do
        strip:Hide()
    end
    for _, holder in pairs(self.lines) do
        holder:Hide()
    end
    return mf
end

function TabBody:PlaceWide(frame, height)
    local parent = self.parent
    frame:SetParent(parent)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", self.side, -self.y)
    frame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -self.side, -self.y)
    if height then frame:SetHeight(height) end
    frame:Show()
end

function TabBody:ExpandedState()
    local p = Profile()
    if p and type(p[self.expandKey]) ~= "table" then
        p[self.expandKey] = {}
    end
    return p and p[self.expandKey] or {}
end

local function HeaderOnToggle(isExpanded, header)
    local body, key = header and header._anBody, header and header._anKey
    if not body then return end
    if key then
        body:ExpandedState()[key] = isExpanded and true or false
    end
    H.Refresh(body.tab)
end

local function HeaderOnEnter(header)
    local tip = header._anTooltip
    if not tip then return end
    GameTooltip:SetOwner(header, "ANCHOR_TOP")
    GameTooltip:SetText(header._anTitle or "", 1, 1, 1)
    GameTooltip:AddLine(tip, 0.85, 0.85, 0.85, true)
    GameTooltip:Show()
end

local function HeaderOnLeave(header)
    if header._anTooltip then GameTooltip:Hide() end
end

--- WN collapsible section header at the cursor (section gap before all but the first block);
--- returns expanded. opts.tooltip: header hover text; opts.count: right-aligned summary text (WN
--- Professions section count: mainNavTabCount font, RIGHT -14); opts.countRole: its text role
--- (default "Muted"); opts.gap: gap before the header instead of the section gap.
function TabBody:Section(key, title, opts)
    if self.y > self.top then
        self.y = self.y + ((opts and opts.gap) or self.sectionGap)
    end
    local expanded = self:ExpandedState()[key] ~= false
    local header = self.headers[key]
    if not header then
        header = ns.UI_CreateCollapsibleHeader(self.parent, title, self.tab .. ":" .. key, expanded, HeaderOnToggle,
            nil, nil, nil, true)
        header._anBody, header._anKey = self, key
        -- Factory:ApplyHighlight owns OnEnter / OnLeave; the tooltip rides on hooks.
        header:HookScript("OnEnter", HeaderOnEnter)
        header:HookScript("OnLeave", HeaderOnLeave)
        self.headers[key] = header
    else
        header:SetParent(self.parent)
        ns.UI_RebindCollapsibleHeader(header, title, expanded, HeaderOnToggle)
    end
    header._anTitle = title
    header._anTooltip = opts and opts.tooltip or nil
    local count = opts and opts.count
    if count and not header._anCount then
        header._anCount = FontManager:CreateFontString(header, FontManager:GetFontRole("mainNavTabCount"), "OVERLAY")
        header._anCount:SetJustifyH("RIGHT")
        header._anCount:SetPoint("RIGHT", header, "RIGHT", -14, 0)
    end
    if header._anCount then
        header._anCount:SetText(count or "")
        header._anCount:SetShown(count ~= nil)
        ns.UI_SetTextColorRole(header._anCount, (opts and opts.countRole) or "Muted")
    end
    self:PlaceWide(header, COLLAPSE_H)
    self.y = self.y + COLLAPSE_H
    return expanded
end

--- One dim line (hint / empty text) at the cursor.
function TabBody:Line(key, text)
    local holder = self.lines[key]
    if not holder then
        holder = Factory:CreateContainer(self.parent, 1, 20, false)
        holder._fs = FontManager:CreateFontString(holder, "body", "OVERLAY")
        holder._fs:SetPoint("TOPLEFT", holder, "TOPLEFT", 12, -6)
        holder._fs:SetPoint("TOPRIGHT", holder, "TOPRIGHT", -12, -6)
        holder._fs:SetJustifyH("LEFT")
        holder._fs:SetWordWrap(true)
        self.lines[key] = holder
    end
    holder._fs:SetText(text or "")
    ns.UI_SetTextColorRole(holder._fs, "Dim")
    local h = math.max(28, (holder._fs:GetStringHeight() or 14) + 12)
    self:PlaceWide(holder, h)
    self.y = self.y + h
end

local function RowOnMouseUp(row, button)
    local d = row._anTblDef
    if d and d.onRowClick then d.onRowClick(row, row._anData, button) end
end

local function RowOnEnter(row)
    local d = row._anTblDef
    if d and d.onRowEnter then
        d.onRowEnter(row, row._anData)
    elseif d then
        H.ShowTruncatedCells(row, d.n)
    end
end

local function RowOnLeave(row)
    local d = row._anTblDef
    if d and d.onRowLeave then d.onRowLeave(row, row._anData) else GameTooltip:Hide() end
end

--- Header click (WN TableKit onSortClick): remember the column / direction, repaint the tab.
local function StripOnSortClick(colKey, ascending, strip)
    local body, key = strip._anBody, strip._anKey
    local st = body and body.sorts[key]
    if not st then return end
    st.key, st.asc = colKey, ascending and true or false
    H.Refresh(body.tab)
end

--- Rows of table `key` in the remembered header order (copied; the caller's list is not touched).
--- sortOpts: { key = default column key, asc = default direction, value = fn(row, colKey) ->
--- number | string | nil }. nil values sort last; ties keep the caller's order.
function TabBody:SortedRows(key, rows, sortOpts, stateKey)
    stateKey = stateKey or key
    local st = self.sorts[stateKey]
    if not st then
        st = { key = sortOpts.key, asc = sortOpts.asc == true }
        self.sorts[stateKey] = st
    end
    local out = self.sorted[key] or {}
    self.sorted[key] = out
    local idx = self.sortIndex
    wipe(idx)
    for i = 1, #rows do
        out[i] = rows[i]
        idx[rows[i]] = i
    end
    for i = #rows + 1, #out do
        out[i] = nil
    end
    local valueOf, colKey, asc = sortOpts.value, st.key, st.asc
    if colKey and valueOf then
        table.sort(out, function(a, b)
            local va, vb = valueOf(a, colKey), valueOf(b, colKey)
            if va ~= nil and vb ~= nil and va ~= vb then
                if asc then return va < vb end
                return va > vb
            end
            if va ~= nil and vb == nil then return true end
            if va == nil and vb ~= nil then return false end
            return idx[a] < idx[b]
        end)
    end
    return out, st
end

--- WN TableKit table (header strip + pooled rows) at the cursor; returns the painted row list
--- (sorted copy when opts.sort is set).
--- opts: onRowEnter(row, data) (default: full text of truncated cells), onRowLeave,
--- onRowClick(row, data, button), emptyText, sort (TabBody:SortedRows; columns with
--- sortable = true, defaultAscending = false for "high first"), header = false (rows only, under a
--- shared TabBody:Strip), sortFrom (key of that shared strip: its sort state orders these rows).
function TabBody:EnsureStrip(key)
    local strip = self.strips[key]
    if not strip then
        strip = TK.CreateHeaderStrip(self.parent, { mode = "text", bottomRule = true, onSortClick = StripOnSortClick })
        strip._widths, strip._offsets = {}, {}
        strip._anBody, strip._anKey = self, key
        self.strips[key] = strip
        self.pools[key] = TK.CreateRowPool(TABLE.ROW_H.standard)
    end
    return strip
end

--- A column strip alone at the cursor (one strip shared by grouped tables painted with
--- opts.header = false, WN Professions layout). sortOpts (optional, TabBody:SortedRows shape): the
--- strip's sortable headers drive the sort of every table drawn with opts.sortFrom = key.
function TabBody:Strip(key, cols, sortOpts)
    local strip = self:EnsureStrip(key)
    local st = self.sorts[key]
    if sortOpts and not st then
        st = { key = sortOpts.key, asc = sortOpts.asc == true }
        self.sorts[key] = st
    end
    TK.ResolveWidths(cols, self.width, strip._widths, strip._offsets)
    self:PlaceWide(strip)
    strip:SetWidth(self.width)
    strip:SetColumns(cols, strip._widths, strip._offsets, #cols)
    strip:SetSort(st and st.key, st and st.asc)
    self.y = self.y + strip:GetStripHeight()
end

function TabBody:Table(key, cols, rows, valueFn, opts)
    local strip = self:EnsureStrip(key)
    local def = self.defs[key] or {}
    self.defs[key] = def
    def.onRowEnter = opts and opts.onRowEnter
    def.onRowLeave = opts and opts.onRowLeave
    def.onRowClick = opts and opts.onRowClick
    def.n = #cols
    local sortState
    if opts and opts.sort then
        rows, sortState = self:SortedRows(key, rows, opts.sort, opts.sortFrom)
    end
    local pool = self.pools[key]
    local n = #cols
    local width = self.width
    TK.ResolveWidths(cols, width, strip._widths, strip._offsets)
    if not (opts and opts.header == false) then
        self:PlaceWide(strip)
        strip:SetWidth(width)
        strip:SetColumns(cols, strip._widths, strip._offsets, n)
        strip:SetSort(sortState and sortState.key, sortState and sortState.asc)
        self.y = self.y + strip:GetStripHeight()
    end
    local rh = pool.height
    self.culls[key] = self.culls[key] or {}
    local cull = H.CullBegin(self.culls[key], self.parent)
    for i = 1, #rows do
        local row = TK.AcquireRow(pool, self.parent, i, width, rh)
        row:SetPoint("TOPLEFT", self.parent, "TOPLEFT", self.side, -self.y)
        H.CullAdd(cull, row, self.y, rh)
        row._anData, row._anTblDef = rows[i], def
        if not row._anWired then
            row._anWired = true
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnMouseUp", RowOnMouseUp)
            row:SetScript("OnEnter", RowOnEnter)
            row:SetScript("OnLeave", RowOnLeave)
        end
        TK.PaintRowCells(row, cols, strip._widths, strip._offsets, n, rows[i], valueFn)
        self.y = self.y + rh
    end
    TK.ReleaseRowsFrom(pool, #rows + 1)
    H.CullCommit(cull)
    if #rows == 0 and opts and opts.emptyText then
        self:Line("tbl:" .. key, opts.emptyText)
    end
    return rows
end

-- ─────────────────────────────────────────────────────────────────
-- WN stat cards (StatisticsUI collection cards: icon + label + one big value, optional short line)
-- ─────────────────────────────────────────────────────────────────

local function CardOnMouseUp(card, button)
    local fn = card._anOnClick
    if button == "LeftButton" and fn then fn() end
end

local function CardOnEnter(card)
    local tip = card._anTooltip
    if not tip then return end
    GameTooltip:SetOwner(card, "ANCHOR_TOP")
    GameTooltip:SetText(card._anTitle or "", 1, 1, 1)
    GameTooltip:AddLine(tip, 0.85, 0.85, 0.85, true)
    GameTooltip:Show()
end

local function CardOnLeave(card)
    if card._anTooltip then GameTooltip:Hide() end
end

--- Value ink: tone = success | danger | warning | gold | dim (H.Ink kinds), nil = WN Normal role.
local function CardValue(value, tone)
    if tone then return H.Ink(value, tone) end
    return value
end

--- Grid of WN stat cards at the cursor (3 per row, 2 when narrow; equal sizes).
--- list[i] = { icon, label, value, tone, sub (one short line or nil), tooltip, onClick }.
function TabBody:StatCards(list)
    local gap = (ns.UI_LAYOUT.PAGE_STACK and ns.UI_LAYOUT.PAGE_STACK.CARD_GAP) or ns.UI_LAYOUT.CARD_GAP or 10
    local cols = 3
    if self.width < 180 * cols + gap * (cols - 1) then cols = 2 end
    local cardW = (self.width - gap * (cols - 1)) / cols
    local parent = self.parent
    for i = 1, #list do
        local d = list[i]
        local card = self.cards[i]
        if not card then
            card = ns.UI_CreateCard(parent, STAT_CARD_H)
            card._layout = ns.UI_CreateCardHeaderLayout(card, d.icon, STAT_ICON, false, d.label, " ", "subtitle", "header")
            local lay = card._layout
            card._sub = FontManager:CreateFontString(lay.container, "small", "OVERLAY")
            card._sub:SetJustifyH("LEFT")
            card._sub:SetWordWrap(false)
            -- Stack label / value / line top-down so the block can be measured and centred as one.
            lay.label:ClearAllPoints()
            lay.label:SetPoint("TOPLEFT", lay.container, "TOPLEFT", 0, 0)
            lay.label:SetPoint("TOPRIGHT", lay.container, "TOPRIGHT", 0, 0)
            lay.value:ClearAllPoints()
            lay.value:SetPoint("TOPLEFT", lay.label, "BOTTOMLEFT", 0, -STAT_VALUE_GAP)
            lay.value:SetPoint("RIGHT", lay.container, "RIGHT", 0, 0)
            card._sub:SetPoint("TOPLEFT", lay.value, "BOTTOMLEFT", 0, -STAT_SUB_GAP)
            card._sub:SetPoint("RIGHT", lay.container, "RIGHT", 0, 0)
            if ns.UI_ApplyStandardCardElevatedChrome then
                ns.UI_ApplyStandardCardElevatedChrome(card)
            end
            card:EnableMouse(true)
            card:SetScript("OnMouseUp", CardOnMouseUp)
            card:SetScript("OnEnter", CardOnEnter)
            card:SetScript("OnLeave", CardOnLeave)
            self.cards[i] = card
        end
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        card:SetParent(parent)
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", parent, "TOPLEFT", self.side + col * (cardW + gap), -(self.y + row * (STAT_CARD_H + gap)))
        card:SetSize(cardW, STAT_CARD_H)
        local lay = card._layout
        if lay.icon and lay.icon.texture and d.icon then
            lay.icon.texture:SetTexture(d.icon)
        end
        lay.label:SetText(d.label or "")
        ns.UI_SetTextColorRole(lay.label, "Bright")
        lay.value:SetText(CardValue(d.value or "", d.tone))
        local sub = d.sub
        card._sub:SetText(sub or "")
        ns.UI_SetTextColorRole(card._sub, "Muted")
        -- WN StatisticsUI FitCardHeaderLayoutToCard: icon pinned STAT_CARD_ICON_LEFT from the card's left
        -- edge, text left-aligned beside it; the stacked label / value / line block is centred vertically.
        local hasSub = sub and sub ~= ""
        card._sub:SetShown(hasSub and true or false)
        local blockH = (lay.label:GetStringHeight() or 12) + STAT_VALUE_GAP + (lay.value:GetStringHeight() or 16)
        if hasSub then
            blockH = blockH + STAT_SUB_GAP + (card._sub:GetStringHeight() or 10)
        end
        local textW = math.max(48, cardW - STAT_CARD_ICON_LEFT - STAT_ICON - STAT_ICON_GAP - 8)
        lay.icon:ClearAllPoints()
        lay.icon:SetPoint("CENTER", card, "LEFT", STAT_CARD_ICON_LEFT + STAT_ICON / 2, 0)
        lay.container:ClearAllPoints()
        lay.container:SetSize(textW, math.ceil(blockH))
        lay.container:SetPoint("LEFT", lay.icon, "RIGHT", STAT_ICON_GAP, 0)
        card._anTitle, card._anTooltip, card._anOnClick = d.label, d.tooltip, d.onClick
        card:Show()
    end
    local rows = math.ceil(#list / cols)
    self.y = self.y + rows * STAT_CARD_H + math.max(0, rows - 1) * gap
end

--- Pooled rows, widths and offsets of table `key` after its paint (row-anchored extras).
function TabBody:TableRows(key)
    local strip, pool = self.strips[key], self.pools[key]
    if not strip then return nil end
    return pool.rows, strip._widths, strip._offsets
end

--- WN tab empty-state card (SharedWidgets_EmptyState.lua UI_ShowTabEmptyStateCard) at the cursor.
function TabBody:Empty(cacheKey, title, desc, atlas)
    self.y = ns.UI_ShowTabEmptyStateCard(self.parent, cacheKey, self.y, {
        fillParent = false,
        sideInset = self.side,
        cacheKey = cacheKey,
        titleText = title,
        descText = desc,
        atlas = atlas,
    })
end

-- ─────────────────────────────────────────────────────────────────
-- Title toolbar (CurrencyUI / ItemsUI toolbar chain)
-- ─────────────────────────────────────────────────────────────────

local function TipOnLeave()
    GameTooltip:Hide()
end

--- WN title-toolbar text button; width follows the label (same sizing as LedgerPage.lua).
--- tooltip: string or function -> string; onEnter (optional) replaces the tooltip handler.
function H.ToolbarButton(titleCard, text, onClick, tooltip, onEnter)
    local btn, label = ns.UI_CreateTitleToolbarTextButton(titleCard, {
        text = text,
        autoWidth = true,
        onClick = onClick,
        onEnter = onEnter or (tooltip and function(b)
            GameTooltip:SetOwner(b, "ANCHOR_BOTTOM")
            GameTooltip:SetText(type(tooltip) == "function" and tooltip() or tooltip, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end) or nil,
        onLeave = (onEnter or tooltip) and TipOnLeave or nil,
    })
    if btn and label then
        btn:SetWidth(math.max(64, math.ceil(label:GetStringWidth() or 0) + 24))
    end
    return btn
end

--- Approximate title-toolbar reserve so the title / subtitle never run under the buttons.
function H.TitleToolbarReserve(widths)
    return (ns.UI_ComputeTitleToolbarReserve and ns.UI_ComputeTitleToolbarReserve(widths)) or 0
end

--- Chains `buttons` right to left on the title card (first = rightmost) and reserves their width
--- for the title / subtitle text.
function H.LayoutToolbar(titleCard, textContainer, buttons)
    local anchor
    local widths = {}
    for i = 1, #buttons do
        local b = buttons[i]
        if b then
            if anchor then
                ns.UI_ChainTitleToolbarControl(titleCard, b, anchor)
            else
                ns.UI_AnchorTitleToolbarControlRight(titleCard, b)
            end
            anchor = b
            widths[#widths + 1] = b:GetWidth() or 0
        end
    end
    if textContainer and #widths > 0 then
        textContainer:SetPoint("RIGHT", titleCard, "RIGHT", -H.TitleToolbarReserve(widths), 0)
    end
end

-- ─────────────────────────────────────────────────────────────────
-- Profession filter (title toolbar + shared WN dropdown menu)
-- ─────────────────────────────────────────────────────────────────

local function ProfessionFilterText(key)
    if key == "All" then
        return SafeL("HUB_PROF_FILTER_ALL", "All")
    end
    return ns.GetProfessionDisplayName and ns.GetProfessionDisplayName(key) or tostring(key)
end

local function ProfessionItems()
    local order = (ns.Constants and ns.Constants.CRAFT_PROFESSION_FILTERS) or { "All" }
    local items = {}
    for i = 1, #order do
        items[i] = { key = order[i], label = ProfessionFilterText(order[i]) }
    end
    return items
end

--- "Profession: X" title-toolbar button; picking a profession sets profile.hubProfessionFilter
--- (shared by every Hub tab) and repaints `tab`.
function H.ProfessionFilterButton(titleCard, tab)
    local label = string.format("%s: %s", SafeL("RECIPE_MATCHER_PROF_SHORT", "Profession"),
        ProfessionFilterText(H.GetHubProfessionFilter()))
    return H.ToolbarButton(titleCard, label, function(btn)
        ns.ArtisanWindow.OpenDropdownMenu(btn, {
            items = ProfessionItems,
            value = H.GetHubProfessionFilter,
            minWidth = PROF_MENU_MIN_W,
            alignRight = true,
            host = profMenuHost,
            onSelected = function(value)
                local p = Profile()
                if p then
                    p.hubProfessionFilter = value
                end
                H.Refresh(tab)
            end,
        })
    end, SafeL("HUB_PROF_FILTER_TT", "Filter by profession (all Hub pages)."))
end
