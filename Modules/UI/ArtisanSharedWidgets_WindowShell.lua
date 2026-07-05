--[[
    Artisan Nexus — shared main-window chrome (header, tabs, tool pills).
    Loot History, Hub, and Recipe Matcher use the same shell for theme unity.
]]

local ADDON_NAME, ns = ...

local MEDIA_LOGO = "Interface\\AddOns\\ArtisanNexus\\Media\\anlogo"

local function Colors()
    return ns.UI_COLORS or {}
end

local function ShellLayout()
    local LAYOUT = ns.UI_LAYOUT or {}
    return {
        pad = LAYOUT.SHELL_PAD or LAYOUT.BASE_INDENT or 12,
        headerH = LAYOUT.SHELL_HEADER_HEIGHT or 44,
        headerHClassic = LAYOUT.SHELL_HEADER_HEIGHT_CLASSIC or 36,
        logoSz = LAYOUT.SHELL_LOGO_SIZE or 28,
        tabH = LAYOUT.SHELL_TAB_HEIGHT or 30,
    }
end

function ns.UI_ApplyMainWindowChrome(frame)
    if not frame then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_ApplyClassicMainWindowChrome then
            ns.UI_ApplyClassicMainWindowChrome(frame)
        end
        return
    end
    if ns.UI_ApplyPanelBackdrop then
        ns.UI_ApplyPanelBackdrop(frame)
        return
    end
    if ns.UI_ApplyVisuals then
        local c = Colors()
        local ac = c.accent or { 0.44, 0.32, 0.58, 1 }
        ns.UI_ApplyVisuals(frame, c.bg, { ac[1], ac[2], ac[3], 0.62 })
    end
end

function ns.UI_RefreshWindowHeader(headerBar)
    if not headerBar then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_RefreshClassicWindowHeader then
            ns.UI_RefreshClassicWindowHeader(headerBar)
        end
    elseif ns.UI_ApplyVisuals then
        local c = Colors()
        local hb = c.lootHeaderBg or c.bgLight
        local ac = c.accent or { 0.44, 0.32, 0.58, 1 }
        local br = c.lootHeaderBorder or { ac[1], ac[2], ac[3], 0.68 }
        ns.UI_ApplyVisuals(headerBar, hb, br)
        if headerBar._anShellTitle then
            local tb = c.textBright or { 0.96, 0.95, 0.97, 1 }
            headerBar._anShellTitle:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1)
        end
        if headerBar._anShellLogo and headerBar._anShellLogo.Show then
            headerBar._anShellLogo:Show()
        end
    end
    if ns.UI_RegisterClassicShellDebug and headerBar then
        local parent = headerBar._anShellParent or headerBar:GetParent()
        if parent then
            ns.UI_RegisterClassicShellDebug(parent, headerBar)
        end
    end
end

--- Dialog root: disable child clip + refresh AceGUI-style title strip (classic only).
---@param frame Frame
function ns.UI_RefreshClassicMainWindowShell(frame)
    if not frame or not (ns.UI_IsClassicUi and ns.UI_IsClassicUi()) then
        return
    end
    if frame.SetClipsChildren then
        frame:SetClipsChildren(false)
    end
    if frame.headerBar and ns.UI_RefreshClassicWindowHeader then
        ns.UI_RefreshClassicWindowHeader(frame.headerBar)
    end
end

--- Full-width row (tabs, status) below classic title strip or modern header bar.
---@param row Region
---@param parent Frame
---@param headerBar Frame|nil
---@param leftPad number|nil
---@param gapBelowTop number|nil
function ns.UI_AnchorClassicShellBodyRow(row, parent, headerBar, leftPad, gapBelowTop)
    if not row or not parent then
        return
    end
    local layout = ns.UI_LAYOUT or {}
    leftPad = leftPad or layout.SHELL_PAD or layout.BASE_INDENT or 12
    gapBelowTop = gapBelowTop or 0
    row:ClearAllPoints()
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() and ns.UI_GetClassicShellContentTop then
        --- Body rows must clear the ornate border art, not just SHELL_PAD.
        if ns.UI_GetClassicShellHorizontalInset then
            leftPad = math.max(leftPad, ns.UI_GetClassicShellHorizontalInset())
        end
        local top = ns.UI_GetClassicShellContentTop() + gapBelowTop
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", leftPad, -top)
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -leftPad, -top)
    elseif headerBar then
        row:SetPoint("TOPLEFT", headerBar, "BOTTOMLEFT", leftPad, -8)
        row:SetPoint("TOPRIGHT", headerBar, "BOTTOMRIGHT", -leftPad, -8)
    end
end

--- Inset content panel (list hosts, window body). Branches on the active skin:
--- classic uses the tooltip-border inset, modern uses themed pixel visuals.
---@param frame Frame
---@param bgColor table|nil default COLORS.bgCard
---@param borderColor table|nil default { COLORS.border, 0.52 }
function ns.UI_StylePanelInset(frame, bgColor, borderColor)
    if not frame then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_ApplyClassicInsetPanel then
            ns.UI_ApplyClassicInsetPanel(frame)
        end
        return
    end
    if not ns.UI_ApplyVisuals then
        return
    end
    if ns.UI_StripClassicBackdropEdge then
        ns.UI_StripClassicBackdropEdge(frame)
    end
    local c = Colors()
    local bg = bgColor or c.bgCard or { 0.078, 0.075, 0.089, 1 }
    local bd = borderColor
    if not bd then
        local b = c.border or { 0.26, 0.24, 0.30, 1 }
        bd = { b[1], b[2], b[3], 0.52 }
    end
    ns.UI_ApplyVisuals(frame, bg, bd, { bgType = "bgCard" })
    --- Frames that lived through a classic phase have hidden pixel borders.
    if ns.UI_RestoreArtisanChrome then
        ns.UI_RestoreArtisanChrome(frame)
    end
end

--- Loot catalog grid cell — classic tooltip border or modern pixel lootCell chrome.
---@param frame Frame
---@param borderColor table|nil override for modern lootCellBorder
function ns.UI_StyleLootCatalogCell(frame, borderColor)
    if not frame then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_ApplyClassicLootCellBorder then
            ns.UI_ApplyClassicLootCellBorder(frame)
        end
        return
    end
    if not ns.UI_ApplyVisuals then
        return
    end
    local c = Colors()
    local bg = c.lootCellBg or c.bgCard or { 0.08, 0.077, 0.09, 0.92 }
    local bd = borderColor
    if not bd then
        bd = c.lootCellBorder
        if not bd then
            local b = c.border or { 0.26, 0.24, 0.30, 1 }
            bd = { b[1], b[2], b[3], 0.44 }
        end
    end
    ns.UI_ApplyVisuals(frame, bg, bd)
    if ns.UI_RestoreArtisanChrome then
        ns.UI_RestoreArtisanChrome(frame)
    end
end

--- Item icon in catalog grid or session pickup row.
---@param iconFrame Frame|nil
---@param borderColor table|nil accent / lootCell border for modern mode
function ns.UI_StyleLootIconFrame(iconFrame, borderColor)
    if not iconFrame then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_ApplyClassicLootIconBorder then
            ns.UI_ApplyClassicLootIconBorder(iconFrame)
        end
        return
    end
    if iconFrame.BorderTop and ns.UI_UpdateBorderColor then
        local c = Colors()
        local bd = borderColor
        if not bd then
            bd = c.lootCellBorder
            if not bd then
                local b = c.border or { 0.26, 0.24, 0.30, 1 }
                bd = { b[1], b[2], b[3], 0.56 }
            end
        end
        ns.UI_UpdateBorderColor(iconFrame, bd)
    end
end

--- Footer / toolbar panel button. Branches on the active skin:
--- classic uses UI-Panel-Button art, modern uses themed pixel visuals.
---@param btn Frame|Button
---@param opts table|nil { pressed, bg, border, borderAlpha, textColor }
function ns.UI_StylePanelButton(btn, opts)
    if not btn then
        return
    end
    opts = opts or {}
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_StyleClassicPanelButton then
            ns.UI_StyleClassicPanelButton(btn, opts.pressed)
            btn._anClassicPanelArt = true
        end
        return
    end
    if not ns.UI_ApplyVisuals then
        return
    end
    if btn._anClassicPanelArt then
        --- Strip the classic UI-Panel-Button art left from a classic phase.
        btn._anClassicPanelArt = nil
        pcall(function()
            btn:SetNormalTexture("")
            btn:SetPushedTexture("")
            btn:SetHighlightTexture("")
            btn:SetDisabledTexture("")
        end)
    end
    local c = Colors()
    local bg = opts.bg or c.tabInactive or { 0.074, 0.072, 0.084, 1 }
    local bd = opts.border
    if not bd then
        local b = c.border or { 0.26, 0.24, 0.30, 1 }
        bd = { b[1], b[2], b[3], opts.borderAlpha or 0.50 }
    end
    ns.UI_ApplyVisuals(btn, bg, bd)
    if ns.UI_RestoreArtisanChrome then
        ns.UI_RestoreArtisanChrome(btn)
    end
    local fs = btn._lbl or (btn.GetFontString and btn:GetFontString())
    if fs and fs.SetTextColor then
        local tc = opts.textColor or c.textNormal or { 0.82, 0.80, 0.86, 1 }
        fs:SetTextColor(tc[1], tc[2], tc[3], tc[4] or 1)
    end
end

---@param btn Frame|Button
---@param selected boolean
---@param opts table|nil { pulse = boolean }
function ns.UI_StyleShellTabButton(btn, selected, opts)
    if not btn then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_StyleClassicTabButton then
            ns.UI_StyleClassicTabButton(btn, selected, opts)
        end
        return
    end
    if not ns.UI_ApplyVisuals then
        return
    end
    opts = opts or {}
    local c = Colors()
    local bg, br
    if selected then
        bg = c.tabActive
        br = { c.accent[1], c.accent[2], c.accent[3], 0.86 }
    elseif opts.pulse then
        bg = {
            math.min(1, c.tabInactive[1] + 0.12),
            math.min(1, c.tabInactive[2] + 0.10),
            math.min(1, c.tabInactive[3] + 0.14),
            1,
        }
        br = { c.accent[1], c.accent[2], c.accent[3], 0.55 }
    else
        bg = c.tabInactive
        br = { c.border[1], c.border[2], c.border[3], 0.45 }
    end
    ns.UI_ApplyVisuals(btn, bg, br)
    local fs = btn._lbl or (btn.GetFontString and btn:GetFontString())
    if fs then
        if selected or opts.pulse then
            fs:SetTextColor(c.textBright[1], c.textBright[2], c.textBright[3])
        else
            fs:SetTextColor(c.textDim[1], c.textDim[2], c.textDim[3])
        end
    end
end

---@param btn Frame|Button
---@param highlight boolean|nil hovered
---@param skipTextColor boolean|nil keep markup in label
function ns.UI_StyleShellToolButton(btn, highlight, skipTextColor)
    if not btn then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if ns.UI_StyleClassicToolButton then
            ns.UI_StyleClassicToolButton(btn)
        end
        return
    end
    if not ns.UI_ApplyVisuals then
        return
    end
    local c = Colors()
    local bg = highlight and c.tabHover or c.bgCard
    ns.UI_ApplyVisuals(btn, bg, { c.border[1], c.border[2], c.border[3], 0.48 })
    if skipTextColor then
        return
    end
    local fs = btn._lbl or (btn.GetFontString and btn:GetFontString())
    if fs then
        fs:SetTextColor(c.textNormal[1], c.textNormal[2], c.textNormal[3])
    end
end

---@param parent Frame
---@param config table|nil
---@return table shell { bar, title, logo, close, settings, utilities, rightClip, pad, headerH }
function ns.UI_CreateWindowHeader(parent, config)
    config = config or {}
    local c = Colors()
    local sl = ShellLayout()
    local pad = sl.pad
    local headerH = sl.headerH
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        headerH = sl.headerHClassic or 36
    end

    local headerBar = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    headerBar._anShellParent = parent
    headerBar:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    headerBar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    headerBar:SetHeight(headerH)
    headerBar:EnableMouse(true)

    local dragFrame = config.dragFrame or parent
    headerBar:RegisterForDrag("LeftButton")
    headerBar:SetScript("OnDragStart", function()
        if config.onDragStart then
            config.onDragStart()
        else
            dragFrame:StartMoving()
        end
    end)
    headerBar:SetScript("OnDragStop", function()
        if config.onDragStop then
            config.onDragStop()
        else
            dragFrame:StopMovingOrSizing()
        end
    end)

    ns.UI_RefreshWindowHeader(headerBar)

    local logo
    if config.showLogo ~= false then
        logo = headerBar:CreateTexture(nil, "ARTWORK")
        logo:SetSize(sl.logoSz, sl.logoSz)
        logo:SetPoint("LEFT", headerBar, "LEFT", pad, 0)
        logo:SetTexture(config.logoTexture or MEDIA_LOGO)
        headerBar._anShellLogo = logo
    end

    local title = headerBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetMaxLines(1)
    if logo then
        title:SetPoint("LEFT", logo, "RIGHT", 8, 0)
    else
        title:SetPoint("LEFT", headerBar, "LEFT", pad, 0)
    end
    local tb = c.textBright or { 0.96, 0.95, 0.97, 1 }
    title:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1)
    title:SetText(config.title or "")
    headerBar._anShellTitle = title

    local close = CreateFrame("Button", nil, headerBar, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", headerBar, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", config.onClose or function()
        parent:Hide()
    end)
    headerBar._anShellClose = close

    local rightClip = close
    local utilityButtons = {}

    local settingsBtn
    if config.showSettings then
        settingsBtn = CreateFrame("Button", nil, headerBar)
        settingsBtn:SetSize(26, 26)
        settingsBtn:SetPoint("RIGHT", close, "LEFT", -4, 0)
        settingsBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
        settingsBtn:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton")
        if ns.UI_IsClassicUi and ns.UI_IsClassicUi() and ns.UI_StyleClassicToolButton then
            ns.UI_StyleClassicToolButton(settingsBtn)
        end
        settingsBtn:SetScript("OnClick", config.onSettings or function()
            if ns.OpenAddonSettings then
                ns.OpenAddonSettings()
            end
        end)
        if config.settingsTooltip then
            local st = config.settingsTooltip
            settingsBtn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:SetText(st.title or "", 1, 1, 1)
                if st.desc and st.desc ~= "" then
                    GameTooltip:AddLine(st.desc, 0.85, 0.85, 0.85, true)
                end
                GameTooltip:Show()
            end)
            settingsBtn:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end
        rightClip = settingsBtn
    end

    local utilities = config.utilities
    if utilities then
        local utilGap = (ns.UI_IsClassicUi and ns.UI_IsClassicUi()) and -4 or -2
        for i = 1, #utilities do
            local u = utilities[i]
            local btn = CreateFrame("Button", nil, headerBar)
            btn:SetSize(26, 26)
            btn:SetPoint("RIGHT", rightClip, "LEFT", utilGap, 0)
            btn:SetNormalTexture(u.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            btn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
            if ns.UI_IsClassicUi and ns.UI_IsClassicUi() and ns.UI_StyleClassicToolButton then
                ns.UI_StyleClassicToolButton(btn)
            end
            if u.onClick then
                btn:SetScript("OnClick", u.onClick)
            end
            if u.title or u.desc then
                btn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    GameTooltip:SetText(u.title or "", 1, 1, 1)
                    if u.desc and u.desc ~= "" then
                        GameTooltip:AddLine(u.desc, 0.85, 0.85, 0.85, true)
                    end
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)
            end
            utilityButtons[i] = btn
            rightClip = btn
        end
    end

    headerBar._anShellSettings = settingsBtn
    headerBar._anShellUtilities = utilityButtons
    headerBar._anShellRightClip = rightClip
    parent._anShellHeaderBar = headerBar

    title:SetPoint("RIGHT", rightClip, "LEFT", -8, 0)

    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() and ns.UI_LayoutClassicShellHeader then
        ns.UI_LayoutClassicShellHeader(headerBar)
    end

    return {
        bar = headerBar,
        title = title,
        logo = logo,
        close = close,
        settings = settingsBtn,
        utilities = utilityButtons,
        rightClip = rightClip,
        pad = pad,
        headerH = headerH,
    }
end

--- Toolbar / tab shell button (UIPanelButtonTemplate in Classic, BackdropTemplate in Modern).
---@param parent Frame
---@param height number|nil
---@return Button
function ns.UI_CreateToolbarButton(parent, height)
    local tpl = (ns.UI_ClassicButtonTemplate and ns.UI_ClassicButtonTemplate()) or "BackdropTemplate"
    local b = CreateFrame("Button", nil, parent, tpl)
    if height and b.SetHeight then
        b:SetHeight(height)
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        b._anClassicNativePanel = true
    else
        local fs = b.GetFontString and b:GetFontString()
        if not fs then
            fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("CENTER")
            b:SetFontString(fs)
        end
        b._lbl = fs
    end
    return b
end

---@param btn Button|Frame
---@param text string
function ns.UI_SetToolbarButtonText(btn, text)
    if not btn then
        return
    end
    if ns.UI_IsNativePanelButton and ns.UI_IsNativePanelButton(btn) then
        if ns.UI_SetNativePanelButtonText then
            ns.UI_SetNativePanelButtonText(btn, text)
        elseif btn.SetText then
            btn:SetText(text)
        end
        return
    end
    local fs = btn._lbl or (btn.GetFontString and btn:GetFontString())
    if fs and fs.SetText then
        fs:SetText(text)
    end
end

--- Full-screen craft panels (Hub, Recipes, Session loot) must not stack on the same anchor.
---@param keep "loot"|"hub"|"recipes"|nil window to leave open; nil closes all three
function ns.UI_CloseSiblingCraftWindows(keep)
    local windows = {
        loot = "ArtisanNexusLootHistoryFrame",
        hub = "ArtisanNexusHub",
        recipes = "ArtisanNexusRecipeMatcher",
    }
    for key, globalName in pairs(windows) do
        if keep ~= key then
            local f = _G[globalName]
            if f and f.IsShown and f:IsShown() then
                f:Hide()
            end
        end
    end
end

--- Default anchor when a craft window opens alone (slash / minimap).
---@param frame Frame
---@param offsetX number|nil
---@param offsetY number|nil
function ns.UI_PlaceCraftWindowDefault(frame, offsetX, offsetY)
    if not frame then
        return
    end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", offsetX or 0, offsetY or 0)
end

--- True when `a` and `b` occupy the same screen region (any axis overlap).
local function CraftWindowFramesOverlap(a, b)
    if not a or not b then
        return false
    end
    local al, ab, aw, ah = a:GetRect()
    local bl, bb, bw, bh = b:GetRect()
    if not al or not bl or not aw or not bw then
        return false
    end
    local ar, at = al + aw, ab + ah
    local br, bt = bl + bw, bb + bh
    return not (ar <= bl or br <= al or at <= bb or bt <= ab)
end

--- Place `frame` beside `anchor` when both fit on screen without overlapping.
---@param frame Frame
---@param anchor Frame
---@param gap number|nil
---@return boolean placed
function ns.UI_TileCraftWindowBeside(frame, anchor, gap)
    if not frame or not anchor then
        return false
    end
    gap = gap or 12
    local edgePad = 8
    local sw = (GetScreenWidth and GetScreenWidth()) or (UIParent and UIParent:GetWidth()) or 1920

    local function fitsScreenAndClear()
        local left = frame:GetLeft()
        local right = frame:GetRight()
        if not left or not right then
            return false
        end
        if left < edgePad or right > sw - edgePad then
            return false
        end
        return not CraftWindowFramesOverlap(frame, anchor)
    end

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", gap, 0)
    if fitsScreenAndClear() then
        return true
    end

    frame:ClearAllPoints()
    frame:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -gap, 0)
    if fitsScreenAndClear() then
        return true
    end

    return false
end

--- Bring a craft window above siblings after open.
---@param frame Frame
function ns.UI_RaiseCraftWindow(frame)
    if frame and frame.Raise then
        frame:Raise()
    end
end

--- Show exactly one main craft window — never stack on the same anchor.
--- If `opts.tileAfter` is set and side-by-side fits, keep both; otherwise close siblings and center.
---@param frame Frame
---@param keep "loot"|"hub"|"recipes"
---@param opts table|nil `{ tileAfter = Frame }` (optional; falls back to exclusive when no room)
function ns.UI_PresentCraftWindow(frame, keep, opts)
    if not frame then
        return
    end
    opts = opts or {}
    local tileAfter = opts.tileAfter
    local tiled = tileAfter and tileAfter.IsShown and tileAfter:IsShown()
        and ns.UI_TileCraftWindowBeside(frame, tileAfter)

    if not tiled then
        if ns.UI_CloseSiblingCraftWindows then
            ns.UI_CloseSiblingCraftWindows(keep)
        end
        if ns.UI_PlaceCraftWindowDefault then
            ns.UI_PlaceCraftWindowDefault(frame)
        else
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
    end

    if ns.UI_RaiseCraftWindow then
        ns.UI_RaiseCraftWindow(frame)
    end
    frame:Show()
end

--- Stretch a row of buttons edge-to-edge (equal width). Matches Modern tab rows.
---@param bar Frame
---@param buttons table[] ordered button list
---@param gap number|nil pixels between buttons (default 5)
function ns.UI_LayoutStretchRow(bar, buttons, gap)
    if not bar or not buttons then
        return
    end
    gap = gap or 5
    local n = #buttons
    if n < 1 then
        return
    end
    local rowH = bar:GetHeight() or 30
    local barW = bar:GetWidth() or 0
    if barW < 80 then
        return
    end
    local totalGap = gap * (n - 1)
    local btnW = math.floor((barW - totalGap) / n)
    if btnW < 1 then
        btnW = 1
    end
    local prev
    for i = 1, n do
        local b = buttons[i]
        if b then
            b:ClearAllPoints()
            b:SetSize(btnW, rowH)
            if i == 1 then
                b:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
            else
                b:SetPoint("TOPLEFT", prev, "TOPRIGHT", gap, 0)
            end
            b:Show()
            prev = b
        end
    end
end

ns.UI_SHELL_LOGO = MEDIA_LOGO
