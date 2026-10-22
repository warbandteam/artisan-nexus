--[[
    Artisan Nexus — profession sidecar: small companion window beside the Blizzard profession
    window (concentration, concentration plan, crafting queue, equipment hint for the open
    profession). Clicking the body opens the Artisan Hub's queue page; nothing else closes.

    Sections, most relevant first: the selected recipe (profit, reagent cost, crafts possible from
    bags + bank + warband bank, have / need per reagent), the open profession (concentration, unspent
    knowledge, best concentration use), queue progress, equipment hint.

    Warband Nexus companion pattern:
      shell / title band / close / ESC + combat hide -> ns.ArtisanWindow.Create (PlansTrackerWindow shell)
      shown with ProfessionsFrame, hidden with it   -> RecipeCompanionWindow.lua:850-874
      section header + label/value rows              -> ProfessionInfoWindow.lua:226-284
                                                        (AddSectionHeader / AddLine / AddFullWidthLine /
                                                        AddEmptyMessage)
    Docked beside ProfessionsFrame until the player drags it; a dragged position is kept in
    profile.professionSidecar (posKey) and wins from then on. Height follows the content.
]]

local ADDON_NAME, ns = ...

local ProfessionSidecarUI = { frame = nil }

local SafeL = ns.SafeLocaleString

-- Window + row metrics (ProfessionInfoWindow.lua:60-64, scaled to the narrow sidecar).
local WINDOW_W = 264
local SECTION_GAP = 10
local LINE_HEIGHT = 18
local LABEL_WIDTH = 108
local DOCK_GAP = 6
local POS_KEY = "professionSidecar"

local function COLORS()
    return ns.UI_COLORS or { accent = { 0.5, 0.4, 0.7 }, border = { 0.25, 0.25, 0.3 } }
end

local function SafeUiLine(val, fallback)
    fallback = fallback or ""
    if ns.CoerceUiString then
        return ns.CoerceUiString(val, fallback)
    end
    if type(val) ~= "string" or val == "" or (issecretvalue and issecretvalue(val)) then
        return fallback
    end
    return val
end

local function Profile()
    return ns.db and ns.db.profile
end

local function Hidden()
    local p = Profile()
    local s = p and p.professionSidecar
    return s and s.hidden == true
end

local function UserPlaced()
    local p = Profile()
    local s = p and p.professionSidecar
    return type(s) == "table" and s.userPlaced == true
end

-- ── Inline colors (ProfessionInfoWindow.lua:166-189) ──

local function RoleHex(role)
    return "|cff" .. ((ns.UI_GetTextRoleHexRaw and ns.UI_GetTextRoleHexRaw(role)) or "ffffff")
end

local function AccentHex()
    return (ns.UI_GetAccentHexColor and ns.UI_GetAccentHexColor()) or "9966cc"
end

local function GoldHex()
    return (ns.UI_GetSemanticGoldHex and ns.UI_GetSemanticGoldHex()) or "|cffffcc00"
end

local function GreenHex()
    return (ns.UI_GetSemanticGreenHex and ns.UI_GetSemanticGreenHex()) or "|cff44ff44"
end

--- ProfessionInfoWindow ValueMax + ProgressColor: green when full, gold when partial.
local function ValueMax(current, maximum)
    if not current or not maximum or maximum <= 0 then
        return RoleHex("Muted") .. "--|r"
    end
    local hex = (current >= maximum and GreenHex()) or (current > 0 and GoldHex()) or RoleHex("Bright")
    return hex .. current .. "|r / " .. hex .. maximum .. "|r"
end

local function Money(copper)
    return (ns.FormatCopper and ns.FormatCopper(math.floor((copper or 0) + 0.5))) or "0"
end

local function RedHex()
    local H = ns.HubUI_Internal
    return "|cff" .. ((H and H.InkHex and H.InkHex("danger")) or "ff5555")
end

--- Signed copper: green gain, red loss.
local function SignedMoney(copper)
    copper = math.floor((copper or 0) + 0.5)
    if copper < 0 then
        return RedHex() .. "-|r" .. Money(-copper)
    end
    return GreenHex() .. "+|r" .. Money(copper)
end

-- ── Row pool: the sidecar repaints often (queue / snapshot / plan messages), so the
-- ProfessionInfoWindow row builders draw into kept font strings and rules instead of
-- creating new ones per paint. ──

local function Acquire(body, kind, font)
    local pool = body._anPool[kind]
    local i = (body._anUsed[kind] or 0) + 1
    body._anUsed[kind] = i
    local obj = pool[i]
    if not obj then
        if kind == "rule" then
            obj = body:CreateTexture(nil, "ARTWORK")
        else
            obj = ns.FontManager:CreateFontString(body, font, "OVERLAY")
            obj:SetJustifyH("LEFT")
        end
        pool[i] = obj
    end
    obj:ClearAllPoints()
    obj:Show()
    return obj
end

local function ResetRows(body)
    for _, pool in pairs(body._anPool) do
        for i = 1, #pool do pool[i]:Hide() end
    end
    body._anUsed = {}
end

local function ContentWidth(body)
    local w = body:GetWidth()
    if not w or w <= 1 then
        w = WINDOW_W - 2 * ((ns.ArtisanWindow and ns.ArtisanWindow.PADDING) or 10)
    end
    return w
end

--- ProfessionInfoWindow.lua:226 AddSectionHeader: accent title + border rule.
local function AddSectionHeader(body, y, text, first)
    if not first then y = y + SECTION_GAP end
    local header = Acquire(body, "body", "body")
    header:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    header:SetWidth(ContentWidth(body))
    header:SetWordWrap(false)
    header:SetText("|cff" .. AccentHex() .. text .. "|r")
    y = y + LINE_HEIGHT + 2
    local line = Acquire(body, "rule")
    line:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    line:SetSize(ContentWidth(body), 1)
    local br = COLORS().border or { 0.25, 0.25, 0.3 }
    line:SetColorTexture(br[1], br[2], br[3], 0.35)
    return y + 4
end

--- ProfessionInfoWindow.lua:243 AddLine: muted label column + value.
local function AddLine(body, y, label, value)
    local lbl = Acquire(body, "body", "body")
    lbl:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    lbl:SetWidth(LABEL_WIDTH)
    lbl:SetWordWrap(false)
    lbl:SetText(RoleHex("Muted") .. label .. "|r")
    local val = Acquire(body, "body", "body")
    val:SetPoint("TOPLEFT", body, "TOPLEFT", LABEL_WIDTH + 5, -y)
    val:SetWidth(math.max(20, ContentWidth(body) - LABEL_WIDTH - 5))
    val:SetWordWrap(false)
    val:SetText(value or (RoleHex("Muted") .. "--|r"))
    return y + LINE_HEIGHT
end

--- ProfessionInfoWindow.lua:262 AddFullWidthLine (wraps here: equipment hints are sentences).
local function AddFullWidthLine(body, y, text)
    local fs = Acquire(body, "small", "small")
    fs:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    fs:SetWidth(ContentWidth(body))
    fs:SetWordWrap(true)
    -- Role ink on the font string: hints carry item links whose own |r would end an inline color.
    ns.UI_SetTextColorRole(fs, "Normal")
    fs:SetText(text)
    return y + math.max(LINE_HEIGHT, math.ceil(fs:GetStringHeight() or 0) + 2)
end

--- ProfessionInfoWindow.lua:273 AddEmptyMessage (one message).
local function AddEmptyMessage(body, y, message)
    local msg = Acquire(body, "body", "body")
    msg:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    msg:SetWidth(ContentWidth(body))
    msg:SetWordWrap(true)
    msg:SetJustifyH("CENTER")
    msg:SetText(GoldHex() .. message .. "|r")
    return y + math.max(LINE_HEIGHT * 2, math.ceil(msg:GetStringHeight() or 0) + 4)
end

-- ── Data ──

--- Catalog key of the open profession (snapshot catalogKey, else its skill line).
local function OpenProfessionKey()
    local snap = ns.ProfessionSnapshotService and ns.ProfessionSnapshotService:GetSnapshot()
    if not snap then
        return nil
    end
    if snap.catalogKey then
        return snap.catalogKey
    end
    local rs = ns.RecipeService
    local sl = snap.childSkillLineID or snap.skillLineID
    return sl and rs and rs.GetProfessionForSkillLine and rs:GetProfessionForSkillLine(sl) or nil
end

--- Concentration planner rows for the open profession (best gold-per-concentration first).
local function PlannerRows()
    local planner = ns.ConcentrationPlannerService
    local prof = OpenProfessionKey()
    if not prof or not planner then
        return nil
    end
    --- The planner only builds professions that have a pool; asking for another one
    --- would schedule rebuilds that never produce it (refresh loop on PLAN_UPDATED).
    local hasPool = false
    local pools = ns.CharacterData:GetConcentrationPools()
    for i = 1, #pools do
        if pools[i].profession == prof then
            hasPool = true
            break
        end
    end
    if not hasPool then
        return nil
    end
    local plan = planner:GetPlan(prof)
    local rows = plan and plan.rows
    if type(rows) ~= "table" or not rows[1] then
        return nil
    end
    return rows
end

local function EquipmentHint()
    local p = Profile()
    if p and p.craftBriefingEquipmentHints == false then
        return nil
    end
    local pes = ns.ProfessionEquipmentService
    local hints = pes and pes.GetHints and pes:GetHints()
    if type(hints) == "table" and hints[1] and hints[1].message then
        local msg = SafeUiLine(hints[1].message, "")
        if msg ~= "" then
            return msg
        end
    end
    return nil
end

--- The recipe selected in the profession window: is it worth crafting and can I craft it now.
--- Set from EventRegistry "ProfessionsRecipeListMixin.Event.OnRecipeSelected" (recipeInfo, recipeList)
--- (Blizzard_ProfessionsRecipeList.lua:137 / Blizzard_ProfessionsCrafting.lua:34, wow-ui-source live
--- 12.1.5.70448, checked 2026-10-22).
local MAX_RECIPE_REAGENTS = 6

local function AddRecipeSection(body, y, first)
    local sel = ProfessionSidecarUI._recipe
    local spellID = sel and sel.recipeID
    local rs = ns.RecipeService
    if not spellID or not rs then
        return y, false
    end
    local name = SafeUiLine(sel.name, "")
    if name == "" then
        name = SafeUiLine(rs.GetRecipeName and rs:GetRecipeName(spellID), "?")
    end
    y = AddSectionHeader(body, y, name, first)
    local ev
    local evSvc = ns.CraftEVService
    if evSvc and evSvc.Evaluate then
        local ok, res = pcall(evSvc.Evaluate, evSvc, spellID, { noLiveOps = true })
        ev = ok and res or nil
    end
    local base = ev and ev.bestNoConc
    if base then
        y = AddLine(body, y, SafeL("HUB_COL_PROFIT", "Profit"),
            base.profit and SignedMoney(base.profit) or (RoleHex("Muted") .. SafeL("HUB_NO_PRICE", "no price") .. "|r"))
        y = AddLine(body, y, SafeL("SIDECAR_LINE_COST", "Reagent cost"), Money(base.reagentCost))
    end
    if sel.learned == false then
        y = AddLine(body, y, SafeL("SIDECAR_LINE_STATUS", "Status"),
            RedHex() .. SafeL("SIDECAR_NOT_LEARNED", "Not learned") .. "|r")
    elseif rs.GetCraftStatus then
        local status, n = rs:GetCraftStatus(spellID, true)
        if status ~= "unknown" then
            local txt = ((n or 0) >= 1 and GreenHex() or RedHex()) .. tostring(n or 0) .. "|r"
            local withAlts = rs.MaxCraftsFromStock and rs:MaxCraftsFromStock(spellID, rs:GetCraftStockCounts(spellID, true)) or 0
            if withAlts > (n or 0) then
                txt = txt .. RoleHex("Muted") .. " (" .. string.format(SafeL("HUB_TT_WITH_ALTS_FMT", "%d with alts"), withAlts) .. ")|r"
            end
            y = AddLine(body, y, SafeL("HUB_TT_CAN_CRAFT", "Can craft"), txt)
        end
    end
    -- Reagents: have (bags + bank + warband bank) / need per craft.
    local slots = rs.GetRequiredBasicSlots and rs:GetRequiredBasicSlots(spellID) or {}
    for i = 1, math.min(#slots, MAX_RECIPE_REAGENTS) do
        local slot = slots[i]
        local need = tonumber(slot.qty) or 0
        local have, firstID = 0, nil
        for ci = 1, #slot.candidates do
            local id = slot.candidates[ci]
            id = type(id) == "table" and id.itemID or id
            if id then
                firstID = firstID or id
                have = have + rs:GetStockByLocation(id).total
            end
        end
        if firstID and need > 0 then
            local itemName = SafeUiLine(ns.GetItemDisplayName and ns.GetItemDisplayName(firstID), "?")
            y = AddLine(body, y, itemName,
                (have >= need and GreenHex() or RedHex()) .. have .. "|r" .. RoleHex("Muted") .. " / " .. need .. "|r")
        end
    end
    return y, true
end

local function Paint()
    local f = ProfessionSidecarUI.frame
    if not f or not f._anBody then
        return
    end
    local body = f._anBody
    ResetRows(body)
    local y = 0
    local any = false

    -- Selected recipe first: it is what the player is looking at.
    local hadRecipe
    y, hadRecipe = AddRecipeSection(body, y, true)
    any = hadRecipe

    -- Open profession: concentration pool + unspent knowledge.
    local snapShown = false
    local snap = ns.ProfessionSnapshotService and ns.ProfessionSnapshotService:GetSnapshot()
    if snap and (snap.concMax or (snap.knowledgeUnspent and snap.knowledgeUnspent > 0)) then
        local profName = SafeUiLine(snap.profession, SafeL("SIDECAR_TITLE", "Artisan Nexus"))
        y = AddSectionHeader(body, y, profName, not any)
        any = true
        snapShown = true
        if snap.concCurrent ~= nil and snap.concMax ~= nil then
            y = AddLine(body, y, SafeL("SIDECAR_LINE_CONCENTRATION", "Concentration"),
                ValueMax(snap.concCurrent, snap.concMax))
        end
        if snap.knowledgeUnspent and snap.knowledgeUnspent > 0 then
            y = AddLine(body, y, SafeL("SIDECAR_LINE_KNOWLEDGE", "Unspent knowledge"),
                GoldHex() .. snap.knowledgeUnspent .. "|r")
        end
    end

    -- Concentration plan: best gold-per-concentration recipe + plan totals.
    -- Concentration: where it earns most (the full plan is on the Hub's Concentration page).
    local rows = PlannerRows()
    if rows then
        local best = rows[1]
        local rs = ns.RecipeService
        local name = SafeUiLine(rs and rs:GetRecipeName(best.spellID),
            string.format(SafeL("RECIPE_ID_FMT", "Recipe %s"), tostring(best.spellID)))
        if not snapShown then
            y = AddSectionHeader(body, y, SafeL("SIDECAR_SEC_PLAN", "Concentration plan"), not any)
        end
        any = true
        y = AddLine(body, y, SafeL("SIDECAR_LINE_BEST_CONC", "Best use"), RoleHex("Bright") .. name .. "|r")
    end

    -- Crafting queue progress.
    local qs = ns.CraftingQueueService
    local sum = qs and qs.GetSummary and qs:GetSummary()
    if sum and sum.recipes and sum.recipes > 0 then
        y = AddSectionHeader(body, y, SafeL("HUB_PLAN_QUEUE_TITLE", "Crafting queue"), not any)
        any = true
        y = AddLine(body, y, SafeL("SIDECAR_LINE_CRAFTED", "Crafted"), ValueMax(sum.completed or 0, sum.total or 0))
    end

    -- Profession equipment hint.
    local hint = EquipmentHint()
    if hint then
        y = AddSectionHeader(body, y, SafeL("SIDECAR_SEC_EQUIPMENT", "Equipment"), not any)
        any = true
        y = AddFullWidthLine(body, y, hint)
    end

    if not any then
        y = AddEmptyMessage(body, y, SafeL("SIDECAR_EMPTY", "No queue or concentration data."))
    end

    -- Window height follows the content (title band + body + bottom inset).
    local W = ns.ArtisanWindow
    local chrome = (f._anHeaderH or 40) + ((W and W.ROW_BELOW_CHROME) or 10) + ((W and W.PADDING) or 10)
    f:SetHeight(math.ceil(chrome + y))
end

--- Dock beside ProfessionsFrame (absolute UIParent anchor) unless the player placed it.
local function Place(f, host)
    local W = ns.ArtisanWindow
    if UserPlaced() and W and W.RestorePosition and W.RestorePosition(f) then
        return
    end
    if W and W.TileBeside and W.TileBeside(f, host, DOCK_GAP) then
        return
    end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", host, "TOPRIGHT", DOCK_GAP, 0)
end

local function Anchor()
    local f = ProfessionSidecarUI.frame
    if not f then
        return
    end
    local host = _G.ProfessionsFrame
    if not host or not host.IsShown or not host:IsShown() or Hidden() or f._anDismissed then
        f:Hide()
        return
    end
    if not f:IsShown() then
        Place(f, host)
        f:Show()
    end
end

local function OpenHub()
    local addon = ns.ArtisanNexus
    if addon and addon.ShowMainWindow then
        addon:ShowMainWindow("plan")
    end
end

function ProfessionSidecarUI:Ensure()
    if self.frame then
        return
    end
    local W = ns.ArtisanWindow
    if not (W and W.Create) then
        return
    end
    local f = W.Create({
        name = "ArtisanNexusProfessionSidecar",
        title = SafeL("SIDECAR_TITLE", "Artisan Nexus"),
        posKey = POS_KEY,
        width = WINDOW_W,
        height = 160,
        resizable = false,
        -- Close hides it until the profession window opens again.
        onClose = function(fr) fr._anDismissed = true end,
        onDragStop = function()
            local p = Profile()
            if p and type(p.professionSidecar) == "table" then
                p.professionSidecar.userPlaced = true
            end
        end,
    })
    if not f then
        return
    end
    local body = f.contentArea
    body._anPool = { body = {}, small = {}, rule = {} }
    body._anUsed = {}
    f._anBody = body
    --- Click: the Hub's queue page (the window stays where it is; nothing closes).
    body:EnableMouse(true)
    body:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            OpenHub()
        end
    end)
    body:SetScript("OnEnter", function(selfBody)
        GameTooltip:SetOwner(selfBody, "ANCHOR_RIGHT")
        GameTooltip:SetText(SafeL("SIDECAR_CLICK_TT", "Click to open the Artisan Hub."), 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    body:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    self.frame = f
end

--- Hide with the profession window even when TRADE_SKILL_CLOSE does not fire.
local function HookHost()
    local host = _G.ProfessionsFrame
    if host and not ProfessionSidecarUI._hostHooked then
        ProfessionSidecarUI._hostHooked = true
        host:HookScript("OnHide", function()
            local f = ProfessionSidecarUI.frame
            if f then
                f._anDismissed = nil
                f:Hide()
            end
        end)
    end
end

function ProfessionSidecarUI:Refresh()
    self:Ensure()
    HookHost()
    Paint()
    Anchor()
end

--- Queue/snapshot/equipment/briefing messages often land in the same frame;
--- collapse them into one repaint on the next frame.
function ProfessionSidecarUI:ScheduleRefresh()
    if self._refreshPending then
        return
    end
    self._refreshPending = true
    C_Timer.After(0, function()
        ProfessionSidecarUI._refreshPending = false
        ProfessionSidecarUI:Refresh()
    end)
end

function ProfessionSidecarUI:Disable()
    local owner = self._eventOwner
    if owner then
        owner:UnregisterAllEvents()
        owner:UnregisterAllMessages()
        self._eventOwner = nil
    end
    if self.frame then
        self.frame:Hide()
    end
end

function ProfessionSidecarUI:Enable()
    self:Ensure()
    if self._eventOwner then
        return
    end
    local E = ns.Constants.EVENTS
    local owner = ns.NewEventOwner("ProfessionSidecarUI")
    self._eventOwner = owner
    owner:RegisterEvent("TRADE_SKILL_SHOW", function()
        if ProfessionSidecarUI.frame then
            ProfessionSidecarUI.frame._anDismissed = nil
        end
        ProfessionSidecarUI:Refresh()
    end)
    owner:RegisterEvent("TRADE_SKILL_CLOSE", function()
        ProfessionSidecarUI._recipe = nil
        local f = ProfessionSidecarUI.frame
        if f then
            f._anDismissed = nil
            f:Hide()
        end
    end)
    local function refresh()
        ProfessionSidecarUI:ScheduleRefresh()
    end
    for _, msg in ipairs({
        E.CRAFT_QUEUE_UPDATED, E.PROFESSION_SNAPSHOT_UPDATED, E.PROFESSION_EQUIPMENT_UPDATED,
        E.CONCENTRATION_PLAN_UPDATED, E.CRAFT_BRIEFING_UPDATED, E.BAG_STOCK_UPDATED, E.AH_PRICES_UPDATED,
    }) do
        owner:RegisterMessage(msg, refresh)
    end
    if EventRegistry and EventRegistry.RegisterCallback and not self._recipeCallback then
        self._recipeCallback = true
        EventRegistry:RegisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", function(_, recipeInfo)
            if type(recipeInfo) ~= "table" or not recipeInfo.recipeID then return end
            ProfessionSidecarUI._recipe = {
                recipeID = recipeInfo.recipeID, name = recipeInfo.name, learned = recipeInfo.learned,
            }
            ProfessionSidecarUI:ScheduleRefresh()
        end, ProfessionSidecarUI)
    end
    --- Theme / font: re-skin the shell and repaint (row inks and heights change).
    local function restyle()
        local f = ProfessionSidecarUI.frame
        if f and ns.ArtisanWindow and ns.ArtisanWindow.RefreshChrome then
            ns.ArtisanWindow.RefreshChrome(f)
        end
        if f and f:IsShown() then
            Paint()
        end
    end
    if E.THEME_CHANGED then owner:RegisterMessage(E.THEME_CHANGED, restyle) end
    if E.FONT_CHANGED then owner:RegisterMessage(E.FONT_CHANGED, restyle) end
end

ns.ProfessionSidecarUI = ProfessionSidecarUI
