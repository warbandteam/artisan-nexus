--[[
    Craft Briefing — post-AH-scan profitable craft summary for owned professions.

    Listens for AN_AH_SCAN_COMPLETE, ranks harvested recipes via ProfitabilityService,
    persists db.global.craftBriefing, emits AN_CRAFT_BRIEFING_UPDATED.
]]

local ADDON_NAME, ns = ...

local E = ns.Constants.EVENTS
local CraftBriefingService = { _enabled = false }

local L = ns.SafeLocaleString

local function Profile()
    return ns.db and ns.db.profile
end

local function BriefingStore()
    if not ns.db or not ns.db.global then
        return nil
    end
    ns.db.global.craftBriefing = ns.db.global.craftBriefing or {}
    return ns.db.global.craftBriefing
end

--- Chat lines use the shared money formatter (coin icons; nil for 0).
local FormatCopper = ns.FormatCopper

local function Notify(msg)
    local addon = ns.ArtisanNexus
    if addon and addon.Print then
        addon:Print(msg)
    end
end

local function ProactiveAlert(topRow, store, scanKind)
    local p = Profile()
    if not p or p.craftBriefingProactiveAlert == false then
        return
    end
    if scanKind == "schematics" then
        return
    end
    if not topRow or not topRow.margin then
        return
    end
    local minProfit = tonumber(p.craftBriefingAlertMinProfit) or 10000
    if topRow.margin < minProfit then
        return
    end
    -- A price older than the freshness window makes `margin` fiction, and a raid warning is the
    -- loudest surface in the addon: only alert on a row the EV engine stands behind. `fresh` is
    -- the output price age (ProfitabilityService); `confidence` also folds in an unpriced or
    -- stale reagent and an operation snapshot taken on another character.
    if topRow.fresh == false or topRow.confidence == "low" then
        return
    end
    local sig = string.format("%s:%d:%d", tostring(topRow.spellID), topRow.margin, topRow.outputItem or 0)
    if store.lastAlertSignature == sig then
        return
    end
    store.lastAlertSignature = sig
    store.lastAlertAt = time()
    local profit = FormatCopper(topRow.margin) or "?"
    Notify(string.format(
        L("CRAFT_BRIEFING_ALERT_FMT", "|cffd4af37Craft alert:|r %s (%s) - %s profit. /an"),
        topRow.name or string.format(L("RECIPE_ID_FMT", "Recipe %s"), tostring(topRow.spellID)),
        topRow.profession or "?",
        profit))
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame,
            L("CRAFT_BRIEFING_ALERT_SHORT", "Profitable craft ready"),
            ChatTypeInfo["RAID_WARNING"])
    end
end

function CraftBriefingService:GetBriefing()
    return BriefingStore()
end

function CraftBriefingService:Rebuild(scanKind)
    local p = Profile()
    if p and p.craftBriefingEnabled == false then
        return
    end

    local ps = ns.ProfitabilityService
    local rs = ns.RecipeService
    if not ps or not rs then
        return
    end

    local topN = (p and tonumber(p.craftBriefingTopN)) or 5
    if topN < 1 then topN = 5 end
    if topN > 15 then topN = 15 end

    local useAverage = p and p.craftBriefingPriceMode == "avg"
    local owned = rs:GetOwnedCraftProfessions()
    local compareConc = not p or p.craftBriefingConcentrationHints ~= false
    local ownedOnly = (p and p.craftBriefingOwnedOnly ~= false)
    local listOpts = {
        harvestedOnly = true,
        useAverage = useAverage,
        ownedProfessionsOnly = ownedOnly,
        -- Owned-only briefings rank what THIS character can craft (ns.CharacterData:IsKnownByMe).
        knownBy = ownedOnly and "me" or "any",
        compareConcentration = compareConc,
    }

    -- Margins are EV-based and net of AH cut + expected deposit loss (CraftEVService). Reagents
    -- priced from vendors count as priced; only required Basic slots can make a row "missing"
    -- (optional / finishing slots never enter the cost, currency-only slots carry no gold price).
    local rows = ps:ListRecipes(listOpts)
    local top = {}
    for i = 1, #rows do
        local r = rows[i]
        if r.margin and r.margin > 0 and (r.missingReagentPrices or 0) == 0 then
            top[#top + 1] = r
            if #top >= topN then
                break
            end
        end
    end

    local warnings = {}
    if #owned < 1 then
        warnings[#warnings + 1] = L("CRAFT_BRIEFING_WARN_NO_PROF", "No crafting professions on this character.")
    end
    local stats = rs.GetStats and rs:GetStats()
    if stats and stats.harvested < 1 then
        warnings[#warnings + 1] = L("CRAFT_BRIEFING_WARN_HARVEST", "Open a profession window once to read recipes.")
    end

    local equipmentHints
    if p and p.craftBriefingEquipmentHints ~= false and ns.ProfessionEquipmentService then
        local pes = ns.ProfessionEquipmentService
        equipmentHints = pes:GetHints()
        if not equipmentHints or #equipmentHints < 1 then
            equipmentHints = pes:Refresh()
        end
    end

    local store = BriefingStore()
    if not store then
        return
    end
    store.updatedAt = time()
    local silent = (scanKind == "ops" or scanKind == "settings" or scanKind == "schematics")
    store.scanKind = (silent and store.scanKind) or scanKind or "unknown"
    store.priceMode = useAverage and "avg" or "spot"
    -- Whether the leading row is backed by a price inside profile.ahFreshTTL. The list still shows
    -- stale rows (an empty briefing would be worse); this says so, and the same rule gates the
    -- proactive alert. nil = no rows, so "stale" and "nothing to show" stay distinguishable.
    if top[1] then
        store.topFresh = top[1].fresh ~= false
    else
        store.topFresh = nil
    end
    store.ownedProfessions = owned
    store.top = top
    store.warnings = warnings
    store.equipmentHints = equipmentHints

    ns.ArtisanNexus:SendMessage(E.CRAFT_BRIEFING_UPDATED, store)

    -- Operation snapshots (every profession open), schematic harvests and settings tweaks refresh numbers silently.
    if silent then
        return
    end

    if #top > 0 then
        ProactiveAlert(top[1], store, scanKind)
    end

    if p and p.craftBriefingChatNotify == false then
        return
    end

    if #top < 1 then
        Notify(L("CRAFT_BRIEFING_NONE", "No profitable crafts at current prices."))
        return
    end

    Notify(L("CRAFT_BRIEFING_CHAT_HEADER", "Top crafts:"))
    for i = 1, #top do
        local r = top[i]
        local profit = FormatCopper(r.margin) or "?"
        local line = string.format(
            L("CRAFT_BRIEFING_LINE_FMT", "%d. %s (%s) - %s profit"),
            i, r.name or string.format(L("RECIPE_ID_FMT", "Recipe %s"), tostring(r.spellID)), r.profession or "?", profit)
        if r.recommendConcentration and r.concProfitDelta and r.concProfitDelta > 0 then
            line = line .. " " .. string.format(
                L("CRAFT_BRIEFING_CONC_SUFFIX", "(+ %s with concentration)"),
                FormatCopper(r.concProfitDelta) or "?")
        end
        Notify(line)
    end
    if equipmentHints and #equipmentHints > 0 then
        for hi = 1, math.min(2, #equipmentHints) do
            local h = equipmentHints[hi]
            if h and h.message then
                Notify(h.message)
            end
        end
    end
    Notify(L("CRAFT_BRIEFING_CHAT_FOOTER", "Full list: /an"))
end

function CraftBriefingService:Enable()
    if self._enabled then
        return
    end
    self._enabled = true
    local addon = ns.ArtisanNexus
    if not addon or not addon.RegisterMessage then
        return
    end
    local owner = self._eventOwner or ns.NewEventOwner("CraftBriefingService")
    self._eventOwner = owner
    if E and E.AH_SCAN_COMPLETE then
        owner:RegisterMessage(E.AH_SCAN_COMPLETE, function(_, payload)
            local kind = payload and payload.kind or "scan"
            CraftBriefingService:Rebuild(kind)
        end)
    end
    if E and E.RECIPE_SCHEMATICS_UPDATED then
        owner:RegisterMessage(E.RECIPE_SCHEMATICS_UPDATED, function()
            local briefing = BriefingStore()
            if briefing and briefing.updatedAt then
                CraftBriefingService:Rebuild("schematics")
            end
        end)
    end
    if E and E.CRAFT_OPS_UPDATED then
        owner:RegisterMessage(E.CRAFT_OPS_UPDATED, function()
            local briefing = BriefingStore()
            if briefing and briefing.updatedAt then
                CraftBriefingService:Rebuild("ops")
            end
        end)
    end
    if E and E.PROFESSION_EQUIPMENT_UPDATED then
        owner:RegisterMessage(E.PROFESSION_EQUIPMENT_UPDATED, function()
            local briefing = BriefingStore()
            if briefing and briefing.updatedAt then
                local hints = ns.ProfessionEquipmentService and ns.ProfessionEquipmentService:GetHints()
                if briefing then
                    briefing.equipmentHints = hints
                end
                if ns.ArtisanNexus and ns.ArtisanNexus.SendMessage and E.CRAFT_BRIEFING_UPDATED then
                    ns.ArtisanNexus:SendMessage(E.CRAFT_BRIEFING_UPDATED, briefing)
                end
            end
        end)
    end
    if E and E.LOADING_COMPLETE then
        owner:RegisterMessage(E.LOADING_COMPLETE, function()
            if addon.ScheduleTimer then
                addon:ScheduleTimer(function()
                    local p = Profile()
                    if p and p.craftBriefingEnabled == false then
                        return
                    end
                    local store = BriefingStore()
                    if store and store.updatedAt then
                        return
                    end
                    local prices = ns.db and ns.db.global and ns.db.global.ahPrices
                    if prices and next(prices) then
                        CraftBriefingService:Rebuild("login")
                    end
                end, 2)
            end
        end)
    end
end

function CraftBriefingService:Disable()
    if not self._enabled then
        return
    end
    self._enabled = false
    if self._eventOwner then
        self._eventOwner:UnregisterAllEvents()
        self._eventOwner:UnregisterAllMessages()
    end
end

ns.CraftBriefingService = CraftBriefingService
