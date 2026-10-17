--[[
    Overload Action Button

    A floating, movable, Extra-Action-style secure button that:
      * Always shows the icon of the best next-available overload spell.
      * Drives a Blizzard cooldown swipe so the remaining CD is visible at a glance.
      * Casts the spell on click (SecureActionButtonTemplate, gathering = out of combat).
      * Exposes itself to Blizzard's Key Bindings UI via `CLICK <name>:LeftButton`
        so players can bind a hotkey without a hidden helper frame.

    Selection rules (same as the tracker "next available" logic):
      1) If mouseover / target is a herb or ore node AND that category has an overload
         ready, show and cast that spell.
      2) Otherwise pick the first category with a ready overload.
      3) Otherwise show the spell with the shortest remaining CD so the user sees the
         correct swipe ticking down.

    Position is saved in db.profile.overloadActionButton = { point, relativePoint, x, y, hidden }.
]]

local ADDON_NAME, ns = ...

local GatheringOverloadActionButton = {}
local BUTTON_NAME = "ArtisanNexusOverloadActionButton"
local BUTTON_SIZE = 52

local button, icon, cooldown
local currentDisplaySID
local refreshPending = false

--- Left button only ("*" = any modifier, so a SHIFT-/CTRL- key binding still resolves):
--- right-click hides the button and must never resolve a cast action. Resolution order
--- per SecureButton_GetModifiedAttribute, verified 2026-10-15, wow-ui-source-live
--- Blizzard_FrameXML/SecureTemplates.lua:101-137.
local ATTR_TYPE = "*type1"
local ATTR_SPELL = "*spell1"

-- ---------------------------------------------------------------------------
-- Selection logic
-- ---------------------------------------------------------------------------

local function GetService()
    return ns and ns.GatheringOverloadService
end

local function GetTrackerSpell(category)
    local svc = GetService()
    if not svc or not svc.GetOverloadTrackerState then return nil end
    local sid, st, dur, rem = svc.GetOverloadTrackerState(category)
    return sid, st, dur, rem
end

local function IsReady(rem)
    return rem == nil or rem <= 0.05
end

local function GuessCategoryFromUnit(unit)
    if not UnitExists or not UnitExists(unit) then return nil end
    local name = UnitName and UnitName(unit)
    if not name or type(name) ~= "string" then return nil end
    if issecretvalue and issecretvalue(name) then return nil end
    if name == "" then return nil end
    local low = name:lower()
    local kw = ns.GetOverloadNodeKeywords and ns.GetOverloadNodeKeywords()
    if not kw then return nil end
    for _, k in ipairs(kw.herb or {}) do
        if low:find(k, 1, true) then return "herb" end
    end
    for _, k in ipairs(kw.mine or {}) do
        if low:find(k, 1, true) then return "mine" end
    end
    return nil
end

--- @return spellID, startTime, duration, remaining
local function ResolveBestSpell()
    -- 1) Mouseover / target node match first
    local cat = GuessCategoryFromUnit("mouseover") or GuessCategoryFromUnit("target")
    if cat then
        local sid, st, dur, rem = GetTrackerSpell(cat)
        if sid and IsReady(rem) then return sid, st, dur, rem end
    end
    -- 2) Any category with a ready overload
    for _, c in ipairs({ "herb", "mine" }) do
        local sid, st, dur, rem = GetTrackerSpell(c)
        if sid and IsReady(rem) then return sid, st, dur, rem end
    end
    -- 3) Spell with the shortest remaining CD (so the swipe means something)
    local bestSid, bestSt, bestDur, bestRem
    for _, c in ipairs({ "herb", "mine" }) do
        local sid, st, dur, rem = GetTrackerSpell(c)
        if sid and rem and (not bestRem or rem < bestRem) then
            bestSid, bestSt, bestDur, bestRem = sid, st, dur, rem
        end
    end
    return bestSid, bestSt, bestDur, bestRem
end

local function GetSpellIconSafe(sid)
    if not sid then return nil end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, a = pcall(C_Spell.GetSpellTexture, sid)
        if ok and a and a ~= 0 and a ~= "" then return a end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, sid)
        if ok and type(info) == "table" then
            return info.iconID or info.originalIconID
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- DB helpers
-- ---------------------------------------------------------------------------

local function GetDB()
    local db = ns.db and ns.db.profile
    if not db then return nil end
    if not db.overloadActionButton then
        db.overloadActionButton = {
            hidden = false,
            point = "CENTER",
            relativePoint = "CENTER",
            x = 0,
            y = -160,
        }
    end
    return db.overloadActionButton
end

local function SavePosition()
    if not button then return end
    local db = GetDB()
    if not db then return end
    local point, _, relativePoint, x, y = button:GetPoint(1)
    db.point = point or db.point
    db.relativePoint = relativePoint or db.relativePoint
    db.x = x or db.x
    db.y = y or db.y
end

local function ApplySavedPosition()
    if not button then return end
    local db = GetDB()
    if not db then return end
    button:ClearAllPoints()
    button:SetPoint(db.point or "CENTER", UIParent, db.relativePoint or "CENTER",
        db.x or 0, db.y or -160)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

local function Refresh()
    if not button then return end
    if InCombatLockdown() then
        -- Secure button: Show/Hide and attribute writes are protected in combat;
        -- defer everything (including the db.hidden Hide) to the next
        -- out-of-combat refresh. The button stays shown, so OnUpdate self-heals.
        return
    end
    local db = GetDB()
    if db and db.hidden then
        button:Hide()
        return
    end

    local sid, st, dur, rem = ResolveBestSpell()
    if not sid then
        button:Hide()
        return
    end
    button:Show()

    if sid ~= currentDisplaySID then
        currentDisplaySID = sid
        button:SetAttribute(ATTR_SPELL, sid)
        local tex = GetSpellIconSafe(sid)
        if tex and icon then icon:SetTexture(tex) end
    end

    if cooldown then
        if st and dur and dur > 0.001 and rem and rem > 0.05 then
            cooldown:SetCooldown(st, dur)
        else
            cooldown:Clear()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------------

local function OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if currentDisplaySID and GameTooltip.SetSpellByID then
        GameTooltip:SetSpellByID(currentDisplaySID)
    else
        GameTooltip:AddLine((ns.L and ns.L["OVERLOAD_BTN_FALLBACK"]) or "Overload")
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine((ns.L and ns.L["FLOAT_BTN_HINT"]) or "Shift+drag to move. Right-click to hide.", 0.62, 0.62, 0.62, true)
    GameTooltip:Show()
end

local function OnLeave()
    GameTooltip:Hide()
end

-- ---------------------------------------------------------------------------
-- Button creation
-- ---------------------------------------------------------------------------

local function EnsureButton()
    if button then return button end

    button = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate,BackdropTemplate")
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetClampedToScreen(true)
    -- Down clicks too: with ActionButtonUseKeyDown=1 a CLICK binding acts on key-down only
    -- (verified 2026-10-15, SecureTemplates.lua:813-814); mouse presses act on release.
    button:RegisterForClicks("AnyUp", "AnyDown")
    button:SetAttribute(ATTR_TYPE, "spell")

    -- Icon
    icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Border (soft purple, Artisan palette)
    button:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
    })
    button:SetBackdropBorderColor(0.42, 0.28, 0.62, 0.9)

    -- Cooldown swipe
    cooldown = CreateFrame("Cooldown", BUTTON_NAME .. "Cooldown", button, "CooldownFrameTemplate")
    cooldown:SetAllPoints(button)
    cooldown:SetDrawEdge(false)
    cooldown:SetHideCountdownNumbers(false)

    -- Drag handle (Shift+LMB to move; saves on release)
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then self:StartMoving() end
    end)
    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)

    -- Right-click hide (out of combat only to keep the secure attribute stable)
    button:SetScript("PreClick", function(self, mouseButton)
        if InCombatLockdown() then return end
        if mouseButton == "RightButton" then
            local db = GetDB()
            if db then db.hidden = true end
            self:Hide()
            if ns.RefreshAddonSettings then ns.RefreshAddonSettings() end
            if ns.ArtisanNexus and ns.ArtisanNexus.Print then
                ns.ArtisanNexus:Print((ns.L and ns.L["FLOAT_BTN_HIDDEN"]) or "Button hidden. Turn it back on in /an config.")
            end
            return
        end
        -- Left-click: make sure we're casting the current best spell, not a stale one.
        local sid = ResolveBestSpell()
        if sid and sid ~= currentDisplaySID then
            self:SetAttribute(ATTR_SPELL, sid)
            currentDisplaySID = sid
        end
    end)

    button:SetScript("OnEnter", OnEnter)
    button:SetScript("OnLeave", OnLeave)

    -- Refresh ticker (lightweight; ~3.3 Hz — enough for swipe, slightly cheaper than 5 Hz)
    button._refreshAccum = 0
    button:SetScript("OnUpdate", function(self, elapsed)
        self._refreshAccum = self._refreshAccum + (elapsed or 0)
        if self._refreshAccum < 0.3 then return end
        self._refreshAccum = 0
        Refresh()
    end)

    ApplySavedPosition()
    return button
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Event-driven refresh: the OnUpdate ticker stops once the button is hidden, so a Hide at
--- OnInitialize (spellbook not loaded yet) or before the profession is learned would
--- otherwise last the session. Coalesced to one Refresh per frame; Refresh is a no-op in
--- combat and PLAYER_REGEN_ENABLED re-runs it.
local function QueueRefresh()
    if refreshPending then return end
    refreshPending = true
    C_Timer.After(0, function()
        refreshPending = false
        Refresh()
    end)
end

function GatheringOverloadActionButton:Init()
    if self._inited then return end
    self._inited = true
    EnsureButton()
    Refresh()

    -- verified 2026-10-15, src/docs: SPELLS_CHANGED + LEARNED_SPELL_IN_SKILL_LINE
    -- (SpellBookDocumentation.lua), SKILL_LINES_CHANGED (SkillInfoDocumentation.lua),
    -- PLAYER_REGEN_ENABLED (UnitDocumentation.lua).
    local owner = ns.NewEventOwner("GatheringOverloadActionButton")
    self._eventOwner = owner
    owner:RegisterEvent("SPELLS_CHANGED", QueueRefresh)
    owner:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE", QueueRefresh)
    owner:RegisterEvent("SKILL_LINES_CHANGED", QueueRefresh)
    owner:RegisterEvent("PLAYER_REGEN_ENABLED", QueueRefresh)

    -- Binding UI label (Key Bindings > Artisan Nexus)
    local L = ns.L
    _G.BINDING_HEADER_ARTISANNEXUS = _G.BINDING_HEADER_ARTISANNEXUS or "Artisan Nexus"
    _G["BINDING_NAME_CLICK " .. BUTTON_NAME .. ":LeftButton"] =
        (L and L["BINDING_OVERLOAD_CAST"]) or "Cast Next Overload"
end

function GatheringOverloadActionButton:Show()
    local db = GetDB()
    if db then db.hidden = false end
    EnsureButton()
    Refresh()
end

function GatheringOverloadActionButton:Hide()
    local db = GetDB()
    if db then db.hidden = true end
    -- Protected frame: defer the actual Hide() out of combat; Refresh honors
    -- db.hidden on the next out-of-combat tick.
    if button and not InCombatLockdown() then button:Hide() end
end

ns.GatheringOverloadActionButton = GatheringOverloadActionButton
