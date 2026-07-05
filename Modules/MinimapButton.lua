--[[
    Minimap launcher via LibDataBroker-1.1 + LibDBIcon-1.0 (same stack as Warband Nexus).
    Custom art: Media/anlogo.tga — WoW resolves extension automatically (omit .tga in path).
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local L = ns.L

local LDB = LibStub("LibDataBroker-1.1", true)
local LDBI = LibStub("LibDBIcon-1.0", true)

--- Keep in sync with ArtisanNexus.toc ## IconTexture.
local MINIMAP_ICON = "Interface\\AddOns\\ArtisanNexus\\Media\\anlogo"

function ArtisanNexus:InitializeMinimapButton()
    if not LDB or not LDBI then
        return
    end
    if self.db.profile.minimap == nil then
        self.db.profile.minimap = { hide = false }
    end

    local dataObj = LDB:NewDataObject(ADDON_NAME, {
        type = "launcher",
        text = (L and L["ADDON_NAME"]) or ADDON_NAME,
        icon = MINIMAP_ICON,
        OnClick = function(_, button)
            if InCombatLockdown() then
                return
            end
            if button == "LeftButton" then
                if IsShiftKeyDown and IsShiftKeyDown() then
                    if ns.ArtisanHubUI and ns.ArtisanHubUI.Toggle then
                        ns.ArtisanHubUI:Toggle()
                    end
                elseif ns.LootHistoryUI and ns.LootHistoryUI.Toggle then
                    ns.LootHistoryUI:Toggle()
                end
            elseif button == "RightButton" then
                if ns.OpenAddonSettings then
                    ns.OpenAddonSettings()
                end
            elseif button == "MiddleButton" then
                if ns.RecipeMatcherUI and ns.RecipeMatcherUI.Toggle then
                    ns.RecipeMatcherUI:Toggle()
                end
            end
        end,
        OnTooltipShow = function(tooltip)
            if not tooltip or not tooltip.AddLine then
                return
            end
            tooltip:SetText("|cff6a0dad" .. ((L and L["ADDON_NAME"]) or ADDON_NAME) .. "|r", 1, 1, 1)
            tooltip:AddLine(" ")
            tooltip:AddLine((L and L["MINIMAP_TT_LEFT"]) or "Left-Click: Toggle Session loot", 0.9, 0.9, 0.9, true)
            tooltip:AddLine((L and L["MINIMAP_TT_SHIFT_LEFT"]) or "Shift+Left-Click: Artisan Hub", 0.85, 0.85, 0.85, true)
            tooltip:AddLine((L and L["MINIMAP_TT_MIDDLE"]) or "Middle-Click: Recipe Matcher", 0.85, 0.85, 0.85, true)
            tooltip:AddLine((L and L["MINIMAP_TT_RIGHT"]) or "Right-Click: Open options", 0.75, 0.75, 0.75, true)
        end,
    })

    LDBI:Register(ADDON_NAME, dataObj, self.db.profile.minimap)
    if self.db.profile.minimap.hide then
        LDBI:Hide(ADDON_NAME)
    else
        LDBI:Show(ADDON_NAME)
    end
end

function ArtisanNexus:SetMinimapButtonVisible(show)
    if not LDBI then
        return
    end
    self.db.profile.minimap = self.db.profile.minimap or {}
    if show then
        LDBI:Show(ADDON_NAME)
        self.db.profile.minimap.hide = false
    else
        LDBI:Hide(ADDON_NAME)
        self.db.profile.minimap.hide = true
    end
end

function ArtisanNexus:ToggleMinimapButton()
    if not LDBI then
        return
    end
    if not self.db.profile.minimap or self.db.profile.minimap.hide then
        self:SetMinimapButtonVisible(true)
        self:Print((L and L["MINIMAP_SHOWN"]) or "Minimap button shown.")
    else
        self:SetMinimapButtonVisible(false)
        self:Print((L and L["MINIMAP_HIDDEN"]) or "Minimap button hidden.")
    end
end
