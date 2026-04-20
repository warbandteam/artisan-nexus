--[[
    Detect likely overloaded herb/ore nodes from world tooltip text.
    Emits AN_GATHERING_OVERLOAD_HINT_UPDATED with payload (informational; no click-to-cast).
    When no hint is active, emits nil payload to clear indicator.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants and ns.Constants.EVENTS

---@class GatheringOverloadService
local GatheringOverloadService = {
    _enabled = false,
    _hooked = false,
    _scanElapsed = 0,
    _lastSig = nil,
}

local scanFrame = CreateFrame("Frame")

local OVERLOAD_KEYWORDS = {
    "overload",
    "overloaded",
    "empowered",
    "overload wild herb",
    "overload wild deposits",
    "overload infused herb",
    "overload infused deposit",
    "overload empowered herb",
    "overload empowered deposit",
}

-- Midnight overload spells by gathering category + node modifier.
local OVERLOAD_SPELLS = {
    herb = {
        infused = { 1223014 }, -- Overload Infused Herb
        wild = { 1225150 }, -- Overload Wild Herb
        empowered = { 423395, 423443 }, -- legacy/alt empowered herb IDs
        fallback = { 423395, 423443, 1223014, 1225150 },
    },
    mine = {
        infused = { 1225392 }, -- Overload Infused Deposit
        wild = { 1225819 }, -- Overload Wild Deposits
        empowered = { 423394, 423334, 423335 }, -- legacy/alt empowered deposit IDs
        fallback = { 423394, 423334, 423335, 1225392, 1225819 },
    },
}

--- Path string or numeric fileId (both valid for Texture:SetTexture in Retail).
local function GetSpellTextureForSpellID(spellID)
    if not spellID then
        return nil
    end
    local id = tonumber(spellID)
    if not id then
        return nil
    end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, a, b = pcall(C_Spell.GetSpellTexture, id)
        if ok then
            if type(a) == "string" and a ~= "" then
                return a
            end
            if type(a) == "number" and a > 0 then
                return a
            end
        end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, id)
        if ok and type(info) == "table" then
            local iid = info.iconID or info.originalIconID
            if type(iid) == "number" and iid > 0 then
                return iid
            end
        end
    end
    if GetSpellTexture then
        local tex = GetSpellTexture(id)
        if tex and tex ~= "" then
            return tex
        end
    end
    return nil
end

local function FirstSpellIDForCategoryModifier(category, modifier)
    local byCat = OVERLOAD_SPELLS[category] or {}
    if modifier and type(byCat[modifier]) == "table" and byCat[modifier][1] then
        return byCat[modifier][1]
    end
    local fb = byCat.fallback
    return fb and fb[1] or nil
end

-- Prefer Infused overload art when modifier is unknown (matches tracker / user expectation).
local function ResolveIconSpellID(category, modifier, statusSpellID)
    if statusSpellID then
        return statusSpellID
    end
    local cat = category == "mine" and "mine" or "herb"
    if modifier then
        return FirstSpellIDForCategoryModifier(cat, modifier)
    end
    local infused = OVERLOAD_SPELLS[cat] and OVERLOAD_SPELLS[cat].infused
    if infused and infused[1] then
        return infused[1]
    end
    return FirstSpellIDForCategoryModifier(cat, nil)
end

local function IsIndicatorEnabled()
    local db = ns.db and ns.db.profile
    if not db then
        return false
    end
    return db.overloadNodeIndicatorEnabled ~= false
end

local function IsSecret(v)
    return issecretvalue and v and issecretvalue(v)
end

local function NormalizeLower(s)
    if not s or type(s) ~= "string" or IsSecret(s) then
        return nil
    end
    return s:lower()
end

--- World nodes often drop the item suffix (e.g. “Wild Brilliant Silver” vs catalog “Brilliant Silver Ore”).
local function MineNodeNameAlias(low)
    if not low or low == "" then
        return nil
    end
    local stripped = low
        :gsub("%s+ore%s*$", "")
        :gsub("%s+deposit%s*$", "")
        :gsub("%s+vein%s*$", "")
        :gsub("%s+seam%s*$", "")
    stripped = stripped:match("^%s*(.-)%s*$") or stripped
    if stripped == "" or stripped == low then
        return nil
    end
    -- Avoid ultra-short tokens (“iron”) that match NPCs; aliases are usually still descriptive.
    if #stripped < 8 then
        return nil
    end
    return stripped
end

local function BuildNodeNameKeywords()
    local out = { herb = {}, mine = {} }
    local seen = { herb = {}, mine = {} }
    for _, cat in ipairs({ "herb", "mine" }) do
        local entries = ns.GetGatheringCatalogByCategory and ns.GetGatheringCatalogByCategory(cat) or {}
        for i = 1, #entries do
            local entry = entries[i]
            local note = entry and entry.note
            local low = NormalizeLower(note)
            if low and low ~= "" and not seen[cat][low] then
                seen[cat][low] = true
                out[cat][#out[cat] + 1] = low
            end
        end
    end
    -- Second pass: mine-only stripped names so hover text matches nodes without “Ore” / “Deposit”.
    local nMine = #out.mine
    for i = 1, nMine do
        local low = out.mine[i]
        local alias = MineNodeNameAlias(low)
        if alias and not seen.mine[alias] then
            seen.mine[alias] = true
            out.mine[#out.mine + 1] = alias
        end
    end
    return out
end

local NODE_NAME_KEYWORDS = BuildNodeNameKeywords()

local function IsSpellKnownSafe(spellID)
    if not spellID then
        return false
    end
    if IsPlayerSpell and IsPlayerSpell(spellID) then
        return true
    end
    if IsSpellKnownOrOverridesKnown and IsSpellKnownOrOverridesKnown(spellID) then
        return true
    end
    if C_SpellBook and C_SpellBook.IsSpellInSpellBook then
        local ok, inBook = pcall(C_SpellBook.IsSpellInSpellBook, spellID)
        if ok and inBook then
            return true
        end
    end
    return false
end

--- Same rules as UI `GetSpellCooldownTiming`: long CDs, `isEnabled`, ready state.
local function GetSpellCooldownTriple(spellID)
    local getVals = ns.GetPlayerSpellCooldownValues
    if not getVals then
        return nil, nil, nil
    end
    local startTime, duration, isEnabled = getVals(spellID)
    startTime = tonumber(startTime)
    duration = tonumber(duration)
    if not startTime or not duration then
        return nil, nil, nil
    end
    if duration > 0.001 and startTime > 0 then
        local rem = (startTime + duration) - GetTime()
        return startTime, duration, math.max(0, rem)
    end
    if isEnabled == 0 then
        return nil, nil, nil
    end
    if duration <= 0 or startTime <= 0 then
        return startTime, duration, 0
    end
    local rem = (startTime + duration) - GetTime()
    return startTime, duration, math.max(0, rem)
end

--- Node hint / ilk bilinen spell için kalan süre (ResolveOverloadStatus); `IsUsableSpell` ile eski davranış korunur.
local function GetCooldownRemaining(spellID)
    local getVals = ns.GetPlayerSpellCooldownValues
    if not getVals then
        return nil
    end
    local startTime, duration, isEnabled = getVals(spellID)
    startTime = tonumber(startTime)
    duration = tonumber(duration)
    if not startTime or not duration then
        return nil
    end
    if duration > 0.001 and startTime > 0 then
        local rem = (startTime + duration) - GetTime()
        if rem < 0 then
            rem = 0
        end
        return rem
    end
    if isEnabled == 0 then
        return nil
    end
    if duration <= 0 or startTime <= 0 then
        if IsUsableSpell then
            local usable = IsUsableSpell(spellID)
            if not usable then
                return nil
            end
        end
        return 0
    end
    local rem = (startTime + duration) - GetTime()
    if rem < 0 then
        rem = 0
    end
    return rem
end

--- HUD tracker: skill bar Wild / Infused farklı ID’ler — en uzun kalan CD’yi taşıyan spell’i göster.
---@return number|nil displaySpellID
---@return number|nil startTime
---@return number|nil duration
---@return number|nil remaining
function GatheringOverloadService.GetOverloadTrackerState(category)
    local by = OVERLOAD_SPELLS[category]
    if not by or not by.fallback then
        return nil, nil, nil, nil
    end
    local fb = by.fallback
    local bestSid, bestSt, bestDur, bestRem
    for j = 1, #fb do
        local sid = fb[j]
        if IsSpellKnownSafe(sid) then
            local st, dur, rem = GetSpellCooldownTriple(sid)
            if rem ~= nil and rem > 0.05 then
                if not bestRem or rem > bestRem then
                    bestSid, bestSt, bestDur, bestRem = sid, st, dur, rem
                end
            end
        end
    end
    if bestSid then
        return bestSid, bestSt, bestDur, bestRem
    end
    for j = 1, #fb do
        local sid = fb[j]
        if IsSpellKnownSafe(sid) then
            local st, dur, rem = GetSpellCooldownTriple(sid)
            return sid, st, dur, rem
        end
    end
    return nil, nil, nil, nil
end

--- Pick the **overload spell for this node**, not “shortest CD among all known overloads” (that showed Infused icon on Wild nodes).
--- Order: modifier list → fallback; first **known** spell wins. Icon + secure cast must match this `spellID`.
local function ResolveOverloadStatus(category, modifier)
    local cats
    if category == "herb" or category == "mine" then
        cats = { category }
    else
        cats = { "herb", "mine" }
    end
    for i = 1, #cats do
        local cat = cats[i]
        local byCat = OVERLOAD_SPELLS[cat] or {}
        local ids = {}
        if modifier and type(byCat[modifier]) == "table" then
            for j = 1, #byCat[modifier] do
                ids[#ids + 1] = byCat[modifier][j]
            end
        end
        local fallback = byCat.fallback or {}
        for j = 1, #fallback do
            ids[#ids + 1] = fallback[j]
        end
        for j = 1, #ids do
            local spellID = ids[j]
            if IsSpellKnownSafe(spellID) then
                local rem = GetCooldownRemaining(spellID)
                return {
                    category = cat,
                    remaining = rem,
                    spellID = spellID,
                }
            end
        end
    end
    return nil
end

local function ReadTooltipLines()
    local out = {}
    if not GameTooltip or not GameTooltip:IsShown() then
        return out
    end
    local name = GameTooltip.GetName and GameTooltip:GetName()
    if not name then
        return out
    end
    local n = GameTooltip:NumLines() or 0
    for i = 1, n do
        for _, suffix in ipairs({ "TextLeft", "TextRight" }) do
            local fs = _G[name .. suffix .. i]
            local t = fs and fs:GetText()
            if t and (issecretvalue and issecretvalue(t)) then
                t = nil
            end
            local low = NormalizeLower(t)
            if low and low ~= "" then
                out[#out + 1] = low
            end
        end
    end
    return out
end

local function AppendUnitNameLine(lines, unit)
    if not lines or not unit then
        return
    end
    if not UnitExists or not UnitExists(unit) then
        return
    end
    local n = UnitName and UnitName(unit)
    local low = NormalizeLower(n)
    if low and low ~= "" then
        lines[#lines + 1] = low
    end
end

local function ReadDetectionLines()
    local lines = ReadTooltipLines()
    -- World-object targets may not always populate GameTooltip on every client/addon setup.
    AppendUnitNameLine(lines, "mouseover")
    AppendUnitNameLine(lines, "target")
    return lines
end

local function TooltipLooksOverloaded(lines)
    for i = 1, #lines do
        local line = lines[i]
        for k = 1, #OVERLOAD_KEYWORDS do
            if line:find(OVERLOAD_KEYWORDS[k], 1, true) then
                return true
            end
        end
    end
    return false
end

local MODIFIER_KEYWORDS = {
    wild = { "wild" },
    infused = { "infused", "lightfused", "voidbound", "primal" },
    empowered = { "empowered" },
}

-- "wild" / "infused" alone match many NPC names; only treat modifiers on lines that look like nodes or overload text.
local GATHERING_LINE_HINTS = {
    "herb",
    "flower",
    "plant",
    "bloom",
    "deposit",
    "vein",
    "mining",
    "overload",
    "soil",
    "seam",
    "rich ",
    " pure ",
}

local function LineLooksLikeGatheringOrOverload(line)
    if not line or line == "" then
        return false
    end
    if TooltipLooksOverloaded({ line }) then
        return true
    end
    for c = 1, #NODE_NAME_KEYWORDS.herb do
        if line:find(NODE_NAME_KEYWORDS.herb[c], 1, true) then
            return true
        end
    end
    for c = 1, #NODE_NAME_KEYWORDS.mine do
        if line:find(NODE_NAME_KEYWORDS.mine[c], 1, true) then
            return true
        end
    end
    for h = 1, #GATHERING_LINE_HINTS do
        if line:find(GATHERING_LINE_HINTS[h], 1, true) then
            return true
        end
    end
    return false
end

local function ResolveModifierFromTooltip(lines)
    for i = 1, #lines do
        local line = lines[i]
        if LineLooksLikeGatheringOrOverload(line) then
            for modifier, kws in pairs(MODIFIER_KEYWORDS) do
                for j = 1, #kws do
                    if line:find(kws[j], 1, true) then
                        return modifier
                    end
                end
            end
        end
    end
    return nil
end

local function ResolveCategoryFromTooltip(lines)
    local hits = { herb = 0, mine = 0 }
    for i = 1, #lines do
        local line = lines[i]
        for c = 1, #NODE_NAME_KEYWORDS.herb do
            if line:find(NODE_NAME_KEYWORDS.herb[c], 1, true) then
                hits.herb = hits.herb + 1
                break
            end
        end
        for c = 1, #NODE_NAME_KEYWORDS.mine do
            if line:find(NODE_NAME_KEYWORDS.mine[c], 1, true) then
                hits.mine = hits.mine + 1
                break
            end
        end
    end
    if hits.herb > hits.mine and hits.herb > 0 then
        return "herb"
    end
    if hits.mine > hits.herb and hits.mine > 0 then
        return "mine"
    end
    return nil
end

--- Do not include `remaining` in the signature — it changes every scan and spams UI.
local function EmitHint(payload)
    if not ArtisanNexus or not ArtisanNexus.SendMessage or not E or not E.GATHERING_OVERLOAD_HINT_UPDATED then
        return
    end
    local sig
    if payload and payload.active then
        sig = table.concat({
            "1",
            payload.category or "",
            payload.overloaded and "1" or "0",
            tostring(payload.spellID or 0),
            payload.modifier or "",
        }, "|")
    else
        sig = "0"
    end
    if sig == GatheringOverloadService._lastSig then
        return
    end
    GatheringOverloadService._lastSig = sig
    ArtisanNexus:SendMessage(E.GATHERING_OVERLOAD_HINT_UPDATED, payload)
end

local function ScanTooltip()
    if not GatheringOverloadService._enabled or not IsIndicatorEnabled() then
        EmitHint(nil)
        return
    end
    if ns.IsOpenWorld and not ns.IsOpenWorld() then
        EmitHint(nil)
        return
    end
    local lines = ReadDetectionLines()
    if #lines < 1 then
        EmitHint(nil)
        return
    end

    local cat, modifier
    local reg = ns.GatheringNodeOverloadRegistry and ns.GatheringNodeOverloadRegistry.Resolve
    local regCat, regMod = reg and reg(lines)
    if regCat then
        cat = regCat
        if regMod ~= nil then
            modifier = regMod
        else
            modifier = ResolveModifierFromTooltip(lines)
        end
    else
        cat = ResolveCategoryFromTooltip(lines)
        modifier = ResolveModifierFromTooltip(lines)
    end

    if not cat then
        EmitHint(nil)
        return
    end
    local overloaded = TooltipLooksOverloaded(lines) or (modifier ~= nil)
    local status = ResolveOverloadStatus(cat, modifier)
    local finalCat = cat
    if not finalCat and status and status.category then
        finalCat = status.category
    end
    if status and status.spellID then
        local sid = status.spellID
        EmitHint({
            active = true,
            category = status.category or finalCat,
            remaining = status.remaining,
            overloaded = overloaded,
            modifier = modifier,
            iconSpellID = sid,
            iconTexture = GetSpellTextureForSpellID(sid),
            spellID = sid,
        })
    else
        local iconSpellID = ResolveIconSpellID(finalCat or cat, modifier, nil)
        local iconTexture = iconSpellID and GetSpellTextureForSpellID(iconSpellID) or nil
        EmitHint({
            active = true,
            category = finalCat,
            remaining = nil,
            overloaded = overloaded,
            modifier = modifier,
            iconSpellID = iconSpellID,
            iconTexture = iconTexture,
        })
    end
end

local function HookTooltip()
    if GatheringOverloadService._hooked or not GameTooltip then
        return
    end
    GatheringOverloadService._hooked = true
    GameTooltip:HookScript("OnShow", ScanTooltip)
    GameTooltip:HookScript("OnHide", function()
        EmitHint(nil)
    end)
end

function GatheringOverloadService:Enable()
    if self._enabled then
        return
    end
    self._enabled = true
    self._scanElapsed = 0
    HookTooltip()
    scanFrame:SetScript("OnUpdate", function(_, elapsed)
        GatheringOverloadService._scanElapsed = GatheringOverloadService._scanElapsed + (elapsed or 0)
        if GatheringOverloadService._scanElapsed < 0.18 then
            return
        end
        GatheringOverloadService._scanElapsed = 0
        ScanTooltip()
    end)
end

function GatheringOverloadService:Disable()
    if not self._enabled then
        return
    end
    self._enabled = false
    scanFrame:SetScript("OnUpdate", nil)
    EmitHint(nil)
end

ns.GatheringOverloadService = GatheringOverloadService
ns.GetOverloadTrackerState = function(category)
    return GatheringOverloadService.GetOverloadTrackerState(category)
end
