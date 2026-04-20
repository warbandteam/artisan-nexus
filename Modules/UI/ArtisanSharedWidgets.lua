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

        frame.BorderTop = frame:CreateTexture(nil, "BORDER")
        frame.BorderTop:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderTop:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        frame.BorderTop:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        frame.BorderTop:SetHeight(pixelScale)
        frame.BorderTop:SetSnapToPixelGrid(false)
        frame.BorderTop:SetTexelSnappingBias(0)
        frame.BorderTop:SetDrawLayer("BORDER", 0)

        frame.BorderBottom = frame:CreateTexture(nil, "BORDER")
        frame.BorderBottom:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderBottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        frame.BorderBottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        frame.BorderBottom:SetHeight(pixelScale)
        frame.BorderBottom:SetSnapToPixelGrid(false)
        frame.BorderBottom:SetTexelSnappingBias(0)
        frame.BorderBottom:SetDrawLayer("BORDER", 0)

        frame.BorderLeft = frame:CreateTexture(nil, "BORDER")
        frame.BorderLeft:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderLeft:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        frame.BorderLeft:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        frame.BorderLeft:SetWidth(pixelScale)
        frame.BorderLeft:SetSnapToPixelGrid(false)
        frame.BorderLeft:SetTexelSnappingBias(0)
        frame.BorderLeft:SetDrawLayer("BORDER", 0)

        frame.BorderRight = frame:CreateTexture(nil, "BORDER")
        frame.BorderRight:SetTexture("Interface\\Buttons\\WHITE8x8")
        frame.BorderRight:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        frame.BorderRight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        frame.BorderRight:SetWidth(pixelScale)
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

local function AccentColor()
    local c = ns.UI_COLORS and ns.UI_COLORS.accent
    if c then return c[1], c[2], c[3], 0.6 end
    return 0.44, 0.32, 0.58, 0.6
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
        ApplyVisuals(frame, { 0.05, 0.05, 0.07, 0.95 }, borderColor)
    end

    local tex = frame:CreateTexture(nil, "ARTWORK")
    if noBorder then
        tex:SetAllPoints()
    else
        local inset = GetPixelScale() * 2
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

ns.UI_ApplyVisuals = ApplyVisuals
ns.UI_CreateIcon = CreateIcon
ns.UI_ResetPixelScale = ResetPixelScale
ns.UI_UpdateBorderColor = UpdateBorderColor
