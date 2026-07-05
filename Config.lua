--[[
    Artisan Nexus — Blizzard Settings (Esc → Options → AddOns): single launcher row.
    Full options: |cff00ccff/an config|r opens ArtisanSettingsFrame (FrameXML + ArtisanSettingsUI glue).
]]

local ADDON_NAME, ns = ...

local tinsert = table.insert

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
    blurb:SetText((L and L["SETTINGS_BLIZZARD_LAUNCHER_TEXT"]) or "")

    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(260, 30)
    btn:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -20)
    btn:SetText((L and L["SETTINGS_BLIZZARD_OPEN_PANEL"]) or "Open Artisan Nexus settings")
    btn:SetScript("OnClick", function()
        Config.OpenSettings()
    end)
end

function Config.OpenSettings()
    if ns.ArtisanSettingsUI and ns.ArtisanSettingsUI.ShowPanel then
        ns.ArtisanSettingsUI:ShowPanel()
        return
    end
    local msg = (L and L["SETTINGS_UI_UNAVAILABLE"]) or "Settings UI is not available."
    if ArtisanNexus and ArtisanNexus.Print then
        ArtisanNexus:Print(msg)
    end
end

ns.OpenAddonSettings = Config.OpenSettings

function Config.RegisterOptions(_addon)
    if not Settings or not Settings.RegisterCanvasLayoutCategory or not Settings.RegisterAddOnCategory then
        return
    end

    local holder = CreateFrame("Frame", "ArtisanNexusBlizzardSettingsCanvas", UIParent)
    BuildBlizzardSettingsCanvas(holder)
    holder:Hide()

    local displayName = (L and L["ADDON_NAME"]) or ADDON_NAME
    local category = Settings.RegisterCanvasLayoutCategory(holder, displayName)
    Settings.RegisterAddOnCategory(category)
end

ns.Config = Config
