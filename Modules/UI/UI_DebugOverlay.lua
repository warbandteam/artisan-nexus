--[[
    Artisan Nexus — layout debug overlay (`/an debug` / Settings > Debug).
    Tints registered frames; hover shows label, size, strata, anchors.
]]

local ADDON_NAME, ns = ...

local tinsert = table.insert
local tconcat = table.concat

ns.UI_DEBUG_REGISTRY = ns.UI_DEBUG_REGISTRY or {}

local REGISTRY = ns.UI_DEBUG_REGISTRY

local DEFAULT_COLOR = { 1, 0, 1, 0.32 }

local SHELL_DEBUG_COLORS = {
    ["shell.main"] = { 0.35, 0.35, 0.40, 0.18 },
    ["shell.headerBar"] = { 0.12, 0.55, 0.95, 0.42 },
    ["shell.titleWingL"] = { 0.20, 0.75, 0.35, 0.45 },
    ["shell.titleCenter"] = { 0.95, 0.75, 0.15, 0.40 },
    ["shell.titleWingR"] = { 0.20, 0.75, 0.35, 0.45 },
    ["shell.logo"] = { 1.00, 0.85, 0.10, 0.50 },
    ["shell.title"] = { 1.00, 0.55, 0.10, 0.45 },
    ["shell.close"] = { 0.95, 0.20, 0.20, 0.50 },
    ["shell.settings"] = { 0.55, 0.30, 0.90, 0.48 },
    ["shell.utility"] = { 0.30, 0.65, 0.95, 0.45 },
    ["loot.tabBar"] = { 0.85, 0.25, 0.55, 0.40 },
    ["loot.modeBar"] = { 0.75, 0.35, 0.65, 0.38 },
    ["loot.resetRow"] = { 0.55, 0.80, 0.30, 0.35 },
}

function ns.UI_IsLayoutDebugEnabled()
    return ns.UI_IsViewportDebugEnabled and ns.UI_IsViewportDebugEnabled()
end

local function ResolveColor(opts)
    if opts and opts.color then
        return opts.color
    end
    if opts and opts.id and SHELL_DEBUG_COLORS[opts.id] then
        return SHELL_DEBUG_COLORS[opts.id]
    end
    if opts and opts.label and SHELL_DEBUG_COLORS[opts.label] then
        return SHELL_DEBUG_COLORS[opts.label]
    end
    return DEFAULT_COLOR
end

local function FrameDisplayName(frame)
    if not frame then
        return "?"
    end
    if frame._anDebugLabel and frame._anDebugLabel ~= "" then
        return frame._anDebugLabel
    end
    local n = frame.GetName and frame:GetName()
    if n and n ~= "" then
        return n
    end
    return "(anonymous frame)"
end

local function FormatAnchorLines(frame)
    if not frame or not frame.GetNumPoints then
        return ""
    end
    local n = frame:GetNumPoints()
    if not n or n < 1 then
        return "  (no anchors)"
    end
    local lines = {}
    for i = 1, n do
        local point, relTo, relPoint, x, y = frame:GetPoint(i)
        local relLabel = FrameDisplayName(relTo)
        if relTo and relTo._anDebugLabel then
            relLabel = relTo._anDebugLabel
        elseif relTo and relTo.GetName then
            local rn = relTo:GetName()
            if rn and rn ~= "" then
                relLabel = rn
            end
        end
        lines[#lines + 1] = string.format(
            "  [%d] %s -> %s %s  (%.1f, %.1f)",
            i,
            tostring(point or "?"),
            relLabel,
            tostring(relPoint or point or "?"),
            x or 0,
            y or 0
        )
    end
    return tconcat(lines, "\n")
end

local function ShowDebugTooltip(owner, entry)
    if not owner or not entry then
        return
    end
    local target = entry.inspectFrame or entry.frame
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    GameTooltip:SetText(entry.label or FrameDisplayName(target), 1, 0.92, 0.45)
    if entry.note and entry.note ~= "" then
        GameTooltip:AddLine(entry.note, 0.75, 0.82, 0.95, true)
    end
    if target and target.GetWidth then
        local w, h = target:GetWidth(), target:GetHeight()
        GameTooltip:AddLine(string.format("Size: %.0f x %.0f", w or 0, h or 0), 0.85, 0.85, 0.85)
    end
    if target and target.GetFrameStrata then
        GameTooltip:AddLine(string.format(
            "Strata: %s  Level: %d",
            target:GetFrameStrata() or "?",
            target:GetFrameLevel() or 0
        ), 0.72, 0.72, 0.72)
    end
    if target and target.GetName then
        local fn = target:GetName()
        if fn and fn ~= "" then
            GameTooltip:AddLine("Frame name: " .. fn, 0.65, 0.65, 0.65)
        end
    end
    if entry.id and entry.id ~= entry.label then
        GameTooltip:AddLine("Key: " .. entry.id, 0.6, 0.75, 0.9)
    end
    local anchors = FormatAnchorLines(target)
    if anchors ~= "" then
        GameTooltip:AddLine("Anchors:", 0.9, 0.82, 0.2)
        GameTooltip:AddLine(anchors, 0.78, 0.78, 0.78, true)
    end
    GameTooltip:Show()
end

local function EnsureOverlay(entry)
    local frame = entry.frame
    if not frame then
        return nil
    end
    local overlay = entry.overlay
    if not overlay or overlay:GetParent() ~= frame then
        overlay = CreateFrame("Frame", nil, frame)
        overlay:SetAllPoints(frame)
        overlay:SetFrameLevel((frame:GetFrameLevel() or 0) + 40)
        local tint = overlay:CreateTexture(nil, "ARTWORK")
        tint:SetAllPoints()
        entry.overlay = overlay
        entry.tint = tint
        overlay:EnableMouse(true)
        overlay:SetScript("OnEnter", function(self)
            ShowDebugTooltip(self, entry)
        end)
        overlay:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end
    return entry
end

local function ApplyDebugChrome(entry)
    if not entry or not entry.frame then
        return
    end
    local enabled = ns.UI_IsLayoutDebugEnabled()
    if not enabled then
        if entry.overlay and entry.overlay.Hide then
            entry.overlay:Hide()
        end
        if entry.tint and entry.tint.Hide then
            entry.tint:Hide()
        end
        return
    end
    EnsureOverlay(entry)
    local c = ResolveColor(entry)
    if entry.tint then
        entry.tint:SetColorTexture(c[1], c[2], c[3], c[4] or 0.32)
        entry.tint:Show()
    end
    if entry.overlay then
        entry.overlay:Show()
    end
end

local function FindRegistryIndex(frame)
    for i = 1, #REGISTRY do
        if REGISTRY[i].frame == frame then
            return i
        end
    end
    return nil
end

---@param frame Frame|Button|nil
---@param opts table|nil { id, label, color, note, inspectFrame }
function ns.UI_RegisterDebugElement(frame, opts)
    if not frame then
        return
    end
    opts = opts or {}
    local label = opts.label or opts.id or FrameDisplayName(frame)
    frame._anDebugLabel = label
    local entry = {
        frame = frame,
        id = opts.id or label,
        label = label,
        color = opts.color,
        note = opts.note,
        inspectFrame = opts.inspectFrame or frame,
    }
    local idx = FindRegistryIndex(frame)
    if idx then
        REGISTRY[idx] = entry
    else
        tinsert(REGISTRY, entry)
    end
    ApplyDebugChrome(entry)
end

--- Hitbox over a texture/region for debug hover (title strip wings, etc.).
---@param parent Frame
---@param region Region
---@param opts table|nil
function ns.UI_RegisterDebugElementForRegion(parent, region, opts)
    if not parent or not region then
        return
    end
    opts = opts or {}
    local hit = region._anDebugHitbox
    if not hit then
        hit = CreateFrame("Frame", nil, parent)
        region._anDebugHitbox = hit
        hit:SetAllPoints(region)
        hit:SetFrameLevel((parent:GetFrameLevel() or 0) + 35)
    end
    hit:ClearAllPoints()
    hit:SetAllPoints(region)
    opts.inspectFrame = opts.inspectFrame or hit
    opts.note = (opts.note and (opts.note .. "\n")) or ""
    if region.GetWidth and region.GetHeight then
        opts.note = opts.note .. string.format("Region: %.0f x %.0f", region:GetWidth() or 0, region:GetHeight() or 0)
    end
    ns.UI_RegisterDebugElement(hit, opts)
end

--- FontStrings are not mouse targets — proxy hitbox tracks the string bounds.
---@param fontString FontString
---@param opts table|nil
function ns.UI_RegisterDebugElementForFontString(fontString, opts)
    if not fontString or not fontString.GetParent then
        return
    end
    local parent = fontString:GetParent()
    if not parent then
        return
    end
    opts = opts or {}
    local hit = fontString._anDebugHitbox
    if not hit then
        hit = CreateFrame("Frame", nil, parent)
        fontString._anDebugHitbox = hit
    end
    hit:ClearAllPoints()
    hit:SetAllPoints(fontString)
    opts.inspectFrame = fontString
    opts.note = (opts.note and (opts.note .. " | ") or "") .. "FontString"
    ns.UI_RegisterDebugElement(hit, opts)
end

function ns.UI_UnregisterDebugFrame(frame)
    if not frame then
        return
    end
    for i = #REGISTRY, 1, -1 do
        local entry = REGISTRY[i]
        if entry.frame == frame then
            if entry.overlay then
                entry.overlay:Hide()
                entry.overlay:SetParent(nil)
            end
            table.remove(REGISTRY, i)
        end
    end
    frame._anDebugLabel = nil
end

function ns.UI_PurgeDebugRegistry()
    for i = #REGISTRY, 1, -1 do
        local entry = REGISTRY[i]
        local f = entry.frame
        if not f or (f.IsObjectType and not f:IsObjectType("Frame") and not f:IsObjectType("Button")) then
            table.remove(REGISTRY, i)
        elseif not f.GetParent or not f:GetParent() then
            if f ~= UIParent then
                table.remove(REGISTRY, i)
            end
        end
    end
end

function ns.UI_RefreshAllDebugChrome()
    ns.UI_PurgeDebugRegistry()
    for i = 1, #REGISTRY do
        ApplyDebugChrome(REGISTRY[i])
    end
end

--- Classic shell / title strip QA (Loot, Hub, Matcher, Settings headers).
---@param parent Frame
---@param headerBar Frame|nil
function ns.UI_RegisterClassicShellDebug(parent, headerBar)
    if not parent or not ns.UI_RegisterDebugElement then
        return
    end
    ns.UI_RegisterDebugElement(parent, {
        id = "shell.main",
        label = "shell.main",
        note = "Main window root (dialog backdrop)",
    })
    if not headerBar then
        return
    end
    ns.UI_RegisterDebugElement(headerBar, {
        id = "shell.headerBar",
        label = "shell.headerBar",
        note = "Header drag band (full shell.main width, title strip band)",
    })
    if parent._anClassicTitleBgL then
        ns.UI_RegisterDebugElementForRegion(parent, parent._anClassicTitleBgL, {
            id = "shell.titleWingL",
            label = "shell.titleWingL",
            note = "UI-DialogBox-Header left cap",
        })
    end
    if parent._anClassicTitleBgC then
        ns.UI_RegisterDebugElementForRegion(parent, parent._anClassicTitleBgC, {
            id = "shell.titleCenter",
            label = "shell.titleCenter",
            note = "Title strip center (logo + title live here)",
        })
    end
    if parent._anClassicTitleBgR then
        ns.UI_RegisterDebugElementForRegion(parent, parent._anClassicTitleBgR, {
            id = "shell.titleWingR",
            label = "shell.titleWingR",
            note = "UI-DialogBox-Header right cap",
        })
    end
    if headerBar._anShellLogo then
        ns.UI_RegisterDebugElementForRegion(headerBar, headerBar._anShellLogo, {
            id = "shell.logo",
            label = "shell.logo",
            note = "Addon logo texture",
        })
    end
    if headerBar._anShellTitle then
        ns.UI_RegisterDebugElementForFontString(headerBar._anShellTitle, {
            id = "shell.title",
            label = "shell.title",
            note = "Window title text",
        })
    end
    if headerBar._anShellClose then
        ns.UI_RegisterDebugElement(headerBar._anShellClose, {
            id = "shell.close",
            label = "shell.close",
            note = "shell glyph close (addon-drawn)",
        })
    end
    if headerBar._anShellSettings then
        ns.UI_RegisterDebugElement(headerBar._anShellSettings, {
            id = "shell.settings",
            label = "shell.settings",
            note = "Settings gear button",
        })
    end
    local utilities = headerBar._anShellUtilities
    if utilities then
        for i = 1, #utilities do
            local btn = utilities[i]
            if btn then
                ns.UI_RegisterDebugElement(btn, {
                    id = "shell.utility",
                    label = "shell.utility[" .. i .. "]",
                    note = "Header utility button",
                })
            end
        end
    end
    local extras = headerBar._anShellExtraRight
    if extras then
        for i = 1, #extras do
            local btn = extras[i]
            if btn then
                ns.UI_RegisterDebugElement(btn, {
                    id = "shell.utility",
                    label = "shell.extra[" .. i .. "]",
                    note = "Header extra-right button (e.g. overload)",
                })
            end
        end
    end
end
