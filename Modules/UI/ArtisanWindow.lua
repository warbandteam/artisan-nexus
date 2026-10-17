--[[
    Artisan Nexus - floating window shell, ns.ArtisanWindow (Warband Nexus floating-window pattern).

    Every Artisan Nexus standalone window (Session Loot, Recipe Matcher, Posting Helper,
    Overload Tracker, ...) is built here exactly the way Warband Nexus builds its floating windows;
    nothing in this file is a widget of its own:

      shell / strata / ESC / combat hide / scale  -> PlansTrackerWindow.lua:2138-2173
      title band (accent band, icon, title)       -> PlansTrackerWindow.lua:2184-2274
      header utility buttons + close button       -> PlansTrackerWindow.lua:152-169, 2276-2313, 2390-2409
      content area below the band                 -> PlansTrackerWindow.lua:2505-2516
      viewport shell + scroll frame + bar column  -> PlansTrackerWindow.lua:484-594, 2522-2588
      resize grip + satellite resize              -> PlansTrackerWindow.lua:2590-2674
      position / size persistence                 -> PlansTrackerWindow.lua:328-349 (RecipeCompanionWindow.lua:139-164)
      theme refresh                               -> PlansTrackerWindow.lua:2807-2844
      themed dropdown + flyout menu               -> PlansTrackerWindow.lua:1867-2110 CreateThemedCategoryDropdown
      destructive confirm (StaticPopup)           -> PlansUI.lua:994-1007

    cfg.hud = true builds a HUD panel (Overload Tracker): same shell and strata, but it is not a
    WindowManager window (no ESC close, no combat hide through the registry); cfg.combatHide hides it
    for the duration of combat instead.

    Tiling (a window opened from another one opens beside it; windows never close each other) is
    Artisan Nexus behaviour (TEXT_FLOW_AUDIT C3) and keeps the pre-transplant placement rules.
]]

local ADDON_NAME, ns = ...
-- Pixel-perfect frames (SharedWidgets_Pixel: SetPoint/SetSize snap to whole physical pixels).
local CreateFrame = function(...) return (ns.UI_CreateFrame or _G.CreateFrame)(...) end

---@param minW number
---@param maxW number
---@param minH number
---@param maxH number
---@return number maxW
---@return number maxH
local function GetFrameBounds(minW, maxW, minH, maxH)
    local p = UIParent
    local outW, outH = maxW, maxH
    if p and p.GetWidth and p.GetHeight then
        local pw = p:GetWidth() or 1200
        local ph = p:GetHeight() or 800
        outW = math.min(maxW, math.max(minW + 80, pw - 24))
        outH = math.min(maxH, math.max(minH + 80, ph - 24))
    end
    return outW, outH
end

local function ApplyResizeBounds(frame, minW, minH, maxW, maxH)
    if not frame then
        return
    end
    local rbW, rbH = GetFrameBounds(minW, maxW, minH, maxH)
    if frame.SetResizeBounds then
        pcall(function()
            frame:SetResizeBounds(minW, minH, rbW, rbH)
        end)
    elseif frame.SetMinResize then
        frame:SetMinResize(minW, minH)
        frame:SetMaxResize(rbW, rbH)
    end
end

-- ─────────────────────────────────────────────────────────────────
-- Floating window shell (ns.ArtisanWindow)
-- ─────────────────────────────────────────────────────────────────

local W = ns.ArtisanWindow or {}
ns.ArtisanWindow = W

local function Factory()
    return ns.UI and ns.UI.Factory
end

local function COLORS()
    return ns.UI_COLORS or { accent = { 0.5, 0.4, 0.7 }, accentDark = { 0.25, 0.2, 0.35 } }
end

local function MainShell()
    return ns.UI_LAYOUT and ns.UI_LAYOUT.MAIN_SHELL or {}
end

-- PlansTrackerWindow.lua:121-133 metrics (header band, icon, utility buttons).
local PADDING = (ns.UI_SPACING and ns.UI_SPACING.TOP_MARGIN) or 10
local HEADER_ICON = 34          -- match main window title icon
local HEADER_BTN = 28           -- match main window close/utility button size
local HEADER_BTN_GAP = 6
local HEADER_ICON_LEFT = 15     -- match main window icon inset
local ROW_BELOW_CHROME = 10
W.PADDING = PADDING
W.HEADER_BTN = HEADER_BTN
W.HEADER_BTN_GAP = HEADER_BTN_GAP
W.ROW_BELOW_CHROME = ROW_BELOW_CHROME

local function HeaderHeight()
    return MainShell().PLANS_TRACKER_HEADER_HEIGHT or 28
end
W.HeaderHeight = HeaderHeight

--- Scrollbar lane: column + gap (aligned with main window SCROLL_INSET_RIGHT).
function W.ScrollBarColumnWidth()
    return (ns.UI_GetScrollbarColumnWidth and ns.UI_GetScrollbarColumnWidth()) or 26
end

function W.ScrollRightReserve()
    return (ns.UI_GetVerticalScrollbarLaneReserve and ns.UI_GetVerticalScrollbarLaneReserve())
        or (W.ScrollBarColumnWidth() + 2)
end

local TRANSPARENT = { 0, 0, 0, 0 }

--- PlansTrackerWindow.lua:35-55 ApplyTrackerViewportTransparent.
function W.ApplyTransparent(frame)
    if not frame then return end
    if ns.UI_IsClassicMode and ns.UI_IsClassicMode() then
        if ns.UI_ApplyClassicTransparentInterior then
            ns.UI_ApplyClassicTransparentInterior(frame)
        end
        return
    end
    if ns.UI_ApplyBorderlessSurface then
        ns.UI_ApplyBorderlessSurface(frame, TRANSPARENT, { bgType = "searchChrome" })
    elseif ns.UI_ApplyVisuals then
        ns.UI_ApplyVisuals(frame, TRANSPARENT, TRANSPARENT)
        if ns.UI_HideFrameBorderQuartet then
            ns.UI_HideFrameBorderQuartet(frame)
        end
        frame._bgType = "searchChrome"
    end
    if frame._wnViewportAtlasUnderlay and frame._wnViewportAtlasUnderlay.Hide then
        frame._wnViewportAtlasUnderlay:Hide()
    end
end

--- PlansTrackerWindow.lua:63-84 ApplyTrackerChrome.
---@param tier string|nil "card" | "row" | "icon" | "popup" | "bar" (classic routing only)
function W.ApplyChrome(frame, bg, border, tier)
    if not frame then return end
    if ns.UI_CanApplyCustomChrome and not ns.UI_CanApplyCustomChrome(frame) then return end
    if ns.UI_IsClassicMode and ns.UI_IsClassicMode() then
        if (tier == "card" or tier == "row") and ns.UI_ApplyClassicCardPanelChrome then
            ns.UI_ApplyClassicCardPanelChrome(frame)
        elseif tier == "icon" and ns.UI_ApplyClassicIconWellChrome then
            ns.UI_ApplyClassicIconWellChrome(frame, bg)
        elseif tier == "popup" and ns.UI_ApplyClassicCardPanelChrome then
            ns.UI_ApplyClassicCardPanelChrome(frame)
        elseif ns.UI_ApplyClassicTransparentInterior then
            ns.UI_ApplyClassicTransparentInterior(frame)
        end
        return
    end
    if not ns.UI_ApplyVisuals then return end
    if not bg and not border then
        W.ApplyTransparent(frame)
        return
    end
    ns.UI_ApplyVisuals(frame, bg, border)
end

--- PlansTrackerWindow.lua:228-242 GetCardColors.
function W.GetCardColors()
    local c = COLORS()
    local bg = c.bgCard or c.bgLight or c.bg or { 0.118, 0.118, 0.145, 0.98 }
    local hoverBg = c.surfaceRowEven or c.bgLight or bg
    local borderAlpha = (ns.UI_IsLightMode and ns.UI_IsLightMode()) and 0.48 or 0.55
    return {
        border = { c.accent[1] * 0.55, c.accent[2] * 0.55, c.accent[3] * 0.55, borderAlpha },
        bg = { bg[1], bg[2], bg[3], bg[4] or 0.98 },
        hoverBorder = { c.accent[1], c.accent[2], c.accent[3], 0.88 },
        hoverBg = { hoverBg[1], hoverBg[2], hoverBg[3], hoverBg[4] or 1 },
    }
end

local function ChromeButtonBackdrop()
    return (ns.UI_GetCloseButtonBackdrop and ns.UI_GetCloseButtonBackdrop()) or { 0.15, 0.15, 0.15, 0.8 }
end

--- PlansTrackerWindow.lua:255-257: border the main window puts on its header utility buttons.
local function UtilityButtonBorder()
    local ac = COLORS().accent
    return { ac[1], ac[2], ac[3], 0.8 }
end

local function CanApplyHeaderButtonChrome(btn)
    return btn and (not ns.UI_CanApplyCustomChrome or ns.UI_CanApplyCustomChrome(btn))
end

--- PlansTrackerWindow.lua:261-269.
local function ApplyUtilityIconStyle(tex, isHover)
    if not tex then return end
    if ns.UI_ApplyHeaderUtilityIconStyle then
        ns.UI_ApplyHeaderUtilityIconStyle(tex, isHover)
    elseif tex.SetVertexColor then
        local c = isHover and COLORS().textBright or COLORS().textNormal
        if c then tex:SetVertexColor(c[1], c[2], c[3]) end
    end
end

--- PlansTrackerWindow.lua:158-169 CreateTrackerHeaderIconButton.
local function CreateHeaderIconButton(parent, size)
    size = size or HEADER_BTN
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(size, size)
    btn:EnableMouse(true)
    if ns.UI_ShouldUseBlizzardChrome and ns.UI_ShouldUseBlizzardChrome()
        and ns.UI_ApplyClassicIconWellChrome then
        ns.UI_ApplyClassicIconWellChrome(btn)
    end
    return btn
end

--- PlansTrackerWindow.lua:2212-2238: theme-accent title band.
local function ApplyHeaderBandChrome(header)
    if ns.UI_IsClassicMode and ns.UI_IsClassicMode() and ns.UI_ApplyFloatingWindowHeaderChrome then
        ns.UI_ApplyFloatingWindowHeaderChrome(header)
        return
    end
    local C = COLORS()
    local hdrBorder = (ns.UI_GetMainHeaderBorderColor and ns.UI_GetMainHeaderBorderColor())
        or { C.accent[1], C.accent[2], C.accent[3], 0.8 }
    local hdrBg
    if ns.UI_IsLightMode and ns.UI_IsLightMode() then
        hdrBg = (ns.UI_GetNavRailActiveBackdrop and ns.UI_GetNavRailActiveBackdrop())
            or (ns.UI_GetMainHeaderChromeColor and ns.UI_GetMainHeaderChromeColor())
    else
        local ad = C.accentDark or { 0.28, 0.14, 0.41, 1 }
        local ac = C.accent or { 0.40, 0.20, 0.58, 1 }
        local t = MainShell().PLANS_TRACKER_HEADER_ACCENT_BLEND or 0.30
        hdrBg = ns.UI_BlendColors
            and ns.UI_BlendColors({ ad[1], ad[2], ad[3], 1 }, { ac[1], ac[2], ac[3], 1 }, t)
            or { ad[1], ad[2], ad[3], 1 }
    end
    if hdrBg then
        W.ApplyChrome(header, hdrBg, hdrBorder)
    elseif ns.UI_ApplyFloatingWindowHeaderChrome then
        ns.UI_ApplyFloatingWindowHeaderChrome(header)
    end
end

--- Header icon: addon logo (main-window title icon) unless the window passes its own texture.
local function ApplyHeaderIcon(tex, icon)
    if icon then
        tex:SetTexture(icon)
        tex:SetTexCoord(0.06, 0.94, 0.06, 0.94)
        return
    end
    if ns.UI_ApplyMainWindowTitleIcon then
        ns.UI_ApplyMainWindowTitleIcon(tex)
    else
        tex:SetTexture(ns.WARBAND_ADDON_MEDIA_ICON or "Interface\\AddOns\\ArtisanNexus\\Media\\anlogo")
        tex:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    end
end

-- ── Position / size persistence (profile[dbKey] = { point, relativePoint, x, y, width, height }) ──

local function PosDB(frame)
    local key = frame and frame._anPosKey
    local p = ns.db and ns.db.profile
    if not key or not p then return nil end
    if type(p[key]) ~= "table" then
        p[key] = {}
    end
    return p[key]
end

--- PlansTrackerWindow.lua:328-341 SavePosition.
function W.SavePosition(frame)
    if not frame or not frame:IsShown() then return end
    local db = PosDB(frame)
    if not db then return end
    if frame:GetNumPoints() < 1 then return end
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    db.point = point
    db.relativePoint = relativePoint
    db.relativeTo = nil
    db.x = x
    db.y = y
    if frame:IsResizable() then
        db.width = frame:GetWidth()
        db.height = frame:GetHeight()
    end
end

--- RecipeCompanionWindow.lua:153-164 RestorePosition (size clamped to the resize bounds).
---@return boolean restored true when a saved anchor was applied
function W.RestorePosition(frame)
    local db = PosDB(frame)
    if not db then return false end
    local cfg = frame._anWindowCfg or {}
    if frame:IsResizable() then
        local w = tonumber(db.width) or cfg.width or frame:GetWidth()
        local h = tonumber(db.height) or cfg.height or frame:GetHeight()
        if cfg.minW and w < cfg.minW then w = cfg.width or cfg.minW end
        if cfg.minH and h < cfg.minH then h = cfg.height or cfg.minH end
        if cfg.maxW and w > cfg.maxW then w = cfg.maxW end
        if cfg.maxH and h > cfg.maxH then h = cfg.maxH end
        frame:SetSize(w, h)
    end
    if not db.point or db.x == nil or db.y == nil then
        return false
    end
    frame:ClearAllPoints()
    frame:SetPoint(db.point, UIParent, db.relativePoint or db.point, tonumber(db.x) or 0, tonumber(db.y) or 0)
    return true
end

-- ── Tiling (pre-transplant placement rules) ──

--- Full-size windows that tile against each other.
local TILE_WINDOWS = { "ArtisanNexusFrame", "ArtisanNexusRecipeMatcher", "ArtisanNexusLootHistoryFrame" }

local function FramesOverlap(a, b)
    if not a or not b then return false end
    local al, ab, aw, ah = a:GetRect()
    local bl, bb, bw, bh = b:GetRect()
    if not al or not bl or not aw or not bw then return false end
    local ar, at = al + aw, ab + ah
    local br, bt = bl + bw, bb + bh
    return not (ar <= bl or br <= al or at <= bb or bt <= ab)
end

--- Place `frame` beside `anchor` (right, else left) when it fits on screen without overlap.
--- Absolute UIParent anchor: windows tile each other both ways, a relative anchor would cycle.
---@return boolean placed
function W.TileBeside(frame, anchor, gap)
    if not frame or not anchor then return false end
    local as = anchor:GetEffectiveScale()
    local aLeft, aRight, aTop = anchor:GetLeft(), anchor:GetRight(), anchor:GetTop()
    if not (aLeft and aRight and aTop) then return false end
    aLeft, aRight, aTop = aLeft * as, aRight * as, aTop * as
    local fs = frame:GetEffectiveScale()
    local fw = (frame:GetWidth() or 0) * fs
    gap = (gap or 12) * fs
    local edgePad = 8 * fs
    local sw = ((GetScreenWidth and GetScreenWidth()) or (UIParent and UIParent:GetWidth()) or 1920)
        * (UIParent and UIParent:GetEffectiveScale() or 1)
    local function placeAt(left)
        if left < edgePad or left + fw > sw - edgePad then
            return false
        end
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left / fs, aTop / fs)
        return not FramesOverlap(frame, anchor)
    end
    return placeAt(aRight + gap) or placeAt(aLeft - gap - fw)
end

local function PlaceHome(frame)
    if not W.RestorePosition(frame) then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

--- Show a floating window without closing any other window.
--- `opts.tileAfter` = the window it was opened from: tile beside it when there is room. With no
--- opener the main window counts as the opener when it is open (Hub launchers). Otherwise the saved
--- / centered anchor, moved beside an open sibling it would cover. Opens raised on top.
---@param frame Frame
---@param opts table|nil { tileAfter = Frame }
function W.Present(frame, opts)
    if not frame then return end
    local tileAfter = opts and opts.tileAfter
    if tileAfter == nil then
        local mf = _G.ArtisanNexusFrame
        if mf and mf ~= frame and mf:IsShown() then
            tileAfter = mf
        end
    end
    if not frame._anRestored then
        frame._anRestored = true
        PlaceHome(frame)
    end
    local placed = tileAfter and tileAfter ~= frame and tileAfter.IsShown and tileAfter:IsShown()
        and W.TileBeside(frame, tileAfter)
    if not placed and frame._anTileSibling then
        for i = 1, #TILE_WINDOWS do
            local other = _G[TILE_WINDOWS[i]]
            if other and other ~= frame and other:IsShown() and FramesOverlap(frame, other) then
                if not W.TileBeside(frame, other) then
                    PlaceHome(frame)
                end
                break
            end
        end
    end
    frame:Show()
    if frame.Raise then frame:Raise() end
end

--- Open the Hub (WN main window) from a floating window, tiled beside it when the Hub was closed.
--- WN ShowMainWindow takes no placement options, so the tiling happens here after it opened.
---@param caller Frame|nil the window the Hub was opened from
---@param tabKey string|nil Hub tab to show
function W.ShowHubBeside(caller, tabKey)
    local addon = ns.ArtisanNexus
    if not (addon and addon.ShowMainWindow) then return end
    local mf = _G.ArtisanNexusFrame
    local wasShown = mf and mf:IsShown()
    addon:ShowMainWindow(tabKey)
    mf = _G.ArtisanNexusFrame
    if not wasShown and mf and mf:IsShown() and caller and caller ~= mf and caller:IsShown() then
        W.TileBeside(mf, caller)
    end
end

-- ── Header utility button (PlansTracker gear / collapse button) ──

--- Header utility button left of the close button (or of the previous utility button).
---@param frame Frame window from W.Create
---@param spec table { icon = IconRegistry key, texture = file path, tooltip, desc, onClick }
function W.AddHeaderButton(frame, spec)
    local header = frame._anHeader
    local btn = CreateHeaderIconButton(header, HEADER_BTN)
    local prev = frame._anHeaderRightmost or frame._anCloseBtn
    btn:SetPoint("RIGHT", prev, "LEFT", -HEADER_BTN_GAP, 0)
    btn:SetFrameLevel(header:GetFrameLevel() + 5)
    local chromeBorder = UtilityButtonBorder()
    if CanApplyHeaderButtonChrome(btn) and ns.UI_ApplyVisuals then
        ns.UI_ApplyVisuals(btn, ChromeButtonBackdrop(), chromeBorder)
    end
    local tex = btn:CreateTexture(nil, "ARTWORK")
    tex:SetSize(16, 16)
    tex:SetPoint("CENTER")
    local monochrome = false
    if spec.icon and ns.UI_SetIcon and ns.UI_SetIcon(tex, spec.icon) then
        monochrome = true
    elseif spec.texture then
        tex:SetTexture(spec.texture)
        tex:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    end
    if monochrome then
        ApplyUtilityIconStyle(tex, false)
    end
    btn._anIcon = tex
    btn._anMonochrome = monochrome
    btn:SetScript("OnEnter", function(self)
        if self._anMonochrome then ApplyUtilityIconStyle(tex, true) end
        if CanApplyHeaderButtonChrome(self) and ns.UI_ApplyVisuals then
            local hoverBg = (ns.UI_GetControlChromeHoverBackdrop and ns.UI_GetControlChromeHoverBackdrop()) or ChromeButtonBackdrop()
            ns.UI_ApplyVisuals(self, hoverBg, UtilityButtonBorder())
        end
        local title = type(spec.tooltip) == "function" and spec.tooltip() or spec.tooltip
        if title and title ~= "" then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(title, 1, 1, 1)
            local desc = type(spec.desc) == "function" and spec.desc() or spec.desc
            if desc and desc ~= "" then
                GameTooltip:AddLine(desc, 0.85, 0.85, 0.85, true)
            end
            GameTooltip:Show()
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if self._anMonochrome then ApplyUtilityIconStyle(tex, false) end
        if CanApplyHeaderButtonChrome(self) and ns.UI_ApplyVisuals then
            ns.UI_ApplyVisuals(self, ChromeButtonBackdrop(), UtilityButtonBorder())
        end
        GameTooltip:Hide()
    end)
    if spec.onClick then
        btn:SetScript("OnClick", spec.onClick)
    end
    frame._anHeaderButtons[#frame._anHeaderButtons + 1] = btn
    frame._anHeaderRightmost = btn
    if frame._anTitleText then
        frame._anTitleText:SetPoint("RIGHT", btn, "LEFT", -10, 0)
    end
    return btn
end

--- Re-chain the header utility buttons (after one is shown / hidden).
function W.LayoutHeaderButtons(frame)
    local prev = frame._anCloseBtn
    for i = 1, #frame._anHeaderButtons do
        local btn = frame._anHeaderButtons[i]
        if btn:IsShown() then
            btn:ClearAllPoints()
            btn:SetPoint("RIGHT", prev, "LEFT", -HEADER_BTN_GAP, 0)
            prev = btn
        end
    end
    frame._anTitleText:SetPoint("RIGHT", prev, "LEFT", -10, 0)
end

-- ── Window ──

---@class ArtisanWindowConfig
---@field name string global frame name
---@field title string
---@field icon string|nil header icon texture (nil = addon logo)
---@field posKey string|nil profile key for position / size
---@field width number
---@field height number
---@field minW number|nil
---@field minH number|nil
---@field maxW number|nil
---@field maxH number|nil
---@field resizable boolean|nil default true
---@field showClose boolean|nil default true
---@field tileSiblings boolean|nil move beside an open full-size window it would cover
---@field onClose function|nil runs before the window hides (close button / ESC)
---@field onLive function|nil live resize reflow (frame)
---@field onCommit function|nil resize released / satellite commit (frame)
---@field hud boolean|nil HUD panel: FLOATING strata, not registered with WindowManager (no ESC close)
---@field combatHide boolean|nil HUD only: hide while in combat; after combat onCombatEnd(frame), else re-show
---@field onCombatEnd function|nil HUD only: decides visibility when combat ends (frame)

--- Build a floating window (PlansTrackerWindow:CreatePlansTrackerWindow shell).
---@param cfg ArtisanWindowConfig
---@return Frame|nil frame (.contentArea = body below the title band)
function W.Create(cfg)
    local F = Factory()
    if not F or not F.CreateContainer then return nil end
    local w, h = cfg.width or 380, cfg.height or 420
    local frame = F:CreateContainer(UIParent, w, h, false, cfg.name)
    if not frame then return nil end
    frame._anWindowCfg = cfg
    frame._anPosKey = cfg.posKey
    frame._anTileSibling = cfg.tileSiblings and true or false
    frame._anHeaderButtons = {}
    frame:Hide()
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    local resizable = cfg.resizable ~= false
    frame:SetResizable(resizable)
    if resizable then
        ApplyResizeBounds(frame, cfg.minW or 300, cfg.minH or 240, cfg.maxW or 1200, cfg.maxH or 1000)
    end
    frame:SetClampedToScreen(true)

    local function CloseWindow()
        if cfg.onClose then
            cfg.onClose(frame)
        end
        frame:Hide()
    end
    frame.Close = CloseWindow

    -- WindowManager: standardized strata/level + ESC + combat hide (a HUD keeps only the strata)
    if ns.WindowManager then
        ns.WindowManager:ApplyStrata(frame, ns.WindowManager.PRIORITY.FLOATING)
        if not cfg.hud then
            ns.WindowManager:Register(frame, ns.WindowManager.PRIORITY.FLOATING, CloseWindow)
            ns.WindowManager:InstallESCHandler(frame)
        end
    else
        frame:SetFrameStrata("HIGH")
        frame:SetFrameLevel(120)
    end

    -- HUD combat hide (WindowManager's PLAYER_REGEN rule for registered windows; a HUD is not one).
    if cfg.hud and cfg.combatHide then
        local combat = _G.CreateFrame("Frame")
        combat:RegisterEvent("PLAYER_REGEN_DISABLED")
        combat:RegisterEvent("PLAYER_REGEN_ENABLED")
        combat:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_REGEN_DISABLED" then
                frame._anCombatHidden = frame:IsShown()
                frame:Hide()
            else
                local wasShown = frame._anCombatHidden
                frame._anCombatHidden = nil
                if cfg.onCombatEnd then
                    cfg.onCombatEnd(frame)
                elseif wasShown then
                    frame:Show()
                end
            end
        end)
    end

    if ns.UI_ApplyFloatingWindowShellChrome then
        ns.UI_ApplyFloatingWindowShellChrome(frame)
    elseif ns.UI_ApplyStandardCardElevatedChrome then
        ns.UI_ApplyStandardCardElevatedChrome(frame)
    end

    if ns.UI_RegisterScaledFrame then
        ns.UI_RegisterScaledFrame(frame)
    elseif ns.UI_ApplyAddonUIScale then
        ns.UI_ApplyAddonUIScale(frame)
    end

    -- Header: full-width title band like the main window.
    local bandH = HeaderHeight()
    local header = F:CreateContainer(frame, math.max(1, w), bandH, false)
    header:SetHeight(bandH)
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    header:EnableMouse(true)
    frame._anHeader = header
    frame._anHeaderH = bandH
    local function OnDragStop()
        W.SavePosition(frame)
        if cfg.onDragStop then cfg.onDragStop(frame) end
    end
    if ns.WindowManager and ns.WindowManager.InstallDragHandler then
        ns.WindowManager:InstallDragHandler(header, frame, OnDragStop)
    else
        header:RegisterForDrag("LeftButton")
        header:SetScript("OnDragStart", function()
            if not InCombatLockdown() then
                frame:StartMoving()
            end
        end)
        header:SetScript("OnDragStop", function()
            frame:StopMovingOrSizing()
            OnDragStop()
        end)
    end
    ApplyHeaderBandChrome(header)
    header:SetFrameLevel(frame:GetFrameLevel() + 10)

    local headerUtilityRight = MainShell().HEADER_UTILITY_CLUSTER_RIGHT_INSET or 18

    local iconHolder = CreateFrame("Frame", nil, header)
    iconHolder:SetSize(HEADER_ICON, HEADER_ICON)
    iconHolder:SetPoint("LEFT", header, "LEFT", HEADER_ICON_LEFT, 0)
    iconHolder:SetFrameLevel(header:GetFrameLevel() + 8)
    local hIcon = iconHolder:CreateTexture(nil, "OVERLAY", nil, 1)
    hIcon:SetAllPoints(iconHolder)
    ApplyHeaderIcon(hIcon, cfg.icon)

    local FontManager = ns.FontManager
    local titleText = FontManager:CreateFontString(header, FontManager:GetFontRole("windowChromeTitle"), "OVERLAY")
    titleText:SetPoint("LEFT", iconHolder, "RIGHT", 8, 0)
    titleText:SetJustifyH("LEFT")
    titleText:SetWordWrap(false)
    titleText:SetMaxLines(1)
    titleText:SetText(cfg.title or "")
    ns.UI_SetTextColorRole(titleText, "Bright")
    frame._anTitleText = titleText

    -- Close button (PlansTrackerWindow.lua:2282-2313).
    local closeR, closeG, closeB = 0.9, 0.3, 0.3
    if ns.UI_GetSemanticRedColor then closeR, closeG, closeB = ns.UI_GetSemanticRedColor() end
    local closeBtn = CreateHeaderIconButton(header, HEADER_BTN)
    closeBtn:SetPoint("RIGHT", header, "RIGHT", -headerUtilityRight, 0)
    if CanApplyHeaderButtonChrome(closeBtn) and ns.UI_ApplyVisuals then
        ns.UI_ApplyVisuals(closeBtn, ChromeButtonBackdrop(), UtilityButtonBorder())
    end
    local closeTex = closeBtn:CreateTexture(nil, "ARTWORK")
    closeTex:SetSize(16, 16)
    closeTex:SetPoint("CENTER")
    ns.UI_SetIcon(closeTex, "close")
    closeTex:SetVertexColor(closeR, closeG, closeB)
    closeBtn._wnCloseTex = closeTex
    closeBtn:SetScript("OnEnter", function()
        closeTex:SetVertexColor(1, 0.2, 0.2)
        if CanApplyHeaderButtonChrome(closeBtn) and ns.UI_ApplyVisuals and ns.UI_GetSemanticNegativeCard then
            local bg, border = ns.UI_GetSemanticNegativeCard(true)
            ns.UI_ApplyVisuals(closeBtn, bg, border)
        end
    end)
    closeBtn:SetScript("OnLeave", function()
        closeTex:SetVertexColor(closeR, closeG, closeB)
        if CanApplyHeaderButtonChrome(closeBtn) and ns.UI_ApplyVisuals then
            ns.UI_ApplyVisuals(closeBtn, ChromeButtonBackdrop(), UtilityButtonBorder())
        end
    end)
    closeBtn:SetScript("OnClick", CloseWindow)
    closeBtn:SetFrameLevel(header:GetFrameLevel() + 5)
    frame._anCloseBtn = closeBtn
    if cfg.showClose == false then
        closeBtn:Hide()
        closeBtn:SetWidth(1)
    end
    titleText:SetPoint("RIGHT", closeBtn, "LEFT", -10, 0)

    -- Content area: region below the title band (PlansTrackerWindow.lua:2505-2516).
    local shellInset = PADDING
    local contentArea = F:CreateContainer(frame, math.max(1, w), math.max(1, h - bandH - shellInset), false)
    contentArea:SetPoint("TOPLEFT", frame, "TOPLEFT", shellInset, -(bandH + ROW_BELOW_CHROME))
    contentArea:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -shellInset, shellInset)
    W.ApplyTransparent(contentArea)
    frame.contentArea = contentArea

    if resizable then
        -- Resize grip: window shell corner (PlansTrackerWindow.lua:2590-2658).
        local resizer = (F.CreateButton and F:CreateButton(frame, 18, 18, true)) or CreateFrame("Button", nil, frame)
        resizer:SetSize(18, 18)
        resizer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -math.max(shellInset - 2, 4), math.max(shellInset - 2, 4))
        resizer:SetFrameStrata(frame:GetFrameStrata())
        resizer:SetFrameLevel(frame:GetFrameLevel() + 40)
        resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
        resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
        resizer:SetScript("OnMouseDown", function()
            if not InCombatLockdown() and frame:IsResizable() then
                frame:StartSizing("BOTTOMRIGHT")
            end
        end)
        resizer:SetScript("OnMouseUp", function()
            frame:StopMovingOrSizing()
            W.SavePosition(frame)
            local LC = ns.UI_LayoutCoordinator
            if LC and LC.OnSatelliteMetricsChanged then
                LC:OnSatelliteMetricsChanged(frame, frame:GetWidth(), frame:GetHeight(), true)
            elseif cfg.onCommit then
                cfg.onCommit(frame)
            end
        end)
        frame.resizeGrip = resizer

        local LC = ns.UI_LayoutCoordinator
        if LC and LC.RegisterSatelliteFrame then
            LC:RegisterSatelliteFrame(frame, {
                onLive = function(fr)
                    header:SetWidth(math.max(1, fr:GetWidth()))
                    if cfg.onLive then cfg.onLive(fr) end
                end,
                onCommit = function(fr)
                    if cfg.onCommit then cfg.onCommit(fr) end
                end,
            })
        else
            frame:SetScript("OnSizeChanged", function(fr)
                header:SetWidth(math.max(1, fr:GetWidth()))
                if cfg.onLive then cfg.onLive(fr) end
            end)
        end
    end

    frame:HookScript("OnHide", function()
        W.SavePosition(frame)
    end)

    return frame
end

--- Re-apply theme-dependent chrome on a live window (PlansTrackerWindow.lua:2807-2841).
function W.RefreshChrome(frame)
    if not frame then return end
    if ns.UI_ApplyFloatingWindowShellChrome then
        ns.UI_ApplyFloatingWindowShellChrome(frame)
    elseif ns.UI_ApplyStandardCardElevatedChrome then
        ns.UI_ApplyStandardCardElevatedChrome(frame)
    end
    if frame._anHeader then
        ApplyHeaderBandChrome(frame._anHeader)
    end
    if frame.contentArea then
        W.ApplyTransparent(frame.contentArea)
    end
    local chromeBorder = UtilityButtonBorder()
    local close = frame._anCloseBtn
    if close and CanApplyHeaderButtonChrome(close) and ns.UI_ApplyVisuals then
        ns.UI_ApplyVisuals(close, ChromeButtonBackdrop(), chromeBorder)
    end
    if close and close._wnCloseTex then
        local r, g, b = 0.9, 0.3, 0.3
        if ns.UI_GetSemanticRedColor then r, g, b = ns.UI_GetSemanticRedColor() end
        close._wnCloseTex:SetVertexColor(r, g, b)
    end
    for i = 1, #(frame._anHeaderButtons or {}) do
        local btn = frame._anHeaderButtons[i]
        if CanApplyHeaderButtonChrome(btn) and ns.UI_ApplyVisuals then
            ns.UI_ApplyVisuals(btn, ChromeButtonBackdrop(), chromeBorder)
        end
        if btn._anMonochrome then
            ApplyUtilityIconStyle(btn._anIcon, false)
        end
    end
    if frame._anTitleText then
        ns.UI_SetTextColorRole(frame._anTitleText, "Bright")
    end
    for i = 1, #(frame._anViewports or {}) do
        local vp = frame._anViewports[i]
        W.ApplyViewportShellChrome(vp.shell)
        W.SyncScroll(vp)
    end
end

-- ── Viewport shell + scroll body (PlansTrackerWindow.lua:484-594, 2522-2588) ──

--- Fixed viewport frame: static panel-tone fill + card-tone border stroke; content scrolls inside.
function W.ApplyViewportShellChrome(shell)
    if not shell then return end
    if ns.IsDebugModeEnabled and ns.IsDebugModeEnabled() then
        local c = COLORS()
        local vp = c.surfaceViewport or c.bgCard or c.bg
        if ns.UI_IsClassicMode and ns.UI_IsClassicMode() then
            W.ApplyChrome(shell, vp, nil, "row")
        else
            W.ApplyChrome(shell, vp, W.GetCardColors().border)
        end
        shell:EnableMouse(false)
        return
    end
    if ns.UI_IsClassicMode and ns.UI_IsClassicMode() then
        if ns.UI_ApplyClassicCardPanelChrome then
            ns.UI_ApplyClassicCardPanelChrome(shell)
        elseif ns.UI_ApplyClassicTransparentInterior then
            ns.UI_ApplyClassicTransparentInterior(shell)
        end
        shell:EnableMouse(false)
        return
    end
    local vc = COLORS()
    local vpBg = (ns.UI_GetMainPanelBackgroundColor and ns.UI_GetMainPanelBackgroundColor())
        or (vc and (vc.surfaceViewport or vc.bg)) or { 0.042, 0.042, 0.055, 0.98 }
    W.ApplyChrome(shell, vpBg, W.GetCardColors().border)
    shell:EnableMouse(false)
end

local function ViewportInnerInset()
    if ns.UI_IsClassicMode and ns.UI_IsClassicMode() then
        local bd = ns.UI_CLASSIC_CARD_BACKDROP
        if bd and bd.insets and bd.insets.left then
            return bd.insets.left
        end
        return 8
    end
    return MainShell().PLANS_TRACKER_VIEWPORT_INNER_INSET or 5
end
W.ViewportInnerInset = ViewportInnerInset

--- Scroll viewport inside `parent`: viewport shell (card chrome) -> scroll frame + bar column ->
--- scroll child. The caller anchors `vp.shell`. Returns the viewport record
--- { shell, scrollFrame, scrollChild, barColumn }; W.SyncScroll(vp) after content changes.
---@param window Frame window from W.Create (theme refresh re-skins the viewport)
---@param parent Frame
---@param opts table|nil { noShellChrome = true } transparent shell (no card frame)
function W.CreateScrollViewport(window, parent, opts)
    local F = Factory()
    opts = opts or {}
    local shell = F:CreateContainer(parent, 1, 1, false)
    if opts.noShellChrome then
        W.ApplyTransparent(shell)
    else
        W.ApplyViewportShellChrome(shell)
    end
    local inset = opts.noShellChrome and 0 or ViewportInnerInset()
    local sbW = W.ScrollBarColumnWidth()
    local scrollFrame = F:CreateScrollFrame(shell, "UIPanelScrollFrameTemplate", true)
    scrollFrame:SetPoint("TOPLEFT", shell, "TOPLEFT", inset, -inset)
    scrollFrame:SetPoint("TOPRIGHT", shell, "TOPRIGHT", -(inset + W.ScrollRightReserve()), -inset)
    scrollFrame:SetPoint("BOTTOMLEFT", shell, "BOTTOMLEFT", inset, inset)
    scrollFrame:EnableMouseWheel(true)
    local barColumn = (F.CreateBareScrollBarColumn and F:CreateBareScrollBarColumn(shell, sbW))
        or F:CreateScrollBarColumn(shell, sbW, 0, 0)
    if F.EnsureScrollBarColumnSync then
        F:EnsureScrollBarColumnSync(scrollFrame, barColumn, { width = sbW, gap = 2 })
    elseif F.SyncScrollBarColumnToViewport then
        F:SyncScrollBarColumnToViewport(scrollFrame, barColumn, { width = sbW, gap = 2 })
    elseif scrollFrame.ScrollBar and F.PositionScrollBarInContainer then
        F:PositionScrollBarInContainer(scrollFrame.ScrollBar, barColumn, 0)
    end
    local scrollChild = F:CreateContainer(scrollFrame, 1, 1, false)
    scrollFrame:SetScrollChild(scrollChild)
    if ns.UI_EnableStandardScrollWheel then
        ns.UI_EnableStandardScrollWheel(scrollFrame)
    else
        scrollFrame:SetScript("OnMouseWheel", function(self, delta)
            if ns.UI_ScrollFrameByMouseWheel then
                ns.UI_ScrollFrameByMouseWheel(self, delta)
            end
        end)
    end
    if ns.UI_WireScrollChildMouseWheel then
        ns.UI_WireScrollChildMouseWheel(scrollFrame, scrollChild)
    end
    W.ApplyTransparent(scrollChild)
    local vp = { shell = shell, scrollFrame = scrollFrame, scrollChild = scrollChild, barColumn = barColumn,
        noShellChrome = opts.noShellChrome }
    if window then
        window._anViewports = window._anViewports or {}
        window._anViewports[#window._anViewports + 1] = vp
    end
    return vp
end

--- Scroll-child width = viewport width (call on resize and before painting rows).
function W.SyncScrollChildWidth(vp)
    local sf = vp and vp.scrollFrame
    if not sf then return 0 end
    local sw = sf:GetWidth() or 0
    if sw > 0 then
        vp.scrollChild:SetWidth(sw)
    end
    return sw
end

--- PlansTrackerWindow.lua:556-594 SyncTrackerScrollBar.
function W.SyncScroll(vp)
    local sf = vp and vp.scrollFrame
    if not sf then return end
    local F = Factory()
    local barCol = vp.barColumn
    local syncOpts = sf._wnBarColumnSyncOpts or { width = W.ScrollBarColumnWidth(), gap = 2 }
    if barCol and ns.UI_EnsureScrollBarColumnSync then
        ns.UI_EnsureScrollBarColumnSync(sf, barCol, syncOpts)
    elseif barCol and ns.UI_SyncScrollBarColumnToViewport then
        ns.UI_SyncScrollBarColumnToViewport(sf, barCol, syncOpts)
    elseif sf.ScrollBar and barCol and F and F.PositionScrollBarInContainer then
        F:PositionScrollBarInContainer(sf.ScrollBar, barCol, 0, sf)
    end
    if barCol and sf:GetFrameLevel() and barCol:GetFrameLevel() < sf:GetFrameLevel() + 2 then
        barCol:SetFrameLevel(sf:GetFrameLevel() + 4)
    end
    if sf.UpdateScrollChildRect then
        sf:UpdateScrollChildRect()
    end
    if ns.UI_ApplyScrollLayoutDebugChrome and vp.shell then
        ns.UI_ApplyScrollLayoutDebugChrome(sf, barCol, vp.shell)
    end
    if F and F.SyncScrollBarThumb then
        F:SyncScrollBarThumb(sf)
    end
    local function tick()
        if not sf or not sf.GetScrollChild then return end
        if sf.UpdateScrollBarVisibility then
            sf:UpdateScrollBarVisibility()
        elseif F and F.UpdateScrollBarVisibility then
            F:UpdateScrollBarVisibility(sf)
        end
    end
    tick()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, tick)
        C_Timer.After(0.05, tick)
    end
end

-- ── Themed dropdown (PlansTrackerWindow.lua:1867-2110 CreateThemedCategoryDropdown) ──
-- The one dropdown of Artisan Nexus: W.CreateDropdown is WN's bordered control (value text +
-- chevron), W.OpenDropdownMenu its flyout menu. Title-toolbar filters open the same menu from a WN
-- toolbar text button, right-aligned under it like WN's toolbar flyouts
-- (SharedWidgets_TitleToolbar.lua:195-300).

local activeDropdownMenu = nil
local DROPDOWN_ITEM_H = 24

local function ControlChromeBackdrop()
    return (ns.UI_GetControlChromeBackdrop and ns.UI_GetControlChromeBackdrop()) or { 0.08, 0.08, 0.10, 0.95 }
end

--- PlansTrackerWindow.lua:281 ApplyTrackerDropdownChrome (neutral control chrome).
function W.ApplyDropdownChrome(dropdown)
    if not dropdown then return end
    if ns.UI_IsClassicMode and ns.UI_IsClassicMode() then
        if ns.UI_ApplyClassicPaneBackdrop then
            ns.UI_ApplyClassicPaneBackdrop(dropdown, ControlChromeBackdrop())
        elseif ns.UI_ApplyClassicInteriorFlatFill then
            ns.UI_ApplyClassicInteriorFlatFill(dropdown, ControlChromeBackdrop())
        end
    else
        W.ApplyChrome(dropdown, ControlChromeBackdrop(), nil)
    end
end

--- PlansTrackerWindow.lua:2798 ns.PlansTracker_CloseOpenDropdown (ESC closes the flyout first).
---@return boolean closed
function W.CloseOpenDropdown()
    if activeDropdownMenu and activeDropdownMenu:IsShown() then
        activeDropdownMenu:Hide()
        activeDropdownMenu = nil
        return true
    end
    return false
end
if ns.UI_RegisterDropdownEscClose then
    ns.UI_RegisterDropdownEscClose(W.CloseOpenDropdown)
end

local function Resolve(v)
    if type(v) == "function" then
        return v()
    end
    return v
end

--- Open (or, when it is already open, close) the themed flyout menu under `anchor`.
---@param anchor Frame the control the menu drops from
---@param opts table { items = { { key, label } } | fn, value = key | fn, onSelected = fn(key),
---                    minWidth = number|nil, alignRight = boolean|nil (toolbar flyout),
---                    host = table|nil (holds the menu frames; default anchor) }
function W.OpenDropdownMenu(anchor, opts)
    local F = Factory()
    local COLORS_ = COLORS()
    -- Menu + click-catcher live on `opts.host` (a stable table for anchors that are rebuilt on every
    -- paint, e.g. title-toolbar buttons), else on the anchor itself.
    local host = opts.host or anchor
    -- Toggle: close if already open
    if activeDropdownMenu and activeDropdownMenu:IsShown() then
        local wasOwn = activeDropdownMenu == host._dropdownMenu
        activeDropdownMenu:Hide()
        activeDropdownMenu = nil
        if wasOwn then
            return
        end
    end
    activeDropdownMenu = nil

    local items = Resolve(opts.items) or {}
    local itemCount = #items
    local itemHeight = DROPDOWN_ITEM_H
    local menuWidth = math.max(anchor:GetWidth() or 0, opts.minWidth or 0)

    local menu = host._dropdownMenu
    if not menu then
        menu = F:CreateContainer(UIParent, menuWidth, 200, true)
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:SetFrameLevel(300)
        menu:SetClampedToScreen(true)
        menu:SetScript("OnHide", function()
            local catcher = host._clickCatcher
            if catcher then
                catcher:Hide()
            end
            if activeDropdownMenu == menu then
                activeDropdownMenu = nil
            end
        end)
        host._dropdownMenu = menu
    end
    if ns.UI_ApplyVisuals then
        local ac = COLORS_.accent or { 0.5, 0.5, 0.5 }
        local menuBg = (ns.UI_GetExternalShellBackdrop and ns.UI_GetExternalShellBackdrop()) or ControlChromeBackdrop()
        ns.UI_ApplyVisuals(menu, menuBg, { ac[1] * 0.6, ac[2] * 0.6, ac[3] * 0.6, 0.8 })
    end
    menu:SetWidth(menuWidth)
    menu:ClearAllPoints()
    if opts.alignRight then
        menu:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -2)
    else
        menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    end
    activeDropdownMenu = menu

    local scrollFrame, scrollChild = ns.UI_ApplyDropdownScrollLayout(menu, itemCount, itemHeight)
    if scrollFrame then
        scrollFrame:EnableMouseWheel(true)
        if ns.UI_EnableStandardScrollWheel then
            ns.UI_EnableStandardScrollWheel(scrollFrame)
        end
        if scrollChild and ns.UI_WireScrollChildMouseWheel then
            ns.UI_WireScrollChildMouseWheel(scrollFrame, scrollChild)
        end
    end

    if scrollChild then
        local bin = ns.UI_RecycleBin
        local ch = { scrollChild:GetChildren() }
        for i = 1, #ch do
            ch[i]:Hide()
            ch[i]:ClearAllPoints()
            if bin then ch[i]:SetParent(bin) else ch[i]:SetParent(nil) end
        end
    end

    local current = Resolve(opts.value)
    local yPos = (ns.UI_LAYOUT and ns.UI_LAYOUT.DROPDOWN_INSET_TOP) or 4
    local btnWidth = (scrollChild and scrollChild:GetWidth()) or (menuWidth - 16)
    for ci = 1, itemCount do
        local item = items[ci]
        local btn = F:CreateButton(scrollChild, btnWidth, itemHeight, true)
        btn:SetPoint("TOPLEFT", 0, -yPos)
        btn._anValue = item.key

        local btnText = ns.FontManager:CreateFontString(btn, "body", "OVERLAY")
        btnText:SetPoint("LEFT", 10, 0)
        btnText:SetText(item.label)

        -- Highlight current selection
        if current == item.key then
            ns.UI_SetTextColorRole(btnText, "Bright")
        else
            ns.UI_SetTextColorRole(btnText, "Normal")
        end

        -- Hover visual
        if ns.UI_ApplyVisuals then
            ns.UI_ApplyVisuals(btn, { 0.08, 0.08, 0.10, 0 }, { 0, 0, 0, 0 })
        end
        if F.ApplyHighlight then
            F:ApplyHighlight(btn)
        end

        btn:SetScript("OnClick", function()
            menu:Hide()
            activeDropdownMenu = nil
            if current == item.key then
                return
            end
            if opts.onSelected then opts.onSelected(item.key) end
        end)

        yPos = yPos + itemHeight
    end

    ns.UI_ApplyDropdownScrollLayout(menu, itemCount, itemHeight)
    menu:Show()

    -- Click-catcher (full-screen invisible frame) closes the menu on an outside click.
    local clickCatcher = host._clickCatcher
    if not clickCatcher then
        clickCatcher = F:CreateContainer(UIParent, 100, 100, false) or CreateFrame("Frame", nil, UIParent)
        clickCatcher:SetAllPoints()
        clickCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
        clickCatcher:SetFrameLevel(menu:GetFrameLevel() - 1)
        clickCatcher:EnableMouse(true)
        clickCatcher:SetScript("OnMouseDown", function()
            if activeDropdownMenu then
                activeDropdownMenu:Hide()
            end
            activeDropdownMenu = nil
            clickCatcher:Hide()
        end)
        host._clickCatcher = clickCatcher
    end
    clickCatcher:Show()
end

--- WN bordered dropdown control: [ value ............ v ]; click opens W.OpenDropdownMenu.
---@param parent Frame
---@param opts table { width, height, items = { { key, label } } | fn, value = key | fn, onSelected = fn(key),
---                    format = fn(key, label) -> value text (optional) }
---@return Button dropdown (.valueText, :Refresh(), :Restyle(), :CloseMenu())
function W.CreateDropdown(parent, opts)
    local F = Factory()
    local w, h = opts.width or 120, opts.height or 26
    local dropdown = F:CreateButton(parent, w, h, false)
    dropdown:SetSize(w, h)
    W.ApplyDropdownChrome(dropdown)

    -- Dropdown affordance: monochrome chevron on the right edge.
    local ddChevron = dropdown:CreateTexture(nil, "OVERLAY")
    ddChevron:SetSize(12, 12)
    ddChevron:SetPoint("RIGHT", dropdown, "RIGHT", -10, 0)
    local function PaintChevron()
        local tn = COLORS().textNormal or { 0.85, 0.85, 0.85 }
        if not (ns.UI_SetWnIconTexture and ns.UI_SetWnIconTexture(ddChevron, "chevron_down", { vertexColor = { tn[1], tn[2], tn[3], 0.9 } })) then
            ddChevron:Hide()
        end
    end
    PaintChevron()

    -- Value text
    local valueText = ns.FontManager:CreateFontString(dropdown, "body", "OVERLAY")
    valueText:SetPoint("LEFT", 10, 0)
    valueText:SetPoint("RIGHT", ddChevron, "LEFT", -8, 0)
    valueText:SetJustifyH("LEFT")
    valueText:SetWordWrap(false)
    ns.UI_SetTextColorRole(valueText, "Bright")
    dropdown.valueText = valueText

    function dropdown:Refresh()
        local key = Resolve(opts.value)
        local items = Resolve(opts.items) or {}
        local label = items[1] and items[1].label or ""
        for i = 1, #items do
            if items[i].key == key then label = items[i].label break end
        end
        valueText:SetText(opts.format and opts.format(key, label) or label)
    end

    function dropdown:Restyle()
        W.ApplyDropdownChrome(self)
        PaintChevron()
        ns.UI_SetTextColorRole(valueText, "Bright")
    end

    function dropdown:CloseMenu()
        local menu = self._dropdownMenu
        if menu and menu:IsShown() then
            menu:Hide()
        end
    end

    -- Dropdown click: open custom menu
    dropdown:SetScript("OnClick", function(self)
        W.OpenDropdownMenu(self, {
            items = opts.items,
            value = opts.value,
            onSelected = function(key)
                if opts.onSelected then opts.onSelected(key) end
                dropdown:Refresh()
            end,
        })
    end)

    -- Hover on dropdown button
    dropdown:SetScript("OnEnter", function(self)
        if ns.UI_IsClassicMode and ns.UI_IsClassicMode() then return end
        local ac = COLORS().accent or { 0.5, 0.5, 0.5 }
        local hoverBg = (ns.UI_GetControlChromeHoverBackdrop and ns.UI_GetControlChromeHoverBackdrop()) or ControlChromeBackdrop()
        W.ApplyChrome(self, hoverBg, { ac[1] * 0.6, ac[2] * 0.6, ac[3] * 0.6, 0.8 })
    end)
    dropdown:SetScript("OnLeave", function(self)
        W.ApplyDropdownChrome(self)
    end)

    dropdown:Refresh()
    return dropdown
end

-- ── Destructive confirm (PlansUI.lua:994-1007 StaticPopup pattern) ──

local CONFIRM_POPUP = "ARTISANNEXUS_WINDOW_CONFIRM"

--- Yes / Cancel confirmation; `onAccept` runs on Yes.
---@param text string question (may contain "\n\nThis cannot be undone!")
---@param acceptText string|nil button1 label (default YES)
---@param onAccept function
function W.Confirm(text, acceptText, onAccept)
    StaticPopupDialogs[CONFIRM_POPUP] = {
        text = "%s",
        button1 = acceptText or YES or "Yes",
        button2 = CANCEL or "Cancel",
        OnAccept = function()
            if onAccept then onAccept() end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopup_Show(CONFIRM_POPUP, text, nil, { onAccept = onAccept })
end
