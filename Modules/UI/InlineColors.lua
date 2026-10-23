--[[
    Artisan Nexus — inline `|cffrrggbb` colour prefixes for FontString markup.

    One copy of the WN RecipeCompanionWindow / ProfessionInfoWindow TextRoleHex + Semantic*Hex pattern
    for the AN windows that build coloured strings (sidecar, Recipe Matcher, price history, posting
    helper). Every getter reads the live theme on each call, so light / dark / classic switches apply
    on the next paint. Close the colour with "|r".
]]

local ADDON_NAME, ns = ...

local IC = {}
ns.UI_InlineHex = IC

--- Text role (Bright / Normal / Muted / Dim ...), SharedWidgets_Theme UI_GetTextRoleHexRaw.
function IC.Role(role)
    return "|cff" .. ((ns.UI_GetTextRoleHexRaw and ns.UI_GetTextRoleHexRaw(role)) or "ffffff")
end

function IC.Green()
    return (ns.UI_GetSemanticGreenHex and ns.UI_GetSemanticGreenHex()) or "|cff44ff44"
end

function IC.Gold()
    return (ns.UI_GetSemanticGoldHex and ns.UI_GetSemanticGoldHex()) or "|cffffcc00"
end

function IC.Red()
    if ns.UI_GetSemanticRedColor then
        local r, g, b = ns.UI_GetSemanticRedColor()
        return string.format("|cff%02x%02x%02x", r * 255, g * 255, b * 255)
    end
    return "|cffff6666"
end

--- Theme accent.
function IC.Accent()
    return "|cff" .. ((ns.UI_GetAccentHexColor and ns.UI_GetAccentHexColor()) or "9966cc")
end
