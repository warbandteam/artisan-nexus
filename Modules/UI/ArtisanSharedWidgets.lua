--[[
    Artisan Nexus — Warband-aligned visual core (lite).
    Ported from warband-nexus Modules/UI/SharedWidgets.lua: ApplyVisuals, CreateIcon, GetPixelScale.
]]

local ADDON_NAME, ns = ...

local DebugPrint = ns.DebugPrint or function() end

--============================================================================
-- Pixel scale (same formula as Warband)
--============================================================================
local mult = nil

local function GetPixelScale(frame)
    local physH = 1080
    if GetPhysicalScreenSize then
        local _, h = GetPhysicalScreenSize()
        if h and h > 0 then physH = h end
    else
        local resolution = GetCVar("gxWindowedResolution") or "1920x1080"
        local _, h = string.match(resolution, "(%d+)x(%d+)")
        h = tonumber(h)
        if h and h > 0 then physH = h end
    end

    local scaleTarget = frame or UIParent
    local effectiveScale = scaleTarget and scaleTarget.GetEffectiveScale and scaleTarget:GetEffectiveScale() or 1
    if not effectiveScale or effectiveScale <= 0 then effectiveScale = 1 end

    if not frame or frame == UIParent then
        if mult then return mult end
        mult = 768.0 / (physH * effectiveScale)
        return mult
    end

    return 768.0 / (physH * effectiveScale)
end

local function ResetPixelScale()
    mult = nil
end

ns.BORDER_REGISTRY = ns.BORDER_REGISTRY or {}

local function UpdateBorderColor(frame, borderColor)
    if not frame or not frame.BorderTop then return end
    local r, g, b, a = borderColor[1], borderColor[2], borderColor[3], borderColor[4] or 1
    frame.BorderTop:SetVertexColor(r, g, b, a)
    frame.BorderBottom:SetVertexColor(r, g, b, a)
    frame.BorderLeft:SetVertexColor(r, g, b, a)
    frame.BorderRight:SetVertexColor(r, g, b, a)
end

--============================================================================
-- ApplyVisuals — 4 dokulu piksel kenarlık
--============================================================================
local function ApplyVisuals(frame, bgColor, borderColor)
    if not frame then return end
    --- Classic skin: no Artisan pixel chrome — WindowShell / Classic helpers own surfaces.
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        return
    end

    if not ns.BORDER_REGISTRY then
        ns.BORDER_REGISTRY = {}
    end

    if not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
    end

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
    })

    if bgColor then
        frame:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 1)
    end

    if not frame.BorderTop then
        local pixelScale = GetPixelScale(frame)
        local thickMult = (ns.UI_BORDER_THICKNESS_MULT or 1)
        local edge = pixelScale * thickMult

        frame.BorderTop = frame:CreateTexture(nil, "BORDER")
        frame.BorderTop:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderTop:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        frame.BorderTop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        frame.BorderTop:SetHeight(edge)
        frame.BorderTop:SetSnapToPixelGrid(false)
        frame.BorderTop:SetTexelSnappingBias(0)
        frame.BorderTop:SetDrawLayer("BORDER", 0)

        frame.BorderBottom = frame:CreateTexture(nil, "BORDER")
        frame.BorderBottom:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderBottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        frame.BorderBottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        frame.BorderBottom:SetHeight(edge)
        frame.BorderBottom:SetSnapToPixelGrid(false)
        frame.BorderBottom:SetTexelSnappingBias(0)
        frame.BorderBottom:SetDrawLayer("BORDER", 0)

        frame.BorderLeft = frame:CreateTexture(nil, "BORDER")
        frame.BorderLeft:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderLeft:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        frame.BorderLeft:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        frame.BorderLeft:SetWidth(edge)
        frame.BorderLeft:SetSnapToPixelGrid(false)
        frame.BorderLeft:SetTexelSnappingBias(0)
        frame.BorderLeft:SetDrawLayer("BORDER", 0)

        frame.BorderRight = frame:CreateTexture(nil, "BORDER")
        frame.BorderRight:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderRight:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        frame.BorderRight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        frame.BorderRight:SetWidth(edge)
        frame.BorderRight:SetSnapToPixelGrid(false)
        frame.BorderRight:SetTexelSnappingBias(0)
        frame.BorderRight:SetDrawLayer("BORDER", 0)

        if borderColor then
            local r, g, b, a = borderColor[1], borderColor[2], borderColor[3], borderColor[4] or 1
            frame.BorderTop:SetVertexColor(r, g, b, a)
            frame.BorderBottom:SetVertexColor(r, g, b, a)
            frame.BorderLeft:SetVertexColor(r, g, b, a)
            frame.BorderRight:SetVertexColor(r, g, b, a)
        end
    elseif borderColor then
        UpdateBorderColor(frame, borderColor)
    end

    if borderColor then
        local isAccent = (borderColor[1] > 0.3 or borderColor[2] > 0.3)
        frame._borderType = isAccent and "accent" or "border"
        frame._borderAlpha = borderColor[4] or 1
    else
        frame._borderType = "border"
        frame._borderAlpha = 0.6
    end

    if bgColor then
        local isBgAccent = (bgColor[1] > 0.15 or bgColor[2] > 0.10)
        frame._bgType = isBgAccent and "accentDark" or "bg"
        frame._bgAlpha = bgColor[4] or 1
    else
        frame._bgType = "bg"
        frame._bgAlpha = 1
    end

    if not frame._borderRegistered then
        frame._borderRegistered = true
        table.insert(ns.BORDER_REGISTRY, frame)
    end
end

--- Remove a frame (and its child subtree) from BORDER_REGISTRY. Content that is
--- rebuilt per refresh (loot catalog cells, hub rows) MUST call this before
--- discarding frames, or the registry grows unboundedly and every theme/scale
--- refresh iterates dead entries all session.
function ns.UI_UnregisterVisuals(frame)
    if not frame then return end
    local reg = ns.BORDER_REGISTRY
    if frame._borderRegistered then
        frame._borderRegistered = nil
        for i = #reg, 1, -1 do
            if reg[i] == frame then
                table.remove(reg, i)
                break
            end
        end
    end
    local ch = { frame:GetChildren() }
    for i = 1, #ch do
        ns.UI_UnregisterVisuals(ch[i])
    end
end

local function AccentColor()
    local c = ns.UI_COLORS and ns.UI_COLORS.accent
    if c then return c[1], c[2], c[3], 0.72 end
    return 0.52, 0.40, 0.66, 0.72
end

local function CreateIcon(parent, texture, size, isAtlas, borderColor, noBorder)
    if not parent then return nil end

    size = size or 32
    isAtlas = isAtlas or false
    if not borderColor then
        local r, g, b, a = AccentColor()
        borderColor = { r, g, b, a }
    end
    noBorder = noBorder or false

    local frame = CreateFrame("Frame", nil, parent)
    frame:Hide()
    frame:SetSize(size, size)

    if not noBorder then
        ApplyVisuals(frame, { 0.09, 0.088, 0.11, 0.96 }, borderColor)
    end

    local tex = frame:CreateTexture(nil, "ARTWORK")
    if noBorder then
        tex:SetAllPoints()
    else
        local inset = GetPixelScale() * (1 + (ns.UI_BORDER_THICKNESS_MULT or 1))
        tex:SetPoint("TOPLEFT", inset, -inset)
        tex:SetPoint("BOTTOMRIGHT", -inset, inset)
    end

    if texture then
        if isAtlas then
            local success = pcall(function()
                tex:SetAtlas(texture, false)
            end)
            if not success then
                DebugPrint("|cffff9900[ArtisanNexus CreateIcon]|r Atlas failed: " .. tostring(texture))
                tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            end
        else
            if type(texture) == "string" then
                tex:SetTexture(texture)
            else
                tex:SetTexture(texture)
            end
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end

    tex:SetSnapToPixelGrid(false)
    tex:SetTexelSnappingBias(0)
    frame.texture = tex

    return frame
end

-- Keep 1px border thickness correct when UI scale changes
local scaleHandler = CreateFrame("Frame")
scaleHandler:RegisterEvent("UI_SCALE_CHANGED")
scaleHandler:RegisterEvent("DISPLAY_SIZE_CHANGED")
scaleHandler:SetScript("OnEvent", function()
    mult = nil
    C_Timer.After(0, function()
        if not ns.BORDER_REGISTRY then return end
        for i = 1, #ns.BORDER_REGISTRY do
            local fr = ns.BORDER_REGISTRY[i]
            if fr and fr.BorderTop then
                local pixelScale = GetPixelScale(fr)
                fr.BorderTop:SetHeight(pixelScale)
                fr.BorderBottom:SetHeight(pixelScale)
                fr.BorderLeft:ClearAllPoints()
                fr.BorderLeft:SetPoint("TOPLEFT", fr, "TOPLEFT", 0, 0)
                fr.BorderLeft:SetPoint("BOTTOMLEFT", fr, "BOTTOMLEFT", 0, 0)
                fr.BorderLeft:SetWidth(pixelScale)
                fr.BorderRight:ClearAllPoints()
                fr.BorderRight:SetPoint("TOPRIGHT", fr, "TOPRIGHT", 0, 0)
                fr.BorderRight:SetPoint("BOTTOMRIGHT", fr, "BOTTOMRIGHT", 0, 0)
                fr.BorderRight:SetWidth(pixelScale)
            end
        end
    end)
end)

--============================================================================
-- Settings XML: Warband-style themed toggle (strip UICheckButtonTemplate art)
--============================================================================

local SETTINGS_TOGGLE_SIZE = 18
local SETTINGS_TOGGLE_DOT = 7
local SETTINGS_TOGGLE_BG = { 0.08, 0.08, 0.10, 1 }
local SETTINGS_TOGGLE_DOT_COL = { 1, 0.82, 0, 1 }
-- UICheckButtonTemplate heights collapse when textures are cleared; layout anchors need a stable row height.
local SETTINGS_CHECK_ROW_HEIGHT = 26

local function StripCheckButtonArt(btn)
    pcall(function()
        btn:SetNormalTexture("")
        btn:SetPushedTexture("")
        btn:SetHighlightTexture("")
        btn:SetDisabledTexture("")
        btn:SetCheckedTexture("")
    end)
    -- Midnight template may still leave texture regions; hide so they cannot draw offset from the custom hitbox.
    pcall(function()
        if btn.GetNormalTexture then
            local nt = btn:GetNormalTexture()
            if nt then nt:SetTexture(nil) nt:Hide() end
        end
        if btn.GetPushedTexture then
            local pt = btn:GetPushedTexture()
            if pt then pt:SetTexture(nil) pt:Hide() end
        end
        if btn.GetHighlightTexture then
            local ht = btn:GetHighlightTexture()
            if ht then ht:SetTexture(nil) ht:Hide() end
        end
        if btn.GetDisabledTexture then
            local dt = btn:GetDisabledTexture()
            if dt then dt:SetTexture(nil) dt:Hide() end
        end
        if btn.GetCheckedTexture then
            local ct = btn:GetCheckedTexture()
            if ct then ct:SetTexture(nil) ct:Hide() end
        end
    end)
end

--- Restore native UICheckButton art on a previously themed toggle (classic skin).
local function RestoreClassicCheckButtonArt(btn)
    pcall(function()
        btn:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        btn:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        btn:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
        btn:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    end)
    pcall(function()
        local nt = btn.GetNormalTexture and btn:GetNormalTexture()
        if nt then nt:Show() end
        local pt = btn.GetPushedTexture and btn:GetPushedTexture()
        if pt then pt:Show() end
        local ht = btn.GetHighlightTexture and btn:GetHighlightTexture()
        if ht then ht:Show() end
        local ct = btn.GetCheckedTexture and btn:GetCheckedTexture()
        if ct then ct:Show() end
    end)
end

---@param btn CheckButton|nil
function ns.UI_StyleSettingsCheckButton(btn)
    if not btn then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        --- Mode-reversal: a toggle themed in Modern must fall back to native art.
        if btn._anThemedToggleStyled and not btn._anToggleClassicMode then
            btn._anToggleClassicMode = true
            if btn.anThemedHost then
                btn.anThemedHost:Hide()
            end
            RestoreClassicCheckButtonArt(btn)
            if btn.Text then
                btn.Text:ClearAllPoints()
                if btn._anTextOrigAnchor then
                    local a = btn._anTextOrigAnchor
                    btn.Text:SetPoint(a[1], a[2] or btn, a[3] or a[1], a[4] or 0, a[5] or 0)
                else
                    btn.Text:SetPoint("LEFT", btn, "RIGHT", 2, 0)
                end
            end
            local bname = btn.GetName and btn:GetName()
            if bname then
                local icon = _G[bname .. "Icon"]
                if icon and icon.Show then
                    icon:Show()
                end
            end
        end
        return
    end
    if btn._anThemedToggleStyled then
        --- Returning from classic: restore the themed host + strip native art.
        if btn._anToggleClassicMode then
            btn._anToggleClassicMode = nil
            StripCheckButtonArt(btn)
            if btn.anThemedHost then
                btn.anThemedHost:Show()
            end
            if btn.anThemedDot then
                btn.anThemedDot:SetShown(btn:GetChecked())
            end
            if btn.Text and btn.anThemedHost then
                btn.Text:ClearAllPoints()
                btn.Text:SetPoint("TOPLEFT", btn.anThemedHost, "TOPRIGHT", 10, -1)
            end
            local bname = btn.GetName and btn:GetName()
            if bname then
                local icon = _G[bname .. "Icon"]
                if icon and icon.Hide then
                    icon:Hide()
                end
            end
        end
        return
    end
    btn._anThemedToggleStyled = true

    if btn.Text and btn.Text.GetPoint then
        local p, rel, relP, x, y = btn.Text:GetPoint(1)
        if p then
            btn._anTextOrigAnchor = { p, rel, relP, x, y }
        end
    end

    StripCheckButtonArt(btn)

    btn:SetHeight(SETTINGS_CHECK_ROW_HEIGHT)

    local COL = ns.UI_COLORS or {}
    local ac = COL.accent or { 0.52, 0.40, 0.66, 1 }
    local borderCol = { ac[1], ac[2], ac[3], 0.82 }
    local toggleBg = (ns.UI_GetControlChromeBackdrop and ns.UI_GetControlChromeBackdrop()) or SETTINGS_TOGGLE_BG

    local host = CreateFrame("Frame", nil, btn)
    host:SetSize(SETTINGS_TOGGLE_SIZE, SETTINGS_TOGGLE_SIZE)
    local padY = (SETTINGS_CHECK_ROW_HEIGHT - SETTINGS_TOGGLE_SIZE) / 2
    host:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, -padY)
    host:EnableMouse(false)
    ApplyVisuals(host, toggleBg, borderCol)
    host._borderType = "accent"
    host._borderAlpha = borderCol[4] or 0.82

    local dot = host:CreateTexture(nil, "OVERLAY")
    dot:SetDrawLayer("OVERLAY", 7)
    dot:SetSize(SETTINGS_TOGGLE_DOT, SETTINGS_TOGGLE_DOT)
    dot:SetPoint("CENTER", host, "CENTER", 0, 0)
    dot:SetColorTexture(SETTINGS_TOGGLE_DOT_COL[1], SETTINGS_TOGGLE_DOT_COL[2], SETTINGS_TOGGLE_DOT_COL[3], SETTINGS_TOGGLE_DOT_COL[4])
    dot:SetShown(btn:GetChecked())

    btn.anThemedHost = host
    btn.anThemedDot = dot

    local bname = btn.GetName and btn:GetName()
    if bname then
        local icon = _G[bname .. "Icon"]
        if icon and icon.Hide then
            icon:Hide()
        end
    end

    if btn.Text then
        btn.Text:ClearAllPoints()
        btn.Text:SetPoint("TOPLEFT", host, "TOPRIGHT", 10, -1)
        btn.Text:SetJustifyH("LEFT")
        if btn.Text.SetFontObject then
            btn.Text:SetFontObject("GameFontHighlight")
        end
        local tn = COL.textNormal or { 0.88, 0.84, 0.92, 1 }
        btn.Text:SetTextColor(tn[1], tn[2], tn[3], tn[4] or 1)
    end

    local function syncDot()
        if btn.anThemedDot then
            btn.anThemedDot:SetShown(btn:GetChecked())
        end
    end

    local prevClick = btn:GetScript("OnClick")
    btn:SetScript("OnClick", function(self, ...)
        if prevClick then
            prevClick(self, ...)
        end
        syncDot()
    end)

    local prevEnter = btn:GetScript("OnEnter")
    local prevLeave = btn:GetScript("OnLeave")
    btn:SetScript("OnEnter", function(self, ...)
        if prevEnter then
            prevEnter(self, ...)
        end
        if host and host.BorderTop and ns.UI_UpdateBorderColor then
            ns.UI_UpdateBorderColor(host, {
                math.min(1, ac[1] * 1.12),
                math.min(1, ac[2] * 1.12),
                math.min(1, ac[3] * 1.12),
                1,
            })
        end
    end)
    btn:SetScript("OnLeave", function(self, ...)
        if prevLeave then
            prevLeave(self, ...)
        end
        if host and ns.UI_UpdateBorderColor then
            ns.UI_UpdateBorderColor(host, borderCol)
        end
    end)
end

--- Settings action buttons (UIPanelButtonTemplate — Reset session / Reset overall).
--- MODERN: hide the template button art (texture regions stashed once so the
--- swap is reversible) and apply themed pixel chrome. CLASSIC: restore the
--- stashed template art and suppress the pixel chrome. Mirrors the reversible
--- pattern used by UI_StyleSettingsCheckButton; idempotent, safe on theme refresh.
---@param btn Button|nil
function ns.UI_StyleSettingsPanelButton(btn)
    if not btn then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        --- Mode-reversal: a button themed in Modern falls back to template art.
        if btn._anPanelBtnStyled and not btn._anPanelBtnClassicMode then
            btn._anPanelBtnClassicMode = true
            if ns.UI_SuppressArtisanChrome then
                ns.UI_SuppressArtisanChrome(btn)
            end
            if btn.SetBackdropColor then
                pcall(function()
                    btn:SetBackdropColor(0, 0, 0, 0)
                end)
            end
            local art = btn._anPanelBtnArt
            if art then
                for i = 1, #art do
                    local rec = art[i]
                    pcall(function()
                        if rec.atlas then
                            rec.tex:SetAtlas(rec.atlas)
                        elseif rec.fileID then
                            rec.tex:SetTexture(rec.fileID)
                        end
                        if rec.coords then
                            rec.tex:SetTexCoord(unpack(rec.coords))
                        end
                        rec.tex:Show()
                    end)
                end
            end
            local fs = btn.GetFontString and btn:GetFontString()
            if fs and fs.SetFontObject then
                fs:SetFontObject("GameFontNormal")
            end
        end
        return
    end
    if not btn._anPanelBtnStyled then
        btn._anPanelBtnStyled = true
        --- Stash the template texture regions ONCE (atlas / fileID / texcoords)
        --- so Classic can restore native art without hardcoded texture paths.
        local art = {}
        local function stash(tex)
            if not tex then
                return
            end
            local rec = { tex = tex }
            pcall(function()
                if tex.GetAtlas then
                    rec.atlas = tex:GetAtlas()
                end
                if not rec.atlas and tex.GetTextureFileID then
                    rec.fileID = tex:GetTextureFileID()
                end
                if tex.GetTexCoord then
                    rec.coords = { tex:GetTexCoord() }
                end
            end)
            art[#art + 1] = rec
        end
        stash(btn.GetNormalTexture and btn:GetNormalTexture())
        stash(btn.GetPushedTexture and btn:GetPushedTexture())
        stash(btn.GetHighlightTexture and btn:GetHighlightTexture())
        stash(btn.GetDisabledTexture and btn:GetDisabledTexture())
        --- Old-style UIPanelButtonTemplate three-slice pieces (parentKeys).
        stash(btn.Left)
        stash(btn.Middle)
        stash(btn.Right)
        btn._anPanelBtnArt = art
    elseif btn._anPanelBtnClassicMode then
        btn._anPanelBtnClassicMode = nil
        if ns.UI_RestoreArtisanChrome then
            ns.UI_RestoreArtisanChrome(btn)
        end
    end
    --- Strip template art (SetTexture(nil) survives Button state swaps; Hide alone does not).
    local art = btn._anPanelBtnArt
    if art then
        for i = 1, #art do
            local rec = art[i]
            pcall(function()
                rec.tex:SetTexture(nil)
                rec.tex:Hide()
            end)
        end
    end
    local COL = ns.UI_COLORS or {}
    local bg = COL.tabInactive or { 0.115, 0.108, 0.128, 1 }
    local br = COL.border or { 0.40, 0.36, 0.48, 1 }
    ApplyVisuals(btn, bg, br)
    local fs = btn.GetFontString and btn:GetFontString()
    if fs and fs.SetFontObject then
        fs:SetFontObject("GameFontHighlightMedium")
    end
end

--- Section title strip (LootHistory / Warband settings card header style).
--- Re-runnable: reverses the pixel strip in Classic and restores it in Modern.
---@param titleFrame Frame|nil
function ns.UI_StyleSettingsSectionTitle(titleFrame)
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if not titleFrame then
            return
        end
        titleFrame:SetHeight(26)
        --- Mode-reversal: hide the Modern pixel strip chrome.
        if titleFrame._anSectionStyled then
            titleFrame._anSectionClassicMode = true
            if ns.UI_SuppressArtisanChrome then
                ns.UI_SuppressArtisanChrome(titleFrame)
            end
            if titleFrame.SetBackdropColor then
                titleFrame:SetBackdropColor(0, 0, 0, 0)
            end
        end
        local bname = titleFrame.GetName and titleFrame:GetName()
        if bname then
            local fs = _G[bname .. "Text"]
            if fs and fs.SetTextColor then
                fs:SetTextColor(1, 0.82, 0)
                titleFrame._anTitleText = fs
            end
        end
        return
    end
    if not titleFrame then
        return
    end
    if titleFrame._anSectionStyled and not titleFrame._anSectionClassicMode then
        return
    end
    if titleFrame._anSectionClassicMode then
        --- Returning from classic: re-show the pixel borders (colors re-applied below).
        titleFrame._anSectionClassicMode = nil
        if ns.UI_RestoreArtisanChrome then
            ns.UI_RestoreArtisanChrome(titleFrame)
        end
    end
    titleFrame._anSectionStyled = true
    if not titleFrame.SetBackdrop then
        Mixin(titleFrame, BackdropTemplateMixin)
    end
    local COL = ns.UI_COLORS or {}
    local bg = COL.lootHeaderBg or COL.accentDark or { 0.125, 0.105, 0.155, 1 }
    local ac = COL.accent or { 0.52, 0.40, 0.66, 1 }
    local brBase = COL.lootHeaderBorder or { ac[1], ac[2], ac[3], 0.88 }
    -- Softer accent edge matches settings section strips; avoids heavy purple strips vs card body.
    local br = { brBase[1], brBase[2], brBase[3], math.min(brBase[4] or 0.88, 0.55) }
    -- Match ArtisanSettingsFrame.xml section title height so anchors do not drift from Lua resize.
    titleFrame:SetHeight(26)
    ApplyVisuals(titleFrame, bg, br)
    local bname = titleFrame.GetName and titleFrame:GetName()
    if bname then
        local fs = _G[bname .. "Text"]
        if fs and fs.SetTextColor then
            local tb = COL.textBright or { 0.96, 0.95, 0.97, 1 }
            fs:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1)
            titleFrame._anTitleText = fs
        end
    end
end

ns.UI_SETTINGS_CHECK_ROW_HEIGHT = SETTINGS_CHECK_ROW_HEIGHT

ns.UI_ApplyVisuals = ApplyVisuals
ns.UI_CreateIcon = CreateIcon
ns.UI_ResetPixelScale = ResetPixelScale
ns.UI_UpdateBorderColor = UpdateBorderColor
ns.GetPixelScale = GetPixelScale
