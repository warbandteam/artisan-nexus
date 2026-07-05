--[[

    Artisan Nexus — Classic UI chrome (plain Blizzard templates).

    When profile.uiMode == "classic", window shell helpers use these instead of themed surfaces.

]]



local ADDON_NAME, ns = ...



local DIALOG_BG = "Interface\\DialogFrame\\UI-DialogBox-Background"

local DIALOG_BORDER = "Interface\\DialogFrame\\UI-DialogBox-Border"



local function ResolveUiMode()

    local p = ns.db and ns.db.profile

    if p and p.uiMode == "classic" then

        return "classic"

    end

    return "modern"

end



function ns.UI_GetUiMode()

    return ResolveUiMode()

end



function ns.UI_IsClassicUi()

    return ResolveUiMode() == "classic"

end



--- Frame template for Blizzard panel buttons (9-slice) vs Modern pixel BackdropTemplate.

function ns.UI_ClassicButtonTemplate()

    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then

        return "UIPanelButtonTemplate"

    end

    return "BackdropTemplate"

end



--- True when btn was created with UIPanelButtonTemplate (Left/Middle/Right slices).

function ns.UI_IsNativePanelButton(btn)

    if not btn then

        return false

    end

    if btn._anClassicNativePanel then

        return true

    end

    return btn.Left ~= nil and btn.Middle ~= nil

end



function ns.UI_SetNativePanelButtonText(btn, text)

    if not btn then

        return

    end

    if btn.SetText then

        btn:SetText(text)

        return

    end

    if btn.Text and btn.Text.SetText then

        btn.Text:SetText(text)

        return

    end

    local fs = btn.GetFontString and btn:GetFontString()

    if fs and fs.SetText then

        fs:SetText(text)

    end

end



--- Modern skin reserves a right-hand scrollbar column; Classic must match that

--- gutter so catalog/session columns and settings scroll share the same width.

---@param gap number|nil extra gap between content and bar (default UI_LAYOUT.SCROLL_GAP)

---@return number

function ns.UI_GetScrollBarGutter(gap)

    local layout = ns.UI_LAYOUT or {}

    if gap == nil then

        gap = layout.SCROLL_GAP or 2

    end

    return (layout.SCROLLBAR_COLUMN_WIDTH or 26) + gap

end



--- Hide Artisan pixel borders without unregistering from BORDER_REGISTRY.

function ns.UI_SuppressArtisanChrome(frame)

    if not frame then

        return

    end

    for _, key in ipairs({ "BorderTop", "BorderBottom", "BorderLeft", "BorderRight" }) do

        local tex = frame[key]

        if tex and tex.Hide then

            tex:Hide()

        end

    end

end



--- Re-show Artisan pixel borders after a classic->modern skin switch.

function ns.UI_RestoreArtisanChrome(frame)

    if not frame then

        return

    end

    for _, key in ipairs({ "BorderTop", "BorderBottom", "BorderLeft", "BorderRight" }) do

        local tex = frame[key]

        if tex and tex.Show then

            tex:Show()

        end

    end

end



function ns.UI_GetClassicDialogInset()
    return (ns.UI_LAYOUT and ns.UI_LAYOUT.CLASSIC_DIALOG_INSET) or 8
end

--- Horizontal inset for classic shell body rows and title strip (matches SHELL_PAD).
function ns.UI_GetClassicShellHorizontalInset()
    local layout = ns.UI_LAYOUT or {}
    return layout.SHELL_PAD or layout.BASE_INDENT or 12
end

--- Wing width for UI-DialogBox-Header caps; shrinks on narrow windows (overload tracker).
function ns.UI_ComputeClassicTitleWingWidth(parent, hInset)
    local layout = ns.UI_LAYOUT or {}
    local wingDefault = layout.CLASSIC_SHELL_TITLE_WING or 28
    local pw = (parent and parent.GetWidth and parent:GetWidth()) or 600
    local minCenter = layout.CLASSIC_SHELL_TITLE_MIN_CENTER or 96
    local maxWing = math.floor((pw - 2 * hInset - minCenter) * 0.5)
    if maxWing < 14 then
        maxWing = 14
    end
    return math.min(wingDefault, maxWing)
end



function ns.UI_ApplyClassicDialogBackdrop(frame)

    if not frame then

        return

    end

    if not frame.SetBackdrop then

        Mixin(frame, BackdropTemplateMixin)

    end

    ns.UI_SuppressArtisanChrome(frame)

    local inset = ns.UI_GetClassicDialogInset()

    frame:SetBackdrop({

        bgFile = DIALOG_BG,

        edgeFile = DIALOG_BORDER,

        tile = true,

        tileSize = 32,

        edgeSize = 32,

        insets = { left = inset, right = inset, top = inset, bottom = inset },

    })

    frame:SetBackdropColor(0, 0, 0, 1)

    frame:SetBackdropBorderColor(1, 1, 1, 1)

    if frame.SetClipsChildren then

        frame:SetClipsChildren(true)

    end

end



function ns.UI_ApplyClassicInsetPanel(frame)

    if not frame then

        return

    end

    if not frame.SetBackdrop then

        Mixin(frame, BackdropTemplateMixin)

    end

    ns.UI_SuppressArtisanChrome(frame)

    frame:SetBackdrop({

        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",

        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",

        tile = false,

        edgeSize = 16,

        insets = { left = 0, right = 0, top = 0, bottom = 0 },

    })

    frame:SetBackdropColor(0.05, 0.05, 0.05, 0.9)

    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)

end



--- Tooltip-border column shell for external scrollbars (classic skin).
--- Reserved for optional use; default classic scroll uses Blizzard bar rail on the slider.
function ns.UI_ApplyClassicScrollColumnChrome(frame)
    if not frame then
        return
    end
    if frame.SetBackdrop then
        frame:SetBackdrop(nil)
    end
end



--- Blizzard stretchable-art rail (UIPanelStretchableArtScrollBarTemplate parity).
function ns.UI_EnsureClassicScrollBarRail(scrollBar)
    if not scrollBar then
        return
    end
    if scrollBar._anClassicTrack and scrollBar._anClassicTrack.Hide then
        scrollBar._anClassicTrack:Hide()
    end

    local rail = "Interface\\PaperDollInfoFrame\\UI-Character-ScrollBar"
    if not scrollBar.Top then
        local top = scrollBar:CreateTexture(nil, "ARTWORK", nil, 0)
        top:SetTexture(rail)
        scrollBar.Top = top
    end
    if not scrollBar.Bottom then
        local bot = scrollBar:CreateTexture(nil, "ARTWORK", nil, 0)
        bot:SetTexture(rail)
        scrollBar.Bottom = bot
    end
    if not scrollBar.Middle then
        local mid = scrollBar:CreateTexture(nil, "ARTWORK", nil, 0)
        mid:SetTexture(rail)
        scrollBar.Middle = mid
    end
    if not scrollBar.Background then
        local bg = scrollBar:CreateTexture(nil, "ARTWORK", nil, -1)
        bg:SetColorTexture(0, 0, 0, 1)
        scrollBar.Background = bg
    end
    scrollBar._anClassicRailInstalled = true
end

local function ClassicScrollColumnWidth(col)
    local layout = ns.UI_LAYOUT or {}
    local colW = col and col.GetWidth and col:GetWidth()
    if not colW or colW < 12 then
        colW = layout.SCROLLBAR_COLUMN_WIDTH or 26
    end
    return colW
end

local RAIL_W = 24
local RAIL_TOP_Y = 18
local RAIL_BOT_Y = -16

local DIALOG_HEADER_TEX = 131080 -- Interface\DialogFrame\UI-DialogBox-Header

local function EnsureClassicDialogTitleTextures(frame)
    if not frame or frame._anClassicTitleBgC then
        return
    end
    frame._anClassicTitleBgL = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    frame._anClassicTitleBgC = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    frame._anClassicTitleBgR = frame:CreateTexture(nil, "ARTWORK", nil, 1)
end

--- AceGUI Frame.lua texcoords — center stretch + capped wings (no square tiling).
local function LayoutClassicDialogTitleTextures(frame, opts)
    if not frame then
        return
    end
    if type(opts) ~= "table" then
        opts = { topOffset = opts or 0 }
    end
    local topOffset = opts.topOffset or 0
    local h = opts.height or 32
    local wingW = opts.wingWidth or 36
    local inset = opts.inset or 6
    EnsureClassicDialogTitleTextures(frame)
    local bgL = frame._anClassicTitleBgL
    local bgC = frame._anClassicTitleBgC
    local bgR = frame._anClassicTitleBgR

    bgC:SetTexture(DIALOG_HEADER_TEX)
    bgC:SetTexCoord(0.31, 0.67, 0, 0.63)
    bgC:ClearAllPoints()
    bgC:SetPoint("TOPLEFT", frame, "TOPLEFT", inset + wingW, topOffset)
    bgC:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(inset + wingW), topOffset)
    bgC:SetHeight(h)
    bgC:Show()

    bgL:SetTexture(DIALOG_HEADER_TEX)
    bgL:SetTexCoord(0.21, 0.31, 0, 0.63)
    bgL:ClearAllPoints()
    bgL:SetPoint("TOPRIGHT", bgC, "TOPLEFT", 0, 0)
    bgL:SetPoint("BOTTOMRIGHT", bgC, "BOTTOMLEFT", 0, 0)
    bgL:SetWidth(wingW)
    bgL:Show()

    bgR:SetTexture(DIALOG_HEADER_TEX)
    bgR:SetTexCoord(0.67, 0.77, 0, 0.63)
    bgR:ClearAllPoints()
    bgR:SetPoint("TOPLEFT", bgC, "TOPRIGHT", 0, 0)
    bgR:SetPoint("BOTTOMLEFT", bgC, "BOTTOMRIGHT", 0, 0)
    bgR:SetWidth(wingW)
    bgR:Show()
end

--- AceGUI-style dialog title strip (UI-DialogBox-Header) on compact bars (overload tracker).
function ns.UI_ApplyClassicDialogTitleBar(frame, titleFontString)
    if not frame then
        return
    end
    if frame.SetBackdrop then
        frame:SetBackdrop(nil)
    end
    ns.UI_SuppressArtisanChrome(frame)
    LayoutClassicDialogTitleTextures(frame, {
        topOffset = (ns.UI_LAYOUT and ns.UI_LAYOUT.CLASSIC_TITLE_TOP_OFFSET) or 12,
        height = 32,
        wingWidth = 28,
        inset = 4,
    })
    if titleFontString and titleFontString.SetPoint then
        titleFontString:ClearAllPoints()
        titleFontString:SetPoint("TOP", frame._anClassicTitleBgC or frame, "TOP", 0, -10)
        titleFontString:SetTextColor(1, 0.82, 0, 1)
    end
end

local function HideClassicTitleTextures(frame)
    if not frame then
        return
    end
    for _, key in ipairs({ "_anClassicTitleBgL", "_anClassicTitleBgC", "_anClassicTitleBgR" }) do
        local tex = frame[key]
        if tex and tex.Hide then
            tex:Hide()
        end
    end
end

--- Y offset from dialog root TOP where body/tabs may begin (below title strip).
function ns.UI_GetClassicShellContentTop()
    local layout = ns.UI_LAYOUT or {}
    if layout.CLASSIC_SHELL_CONTENT_TOP then
        return layout.CLASSIC_SHELL_CONTENT_TOP
    end
    local topY = layout.CLASSIC_TITLE_TOP_OFFSET or 12
    local stripH = layout.CLASSIC_SHELL_TITLE_STRIP_HEIGHT or 40
    local gap = layout.CLASSIC_SHELL_TITLE_BODY_GAP or 4
    return topY + stripH + gap
end

--- Main shell header: AceGUI Frame.lua — title strip on the dialog root, straddling top chrome.
function ns.UI_LayoutClassicShellHeader(headerBar)
    if not headerBar then
        return
    end
    local parent = headerBar._anShellParent or headerBar:GetParent()
    if not parent then
        return
    end
    local layout = ns.UI_LAYOUT or {}
    local topY = layout.CLASSIC_TITLE_TOP_OFFSET or 12
    local stripH = layout.CLASSIC_SHELL_TITLE_STRIP_HEIGHT or 40
    local hInset = (ns.UI_GetClassicShellHorizontalInset and ns.UI_GetClassicShellHorizontalInset())
        or layout.SHELL_PAD or 12
    local wingW = (ns.UI_ComputeClassicTitleWingWidth and ns.UI_ComputeClassicTitleWingWidth(parent, hInset))
        or (layout.CLASSIC_SHELL_TITLE_WING or 28)
    local contentTop = ns.UI_GetClassicShellContentTop()
    local padV = 4

    if headerBar.SetBackdrop then
        headerBar:SetBackdrop(nil)
    end
    ns.UI_SuppressArtisanChrome(headerBar)

    HideClassicTitleTextures(headerBar)
    LayoutClassicDialogTitleTextures(parent, {
        topOffset = topY,
        height = stripH,
        wingWidth = wingW,
        inset = hInset,
    })

    if not parent._anClassicShellLayoutHooked and parent.HookScript then
        parent._anClassicShellLayoutHooked = true
        parent._anShellHeaderBar = headerBar
        parent:HookScript("OnSizeChanged", function()
            local hb = parent._anShellHeaderBar or parent.headerBar
            if hb and ns.UI_LayoutClassicShellHeader then
                ns.UI_LayoutClassicShellHeader(hb)
            end
        end)
    elseif parent and not parent._anShellHeaderBar then
        parent._anShellHeaderBar = headerBar
    end

    headerBar:ClearAllPoints()
    headerBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    headerBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    headerBar:SetHeight(contentTop)

    local titleCenter = parent._anClassicTitleBgC or parent
    local titleWingL = parent._anClassicTitleBgL or parent
    local titleWingR = parent._anClassicTitleBgR or parent

    --- Square controls vertically centered in the title strip via TOP+BOTTOM on center bg.
    local function FitSquareControlInStrip(widget, point, rel, relPoint, x)
        if not widget or not titleCenter then
            return
        end
        widget:ClearAllPoints()
        local sz = math.max(18, math.min(26, stripH - padV * 2))
        if point and rel then
            widget:SetPoint(point, rel, relPoint or point, x or 0, 0)
        end
        widget:SetPoint("TOP", titleCenter, "TOP", 0, -padV)
        widget:SetPoint("BOTTOM", titleCenter, "BOTTOM", 0, padV)
        if widget.SetWidth then
            widget:SetWidth(sz)
        end
    end

    if headerBar._anShellLogo then
        local logoSz = math.max(18, math.min(24, stripH - padV * 2))
        headerBar._anShellLogo:ClearAllPoints()
        headerBar._anShellLogo:SetSize(logoSz, logoSz)
        headerBar._anShellLogo:SetPoint("CENTER", titleWingL, "CENTER", 8, 0)
        headerBar._anShellLogo:Show()
    end

    local rightClip = headerBar._anShellClose
    if rightClip then
        FitSquareControlInStrip(rightClip, "RIGHT", titleWingR, "RIGHT", -5)
    end
    local settingsBtn = headerBar._anShellSettings
    if settingsBtn then
        if rightClip then
            FitSquareControlInStrip(settingsBtn, "RIGHT", rightClip, "LEFT", -4)
        else
            FitSquareControlInStrip(settingsBtn, "RIGHT", titleWingR, "RIGHT", -30)
        end
        rightClip = settingsBtn
    end
    local utilities = headerBar._anShellUtilities
    if utilities then
        for i = 1, #utilities do
            local btn = utilities[i]
            if btn and btn.ClearAllPoints then
                if rightClip then
                    FitSquareControlInStrip(btn, "RIGHT", rightClip, "LEFT", -4)
                else
                    FitSquareControlInStrip(btn, "RIGHT", titleWingR, "RIGHT", -6)
                end
                rightClip = btn
            end
        end
    end
    local extras = headerBar._anShellExtraRight
    if extras then
        for i = 1, #extras do
            local btn = extras[i]
            if btn and btn.ClearAllPoints then
                if rightClip then
                    FitSquareControlInStrip(btn, "RIGHT", rightClip, "LEFT", -4)
                else
                    FitSquareControlInStrip(btn, "RIGHT", titleWingR, "RIGHT", -6)
                end
                rightClip = btn
            end
        end
    end
    headerBar._anShellRightClip = rightClip

    if headerBar._anShellTitle then
        headerBar._anShellTitle:ClearAllPoints()
        if headerBar._anShellLogo then
            headerBar._anShellTitle:SetPoint("LEFT", headerBar._anShellLogo, "RIGHT", 6, 0)
        else
            headerBar._anShellTitle:SetPoint("LEFT", titleWingL, "LEFT", 8, 0)
        end
        headerBar._anShellTitle:SetPoint("TOP", titleCenter, "TOP", 0, -14)
        if rightClip then
            headerBar._anShellTitle:SetPoint("RIGHT", rightClip, "LEFT", -8, 0)
        else
            headerBar._anShellTitle:SetPoint("RIGHT", titleWingR, "LEFT", -8, 0)
        end
        headerBar._anShellTitle:SetTextColor(1, 0.82, 0, 1)
    end
end

local function LayoutClassicScrollBarRail(scrollBar)
    if not scrollBar or not scrollBar.Top then
        return
    end
    local rail = "Interface\\PaperDollInfoFrame\\UI-Character-ScrollBar"
    local railX = scrollBar._anRailOffsetX or 0

    scrollBar.Top:ClearAllPoints()
    scrollBar.Top:SetTexture(rail)
    scrollBar.Top:SetSize(RAIL_W, 48)
    scrollBar.Top:SetTexCoord(0, 0.45, 0, 0.20)
    scrollBar.Top:SetPoint("TOPLEFT", scrollBar, "TOPLEFT", railX, RAIL_TOP_Y)

    scrollBar.Bottom:ClearAllPoints()
    scrollBar.Bottom:SetTexture(rail)
    scrollBar.Bottom:SetSize(RAIL_W, 64)
    scrollBar.Bottom:SetTexCoord(0.515625, 0.97, 0.1440625, 0.4140625)
    scrollBar.Bottom:SetPoint("BOTTOMLEFT", scrollBar, "BOTTOMLEFT", railX, RAIL_BOT_Y)

    scrollBar.Middle:ClearAllPoints()
    scrollBar.Middle:SetTexture(rail)
    scrollBar.Middle:SetTexCoord(0, 0.45, 0.1640625, 1)
    scrollBar.Middle:SetPoint("TOPLEFT", scrollBar.Top, "BOTTOMLEFT", 0, 0)
    scrollBar.Middle:SetPoint("BOTTOMRIGHT", scrollBar.Bottom, "TOPRIGHT", 0, 0)

    if scrollBar._anExternalColumn and scrollBar.Background and scrollBar.Background.Hide then
        scrollBar.Background:Hide()
    elseif scrollBar.Background then
        scrollBar.Background:ClearAllPoints()
        scrollBar.Background:SetPoint("TOPLEFT", scrollBar.Top, "TOPLEFT", 3, 0)
        scrollBar.Background:SetPoint("BOTTOMRIGHT", scrollBar.Bottom, "BOTTOMRIGHT", -3, 0)
        scrollBar.Background:Show()
    end

    scrollBar.Top:Show()
    scrollBar.Bottom:Show()
    scrollBar.Middle:Show()
end

--- Classic external column: center buttons, rail, and thumb track in the column.
function ns.UI_LayoutClassicScrollBarInColumn(scrollBar, scrollBarContainer)
    if not scrollBar or not scrollBarContainer then
        return
    end
    local layout = ns.UI_LAYOUT or {}
    local colW = ClassicScrollColumnWidth(scrollBarContainer)
    local btnH = layout.SCROLL_BAR_BUTTON_SIZE or 16
    local barW = btnH
    local biasY = layout.SCROLL_BAR_COLUMN_Y_BIAS or 0
    local btnX = math.floor((colW - btnH) * 0.5 + 0.5)
    local railLeft = math.floor((colW - RAIL_W) * 0.5 + 0.5)
    scrollBar._anRailOffsetX = railLeft - btnX
    scrollBar._anExternalColumn = true

    if ns.UI_EnsureClassicScrollBarRail then
        ns.UI_EnsureClassicScrollBarRail(scrollBar)
    end

    local up = scrollBar.ScrollUpButton
    local down = scrollBar.ScrollDownButton
    if up then
        up:ClearAllPoints()
        up:SetSize(btnH, btnH)
        up:SetPoint("TOPLEFT", scrollBarContainer, "TOPLEFT", btnX, biasY)
        up:Show()
    end
    if down then
        down:ClearAllPoints()
        down:SetSize(btnH, btnH)
        down:SetPoint("BOTTOMLEFT", scrollBarContainer, "BOTTOMLEFT", btnX, biasY)
        down:Show()
    end

    scrollBar:ClearAllPoints()
    if up and down then
        scrollBar:SetPoint("TOPLEFT", up, "BOTTOMLEFT", 0, 0)
        scrollBar:SetPoint("BOTTOMLEFT", down, "TOPLEFT", 0, 0)
        scrollBar:SetPoint("RIGHT", up, "RIGHT", 0, 0)
    else
        scrollBar:SetPoint("TOPLEFT", scrollBarContainer, "TOPLEFT", btnX, btnH)
        scrollBar:SetPoint("BOTTOMLEFT", scrollBarContainer, "BOTTOMLEFT", btnX, -btnH)
    end
    scrollBar:SetWidth(barW)
    scrollBar:Show()

    LayoutClassicScrollBarRail(scrollBar)

    local thumb = scrollBar.ThumbTexture
    if thumb then
        thumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
        thumb:SetTexCoord(0.20, 0.80, 0.125, 0.875)
        thumb:SetVertexColor(1, 1, 1, 1)
    end
end

function ns.UI_HookClassicScrollBarColumnLayout(scroll, barCol)
    if not scroll or not barCol or barCol._anClassicLayoutHooked then
        return
    end
    barCol._anClassicLayoutHooked = true
    local function relayout()
        if not scroll.ScrollBar then
            return
        end
        local Factory = ns.UI and ns.UI.Factory
        if Factory and Factory.InstallClassicExternalScrollBar then
            Factory:InstallClassicExternalScrollBar(scroll.ScrollBar, barCol, scroll)
        elseif ns.UI_LayoutClassicScrollBarInColumn then
            ns.UI_LayoutClassicScrollBarInColumn(scroll.ScrollBar, barCol)
        end
    end
    barCol:SetScript("OnSizeChanged", relayout)
    if C_Timer and C_Timer.After then
        C_Timer.After(0, relayout)
    else
        relayout()
    end
end



--- Compact tooltip-border chrome for loot catalog cells and session row icons (classic skin).
function ns.UI_ApplyClassicLootCellBorder(frame, edgeSize)
    if not frame then
        return
    end
    if not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
    end
    if ns.UI_SuppressArtisanChrome then
        ns.UI_SuppressArtisanChrome(frame)
    end
    edgeSize = edgeSize or 12
    frame:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false,
        edgeSize = edgeSize,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.05, 0.82)
    frame:SetBackdropBorderColor(0.52, 0.52, 0.52, 1)
end



function ns.UI_ApplyClassicLootIconBorder(iconFrame)
    if not iconFrame then
        return
    end
    ns.UI_ApplyClassicLootCellBorder(iconFrame, 10)
    local tex = iconFrame.texture
    if tex then
        local inset = 3
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", iconFrame, "TOPLEFT", inset, -inset)
        tex:SetPoint("BOTTOMRIGHT", iconFrame, "BOTTOMRIGHT", -inset, inset)
    end
end



function ns.UI_ApplyClassicMainWindowChrome(frame)

    ns.UI_ApplyClassicDialogBackdrop(frame)
    frame._anClassicDialogRoot = true

    if frame and frame.SetClipsChildren then
        frame:SetClipsChildren(false)
    end

end



--- AceGUI-style dialog header on main window shell bars (UI-DialogBox-Header).
function ns.UI_RefreshClassicWindowHeader(headerBar)

    if not headerBar then

        return

    end

    if ns.UI_LayoutClassicShellHeader then

        ns.UI_LayoutClassicShellHeader(headerBar)

        return

    end

end



--- Position native UIPanelScrollFrameTemplate scrollbar (Classic skin).
--- Keep Blizzard anchor + thumb sizing; only strip Artisan chrome overrides.
---@param scroll ScrollFrame
function ns.UI_ApplyClassicScrollBarLayout(scroll)
    if not scroll then
        return
    end
    local col = scroll._anScrollBarColumn
    if col and col.Hide and not scroll._anExternalBarColumn then
        col:Hide()
    end
    if scroll.UpdateScrollBarVisibility then
        scroll._anSavedUpdateVis = scroll.UpdateScrollBarVisibility
        scroll.UpdateScrollBarVisibility = nil
    end
    local bar = scroll.ScrollBar
    if not bar then
        return
    end
    if scroll._anExternalBarColumn then
        for _, key in ipairs({ "Top", "Middle", "Bottom" }) do
            local tex = scroll[key]
            if tex and tex.Hide then
                tex:Hide()
            end
        end
    end
    if ns.UI_SuppressArtisanChrome then
        ns.UI_SuppressArtisanChrome(bar)
    end
    if bar.CustomTrack and bar.CustomTrack.Hide then
        bar.CustomTrack:Hide()
    end
    if bar._thumbTexture and bar._thumbTexture.SetTexture then
        bar._thumbTexture:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
        bar._thumbTexture:SetTexCoord(0.20, 0.80, 0.125, 0.875)
        bar._thumbTexture:SetVertexColor(1, 1, 1, 1)
    end
    if bar.BorderTop and bar.BorderTop.Hide then
        bar.BorderTop:Hide()
        bar.BorderBottom:Hide()
        bar.BorderLeft:Hide()
        bar.BorderRight:Hide()
    end
    if bar._anClassicTrack and bar._anClassicTrack.Hide then
        bar._anClassicTrack:Hide()
    end
    if scroll._anExternalBarColumn and bar.Background and bar.Background.Hide then
        bar.Background:Hide()
    end
    if ns.UI_EnsureClassicScrollBarRail then
        ns.UI_EnsureClassicScrollBarRail(bar)
    end
    if scroll._anExternalBarColumn and col then
        local Factory = ns.UI and ns.UI.Factory
        if Factory and Factory.InstallClassicExternalScrollBar then
            Factory:InstallClassicExternalScrollBar(bar, col, scroll)
        elseif ns.UI_LayoutClassicScrollBarInColumn then
            ns.UI_LayoutClassicScrollBarInColumn(bar, col)
        end
    end
    if bar.ScrollUpBtn then
        bar.ScrollUpBtn:Hide()
    end
    if bar.ScrollDownBtn then
        bar.ScrollDownBtn:Hide()
    end
    if bar.ScrollUpButton then
        bar.ScrollUpButton:Show()
    end
    if bar.ScrollDownButton then
        bar.ScrollDownButton:Show()
    end
    local thumb = bar.ThumbTexture
    if thumb then
        thumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
        thumb:SetTexCoord(0.20, 0.80, 0.125, 0.875)
        thumb:SetVertexColor(1, 1, 1, 1)
        -- Do not SetSize: engine scales thumb from scroll range vs viewport.
    end
    bar:Show()
    if ns.UI_RefreshNativeScrollFrame then
        ns.UI_RefreshNativeScrollFrame(scroll)
    end
end



local function NativePanelFontString(btn)

    if not btn then

        return nil

    end

    if btn.Text then

        return btn.Text

    end

    return btn.GetFontString and btn:GetFontString()

end



local function SetNativePanelSelected(btn, selected)

    if not btn or not ns.UI_IsNativePanelButton(btn) then

        return

    end

    if btn.SetBackdrop then

        btn:SetBackdrop(nil)

    end

    if selected then

        if btn.LockHighlight then

            btn:LockHighlight()

        end

        if btn.SetButtonState then

            btn:SetButtonState("PUSHED", true)

        end

    else

        if btn.UnlockHighlight then

            btn:UnlockHighlight()

        end

        if btn.SetButtonState then

            btn:SetButtonState("NORMAL", false)

        end

    end

end



--- Tab / toggle row — UIPanelButtonTemplate only; text color for pulse/selection.

---@param btn Frame|Button

---@param selected boolean

---@param opts table|nil { pulse = boolean }

function ns.UI_StyleClassicTabButton(btn, selected, opts)

    if not btn then

        return

    end

    ns.UI_SuppressArtisanChrome(btn)

    if ns.UI_IsNativePanelButton(btn) then

        SetNativePanelSelected(btn, selected and true or false)

        local fs = NativePanelFontString(btn)

        if fs and fs.SetTextColor then

            if selected or (opts and opts.pulse) then

                fs:SetTextColor(1, 0.82, 0)

            else

                fs:SetTextColor(1, 1, 1)

            end

        end

        return

    end

    --- Legacy BackdropTemplate row (should not appear after LootHistory rebuild).

    if btn.SetBackdrop then

        btn:SetBackdrop(nil)

    end

end



--- Toolbar / footer — native panel template only; do not stretch single-slice textures.

function ns.UI_StyleClassicPanelButton(btn, pressed)

    if not btn then

        return

    end

    ns.UI_SuppressArtisanChrome(btn)

    if ns.UI_IsNativePanelButton(btn) then

        SetNativePanelSelected(btn, pressed and true or false)

        local fs = NativePanelFontString(btn)

        if fs and fs.SetTextColor then

            fs:SetTextColor(1, 1, 1)

        end

        return

    end

    if btn.SetBackdrop then

        btn:SetBackdrop(nil)

    end

end



function ns.UI_StyleClassicToolButton(btn)

    if not btn then

        return

    end

    ns.UI_SuppressArtisanChrome(btn)

    if btn.SetBackdrop then

        btn:SetBackdrop(nil)

    end

    if btn.SetAlpha then

        btn:SetAlpha(1)

    end

    if btn.SetHighlightTexture and not btn._anClassicToolHighlight then

        btn._anClassicToolHighlight = true

        btn:SetHighlightTexture("Interface\\Buttons\\WHITE8X8", "ADD")

        local ht = btn.GetHighlightTexture and btn:GetHighlightTexture()

        if ht then

            ht:SetAlpha(0.12)

        end

    end

end



function ns.UI_ResetMainWindowsForUiMode()

    if ns.LootHistoryUI and ns.LootHistoryUI.ResetForUiMode then

        ns.LootHistoryUI:ResetForUiMode()

    end

    if ns.ArtisanHubUI and ns.ArtisanHubUI.ResetForUiMode then

        ns.ArtisanHubUI:ResetForUiMode()

    end

    if ns.RecipeMatcherUI and ns.RecipeMatcherUI.ResetForUiMode then

        ns.RecipeMatcherUI:ResetForUiMode()

    end

    if ns.PriceHistoryUI and ns.PriceHistoryUI.ResetForUiMode then

        ns.PriceHistoryUI:ResetForUiMode()

    end

    if ns.PostingHelperUI and ns.PostingHelperUI.ResetForUiMode then

        ns.PostingHelperUI:ResetForUiMode()

    end

    if ns.ProfessionSidecarUI and ns.ProfessionSidecarUI.ResetForUiMode then

        ns.ProfessionSidecarUI:ResetForUiMode()

    end

    if ns.GatheringOverloadIndicator and ns.GatheringOverloadIndicator.ResetForUiMode then

        ns.GatheringOverloadIndicator:ResetForUiMode()

    end

end


