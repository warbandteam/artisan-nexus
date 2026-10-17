--[[
    Artisan Nexus — versioned, NON-destructive SavedVariables migrations.

    `db.global._schemaVersion` vs file-local `CURRENT_SCHEMA_VERSION`: each step in
    `MIGRATIONS` transforms schema v → v+1 in place. Steps must be idempotent and must
    NEVER wipe another character's data (offline characters keep their records).
    `_schemaVersion` / `addonVersion` are stamped here and deliberately absent from
    Core.lua defaults — AceDB strips stored values equal to defaults at logout.
]]

local ADDON_NAME, ns = ...

local DebugPrint = ns.DebugPrint

---@class MigrationService
local MigrationService = {}
ns.MigrationService = MigrationService

-- Bump when the SavedVariables layout changes; add a matching MIGRATIONS step.
local CURRENT_SCHEMA_VERSION = 10

--- Removed fishing input / double-cast gesture keys (feature deleted; strip from profile).
local LEGACY_FISHING_INPUT_PROFILE_KEYS = {
    "fishingSecureLootClickEnabled",
    "fishingSoftTargetInteractTuneEnabled",
    "settingsAdvancedFishingExpanded",
    "fishingDoubleClickUseLeftButton",
    "fishingDoubleClickUseRightButton",
    "fishingDoubleClickEnabled",
    "fishingClickThreshold",
    "fishingDoubleRightClickEnabled",
    "fishingDoubleRightClickCastEnabled",
    "fishingRightClickInteractEnabled",
    "fishingDoubleRightArmSeconds",
    "fishingInputDebug",
    "_fishingUnifiedDoubleRight202605",
    "_fishingWorldClickMigration2026",
    "_fishingRemovedUiToggles202606",
    "_fishingInputRemoved202602",
    "_fishingDoubleCastRemoved202606",
}

--- Profile keys of removed features / never-read settings (stripped from EVERY stored profile).
local DEAD_PROFILE_KEYS = {
    "routeHeatmapEnabled",
    "minimapGatherPinsEnabled",
    "farmTargetHighlightEnabled",
    "gatherLootAutoWaypoint",
    "farmTargetAutoWaypoint",
    "_gatherLogRemoved202606",
    "_settingsAlwaysEnabled202606",
    "_mapOverlayRemoved202606",
    "hubPlanView", -- Queue & Shopping page view switch; the page stacks both views now
    "settingsFrame", -- standalone settings window geometry; settings live on a Hub page now
    "enabled", -- master toggle; no UI sets it, the addon is always enabled
}

---@param p table one stored profile
local function StripDeadProfileKeys(p)
    for i = 1, #DEAD_PROFILE_KEYS do
        p[DEAD_PROFILE_KEYS[i]] = nil
    end
end

-- ─────────────────────────────────────────────────────────────────
-- v8 → v9: pre-WN look / window profile keys → Warband Nexus keys
-- ─────────────────────────────────────────────────────────────────

--- Old AN accent presets (pre-WN ArtisanTheme.lua ACCENT_PRESET_RGB); "default" = WN default accent.
local LEGACY_ACCENT_PRESET_RGB = {
    violet = { 0.44, 0.32, 0.58 },
    gold = { 0.78, 0.62, 0.22 },
    teal = { 0.22, 0.58, 0.54 },
    rose = { 0.72, 0.28, 0.42 },
    cobalt = { 0.28, 0.42, 0.78 },
}

--- Old Hub page keys (profile.hubActiveTab, incl. the legacy aliases of HubWindow.lua) → WN main tab.
local LEGACY_HUB_TAB = {
    overview = "overview", crafting = "crafting", plan = "plan", concentration = "concentration",
    orders = "orders", market = "market", ledger = "ledger",
    profit = "crafting", profitability = "crafting", shop = "plan", shopping = "plan", queue = "plan",
    conc = "concentration", planner = "concentration", cooldowns = "concentration",
    auctions = "market", sales = "ledger",
}

--- Old Settings page section (profile.settingsSection) → WN settings panel (profile.settingsPanel).
local LEGACY_SETTINGS_SECTION = {
    general = "general", loot = "loot", crafting = "crafting", auction = "auction", advanced = "advanced",
}

--- Old Hub window size (pre-WN ArtisanTheme.lua HUB_WINDOW_WIDTH / HUB_WINDOW_HEIGHT); the Hub did not
--- persist its size, only its anchor.
local LEGACY_HUB_W, LEGACY_HUB_H = 960, 640

--- Anchor point → fraction of the frame / parent box from its bottom-left corner.
local POINT_FRAC = {
    TOPLEFT = { 0, 1 }, TOP = { 0.5, 1 }, TOPRIGHT = { 1, 1 },
    LEFT = { 0, 0.5 }, CENTER = { 0.5, 0.5 }, RIGHT = { 1, 0.5 },
    BOTTOMLEFT = { 0, 0 }, BOTTOM = { 0.5, 0 }, BOTTOMRIGHT = { 1, 0 },
}

--- WN UI_CalculateThemeColors (SharedWidgets_Theme.lua) when loaded; same formula inline otherwise.
local function ThemeColorsFromRGB(r, g, b)
    if ns.UI_CalculateThemeColors then
        return ns.UI_CalculateThemeColors(r, g, b)
    end
    local function Desaturate(cr, cg, cb, amount)
        local gray = (cr + cg + cb) / 3
        return cr + (gray - cr) * amount, cg + (gray - cg) * amount, cb + (gray - cb) * amount
    end
    local function Scale(cr, cg, cb, f)
        return math.min(1, cr * f), math.min(1, cg * f), math.min(1, cb * f)
    end
    local dr, dg, db = Scale(r, g, b, 0.7)
    local br, bg, bb = Desaturate(r * 0.5, g * 0.5, b * 0.5, 0.6)
    local ar, ag, ab = Scale(r, g, b, 0.5)
    local hr, hg, hb = Scale(r, g, b, 0.6)
    return {
        accent = { r, g, b },
        accentDark = { dr, dg, db },
        border = { br, bg, bb },
        tabActive = { ar, ag, ab },
        tabHover = { hr, hg, hb },
    }
end

--- Old Hub anchor { point, relativePoint, relativeTo, x, y } (frame:GetPoint offsets on UIParent, in
--- the window's scaled space) → WN profile.windowPosition { TOPLEFT, BOTTOMLEFT, left, top }
--- (UI.lua SaveWindowGeometry). nil when the anchor cannot be converted.
local function ConvertLegacyHubAnchor(t, uiScale)
    if type(t) ~= "table" or t.x == nil or t.y == nil then
        return nil
    end
    local rel = t.relativeTo
    if rel ~= nil and rel ~= "" and rel ~= "UIParent" then
        return nil
    end
    local pf = POINT_FRAC[t.point or ""]
    local rf = POINT_FRAC[t.relativePoint or t.point or ""]
    if not pf or not rf then
        return nil
    end
    local x, y = tonumber(t.x), tonumber(t.y)
    if not x or not y then
        return nil
    end
    local s = tonumber(uiScale) or 1
    if s <= 0 then s = 1 end
    local pw = (UIParent and UIParent.GetWidth and UIParent:GetWidth()) or 0
    local ph = (UIParent and UIParent.GetHeight and UIParent:GetHeight()) or 0
    if pw <= 0 or ph <= 0 then
        return nil
    end
    local left = (pw * rf[1]) / s + x - LEGACY_HUB_W * pf[1]
    local top = (ph * rf[2]) / s + y + LEGACY_HUB_H * (1 - pf[2])
    return { point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = left, y = top }
end

--- True when the WN theme colors are absent or still the WN default accent (Core.lua defaults:
--- AceDB copies defaults into the active profile before migrations run).
local function IsDefaultThemeColors(tc)
    if type(tc) ~= "table" then
        return true
    end
    local a = tc.accent
    if type(a) ~= "table" then
        return true
    end
    local function near(v, d) return math.abs((tonumber(v) or -1) - d) < 0.001 end
    return near(a[1], 0.40) and near(a[2], 0.20) and near(a[3], 0.58)
end

--- Moves one stored profile's pre-WN UI keys onto the WN keys, then strips the old keys.
--- Idempotent: a second run finds no old keys. A WN key that already holds a non-default value is
--- kept ("unset" = nil or the Core.lua default, which AceDB copies into the active profile).
---   uiMode "classic"            → uiTheme = "classic" (+ modernColorMode from themeMode)
---   themeMode "dark"|"light"    → same key in WN; "light" also fills modernColorMode
---   accentPreset / accentCustom → themeColors (WN UI_CalculateThemeColors shape)
---   fontScale                   → fonts.useCustomScale = true, fonts.scaleCustom
---   hubFrame                    → windowPosition (TOPLEFT of the old 960x640 Hub)
---   hubActiveTab                → lastTab (old aliases mapped; unknown dropped)
---   settingsSection             → settingsPanel
---@param p table one stored profile
function MigrationService.MigrateLegacyUiProfile(p)
    if type(p) ~= "table" then
        return
    end

    if p.uiMode == "classic" and (p.uiTheme == nil or p.uiTheme == "modern") then
        p.uiTheme = "classic"
        if p.modernColorMode == nil or p.modernColorMode == "dark" then
            p.modernColorMode = (p.themeMode == "light") and "light" or "dark"
        end
    end
    p.uiMode = nil

    if p.themeMode == "light" and (p.modernColorMode == nil or p.modernColorMode == "dark") then
        p.modernColorMode = "light"
    elseif p.themeMode ~= nil and p.themeMode ~= "dark" and p.themeMode ~= "light" and p.themeMode ~= "classic" then
        p.themeMode = nil
    end

    local preset = p.accentPreset
    if IsDefaultThemeColors(p.themeColors) and preset ~= nil and preset ~= "default" then
        local rgb
        if preset == "custom" and type(p.accentCustom) == "table" then
            local c = p.accentCustom
            if tonumber(c[1]) and tonumber(c[2]) and tonumber(c[3]) then
                rgb = { tonumber(c[1]), tonumber(c[2]), tonumber(c[3]) }
            end
        else
            rgb = LEGACY_ACCENT_PRESET_RGB[preset]
        end
        if rgb then
            p.themeColors = ThemeColorsFromRGB(rgb[1], rgb[2], rgb[3])
        end
    end
    p.accentPreset = nil
    p.accentCustom = nil

    local fs = tonumber(p.fontScale)
    if fs and math.abs(fs - 1) > 0.001 then
        if type(p.fonts) ~= "table" then
            p.fonts = {}
        end
        local custom = tonumber(p.fonts.scaleCustom)
        if p.fonts.useCustomScale ~= true and (custom == nil or math.abs(custom - 1) < 0.001) then
            p.fonts.useCustomScale = true
            p.fonts.scaleCustom = math.max(0.8, math.min(1.5, fs))
        end
    end
    p.fontScale = nil

    if p.windowPosition == nil then
        local pos = ConvertLegacyHubAnchor(p.hubFrame, p.uiScale)
        if pos then
            p.windowPosition = pos
        end
    end
    p.hubFrame = nil

    local tab = LEGACY_HUB_TAB[p.hubActiveTab or ""]
    if tab and p.lastTab == nil then
        p.lastTab = tab
    end
    p.hubActiveTab = nil

    local panel = LEGACY_SETTINGS_SECTION[p.settingsSection or ""]
    if panel and (p.settingsPanel == nil or p.settingsPanel == "general") then
        p.settingsPanel = panel
    end
    p.settingsSection = nil
end

--- Calls fn(profileTable) for every stored profile (the schema stamp is global, so a per-profile
--- step must cover inactive profiles too). Falls back to the active profile when the raw store is absent.
---@param db table AceDB object
---@param fn fun(p: table)
local function ForEachProfile(db, fn)
    local profiles = db.sv and db.sv.profiles
    if type(profiles) == "table" then
        for _, p in pairs(profiles) do
            if type(p) == "table" then
                fn(p)
            end
        end
    elseif type(db.profile) == "table" then
        fn(db.profile)
    end
end

--- MIGRATIONS[v] upgrades schema v → v+1 in place. Idempotent; never wipes
--- other characters' data.
local MIGRATIONS = {
    --- v1 → v2: GUID-keyed character attribution. New stores are created empty;
    --- legacy event rows carry no character key and group under the "unknown"
    --- bucket at read time — nothing is destroyed.
    [1] = function(db)
        local g = db.global
        g.charRegistry = g.charRegistry or {}
        g.professionSnapshots = g.professionSnapshots or {}
    end,
    --- v2 → v3: drop legacy fishing input / double-cast profile keys (no runtime feature).
    [2] = function(db)
        ForEachProfile(db, function(p)
            for i = 1, #LEGACY_FISHING_INPUT_PROFILE_KEYS do
                p[LEGACY_FISHING_INPUT_PROFILE_KEYS[i]] = nil
            end
        end)
    end,
    --- v3 → v4: legacy overload tracker default was TOP-center (too high); anchor above action bars.
    [3] = function(db)
        ForEachProfile(db, function(p)
            local t = p.overloadTrackerFrame
            if type(t) ~= "table" or t._overloadAnchorBottom202607 then
                return
            end
            local px = tonumber(t.x) or 0
            local py = tonumber(t.y) or 0
            local rel = t.relativePoint or t.point or "TOP"
            if t.point == "TOP" and rel == "TOP" and px == 0 and py == -140 then
                t.point = "BOTTOMRIGHT"
                t.relativePoint = "BOTTOMRIGHT"
                t.x = -24
                t.y = 120
                t._overloadAnchorBottom202607 = true
            end
        end)
    end,
    --- v4 → v5: intentionally empty. An unreleased build reset sessionLootOverlayScale here; the
    --- compact overlay was reverted, but the version stays 5 so DBs already stamped v5 never skip
    --- a future step.
    [4] = function() end,
    --- v5 → v6: purge legacy-expansion recipe schematics. An earlier build mapped recipes by the
    --- base profession skill line, harvesting every expansion's recipes (e.g. 355 Classic–TWW
    --- Tailoring rows); their old reagents bloated the AH scan queue with unlisted items.
    --- Only spellIDs in the static Midnight catalog are kept; real new Midnight recipes missing
    --- from the catalog are re-read on the next profession open.
    [5] = function(db)
        local g = db.global
        local cat = ns.MidnightRecipeCatalog
        if type(g) ~= "table" or type(g.recipeSchematics) ~= "table" or type(cat) ~= "table" then
            return
        end
        local keep = {}
        for _, data in pairs(cat) do
            if type(data) == "table" and type(data.recipes) == "table" then
                for spellID in pairs(data.recipes) do
                    keep[tonumber(spellID) or spellID] = true
                end
            end
        end
        local removed = 0
        for spellID in pairs(g.recipeSchematics) do
            if not keep[tonumber(spellID) or spellID] then
                g.recipeSchematics[spellID] = nil
                removed = removed + 1
            end
        end
        if type(g.craftOps) == "table" then
            for spellID in pairs(g.craftOps) do
                if not keep[tonumber(spellID) or spellID] then
                    g.craftOps[spellID] = nil
                end
            end
        end
        if removed > 0 then
            DebugPrint("|cff9370DB[AN Migration]|r removed " .. removed .. " legacy recipe schematics")
        end
    end,
    --- v6 → v7: dead-key cleanup + character data provider.
    --- * Strips removed-feature / unread keys from every stored profile (was an inline per-profile
    ---   block in Core.lua): map-overlay keys, the legacy percent `posting.undercutBy`, and
    ---   `enabled` (no UI can set it; the addon is always enabled), `hubPlanView`. Global `dataVersion`
    ---   (never read; `_schemaVersion` is the schema stamp) is dropped.
    --- * The removed GatherLog module's SavedVariables are no longer declared in the TOC, so they
    ---   are never loaded and need no cleanup. `_G.GatherLogDB` can only belong to another addon and
    ---   is deliberately left alone.
    --- * ns.CharacterData (Modules/Data/CharacterDataProvider.lua): nothing is deleted when Warband
    ---   Nexus is installed — WN may be uninstalled later. While WN covers a capability AN simply
    ---   stops writing it (professionSnapshots, learnedBy, charRegistry, itemSnapshots); AN-native rows
    ---   not refreshed for 30 days are pruned by the provider on enable. New store:
    ---   global.itemSnapshots = { chars = { [guid] = { at, bags = {[itemID]=n}, bank = {...} } },
    ---   warband = { at, counts } } (catalog reagents only), created on demand.
    [6] = function(db)
        local g = db.global
        g.dataVersion = nil
        local profiles = db.sv and db.sv.profiles
        if type(profiles) == "table" then
            for _, p in pairs(profiles) do
                if type(p) == "table" then
                    StripDeadProfileKeys(p)
                    if type(p.posting) == "table" then
                        p.posting.undercutBy = nil
                    end
                end
            end
        end
        g.gatherRoutePoints = nil
        g.farmTargetRoutePoints = nil
    end,
    --- v7 → v8: settings moved into the Hub. Re-run the dead-key strip for DBs already stamped v7,
    --- now covering `settingsFrame` (old settings window geometry) and the master `enabled` toggle.
    [7] = function(db)
        ForEachProfile(db, StripDeadProfileKeys)
    end,
    --- v8 → v9: the Warband Nexus UI framework replaced AN's own look/window settings. Each old
    --- choice moves to the WN key that now holds it (only when the WN key is still unset, so a
    --- choice already made in the WN settings wins), then the old key is stripped. See
    --- MigrateLegacyUiProfile for the mapping.
    [8] = function(db)
        ForEachProfile(db, function(p)
            MigrationService.MigrateLegacyUiProfile(p)
        end)
    end,
    --- v9 → v10: equipment was searched with a level-less key in SearchForItemKeys, found nothing and
    --- was recorded in global.ahEmpty ("no listings") for the freshness window. The AH scanner now
    --- queries equipment with SendSellSearchQuery; drop the wrong markers so the next sync re-checks.
    [9] = function(db)
        db.global.ahEmpty = nil
    end,
}

function MigrationService:CheckAddonVersion(db, addon)
    local ADDON_VERSION = (ns.Constants and ns.Constants.ADDON_VERSION) or "0.1.0"
    local savedVersion = db.global.addonVersion or "0.0.0"
    if savedVersion ~= ADDON_VERSION then
        DebugPrint("|cff9370DB[AN Migration]|r version " .. savedVersion .. " → " .. ADDON_VERSION)
    end
    -- Stamp unconditionally: the value must differ from any AceDB default to persist.
    db.global.addonVersion = ADDON_VERSION
end

---@param db table
function MigrationService:RunMigrations(db)
    if not db or not db.global then return end
    local g = db.global
    local stored = g._schemaVersion
    if stored == nil then
        -- Pre-versioned install, or the old `_schemaVersion = 1` default was
        -- stripped by AceDB at logout: treat existing data as v1.
        stored = 1
    end
    if stored > CURRENT_SCHEMA_VERSION then
        return -- downgraded addon: leave newer data untouched
    end
    while stored < CURRENT_SCHEMA_VERSION do
        local step = MIGRATIONS[stored]
        if step then
            local ok, err = pcall(step, db)
            if not ok then
                DebugPrint("|cff9370DB[AN Migration]|r step v" .. stored .. " failed: " .. tostring(err))
                -- Later steps stay blocked (they may assume this one ran), but say so outside debug mode.
                local addon = ns.ArtisanNexus
                if addon and addon.Print then
                    local fmt = (ns.L and ns.L["MIGRATION_STEP_FAILED"])
                        or "Data upgrade step %d failed; later steps paused. Please report: %s"
                    addon:Print(string.format(fmt, stored, tostring(err)))
                end
                break
            end
            DebugPrint("|cff9370DB[AN Migration]|r schema v" .. stored .. " → v" .. (stored + 1))
        end
        stored = stored + 1
    end
    g._schemaVersion = stored
end
