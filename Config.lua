--[[
    Artisan Nexus — settings entry point.
    ns.OpenAddonSettings opens the Settings tab of the main window (WN SettingsUI); every
    launcher calls it. The Blizzard Settings (Esc → Options → AddOns) entry is a one-button canvas.
]]

local ADDON_NAME, ns = ...


local ArtisanNexus = ns.ArtisanNexus
local L = ns.L

local Config = {}

---@param parent Frame
local function BuildBlizzardSettingsCanvas(parent)
    parent:SetSize(560, 280)

    local title = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 20, -24)
    title:SetJustifyH("LEFT")
    title:SetText((L and L["CONFIG_HEADER"]) or ADDON_NAME)
    title:SetTextColor(0.98, 0.97, 0.99)

    local blurb = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
    blurb:SetPoint("TOPRIGHT", -24, -52)
    blurb:SetJustifyH("LEFT")
    blurb:SetSpacing(4)
    blurb:SetText((L and L["SETTINGS_BLIZZARD_LAUNCHER_TEXT"]) or "Use the button below or type |cff00ccff/an config|r.")

    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(260, 30)
    btn:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -20)
    btn:SetText((L and L["SETTINGS_BLIZZARD_OPEN_PANEL"]) or "Open settings panel")
    btn:SetScript("OnClick", function()
        Config.OpenSettings()
    end)
end

--- Open the Settings tab of the main window (Warband Nexus OpenOptions, Modules/UI.lua).
function Config.OpenSettings()
    if ArtisanNexus and ArtisanNexus.OpenOptions then
        ArtisanNexus:OpenOptions()
        return
    end
    local msg = (L and L["SETTINGS_UI_UNAVAILABLE"]) or "Settings failed to load. Reload the UI."
    if ArtisanNexus and ArtisanNexus.Print then
        ArtisanNexus:Print(msg)
    end
end

ns.OpenAddonSettings = Config.OpenSettings

function Config.RegisterOptions(_addon)
    local holder = CreateFrame("Frame", "ArtisanNexusBlizzardSettingsCanvas", UIParent)
    BuildBlizzardSettingsCanvas(holder)
    holder:Hide()

    local displayName = (L and L["ADDON_NAME"]) or ADDON_NAME
    local category = Settings.RegisterCanvasLayoutCategory(holder, displayName)
    Settings.RegisterAddOnCategory(category)
end

ns.Config = Config
