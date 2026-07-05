--[[
    Artisan Nexus — scroll factory (Warband-aligned custom scrollbars).
    Loaded after ArtisanSharedWidgets.lua + ArtisanTheme.lua.
]]

local _, ns = ...

local floor = math.floor
local min = math.min
local max = math.max
local tinsert = table.insert

ns.UI = ns.UI or {}
ns.UI.Factory = ns.UI.Factory or {}

local Factory = ns.UI.Factory
local COLORS = ns.UI_COLORS
local GetPixelScale = ns.GetPixelScale or function() return 1 end
local GetColors = function() return ns.UI_COLORS or {} end

ns.SCROLL_CHROME_REGISTRY = ns.SCROLL_CHROME_REGISTRY or {}
local SCROLL_CHROME_REGISTRY = ns.SCROLL_CHROME_REGISTRY

ns.VIEWPORT_DEBUG_REGISTRY = ns.VIEWPORT_DEBUG_REGISTRY or {}

local VIEWPORT_DEBUG_COLORS = {
    loot_catalog_vp = { 0.12, 0.42, 0.92, 0.38 },
    loot_catalog_host = { 0.12, 0.42, 0.92, 0.12 },
    loot_catalog_scroll = { 0.20, 0.62, 1.00, 0.22 },
    loot_catalog_bar = { 0.92, 0.18, 0.82, 0.45 },
    loot_session_vp = { 0.92, 0.38, 0.12, 0.38 },
    loot_session_host = { 0.92, 0.38, 0.12, 0.12 },
    loot_session_scroll = { 1.00, 0.55, 0.20, 0.22 },
    loot_session_bar = { 0.92, 0.18, 0.82, 0.45 },
    hub_body_vp = { 0.18, 0.78, 0.32, 0.35 },
    hub_body_host = { 0.18, 0.78, 0.32, 0.12 },
    hub_scroll = { 0.55, 0.90, 0.22, 0.28 },
    hub_bar = { 0.92, 0.18, 0.82, 0.45 },
    recipe_vp = { 0.58, 0.22, 0.88, 0.35 },
    recipe_host = { 0.58, 0.22, 0.88, 0.12 },
    recipe_scroll = { 0.72, 0.40, 1.00, 0.24 },
    recipe_bar = { 0.92, 0.18, 0.82, 0.45 },
    settings_scroll = { 0.12, 0.82, 0.88, 0.30 },
    settings_bar = { 0.92, 0.18, 0.82, 0.45 },
}

function ns.UI_IsViewportDebugEnabled()
    local addon = ns.ArtisanNexus
    return addon and addon.db and addon.db.profile and addon.db.profile.debugMode == true
end

--- Tint a viewport/host/bar column when `/an debug` is on (layout QA).
function ns.UI_ApplyViewportDebugBg(frame, key)
    if not frame then
        return
    end
    local tex = frame._anViewportDebugBg
    if not ns.UI_IsViewportDebugEnabled() then
        if tex then
            tex:Hide()
        end
        return
    end
    local c = VIEWPORT_DEBUG_COLORS[key] or { 1, 0, 1, 0.30 }
    if not tex then
        tex = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        tex:SetAllPoints()
        frame._anViewportDebugBg = tex
    end
    tex:SetColorTexture(c[1], c[2], c[3], c[4])
    tex:Show()
    frame._anViewportDebugKey = key
end

function ns.UI_RegisterViewportDebug(frame, key)
    if not frame or not key then
        return
    end
    local reg = ns.VIEWPORT_DEBUG_REGISTRY
    for i = 1, #reg do
        local entry = reg[i]
        if entry.frame == frame then
            entry.key = key
            ns.UI_ApplyViewportDebugBg(frame, key)
            return
        end
    end
    reg[#reg + 1] = { frame = frame, key = key }
    ns.UI_ApplyViewportDebugBg(frame, key)
end

function ns.UI_RefreshAllViewportDebugChrome()
    local reg = ns.VIEWPORT_DEBUG_REGISTRY
    if not reg then
        return
    end
    for i = #reg, 1, -1 do
        local entry = reg[i]
        if not entry.frame then
            table.remove(reg, i)
        else
            ns.UI_ApplyViewportDebugBg(entry.frame, entry.key)
        end
    end
end

local function ResolveScrollChromeBackdrop()
    if ns.UI_GetControlChromeHoverBackdrop then
        local c = ns.UI_GetControlChromeHoverBackdrop()
        return c[1], c[2], c[3], (c[4] or 1) * 0.92
    end
    return 0.08, 0.08, 0.10, 0.9
end

local function ApplyScrollChromeBackdrop(tex)
    if not tex or not tex.SetColorTexture then return end
    local r, g, b, a = ResolveScrollChromeBackdrop()
    tex:SetColorTexture(r, g, b, a)
end

local function RegisterScrollChrome(host)
    if host and not host._anScrollChromeRegistered then
        host._anScrollChromeRegistered = true
        tinsert(SCROLL_CHROME_REGISTRY, host)
    end
end

local function RefreshScrollChromeHost(host)
    if not host then return end
    if host._anTrackBg then
        ApplyScrollChromeBackdrop(host._anTrackBg)
    end
    if host.CustomTrack then
        ApplyScrollChromeBackdrop(host.CustomTrack)
    end
    if host.ScrollUpBtn and host.ScrollUpBtn.bg then
        ApplyScrollChromeBackdrop(host.ScrollUpBtn.bg)
    end
    if host.ScrollDownBtn and host.ScrollDownBtn.bg then
        ApplyScrollChromeBackdrop(host.ScrollDownBtn.bg)
    end
    local C = GetColors()
    local ac = C.accent or { 0.44, 0.32, 0.58, 1 }
    if host._thumbTexture then
        host._thumbTexture:SetColorTexture(ac[1], ac[2], ac[3], 0.9)
    end
    if host.BorderLeft then
        host.BorderLeft:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
        host.BorderRight:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
        host.BorderTop:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
        host.BorderBottom:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
    end
end

function ns.UI_RefreshScrollChrome()
    for i = #SCROLL_CHROME_REGISTRY, 1, -1 do
        local host = SCROLL_CHROME_REGISTRY[i]
        if not host then
            table.remove(SCROLL_CHROME_REGISTRY, i)
        else
            RefreshScrollChromeHost(host)
        end
    end
    if ns.UI_RefreshScrollBarColumns then
        ns.UI_RefreshScrollBarColumns()
    end
end

function ns.UI_GetScrollStep()
    local layout = ns.UI_LAYOUT or {}
    local base = layout.SCROLL_BASE_STEP or 28
    local speed = layout.SCROLL_SPEED_DEFAULT or 1.0
    local addon = ns.ArtisanNexus
    if addon and addon.db and addon.db.profile and addon.db.profile.scrollSpeed then
        speed = addon.db.profile.scrollSpeed
    end
    return floor(base * speed + 0.5)
end

local function ScrollFrameNeedsScroll(scrollFrame, contentHeight, frameHeight)
    local slack = 4
    if frameHeight and frameHeight >= 2 then
        return (contentHeight or 0) > frameHeight + slack
    end
    return (contentHeight or 0) > (frameHeight or 0) + slack
end

--- Themed scrollbar thumb: viewport/content ratio on usable track (Blizzard proportional rule).
local function ComputeThemedScrollThumbHeight(scrollBar, viewportH, contentH)
    local layout = ns.UI_LAYOUT or {}
    local minThumb = layout.SCROLL_THUMB_MIN_HEIGHT or 24
    local maxThumb = layout.SCROLL_THUMB_MAX_HEIGHT or 160
    if not scrollBar or not viewportH or viewportH < 1 then
        return minThumb
    end
    local upBtn = scrollBar.ScrollUpBtn or scrollBar.ScrollUpButton
    local downBtn = scrollBar.ScrollDownBtn or scrollBar.ScrollDownButton
    local btnTotal = 0
    if upBtn and upBtn.GetHeight then
        btnTotal = btnTotal + (upBtn:GetHeight() or 0)
    end
    if downBtn and downBtn.GetHeight then
        btnTotal = btnTotal + (downBtn:GetHeight() or 0)
    end
    local trackH = math.max(1, (scrollBar:GetHeight() or viewportH) - btnTotal)
    if not contentH or contentH <= viewportH then
        return math.min(trackH, maxThumb)
    end
    local ratio = viewportH / contentH
    local thumbH = math.floor(trackH * ratio)
    return math.max(minThumb, math.min(maxThumb, thumbH))
end

local function ApplyThemedScrollThumb(scrollBar, viewportH, contentH)
    if not scrollBar or not scrollBar.ThumbTexture then
        return
    end
    local layout = ns.UI_LAYOUT or {}
    local thumbW = layout.SCROLL_BAR_WIDTH or 14
    local thumbH = ComputeThemedScrollThumbHeight(scrollBar, viewportH, contentH)
    scrollBar.ThumbTexture:SetSize(thumbW, thumbH)
end

local function ApplyAccentBorders(frame, pixelScale)
    local C = GetColors()
    local ac = C.accent or { 0.44, 0.32, 0.58, 1 }
    if not frame.BorderTop then
        frame.BorderTop = frame:CreateTexture(nil, "BORDER")
        frame.BorderTop:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderTop:SetPoint("TOPLEFT", 0, 0)
        frame.BorderTop:SetPoint("TOPRIGHT", 0, 0)
        frame.BorderTop:SetHeight(pixelScale)

        frame.BorderBottom = frame:CreateTexture(nil, "BORDER")
        frame.BorderBottom:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderBottom:SetPoint("BOTTOMLEFT", 0, 0)
        frame.BorderBottom:SetPoint("BOTTOMRIGHT", 0, 0)
        frame.BorderBottom:SetHeight(pixelScale)

        frame.BorderLeft = frame:CreateTexture(nil, "BORDER")
        frame.BorderLeft:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderLeft:SetPoint("TOPLEFT", 0, 0)
        frame.BorderLeft:SetPoint("BOTTOMLEFT", 0, 0)
        frame.BorderLeft:SetWidth(pixelScale)

        frame.BorderRight = frame:CreateTexture(nil, "BORDER")
        frame.BorderRight:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderRight:SetPoint("TOPRIGHT", 0, 0)
        frame.BorderRight:SetPoint("BOTTOMRIGHT", 0, 0)
        frame.BorderRight:SetWidth(pixelScale)

        frame._borderType = "accent"
        frame._borderAlpha = 0.6
        if ns.BORDER_REGISTRY then
            tinsert(ns.BORDER_REGISTRY, frame)
        end
    end
    frame.BorderTop:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
    frame.BorderBottom:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
    frame.BorderLeft:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
    frame.BorderRight:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
end

local function CreateScrollArrowButton(scrollBar, scrollFrame, isUp)
    local layout = ns.UI_LAYOUT or {}
    local btnSize = layout.SCROLL_BAR_BUTTON_SIZE or 16
    local btn = isUp and scrollBar.ScrollUpBtn or scrollBar.ScrollDownBtn
    if btn then return btn end

    btn = CreateFrame("Button", nil, scrollFrame:GetParent())
    btn:SetSize(btnSize, btnSize)

    local bg = btn:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    ApplyScrollChromeBackdrop(bg)
    btn.bg = bg

    local pixelScale = GetPixelScale(btn)
    ApplyAccentBorders(btn, pixelScale)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(12, 12)
    icon:SetPoint("CENTER")
    icon:SetAtlas("common-icon-offscreen", false)
    icon:SetRotation(isUp and (-math.pi / 2) or (math.pi / 2))
    local C = GetColors()
    local ac = C.accent or { 0.44, 0.32, 0.58, 1 }
    icon:SetVertexColor(ac[1], ac[2], ac[3], 1)
    btn.icon = icon
    btn._iconTexture = icon

    btn:SetScript("OnClick", function()
        local step = ns.UI_GetScrollStep()
        local current = scrollFrame:GetVerticalScroll()
        local maxScroll = scrollFrame:GetVerticalScrollRange()
        local val
        if isUp then
            val = max(0, current - step)
        else
            val = min(maxScroll, current + step)
        end
        scrollFrame:SetVerticalScroll(val)
    end)

    btn:SetScript("OnEnter", function(self)
        local C2 = GetColors()
        local a = C2.accent or { 0.44, 0.32, 0.58, 1 }
        self.bg:SetColorTexture(a[1] * 0.3, a[2] * 0.3, a[3] * 0.3, 1)
        self.icon:SetVertexColor(a[1] * 1.3, a[2] * 1.3, a[3] * 1.3, 1)
    end)

    btn:SetScript("OnLeave", function(self)
        local C2 = GetColors()
        local a = C2.accent or { 0.44, 0.32, 0.58, 1 }
        ApplyScrollChromeBackdrop(self.bg)
        self.icon:SetVertexColor(a[1], a[2], a[3], 1)
    end)

    if isUp then
        scrollBar.ScrollUpBtn = btn
    else
        scrollBar.ScrollDownBtn = btn
    end
    return btn
end

function Factory:InstallScrollBarStyle(scrollFrame)
    if not scrollFrame or scrollFrame._anScrollStyled or not scrollFrame.ScrollBar then
        return scrollFrame
    end
    scrollFrame._anScrollStyled = true

    local scrollBar = scrollFrame.ScrollBar
    if scrollBar.ScrollUpButton then
        scrollBar.ScrollUpButton:Hide()
        scrollBar.ScrollUpButton:SetSize(0.1, 0.1)
    end
    if scrollBar.ScrollDownButton then
        scrollBar.ScrollDownButton:Hide()
        scrollBar.ScrollDownButton:SetSize(0.1, 0.1)
    end

    if not scrollBar.CustomTrack then
        scrollBar.CustomTrack = scrollBar:CreateTexture(nil, "BACKGROUND")
        scrollBar.CustomTrack:SetAllPoints(scrollBar)
        ApplyScrollChromeBackdrop(scrollBar.CustomTrack)
    end
    RegisterScrollChrome(scrollBar)

    local pixelScale = GetPixelScale(scrollBar)
    ApplyAccentBorders(scrollBar, pixelScale)

    if scrollBar.ThumbTexture then
        local C = GetColors()
        local ac = C.accent or { 0.44, 0.32, 0.58, 1 }
        scrollBar.ThumbTexture:SetColorTexture(ac[1], ac[2], ac[3], 0.9)
        scrollBar._thumbTexture = scrollBar.ThumbTexture

        scrollBar:SetScript("OnEnter", function(self)
            if self.ThumbTexture then
                local C2 = GetColors()
                local a = C2.accent or { 0.44, 0.32, 0.58, 1 }
                self.ThumbTexture:SetColorTexture(a[1] * 1.2, a[2] * 1.2, a[3] * 1.2, 1)
            end
        end)
        scrollBar:SetScript("OnLeave", function(self)
            if self.ThumbTexture then
                local C2 = GetColors()
                local a = C2.accent or { 0.44, 0.32, 0.58, 1 }
                self.ThumbTexture:SetColorTexture(a[1], a[2], a[3], 0.9)
            end
        end)
    end

    CreateScrollArrowButton(scrollBar, scrollFrame, true)
    CreateScrollArrowButton(scrollBar, scrollFrame, false)

    scrollBar:Hide()
    if scrollBar.ScrollUpBtn then scrollBar.ScrollUpBtn:Hide() end
    if scrollBar.ScrollDownBtn then scrollBar.ScrollDownBtn:Hide() end

    scrollBar._scrollFrame = scrollFrame
    scrollBar:SetScript("OnValueChanged", function(self, value)
        if self._scrollFrame and self._scrollFrame.SetVerticalScroll then
            self._scrollFrame:SetVerticalScroll(value)
        end
    end)

    scrollFrame.UpdateScrollBarVisibility = function(self)
        if not self.ScrollBar then return end
        local bar = self.ScrollBar
        local scrollChild = self:GetScrollChild()
        if not scrollChild then return end
        local contentHeight = scrollChild:GetHeight() or 0
        local frameHeight = self:GetHeight() or 0
        local needsScroll = ScrollFrameNeedsScroll(self, contentHeight, frameHeight)
        local barInExternalContainer = (bar.GetParent and bar:GetParent() ~= self)
        local col = self._anScrollBarColumn

        if col and self._anScrollAnchorTL and self._anScrollAnchorBRHidden and self._anScrollAnchorBRShown then
            local tl = self._anScrollAnchorTL
            local brHidden = self._anScrollAnchorBRHidden
            local brShown = self._anScrollAnchorBRShown
            self:ClearAllPoints()
            self:SetPoint(tl.a1 or "TOPLEFT", tl.frame, tl.a2 or "TOPLEFT", tl.x or 0, tl.y or 0)
            if needsScroll then
                col:Show()
                self:SetPoint(brShown.a1 or "BOTTOMRIGHT", brShown.frame, brShown.a2 or "BOTTOMLEFT", brShown.x or -2, brShown.y or 0)
            else
                col:Hide()
                if self._anExternalBarColumn then
                    self:SetPoint(brShown.a1 or "BOTTOMRIGHT", brShown.frame, brShown.a2 or "BOTTOMLEFT", brShown.x or -2, brShown.y or 0)
                else
                    self:SetPoint(brHidden.a1 or "BOTTOMRIGHT", brHidden.frame, brHidden.a2 or "BOTTOMRIGHT", brHidden.x or 0, brHidden.y or 0)
                end
                if self.SetVerticalScroll then
                    self:SetVerticalScroll(0)
                end
            end
        end

        if needsScroll then
            bar:Show()
            if bar.ScrollUpBtn then bar.ScrollUpBtn:Show() end
            if bar.ScrollDownBtn then bar.ScrollDownBtn:Show() end
            ApplyThemedScrollThumb(bar, frameHeight, contentHeight)
        else
            bar:Hide()
            if bar.ScrollUpBtn then bar.ScrollUpBtn:Hide() end
            if bar.ScrollDownBtn then bar.ScrollDownBtn:Hide() end
            if not barInExternalContainer and not col then
                return
            end
        end
    end

    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local step = ns.UI_GetScrollStep()
        local current = self:GetVerticalScroll()
        local maxScroll = self:GetVerticalScrollRange()
        local newScroll = max(0, min(maxScroll, current - (delta * step)))
        self:SetVerticalScroll(newScroll)
    end)

    return scrollFrame
end

function Factory:CreateScrollFrame(parent, template, customStyle)
    if not parent then return nil end
    template = template or "UIPanelScrollFrameTemplate"
    local scrollFrame = CreateFrame("ScrollFrame", nil, parent, template)
    if customStyle ~= false then
        self:InstallScrollBarStyle(scrollFrame)
    end
    return scrollFrame
end

ns.SCROLL_COLUMN_REGISTRY = ns.SCROLL_COLUMN_REGISTRY or {}

local function InstallScrollBarColumnChrome(container)
    if not container or container._anColumnChromeInstalled then
        return
    end
    container._anColumnChromeInstalled = true

    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if container.SetBackdrop then
            container:SetBackdrop(nil)
        end
        return
    end

    if not container._anTrackBg then
        local track = container:CreateTexture(nil, "BACKGROUND", nil, -2)
        track:SetAllPoints()
        ApplyScrollChromeBackdrop(track)
        container._anTrackBg = track
    end
    local pixelScale = GetPixelScale(container)
    ApplyAccentBorders(container, pixelScale)
    RegisterScrollChrome(container)
end

function ns.UI_RefreshScrollBarColumns()
    local reg = ns.SCROLL_COLUMN_REGISTRY
    if not reg then
        return
    end
    for i = #reg, 1, -1 do
        local col = reg[i]
        if not col then
            table.remove(reg, i)
        elseif ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
            -- Classic: rail art lives on ScrollBar (UI_EnsureClassicScrollBarRail), not the column shell.
        else
            if col._anTrackBg then
                ApplyScrollChromeBackdrop(col._anTrackBg)
            end
            if col.BorderLeft then
                local C = GetColors()
                local ac = C.accent or { 0.44, 0.32, 0.58, 1 }
                col.BorderLeft:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
                col.BorderRight:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
                col.BorderTop:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
                col.BorderBottom:SetColorTexture(ac[1], ac[2], ac[3], 0.6)
            end
        end
    end
end

function Factory:EnsureScrollBarColumnChrome(container)
    InstallScrollBarColumnChrome(container)
end

function Factory:CreateScrollBarColumn(parent, width, topInset, bottomInset, rightInset)
    if not parent then return nil end
    local layout = ns.UI_LAYOUT or {}
    local w = width or layout.SCROLLBAR_COLUMN_WIDTH or 26
    local top = (topInset == nil) and 0 or topInset
    local bottom = (bottomInset == nil) and 0 or bottomInset
    if rightInset == nil then
        if parent._anClassicDialogRoot and ns.UI_IsClassicUi and ns.UI_IsClassicUi() and ns.UI_GetClassicDialogInset then
            rightInset = ns.UI_GetClassicDialogInset()
        else
            rightInset = 0
        end
    end
    local container = CreateFrame("Frame", nil, parent)
    container:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -rightInset, -top)
    container:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -rightInset, bottom)
    container:SetWidth(w)
    container:SetFrameLevel((parent:GetFrameLevel() or 0) + 2)
    container:SetClipsChildren(true)
    InstallScrollBarColumnChrome(container)
    tinsert(ns.SCROLL_COLUMN_REGISTRY, container)
    container:Show()
    return container
end

function Factory:PositionScrollBarInContainer(scrollBar, scrollBarContainer, inset)
    if not scrollBar or not scrollBarContainer then return end
    local layout = ns.UI_LAYOUT or {}
    local btnSize = layout.SCROLL_BAR_BUTTON_SIZE or 16
    local barWidth = layout.SCROLL_BAR_WIDTH or 16

    local containerLevel = scrollBarContainer:GetFrameLevel()
    scrollBar:SetParent(scrollBarContainer)
    scrollBar:SetFrameLevel(containerLevel + 1)
    scrollBar:Show()

    if scrollBar.ScrollUpBtn then
        scrollBar.ScrollUpBtn:SetParent(scrollBarContainer)
        scrollBar.ScrollUpBtn:SetFrameLevel(containerLevel + 3)
        scrollBar.ScrollUpBtn:ClearAllPoints()
        scrollBar.ScrollUpBtn:SetSize(btnSize, btnSize)
        scrollBar.ScrollUpBtn:SetPoint("TOP", scrollBarContainer, "TOP", 0, 0)
        scrollBar.ScrollUpBtn:Show()
    end
    if scrollBar.ScrollDownBtn then
        scrollBar.ScrollDownBtn:SetParent(scrollBarContainer)
        scrollBar.ScrollDownBtn:SetFrameLevel(containerLevel + 3)
        scrollBar.ScrollDownBtn:ClearAllPoints()
        scrollBar.ScrollDownBtn:SetSize(btnSize, btnSize)
        scrollBar.ScrollDownBtn:SetPoint("BOTTOM", scrollBarContainer, "BOTTOM", 0, 0)
        scrollBar.ScrollDownBtn:Show()
    end
    scrollBar:ClearAllPoints()
    if scrollBar.ScrollUpBtn and scrollBar.ScrollDownBtn then
        scrollBar:SetPoint("TOP", scrollBar.ScrollUpBtn, "BOTTOM", 0, 0)
        scrollBar:SetPoint("BOTTOM", scrollBar.ScrollDownBtn, "TOP", 0, 0)
    else
        scrollBar:SetPoint("TOP", scrollBarContainer, "TOP", 0, 0)
        scrollBar:SetPoint("BOTTOM", scrollBarContainer, "BOTTOM", 0, 0)
    end
    scrollBar:SetWidth(barWidth)
    scrollBar:SetPoint("CENTER", scrollBarContainer, "CENTER", 0, 0)
end

--- Reparent native scrollbar into external column; keep scroll via hooked OnValueChanged.
function Factory:InstallClassicExternalScrollBar(scrollBar, scrollBarContainer, scrollFrame)
    if not scrollBar or not scrollBarContainer or not scrollFrame then
        return
    end
    scrollBar._anScrollFrame = scrollFrame
    if not scrollBar._anExternalValueHooked then
        scrollBar._anExternalValueHooked = true
        scrollBar:SetScript("OnValueChanged", function(self, value)
            local sf = self._anScrollFrame
            if sf and sf.SetVerticalScroll then
                sf:SetVerticalScroll(value)
            end
        end)
    end

    local colLevel = scrollBarContainer:GetFrameLevel() or 0
    scrollBar:SetParent(scrollBarContainer)
    scrollBar:SetFrameLevel(colLevel + 1)
    scrollBar:Show()

    local up = scrollBar.ScrollUpButton
    local down = scrollBar.ScrollDownButton
    if up then
        up:SetParent(scrollBarContainer)
        up:SetFrameLevel(colLevel + 2)
    end
    if down then
        down:SetParent(scrollBarContainer)
        down:SetFrameLevel(colLevel + 2)
    end

    if ns.UI_LayoutClassicScrollBarInColumn then
        ns.UI_LayoutClassicScrollBarInColumn(scrollBar, scrollBarContainer)
    end
end

--- Native UIPanelScrollFrameTemplate bar (Classic): scrollbar lives in external column, not on scroll frame edge.
function Factory:PositionNativeScrollBarInContainer(scrollBar, scrollBarContainer, scrollFrame)
    if not scrollBar or not scrollBarContainer then
        return
    end
    scrollFrame = scrollFrame or scrollBar:GetParent()
    Factory:InstallClassicExternalScrollBar(scrollBar, scrollBarContainer, scrollFrame)
end

function Factory:UpdateScrollBarVisibility(scrollFrame)
    if scrollFrame and scrollFrame.UpdateScrollBarVisibility then
        scrollFrame:UpdateScrollBarVisibility()
    end
end

--- Reserve right gutter on viewport inset; scrollbar column anchors to `host` outside this panel.
---@param viewport Frame inset panel (scroll parent)
---@param host Frame outer host (barParent)
---@param gap number|nil
function ns.UI_ApplyViewportInset(viewport, host, gap)
    if not viewport or not host then
        return
    end
    local gutter = (ns.UI_GetScrollBarGutter and ns.UI_GetScrollBarGutter(gap))
        or ((ns.UI_LAYOUT and ns.UI_LAYOUT.SCROLLBAR_COLUMN_WIDTH or 26) + (gap or (ns.UI_LAYOUT and ns.UI_LAYOUT.SCROLL_GAP) or 2))
    viewport:ClearAllPoints()
    viewport:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    viewport:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)
    viewport:SetPoint("TOPRIGHT", host, "TOPRIGHT", -gutter, 0)
    viewport:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -gutter, 0)
    viewport:SetClipsChildren(true)
    if host.SetClipsChildren then
        host:SetClipsChildren(true)
    end
end

--- Gutter strip on host right; height matches `heightFrame` (typically the scroll viewport).
function ns.UI_CreateScrollBarChromeHost(host, heightFrame)
    if not host or not heightFrame then
        return nil
    end
    local gutter = (ns.UI_GetScrollBarGutter and ns.UI_GetScrollBarGutter())
        or ((ns.UI_LAYOUT and ns.UI_LAYOUT.SCROLLBAR_COLUMN_WIDTH or 26) + (ns.UI_LAYOUT and ns.UI_LAYOUT.SCROLL_GAP or 2))
    local strip = CreateFrame("Frame", nil, host)
    strip:SetWidth(gutter)
    strip:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
    strip:SetPoint("TOP", heightFrame, "TOP", 0, 0)
    strip:SetPoint("BOTTOM", heightFrame, "BOTTOM", 0, 0)
    strip:SetClipsChildren(true)
    return strip
end

--- Shared opts: scroll inside `viewport`, bar column on `barParent` (outside viewport).
function ns.UI_BuildExternalScrollOpts(barParent, overrides)
    overrides = overrides or {}
    local layout = ns.UI_LAYOUT or {}
    local pad = overrides.pad or 6
    local gap = overrides.gap or layout.SCROLL_GAP or 2
    return {
        barParent = barParent,
        padL = overrides.padL or pad,
        padT = overrides.padT or -pad,
        padR = overrides.padR or pad,
        padB = overrides.padB or pad,
        gap = gap,
        topInset = overrides.topInset or math.abs(overrides.padT or pad),
        bottomInset = overrides.bottomInset or (overrides.padB or pad),
        barWidth = overrides.barWidth,
    }
end

--- Warband-style scroll host: bar column on the right, themed wheel + visibility.
---@return ScrollFrame scroll, Frame content, Frame barColumn
function ns.UI_AttachThemedScroll(parent, opts)
    opts = opts or {}
    local padL = opts.padL or 6
    local padR = opts.padR or padL
    local padT = opts.padT or -6
    local padB = opts.padB or 6
    local gap = opts.gap or 2
    local topInset = opts.topInset or math.abs(padT)
    local bottomInset = opts.bottomInset or padB
    local barParent = opts.barParent or parent
    local useExternalBar = barParent ~= parent

    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", padL, padT)
        scroll:SetClipsChildren(true)
        local barCol
        if useExternalBar then
            barCol = Factory:CreateScrollBarColumn(barParent, opts.barWidth, topInset, bottomInset)
            scroll:SetPoint("BOTTOMRIGHT", barCol, "BOTTOMLEFT", -gap, 0)
            scroll._anScrollBarColumn = barCol
            scroll._anExternalBarColumn = true
        else
            scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -padR, padB)
        end
        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(1, 1)
        scroll:SetScrollChild(content)
        if useExternalBar and barCol and scroll.ScrollBar then
            Factory:PositionNativeScrollBarInContainer(scroll.ScrollBar, barCol, scroll)
            if ns.UI_HookClassicScrollBarColumnLayout then
                ns.UI_HookClassicScrollBarColumnLayout(scroll, barCol)
            end
        end
        if ns.UI_ApplyClassicScrollBarLayout then
            ns.UI_ApplyClassicScrollBarLayout(scroll)
        end
        if ns.UI_EnableStandardScrollWheel then
            ns.UI_EnableStandardScrollWheel(scroll)
        end
        if not scroll._anNativeScrollHooked and scroll.HookScript then
            scroll._anNativeScrollHooked = true
            scroll:HookScript("OnScrollRangeChanged", function(sf)
                if ns.UI_ApplyClassicScrollBarLayout then
                    ns.UI_ApplyClassicScrollBarLayout(sf)
                elseif ns.UI_RefreshNativeScrollFrame then
                    ns.UI_RefreshNativeScrollFrame(sf)
                end
            end)
        end
        return scroll, content, barCol
    end

    local barCol = Factory:CreateScrollBarColumn(barParent, opts.barWidth, topInset, bottomInset)
    local scroll = Factory:CreateScrollFrame(parent, "UIPanelScrollFrameTemplate", true)
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", padL, padT)
    scroll:SetPoint("BOTTOMRIGHT", barCol, "BOTTOMLEFT", -gap, 0)
    scroll._anScrollBarColumn = barCol
    scroll._anScrollAnchorTL = { a1 = "TOPLEFT", frame = parent, a2 = "TOPLEFT", x = padL, y = padT }
    scroll._anScrollAnchorBRHidden = { a1 = "BOTTOMRIGHT", frame = parent, a2 = "BOTTOMRIGHT", x = -padR, y = padB }
    scroll._anScrollAnchorBRShown = { a1 = "BOTTOMRIGHT", frame = barCol, a2 = "BOTTOMLEFT", x = -gap, y = 0 }
    scroll._anExternalBarColumn = (barParent ~= parent)
    Factory:PositionScrollBarInContainer(scroll.ScrollBar, barCol, 0)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    return scroll, content, barCol
end

function ns.UI_RefreshNativeScrollFrame(scrollFrame)
    if not scrollFrame then
        return
    end
    if scrollFrame.UpdateScrollChildRect then
        pcall(function()
            scrollFrame:UpdateScrollChildRect()
        end)
    end
    local bar = scrollFrame.ScrollBar
    if bar and bar.SetMinMaxValues then
        local yrange = scrollFrame:GetVerticalScrollRange() or 0
        local val = scrollFrame:GetVerticalScroll() or 0
        if val > yrange then
            val = yrange
        end
        bar:SetMinMaxValues(0, yrange)
        bar:SetValue(val)
    end
end

function ns.UI_FinishScrollLayout(scrollFrame)
    Factory:UpdateScrollBarVisibility(scrollFrame)
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        local col = scrollFrame and scrollFrame._anScrollBarColumn
        local bar = scrollFrame and scrollFrame.ScrollBar
        if col and bar then
            if scrollFrame._anExternalBarColumn and Factory.InstallClassicExternalScrollBar then
                Factory:InstallClassicExternalScrollBar(bar, col, scrollFrame)
            elseif ns.UI_LayoutClassicScrollBarInColumn then
                ns.UI_LayoutClassicScrollBarInColumn(bar, col)
            end
        end
        if ns.UI_ApplyClassicScrollBarLayout then
            ns.UI_ApplyClassicScrollBarLayout(scrollFrame)
        else
            ns.UI_RefreshNativeScrollFrame(scrollFrame)
        end
    end
end

--- Match scroll child width to the scroll viewport (scrollbar column already excluded in modern skin).
---@param scroll Frame
---@param content Frame
---@param pad number|nil horizontal trim (default 0)
function ns.UI_SyncScrollChildWidth(scroll, content, pad)
    pad = pad or 0
    if not scroll or not content then
        return
    end
    local w = scroll:GetWidth()
    if w and w > pad then
        content:SetWidth(w - pad)
    end
end

--- 1px vertical separator between split panes; call RefreshDividerColor on theme change.
---@param parent Frame
---@return Frame divider
function ns.UI_CreatePaneDivider(parent)
    local divider = CreateFrame("Frame", nil, parent)
    divider:SetWidth(1)
    local tex = divider:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    divider._dividerTex = tex
    function divider:RefreshDividerColor()
        local c = ns.UI_COLORS or {}
        local b = c.border or { 0.26, 0.24, 0.30, 1 }
        tex:SetColorTexture(b[1], b[2], b[3], 0.55)
    end
    divider:RefreshDividerColor()
    return divider
end

--- Horizontal 1px rule (status bars, toolbars).
---@param parent Frame
---@return Texture line
function ns.UI_CreateHorizontalRule(parent)
    local tex = parent:CreateTexture(nil, "BORDER")
    tex:SetHeight(1)
    tex:SetPoint("LEFT", parent, "LEFT", 0, 0)
    tex:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    function tex:RefreshRuleColor()
        local c = ns.UI_COLORS or {}
        local b = c.border or { 0.26, 0.24, 0.30, 1 }
        tex:SetColorTexture(b[1], b[2], b[3], 0.45)
    end
    tex:RefreshRuleColor()
    return tex
end

function ns.UI_EnableStandardScrollWheel(scrollFrame)
    if not scrollFrame then return end
    scrollFrame:EnableMouseWheel(true)
    scrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local step = ns.UI_GetScrollStep()
        local cur = self:GetVerticalScroll()
        local maxS = self:GetVerticalScrollRange()
        local newScroll = max(0, min(cur - (delta * step), maxS))
        self:SetVerticalScroll(newScroll)
    end)
end
