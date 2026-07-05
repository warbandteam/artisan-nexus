--[[
    Compact profession sidecar beside the Blizzard trade skill window (queue + snapshot).
]]

local ADDON_NAME, ns = ...

local ProfessionSidecarUI = { frame = nil }

local function Hidden()
    local p = ns.db and ns.db.profile and ns.db.profile.professionSidecar
    return p and p.hidden == true
end

local function Anchor()
    local f = ProfessionSidecarUI.frame
    if not f then
        return
    end
    local host = _G.ProfessionsFrame or _G.TradeSkillFrame
    if not host or not host.IsShown or not host:IsShown() or Hidden() then
        f:Hide()
        return
    end
    f:SetParent(host)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", host, "TOPRIGHT", 6, -8)
    f:Show()
end

local function Paint()
    local f = ProfessionSidecarUI.frame
    if not f or not f.body then
        return
    end
    local lines = {}
    local snap = ns.ProfessionSnapshotService
    if snap and snap.GetChipText then
        local chip = snap:GetChipText()
        if chip and chip ~= "" then
            lines[#lines + 1] = chip
        end
    end
    local qs = ns.CraftingQueueService
    if qs and qs.GetSummary then
        local sum = qs:GetSummary()
        if sum and sum.recipes and sum.recipes > 0 then
            lines[#lines + 1] = string.format("Queue %d/%d", sum.completed or 0, sum.total or 0)
        end
    end
    local p = ns.db and ns.db.profile
    if not p or p.craftBriefingEquipmentHints ~= false then
        local pes = ns.ProfessionEquipmentService
        local hints = pes and pes.GetHints and pes:GetHints()
        if type(hints) == "table" and hints[1] and hints[1].message then
            lines[#lines + 1] = hints[1].message
        end
    end
    if #lines < 1 then
        lines[#lines + 1] = (ns.L and ns.L["SIDECAR_EMPTY"]) or "Open a profession to see queue info."
    end
    f.body:SetText(table.concat(lines, "\n"))
end

function ProfessionSidecarUI:Ensure()
    if self.frame then
        return
    end
    local layout = ns.UI_LAYOUT or {}
    local fonts = ns.UI_FONTS or {}
    local f = CreateFrame("Frame", "ArtisanNexusProfessionSidecar", UIParent, "BackdropTemplate")
    f:SetSize(layout.SIDECAR_WIDTH or 184, layout.SIDECAR_MIN_HEIGHT or 108)
    if ns.UI_StylePanelInset and ns.UI_COLORS then
        ns.UI_StylePanelInset(f, ns.UI_COLORS.bgCard, ns.UI_COLORS.border)
    elseif ns.UI_ApplyVisuals and ns.UI_COLORS then
        ns.UI_ApplyVisuals(f, ns.UI_COLORS.bgCard or { 0.06, 0.06, 0.08, 0.92 }, ns.UI_COLORS.border)
    else
        f:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        f:SetBackdropColor(0.06, 0.06, 0.08, 0.92)
        f:SetBackdropBorderColor(0.35, 0.35, 0.40, 0.9)
    end
    local title = f:CreateFontString(nil, "OVERLAY", fonts.WINDOW_SECTION or "GameFontHighlightMedium")
    title:SetPoint("TOPLEFT", 8, -6)
    title:SetText((ns.L and ns.L["SIDECAR_TITLE"]) or "Artisan Nexus")
    local body = f:CreateFontString(nil, "OVERLAY", fonts.WINDOW_BODY or "GameFontNormal")
    body:SetPoint("TOPLEFT", 8, -26)
    body:SetPoint("BOTTOMRIGHT", -8, 8)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetWordWrap(true)
    f.body = body
    self.frame = f
end

function ProfessionSidecarUI:Refresh()
    self:Ensure()
    Paint()
    Anchor()
end

function ProfessionSidecarUI:Enable()
    self:Ensure()
    if self._eventOwner then
        return
    end
    local E = ns.Constants and ns.Constants.EVENTS
    local owner = ns.NewEventOwner("ProfessionSidecarUI")
    self._eventOwner = owner
    owner:RegisterEvent("TRADE_SKILL_SHOW", function()
        ProfessionSidecarUI:Refresh()
    end)
    owner:RegisterEvent("TRADE_SKILL_CLOSE", function()
        if ProfessionSidecarUI.frame then
            ProfessionSidecarUI.frame:Hide()
        end
    end)
    if E and E.CRAFT_QUEUE_UPDATED then
        owner:RegisterMessage(E.CRAFT_QUEUE_UPDATED, function()
            ProfessionSidecarUI:Refresh()
        end)
    end
    if E and E.PROFESSION_SNAPSHOT_UPDATED then
        owner:RegisterMessage(E.PROFESSION_SNAPSHOT_UPDATED, function()
            ProfessionSidecarUI:Refresh()
        end)
    end
    if E and E.PROFESSION_EQUIPMENT_UPDATED then
        owner:RegisterMessage(E.PROFESSION_EQUIPMENT_UPDATED, function()
            ProfessionSidecarUI:Refresh()
        end)
    end
    if E and E.CRAFT_BRIEFING_UPDATED then
        owner:RegisterMessage(E.CRAFT_BRIEFING_UPDATED, function()
            ProfessionSidecarUI:Refresh()
        end)
    end
end

--- UI-mode switch: drop the cached frame so Ensure rebuilds with the active skin.
function ProfessionSidecarUI:ResetForUiMode()
    if self.frame then
        self.frame:Hide()
        self.frame = nil
    end
end

ns.ProfessionSidecarUI = ProfessionSidecarUI
