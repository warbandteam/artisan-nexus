--[[
    Double right-click on WorldFrame: secure /cast Fishing or interact with bobber (macro).
    Uses SecureActionButtonTemplate; hook is SecureHookScript (post-hook, does not block camera).
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local L = ns.L

local FishingInput = {}

local localeFrame = CreateFrame("Frame")
localeFrame:SetScript("OnEvent", function()
    FishingInput:UpdateSecureMacroText()
end)
FishingInput._localeFrame = localeFrame

local DOUBLE_CLICK_MAX = 0.35
local lastRightClickTime = 0

local BOBBER_NPC_IDS = {
    [124736] = true,
    [35591] = true,
    [216204] = true,
}

local function GetNPCIDFromGUID(guid)
    if not guid or (issecretvalue and issecretvalue(guid)) then return nil end
    local unitType, _, _, _, _, npcID = strsplit("-", guid)
    if unitType == "Creature" then return tonumber(npcID) end
    return nil
end

local function IsBobberTarget()
    if not UnitExists("target") then return false end
    local guid = UnitGUID("target")
    local nid = GetNPCIDFromGUID(guid)
    return nid and BOBBER_NPC_IDS[nid] == true
end

--- Interact if loot UI is fishing, bobber is targeted, or FishingService says we're mid-session.
local function ShouldUseInteract()
    if IsFishingLoot and IsFishingLoot() then
        return true
    end
    if IsBobberTarget() then
        return true
    end
    if ns.FishingService and ns.FishingService:ShouldUseInteractInsteadOfCast() then
        return true
    end
    return false
end

function FishingInput:UpdateSecureMacroText()
    local interact = _G["ArtisanNexusSecureInteractBobber"]
    if not interact then return end
    if InCombatLockdown() then return end
    local bobberName = (L and L["FISHING_BOBBER_NAME"]) or "Fishing Bobber"
    --- Retail: /interact uses soft-target / interact key behavior (see warcraft.wiki.gg macro docs).
    interact:SetAttribute("macrotext", "/targetexact " .. bobberName .. "\n/interact\n")
end

local function CreateSecureButtons()
    if _G["ArtisanNexusSecureCastFishing"] then return end

    local cast = CreateFrame("Button", "ArtisanNexusSecureCastFishing", UIParent, "SecureActionButtonTemplate")
    cast:SetSize(1, 1)
    cast:SetPoint("CENTER", UIParent, "CENTER", 0, 12000)
    cast:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    cast:SetAttribute("type", "macro")
    cast:SetAttribute("macrotext", "/cast Fishing\n")

    local interact = CreateFrame("Button", "ArtisanNexusSecureInteractBobber", UIParent, "SecureActionButtonTemplate")
    interact:SetSize(1, 1)
    interact:SetPoint("CENTER", UIParent, "CENTER", 0, 12001)
    interact:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    interact:SetAttribute("type", "macro")
    local bobberName = (L and L["FISHING_BOBBER_NAME"]) or "Fishing Bobber"
    interact:SetAttribute("macrotext", "/targetexact " .. bobberName .. "\n/interact\n")
end

function FishingInput:OnDoubleRightClick()
    if InCombatLockdown() then return end
    local cast = _G["ArtisanNexusSecureCastFishing"]
    local interact = _G["ArtisanNexusSecureInteractBobber"]
    if not cast or not interact then return end

    if ShouldUseInteract() then
        interact:Click()
    else
        cast:Click()
    end
end

function ArtisanNexus:AN_WorldMouseDown(frame, button)
    if button ~= "RightButton" then return end
    if not self.db.profile.enabled or not self.db.profile.modulesEnabled.fishing then return end
    if not self.db.profile.fishingDoubleClickEnabled then return end
    local now = GetTime()
    if now - lastRightClickTime <= DOUBLE_CLICK_MAX then
        lastRightClickTime = 0
        FishingInput:OnDoubleRightClick()
    else
        lastRightClickTime = now
    end
end

function FishingInput:Enable()
    CreateSecureButtons()
    self:UpdateSecureMacroText()
    ArtisanNexus:SecureHookScript(WorldFrame, "OnMouseDown", "AN_WorldMouseDown")
    self._localeFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
end

function FishingInput:Disable()
    ArtisanNexus:Unhook(WorldFrame, "OnMouseDown")
    lastRightClickTime = 0
    self._localeFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
end

ns.FishingInput = FishingInput
