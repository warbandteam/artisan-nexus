--[[
    Secure floating button: craft the next incomplete queue entry (spell cast).
    Requires an open profession window; position saved in db.profile.craftQueueActionButton.
]]

local ADDON_NAME, ns = ...

local BUTTON_NAME = "ArtisanNexusCraftQueueActionButton"
local BUTTON_SIZE = 48
local CraftQueueActionButton = {}

local button, icon, cooldown
local currentSpellID

local function GetDB()
    local db = ns.db and ns.db.profile
    if not db then
        return nil
    end
    if not db.craftQueueActionButton then
        db.craftQueueActionButton = {
            hidden = false,
            point = "CENTER",
            relativePoint = "CENTER",
            x = 120,
            y = -120,
        }
    end
    return db.craftQueueActionButton
end

local function ResolveNextSpell()
    local svc = ns.CraftingQueueService
    if not svc or not svc.GetQueue then
        return nil
    end
    local q = svc:GetQueue()
    for i = 1, #q do
        local e = q[i]
        if e and e.spellID and (e.progress or 0) < (e.target or 1) then
            return e.spellID
        end
    end
    return nil
end

local function TradeOpen()
    if C_TradeSkillUI and C_TradeSkillUI.IsTradeSkillReady then
        return C_TradeSkillUI.IsTradeSkillReady() == true
    end
    local pf = _G.ProfessionsFrame or _G.TradeSkillFrame
    return pf and pf.IsShown and pf:IsShown()
end

local function SpellIcon(sid)
    if not sid then
        return nil
    end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, tex = pcall(C_Spell.GetSpellTexture, sid)
        if ok and tex then
            return tex
        end
    end
    if GetSpellTexture then
        return GetSpellTexture(sid)
    end
    return nil
end

local function SavePosition()
    if not button then
        return
    end
    local db = GetDB()
    if not db then
        return
    end
    local point, _, relativePoint, x, y = button:GetPoint(1)
    db.point = point or db.point
    db.relativePoint = relativePoint or db.relativePoint
    db.x = x or db.x
    db.y = y or db.y
end

local function ApplySavedPosition()
    if not button then
        return
    end
    local db = GetDB()
    if not db then
        return
    end
    button:ClearAllPoints()
    button:SetPoint(db.point or "CENTER", UIParent, db.relativePoint or "CENTER", db.x or 120, db.y or -120)
end

local function Refresh()
    if not button then
        return
    end
    local db = GetDB()
    if db and db.hidden then
        button:Hide()
        return
    end
    if not TradeOpen() then
        button:Hide()
        return
    end
    local sid = ResolveNextSpell()
    if not sid then
        button:Hide()
        return
    end
    button:Show()
    if InCombatLockdown() then
        return
    end
    if sid ~= currentSpellID then
        currentSpellID = sid
        button:SetAttribute("spell", sid)
        local tex = SpellIcon(sid)
        if tex and icon then
            icon:SetTexture(tex)
        end
    end
end

local function EnsureButton()
    if button then
        return button
    end
    button = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate,BackdropTemplate")
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetClampedToScreen(true)
    button:RegisterForClicks("AnyUp")
    button:SetAttribute("type", "spell")

    icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
    button:SetBackdropBorderColor(0.52, 0.40, 0.20, 0.95)

    cooldown = CreateFrame("Cooldown", BUTTON_NAME .. "Cooldown", button, "CooldownFrameTemplate")
    cooldown:SetAllPoints(button)

    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        if IsShiftKeyDown() then
            self:StartMoving()
        end
    end)
    button:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    button:SetScript("PreClick", function(self, mouseButton)
        if InCombatLockdown() then
            return
        end
        if mouseButton == "RightButton" then
            local db = GetDB()
            if db then
                db.hidden = true
            end
            self:Hide()
            return
        end
        local sid = ResolveNextSpell()
        if sid then
            self:SetAttribute("spell", sid)
            currentSpellID = sid
        end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine((ns.L and ns.L["CRAFT_QUEUE_BTN_TITLE"]) or "Craft next in queue", 1, 0.82, 0)
        GameTooltip:AddLine((ns.L and ns.L["CRAFT_QUEUE_BTN_DESC"]) or "Casts the first incomplete queue recipe.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    button._accum = 0
    button:SetScript("OnUpdate", function(self, elapsed)
        self._accum = self._accum + (elapsed or 0)
        if self._accum < 0.35 then
            return
        end
        self._accum = 0
        Refresh()
    end)
    ApplySavedPosition()
    return button
end

function CraftQueueActionButton:Show()
    EnsureButton()
    Refresh()
end

function CraftQueueActionButton:Hide()
    if button then
        button:Hide()
    end
end

function CraftQueueActionButton:Enable()
    EnsureButton()
    if self._eventOwner then
        return
    end
    local E = ns.Constants and ns.Constants.EVENTS
    local owner = ns.NewEventOwner("CraftQueueActionButton")
    self._eventOwner = owner
    owner:RegisterEvent("TRADE_SKILL_SHOW", function()
        CraftQueueActionButton:Show()
    end)
    owner:RegisterEvent("TRADE_SKILL_CLOSE", function()
        CraftQueueActionButton:Hide()
    end)
    if E and E.CRAFT_QUEUE_UPDATED then
        owner:RegisterMessage(E.CRAFT_QUEUE_UPDATED, function()
            Refresh()
        end)
    end
end

ns.CraftQueueActionButton = CraftQueueActionButton
