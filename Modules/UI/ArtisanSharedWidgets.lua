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
local function ApplyVisuals(frame, bgColor, borderColor, visualOpts)
    if not frame then return end
    visualOpts = type(visualOpts) == "table" and visualOpts or nil
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
    if frame.SetBackdropBorderColor then
        frame:SetBackdropBorderColor(0, 0, 0, 0)
    end

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

    if visualOpts and visualOpts.borderType then
        frame._borderType = visualOpts.borderType
        frame._borderAlpha = (borderColor and borderColor[4]) or frame._borderAlpha or 0.6
    elseif borderColor then
        local isAccent = (borderColor[1] > 0.3 or borderColor[2] > 0.3)
        frame._borderType = isAccent and "accent" or "border"
        frame._borderAlpha = borderColor[4] or 1
    else
        frame._borderType = "border"
        frame._borderAlpha = 0.6
    end

    if visualOpts and visualOpts.bgType then
        frame._bgType = visualOpts.bgType
        frame._bgAlpha = (bgColor and bgColor[4]) or frame._bgAlpha or 1
    elseif bgColor then
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

local SETTINGS_TOGGLE_SIZE = 20
local SETTINGS_TOGGLE_BG = { 0.08, 0.08, 0.10, 1 }
-- UICheckButtonTemplate heights collapse when textures are cleared; layout anchors need a stable row height.
local SETTINGS_CHECK_ROW_HEIGHT = 28

local StripTemplateTextures

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

--- Keep UICheckButtonTemplate art hidden under Modern pixel toggle host.
local function HideNativeCheckButtonArt(btn)
    if not btn then
        return
    end
    StripCheckButtonArt(btn)
    pcall(function()
        if btn.GetCheckedTexture then
            local ct = btn:GetCheckedTexture()
            if ct then
                ct:SetTexture(nil)
                ct:Hide()
            end
        end
    end)
    local bname = btn.GetName and btn:GetName()
    if bname then
        local icon = _G[bname .. "Icon"]
        if icon and icon.Hide then
            icon:Hide()
        end
    end
end

--- Re-apply accent/control chrome on an already themed Modern settings toggle.
local function ApplyModernToggleVisual(btn, host, markTex)
    if not btn or not host then
        return
    end
    HideNativeCheckButtonArt(btn)
    StripTemplateTextures(btn, markTex)
    host:SetFrameLevel((btn:GetFrameLevel() or 0) + 8)
    local COL = ns.UI_COLORS or {}
    local ac = COL.accent or { 0.52, 0.40, 0.66, 1 }
    local checked = btn:GetChecked()
    local uncheckedBg = (ns.UI_GetControlChromeBackdrop and ns.UI_GetControlChromeBackdrop()) or SETTINGS_TOGGLE_BG
    local checkedBg = (ns.UI_GetControlChromeHoverBackdrop and ns.UI_GetControlChromeHoverBackdrop())
        or {
            ac[1] * 0.18 + uncheckedBg[1] * 0.82,
            ac[2] * 0.18 + uncheckedBg[2] * 0.82,
            ac[3] * 0.18 + uncheckedBg[3] * 0.82,
            1,
        }
    local bg = checked and checkedBg or uncheckedBg
    local borderAlpha = checked and 0.72 or 0.48
    local borderCol = { ac[1], ac[2], ac[3], borderAlpha }
    ApplyVisuals(host, bg, borderCol, {
        bgType = checked and "controlChromeHover" or "controlChrome",
        borderType = "accent",
    })
    host._borderAlpha = borderAlpha
    if markTex then
        markTex:SetSize(8, 8)
        markTex:SetColorTexture(ac[1], ac[2], ac[3], checked and 0.88 or 0)
        markTex:SetShown(checked)
    end
    if btn.Text then
        local tn = COL.textNormal or { 0.88, 0.84, 0.92, 1 }
        btn.Text:SetTextColor(tn[1], tn[2], tn[3], tn[4] or 1)
    end
end

local function RefreshModernSettingsCheckButton(btn)
    ApplyModernToggleVisual(btn, btn.anThemedHost, btn.anThemedDot)
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
            HideNativeCheckButtonArt(btn)
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
        end
        if btn.anThemedHost then
            ApplyModernToggleVisual(btn, btn.anThemedHost, btn.anThemedDot)
            return
        end
        btn._anThemedToggleStyled = nil
    end
    btn._anThemedToggleStyled = true

    if btn.Text and btn.Text.GetPoint then
        local p, rel, relP, x, y = btn.Text:GetPoint(1)
        if p then
            btn._anTextOrigAnchor = { p, rel, relP, x, y }
        end
    end

    HideNativeCheckButtonArt(btn)

    btn:SetHeight(SETTINGS_CHECK_ROW_HEIGHT)

    local host = CreateFrame("Frame", nil, btn)
    host:SetSize(SETTINGS_TOGGLE_SIZE, SETTINGS_TOGGLE_SIZE)
    local padY = (SETTINGS_CHECK_ROW_HEIGHT - SETTINGS_TOGGLE_SIZE) / 2
    host:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, -padY)
    host:EnableMouse(false)

    local mark = host:CreateTexture(nil, "OVERLAY")
    mark:SetDrawLayer("OVERLAY", 7)
    mark:SetPoint("CENTER", host, "CENTER", 0, 0)

    btn.anThemedHost = host
    btn.anThemedDot = mark
    ApplyModernToggleVisual(btn, host, mark)

    if btn.Text then
        btn.Text:ClearAllPoints()
        btn.Text:SetPoint("TOPLEFT", host, "TOPRIGHT", 10, -1)
        btn.Text:SetJustifyH("LEFT")
        if btn.Text.SetFontObject then
            btn.Text:SetFontObject("GameFontHighlightMedium")
        end
    end

    local function syncDot()
        ApplyModernToggleVisual(btn, btn.anThemedHost, btn.anThemedDot)
    end

    if btn.HookScript then
        btn:HookScript("OnShow", function()
            if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
                return
            end
            RefreshModernSettingsCheckButton(btn)
        end)
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
            local ac = (ns.UI_COLORS and ns.UI_COLORS.accent) or { 0.52, 0.40, 0.66, 1 }
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
        ApplyModernToggleVisual(btn, host, mark)
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
    --- Full region scan every pass — UIDropDownMenu can add textures after the first stash.
    StripTemplateTextures(btn)
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
    if btn.Icon then
        pcall(function()
            btn.Icon:SetTexture(nil)
            btn.Icon:Hide()
        end)
    end
    local COL = ns.UI_COLORS or {}
    local bg = (ns.UI_GetControlChromeBackdrop and ns.UI_GetControlChromeBackdrop())
        or COL.tabInactive or { 0.115, 0.108, 0.128, 1 }
    local ac = COL.accent or { 0.52, 0.40, 0.66, 1 }
    local br = { ac[1], ac[2], ac[3], 0.55 }
    if ns.UI_StripClassicBackdropEdge then
        ns.UI_StripClassicBackdropEdge(btn)
    end
    ApplyVisuals(btn, bg, br, { bgType = "controlChrome", borderType = "accent" })
    btn._borderAlpha = 0.55
    local fs = btn.GetFontString and btn:GetFontString()
    if fs and fs.SetFontObject then
        fs:SetFontObject("GameFontHighlightMedium")
    end
end

--- Section title: Modern = bright label + accent underline (WN Theme tab); Classic = gold text only.
---@param titleFrame Frame|nil
function ns.UI_StyleSettingsSectionTitle(titleFrame)
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        if not titleFrame then
            return
        end
        titleFrame:SetHeight(26)
        if titleFrame._anSectionStyled then
            titleFrame._anSectionClassicMode = true
            if ns.UI_SuppressArtisanChrome then
                ns.UI_SuppressArtisanChrome(titleFrame)
            end
            if titleFrame.SetBackdropColor then
                titleFrame:SetBackdropColor(0, 0, 0, 0)
            end
            if titleFrame._anSectionUnderline then
                titleFrame._anSectionUnderline:Hide()
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
    if titleFrame._anSectionClassicMode then
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
    local ac = COL.accent or { 0.52, 0.40, 0.66, 1 }
    titleFrame:SetHeight(34)
    if ns.UI_SuppressArtisanChrome then
        ns.UI_SuppressArtisanChrome(titleFrame)
    end
    if titleFrame.SetBackdrop then
        titleFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8x8",
            edgeFile = "Interface\\Buttons\\WHITE8x8",
            tile = false,
            edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        titleFrame:SetBackdropColor(0, 0, 0, 0)
        titleFrame:SetBackdropBorderColor(0, 0, 0, 0)
    end
    if not titleFrame._anSectionUnderline then
        titleFrame._anSectionUnderline = titleFrame:CreateTexture(nil, "ARTWORK")
        titleFrame._anSectionUnderline:SetHeight(2)
        titleFrame._anSectionUnderline:SetPoint("BOTTOMLEFT", titleFrame, "BOTTOMLEFT", 0, 0)
        titleFrame._anSectionUnderline:SetPoint("BOTTOMRIGHT", titleFrame, "BOTTOMRIGHT", 0, 0)
    end
    titleFrame._anSectionUnderline:SetColorTexture(ac[1], ac[2], ac[3], 0.55)
    titleFrame._anSectionUnderline:Show()
    local bname = titleFrame.GetName and titleFrame:GetName()
    if bname then
        local fs = _G[bname .. "Text"]
        if fs then
            if fs.SetFontObject then
                fs:SetFontObject("GameFontNormalLarge")
            end
            if fs.SetTextColor then
                local tb = COL.textBright or { 0.96, 0.95, 0.97, 1 }
                fs:SetTextColor(tb[1], tb[2], tb[3], tb[4] or 1)
            end
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", titleFrame, "LEFT", 0, 4)
            fs:SetJustifyH("LEFT")
            titleFrame._anTitleText = fs
        end
    end
end

local TEMPLATE_TEX_KEYS = {
    "Left", "Middle", "Right", "Top", "Bottom",
    "MiddleLeft", "MiddleRight", "MiddleMiddle",
    "Icon", "Highlight", "Arrow", "Thumb", "Background", "Center",
}

local function IsArtisanBorderTex(frame, tex)
    if not frame or not tex then
        return false
    end
    return tex == frame.BorderTop or tex == frame.BorderBottom
        or tex == frame.BorderLeft or tex == frame.BorderRight
end

--- Strip Blizzard template textures/atlas (DropDownToggleButton, OptionsSliderTemplate, etc.).
---@param frame Region|nil
---@param skipTex Texture|nil
function StripTemplateTextures(frame, skipTex)
    if not frame then
        return
    end
    for i = 1, #TEMPLATE_TEX_KEYS do
        local tex = frame[TEMPLATE_TEX_KEYS[i]]
        if tex and tex ~= skipTex and not IsArtisanBorderTex(frame, tex) then
            pcall(function()
                if tex.SetAtlas then
                    tex:SetAtlas(nil)
                end
                if tex.SetTexture then
                    tex:SetTexture(nil)
                end
                if tex.Hide then
                    tex:Hide()
                end
            end)
        end
    end
    local getters = { "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }
    for i = 1, #getters do
        local getter = frame[getters[i]]
        if getter then
            local ok, tex = pcall(getter, frame)
            if ok and tex and tex ~= skipTex and not IsArtisanBorderTex(frame, tex) then
                pcall(function()
                    if tex.SetAtlas then
                        tex:SetAtlas(nil)
                    end
                    if tex.SetTexture then
                        tex:SetTexture(nil)
                    end
                    if tex.Hide then
                        tex:Hide()
                    end
                end)
            end
        end
    end
    if frame.GetNumRegions and frame.GetRegions then
        local count = frame:GetNumRegions()
        for ri = 1, count do
            local r = select(ri, frame:GetRegions())
            if r and r ~= skipTex and r.IsObjectType and r:IsObjectType("Texture")
                and not IsArtisanBorderTex(frame, r) then
                pcall(function()
                    if r.SetAtlas then
                        r:SetAtlas(nil)
                    end
                    if r.SetTexture then
                        r:SetTexture(nil)
                    end
                    if r.Hide then
                        r:Hide()
                    end
                end)
            end
        end
    end
end

--- Settings UIDropDownMenu row: Modern applies panel-button chrome to the menu
--- button and theme font on the selected-value label; Classic keeps template art.
---@param dropdown Frame|nil
function ns.UI_StyleSettingsDropDown(dropdown)
    if not dropdown then
        return
    end
    local classic = ns.UI_IsClassicUi and ns.UI_IsClassicUi()
    if not classic then
        StripTemplateTextures(dropdown)
    end
    local btn = dropdown.Button
    if not btn then
        local btnName = dropdown.GetName and dropdown:GetName() and (dropdown:GetName() .. "Button") or nil
        btn = btnName and _G[btnName]
    end
    if btn and not classic then
        StripTemplateTextures(btn)
        if ns.UI_StripClassicBackdropEdge then
            ns.UI_StripClassicBackdropEdge(btn)
        end
    end
    if btn and ns.UI_StyleSettingsPanelButton then
        ns.UI_StyleSettingsPanelButton(btn)
    end
    if btn and not classic then
        if not btn._anDropDownStyledHook and btn.HookScript then
            btn._anDropDownStyledHook = true
            btn:HookScript("OnShow", function()
                if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
                    return
                end
                ns.UI_StyleSettingsDropDown(dropdown)
            end)
        end
        if not dropdown._anDropDownStyledHook and dropdown.HookScript then
            dropdown._anDropDownStyledHook = true
            dropdown:HookScript("OnShow", function()
                if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
                    return
                end
                ns.UI_StyleSettingsDropDown(dropdown)
            end)
        end
    end
    local textName = dropdown.GetName and dropdown:GetName() and (dropdown:GetName() .. "Text") or nil
    local text = (textName and _G[textName]) or (btn and btn.GetFontString and btn:GetFontString())
    if text and text.SetFontObject and not classic then
        text:SetFontObject("GameFontHighlightMedium")
        local tn = (ns.UI_COLORS and ns.UI_COLORS.textNormal) or { 0.88, 0.84, 0.92, 1 }
        text:SetTextColor(tn[1], tn[2], tn[3], tn[4] or 1)
    end
    if btn and not classic then
        btn:SetHeight(28)
        if btn.Icon then
            pcall(function()
                btn.Icon:Hide()
            end)
        end
        if not btn._anDropChevron then
            local chev = btn:CreateTexture(nil, "OVERLAY")
            chev:SetSize(10, 6)
            chev:SetPoint("RIGHT", btn, "RIGHT", -12, 0)
            btn._anDropChevron = chev
        end
        local chev = btn._anDropChevron
        local muted = (ns.UI_COLORS and ns.UI_COLORS.textMuted) or { 0.72, 0.68, 0.78, 1 }
        pcall(function()
            chev:SetTexture("Interface\\Buttons\\UI-ExpandButton-Down")
            chev:SetVertexColor(muted[1], muted[2], muted[3], 0.95)
        end)
        chev:Show()
        if text then
            text:ClearAllPoints()
            text:SetPoint("LEFT", btn, "LEFT", 12, 0)
            text:SetPoint("RIGHT", chev, "LEFT", -6, 0)
            text:SetJustifyH("LEFT")
        end
    end
end

--- Update accent fill width on a Modern settings slider track.
---@param slider Slider|nil
function ns.UI_UpdateSettingsSliderFill(slider)
    if not slider or not slider._anSliderTrack or not slider._anSliderFill then
        return
    end
    local minV, maxV = slider:GetMinMaxValues()
    local val = slider:GetValue()
    if not minV or not maxV or maxV <= minV then
        return
    end
    local pct = (val - minV) / (maxV - minV)
    local trackW = slider._anSliderTrack:GetWidth()
    if not trackW or trackW <= 0 then
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if slider and slider:IsShown() and ns.UI_UpdateSettingsSliderFill then
                    ns.UI_UpdateSettingsSliderFill(slider)
                end
            end)
        end
        return
    end
    local fillW = math.max(4, trackW * pct)
    slider._anSliderFill:ClearAllPoints()
    slider._anSliderFill:SetPoint("TOPLEFT", slider._anSliderTrack, "TOPLEFT", 1, -1)
    slider._anSliderFill:SetPoint("BOTTOMLEFT", slider._anSliderTrack, "BOTTOMLEFT", 1, 1)
    slider._anSliderFill:SetWidth(fillW)
end

local SETTINGS_SLIDER_BLOCK_H = 58
local SETTINGS_SLIDER_TRACK_H = 12

--- Wrap OptionsSliderTemplate in a block: labels on top, short track row at bottom.
---@param slider Slider|nil
---@param width number|nil
function ns.UI_BuildSettingsSliderBlock(slider, width)
    if not slider or (ns.UI_IsClassicUi and ns.UI_IsClassicUi()) then
        return
    end
    width = width or slider:GetWidth() or 420
    local parent = slider:GetParent()
    if not parent then
        return
    end

    if not slider._anSliderBlock then
        local block = CreateFrame("Frame", nil, parent)
        block:SetSize(width, SETTINGS_SLIDER_BLOCK_H)
        local point, rel, relPoint, ax, ay = slider:GetPoint(1)
        if point then
            block:SetPoint(point, rel or parent, relPoint or point, ax or 0, ay or 0)
        end
        slider._anSliderBlock = block

        local function liftToBlock(fs)
            if fs and fs.SetParent then
                fs:SetParent(block)
            end
        end
        liftToBlock(slider.Text)
        liftToBlock(slider.Value)
        liftToBlock(slider.Low)
        liftToBlock(slider.High)

        slider:SetParent(block)
        slider:ClearAllPoints()
        slider:SetPoint("BOTTOMLEFT", block, "BOTTOMLEFT", 0, 18)
        slider:SetPoint("BOTTOMRIGHT", block, "BOTTOMRIGHT", 0, 18)
        slider:SetHeight(SETTINGS_SLIDER_TRACK_H)
    else
        slider._anSliderBlock:SetWidth(width)
    end

    local block = slider._anSliderBlock
    if slider.Text then
        slider.Text:ClearAllPoints()
        slider.Text:SetPoint("TOPLEFT", block, "TOPLEFT", 0, -2)
        slider.Text:SetJustifyH("LEFT")
        slider.Text:SetWidth(math.max(120, width - 80))
    end
    if slider.Value then
        slider.Value:ClearAllPoints()
        slider.Value:SetPoint("TOPRIGHT", block, "TOPRIGHT", 0, -2)
        slider.Value:SetJustifyH("RIGHT")
        slider.Value:SetWidth(72)
    end
    if slider.Low then
        slider.Low:ClearAllPoints()
        slider.Low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -3)
    end
    if slider.High then
        slider.High:ClearAllPoints()
        slider.High:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -3)
    end

    if not slider._anFillHooked and slider.HookScript then
        slider._anFillHooked = true
        slider:HookScript("OnValueChanged", function()
            ns.UI_UpdateSettingsSliderFill(slider)
        end)
    end
    ns.UI_UpdateSettingsSliderFill(slider)
end

--- Legacy hook — track band is owned by UI_BuildSettingsSliderBlock now.
---@param slider Slider|nil
---@param trackH number|nil
function ns.UI_LayoutSettingsSliderTrack(slider, trackH)
    if slider and ns.UI_UpdateSettingsSliderFill then
        ns.UI_UpdateSettingsSliderFill(slider)
    end
end

--- OptionsSliderTemplate rows in FrameXML settings: strip Blizzard track/thumb art and
--- apply Factory-aligned accent thumb + control-chrome track (WN CreateThemedSlider parity).
---@param slider Slider|nil
function ns.UI_StyleSettingsSlider(slider)
    if not slider then
        return
    end
    if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
        return
    end
    if not slider._anSliderStyled then
        slider._anSliderStyled = true
        StripTemplateTextures(slider)
        if slider.HookScript then
            slider:HookScript("OnShow", function()
                if ns.UI_IsClassicUi and ns.UI_IsClassicUi() then
                    return
                end
                if ns.UI_StyleSettingsSlider then
                    ns.UI_StyleSettingsSlider(slider)
                end
            end)
        end
    end
    if ns.UI_BuildSettingsSliderBlock then
        ns.UI_BuildSettingsSliderBlock(slider, slider:GetWidth())
    end
    local legacyThumb = slider.GetThumbTexture and slider:GetThumbTexture()
    if legacyThumb and legacyThumb ~= slider._anModernThumb then
        pcall(function()
            if legacyThumb.SetAtlas then
                legacyThumb:SetAtlas(nil)
            end
            if legacyThumb.SetTexture then
                legacyThumb:SetTexture(nil)
            end
            if legacyThumb.Hide then
                legacyThumb:Hide()
            end
        end)
    end
    if ns.UI_StripClassicBackdropEdge then
        ns.UI_StripClassicBackdropEdge(slider)
    end
    if not slider.SetBackdrop then
        Mixin(slider, BackdropTemplateMixin)
    end
    local COL = ns.UI_COLORS or {}
    local trackBg = (ns.UI_GetControlChromeBackdrop and ns.UI_GetControlChromeBackdrop())
        or COL.tabInactive or { 0.115, 0.108, 0.128, 1 }
    local ac = COL.accent or { 0.52, 0.40, 0.66, 1 }
    if ns.UI_SuppressArtisanChrome then
        ns.UI_SuppressArtisanChrome(slider)
    end
    slider:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false,
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    slider:SetBackdropColor(0, 0, 0, 0)
    slider:SetBackdropBorderColor(0, 0, 0, 0)
    if not slider._anModernThumb then
        slider._anModernThumb = slider:CreateTexture(nil, "OVERLAY")
        slider._anModernThumb:SetSize(16, 16)
    end
    slider._anModernThumb:SetColorTexture(ac[1], ac[2], ac[3], 1)
    slider:SetThumbTexture(slider._anModernThumb)
    if not slider._anSliderTrack then
        slider._anSliderTrack = slider:CreateTexture(nil, "BACKGROUND", nil, 0)
        slider._anSliderTrack:SetPoint("TOPLEFT", slider, "TOPLEFT", 0, 0)
        slider._anSliderTrack:SetPoint("BOTTOMRIGHT", slider, "BOTTOMRIGHT", 0, 0)
    end
    slider._anSliderTrack:SetColorTexture(trackBg[1], trackBg[2], trackBg[3], trackBg[4] or 1)
    slider._anSliderTrack:Show()
    if not slider._anSliderTrackBorder then
        slider._anSliderTrackBorder = slider:CreateTexture(nil, "BORDER", nil, 1)
        slider._anSliderTrackBorder:SetPoint("TOPLEFT", slider._anSliderTrack, "TOPLEFT", 0, 0)
        slider._anSliderTrackBorder:SetPoint("BOTTOMRIGHT", slider._anSliderTrack, "BOTTOMRIGHT", 0, 0)
        slider._anSliderTrackBorder:SetColorTexture(ac[1], ac[2], ac[3], 0.22)
    end
    slider._anSliderTrackBorder:Show()
    if not slider._anSliderFill then
        slider._anSliderFill = slider:CreateTexture(nil, "ARTWORK", nil, 2)
        slider._anSliderFill:SetPoint("TOPLEFT", slider._anSliderTrack, "TOPLEFT", 1, -1)
        slider._anSliderFill:SetPoint("BOTTOMLEFT", slider._anSliderTrack, "BOTTOMLEFT", 1, 1)
        slider._anSliderFill:SetHeight(SETTINGS_SLIDER_TRACK_H - 2)
    end
    slider._anSliderFill:SetColorTexture(ac[1], ac[2], ac[3], 0.55)
    slider._anSliderFill:Show()
    ns.UI_UpdateSettingsSliderFill(slider)
end

ns.UI_SETTINGS_CHECK_ROW_HEIGHT = SETTINGS_CHECK_ROW_HEIGHT

ns.UI_ApplyVisuals = ApplyVisuals
ns.UI_CreateIcon = CreateIcon
ns.UI_ResetPixelScale = ResetPixelScale
ns.UI_UpdateBorderColor = UpdateBorderColor
ns.GetPixelScale = GetPixelScale
