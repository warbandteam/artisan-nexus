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
        --- Same entry points as `/an`: left = Hub, right = Settings, Shift+Left = Session
        --- Loot, middle = Recipe Matcher.
        OnClick = function(_, button)
            if InCombatLockdown() then
                return
            end
            if button == "LeftButton" then
                if IsShiftKeyDown() then
                    if ns.LootHistoryUI and ns.LootHistoryUI.Toggle then
                        ns.LootHistoryUI:Toggle()
                    end
                elseif ns.ArtisanNexus and ns.ArtisanNexus.ToggleMainWindow then
                    ns.ArtisanNexus:ToggleMainWindow()
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
            tooltip:AddLine((L and L["MINIMAP_TT_LEFT"]) or "Left-Click: Artisan Hub", 0.9, 0.9, 0.9, true)
            tooltip:AddLine((L and L["MINIMAP_TT_SHIFT_LEFT"]) or "Shift+Left-Click: Session Loot", 0.85, 0.85, 0.85, true)
            tooltip:AddLine((L and L["MINIMAP_TT_MIDDLE"]) or "Middle-Click: Recipe Matcher", 0.85, 0.85, 0.85, true)
            tooltip:AddLine((L and L["MINIMAP_TT_RIGHT"]) or "Right-Click: Settings", 0.75, 0.75, 0.75, true)
        end,
    })

    LDBI:Register(ADDON_NAME, dataObj, self.db.profile.minimap)
    if self.db.profile.minimap.hide then
        LDBI:Hide(ADDON_NAME)
    else
        LDBI:Show(ADDON_NAME)
    end
end

--- Profile switch/copy/reset: LibDBIcon keeps the table it was registered with, so rebind
--- the button to the active profile's minimap table (position, hide, lock).
--- verified 2026-10-15, libs/LibDBIcon-1.0/LibDBIcon-1.0.lua:428 lib:Refresh(name, db)
--- (sets button.db = db, re-positions, applies hide/lock).
function ArtisanNexus:RefreshMinimapButton()
    if not LDBI or not (LDBI.IsRegistered and LDBI:IsRegistered(ADDON_NAME)) then
        return
    end
    if self.db.profile.minimap == nil then
        self.db.profile.minimap = { hide = false }
    end
    LDBI:Refresh(ADDON_NAME, self.db.profile.minimap)
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
