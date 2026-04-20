--[[
    Lightweight gathering route heatmap on World Map.
    Records gather pickup coordinates and draws density dots for the current map.
]]

local ADDON_NAME, ns = ...

local ArtisanNexus = ns.ArtisanNexus
local E = ns.Constants and ns.Constants.EVENTS

---@class GatheringRouteOverlay
local GatheringRouteOverlay = {
    _inited = false,
    frame = nil,
    pointsPool = {},
    activeDots = {},
}

local MAX_POINTS_PER_MAP = 280
local GRID = 52

local function IsEnabled()
    local db = ns.db and ns.db.profile
    return db and db.routeHeatmapEnabled == true and (not ns.IsOpenWorld or ns.IsOpenWorld())
end

local function GetStore()
    if not (ns.db and ns.db.global) then
        return nil
    end
    ns.db.global.gatherRoutePoints = ns.db.global.gatherRoutePoints or {}
    return ns.db.global.gatherRoutePoints
end

local function GetPlayerMapPoint()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not mapID then
        return nil
    end
    local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then
        return nil
    end
    local x = pos.GetX and pos:GetX() or pos.x
    local y = pos.GetY and pos:GetY() or pos.y
    if not x or not y then
        return nil
    end
    return mapID, x, y
end

local function RecordPoint()
    local store = GetStore()
    if not store then
        return
    end
    local mapID, x, y = GetPlayerMapPoint()
    if not mapID then
        return
    end
    local t = store[mapID]
    if type(t) ~= "table" then
        t = {}
        store[mapID] = t
    end
    t[#t + 1] = { x = x, y = y, t = time() }
    while #t > MAX_POINTS_PER_MAP do
        table.remove(t, 1)
    end
end

local function GetMapChild()
    local wm = WorldMapFrame
    if not wm or not wm.ScrollContainer or not wm.ScrollContainer.Child then
        return nil
    end
    return wm.ScrollContainer.Child
end

local function AcquireDot(self)
    local dot = table.remove(self.pointsPool)
    if dot then
        dot:Show()
        return dot
    end
    local d = self.frame:CreateTexture(nil, "OVERLAY")
    d:SetTexture("Interface\\Buttons\\WHITE8x8")
    d:SetBlendMode("ADD")
    return d
end

local function ReleaseDots(self, fromIdx)
    for i = fromIdx, #self.activeDots do
        local d = self.activeDots[i]
        d:Hide()
        self.pointsPool[#self.pointsPool + 1] = d
        self.activeDots[i] = nil
    end
end

function GatheringRouteOverlay:Refresh()
    if not self.frame then
        return
    end
    if not IsEnabled() then
        self.frame:Hide()
        return
    end
    local child = GetMapChild()
    if not child or not child:IsShown() then
        self.frame:Hide()
        return
    end
    self.frame:SetParent(child)
    self.frame:SetAllPoints(child)
    self.frame:Show()

    local mapID = WorldMapFrame and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    local store = GetStore()
    local points = mapID and store and store[mapID] or nil
    if type(points) ~= "table" or #points < 1 then
        self.frame:Hide()
        return
    end

    local density = {}
    for i = 1, #points do
        local p = points[i]
        local bx = math.floor((p.x or 0) * GRID)
        local by = math.floor((p.y or 0) * GRID)
        local key = bx .. ":" .. by
        local row = density[key]
        if not row then
            row = { x = (bx + 0.5) / GRID, y = (by + 0.5) / GRID, n = 0 }
            density[key] = row
        end
        row.n = row.n + 1
    end

    local idx = 1
    local w, h = child:GetWidth() or 1000, child:GetHeight() or 700
    for _, row in pairs(density) do
        local dot = AcquireDot(self)
        self.activeDots[idx] = dot
        dot:SetParent(self.frame)
        local n = row.n or 1
        local sz = math.min(11, 3 + n)
        dot:SetSize(sz, sz)
        local A = ns.UI_COLORS and ns.UI_COLORS.accent
        local ar, ag, ab = A and A[1] or 0.36, A and A[2] or 0.55, A and A[3] or 0.70
        dot:SetVertexColor(ar, ag, ab, math.min(0.88, 0.18 + n * 0.10))
        dot:ClearAllPoints()
        dot:SetPoint("TOPLEFT", self.frame, "TOPLEFT", (row.x * w) - (sz / 2), -(row.y * h) - (sz / 2))
        idx = idx + 1
    end
    ReleaseDots(self, idx)
end

function GatheringRouteOverlay:OnGatherRecorded()
    if not IsEnabled() then
        return
    end
    RecordPoint()
    self:Refresh()
end

function GatheringRouteOverlay:Init()
    if self._inited then
        return
    end
    self._inited = true
    self.frame = CreateFrame("Frame", "ArtisanNexusGatherRouteHeatmap", UIParent)
    self.frame:Hide()
    if ArtisanNexus and ArtisanNexus.RegisterMessage and E and E.GATHERING_LOOT_RECORDED then
        ArtisanNexus:RegisterMessage(E.GATHERING_LOOT_RECORDED, function()
            GatheringRouteOverlay:OnGatherRecorded()
        end)
    end
    local watch = CreateFrame("Frame")
    watch:RegisterEvent("PLAYER_ENTERING_WORLD")
    watch:RegisterEvent("ZONE_CHANGED")
    watch:RegisterEvent("ZONE_CHANGED_INDOORS")
    watch:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    watch:SetScript("OnEvent", function()
        GatheringRouteOverlay:Refresh()
    end)
    if WorldMapFrame then
        WorldMapFrame:HookScript("OnShow", function()
            GatheringRouteOverlay:Refresh()
        end)
        if hooksecurefunc and WorldMapFrame.SetMapID then
            hooksecurefunc(WorldMapFrame, "SetMapID", function()
                GatheringRouteOverlay:Refresh()
            end)
        end
    end
end

ns.GatheringRouteOverlay = GatheringRouteOverlay
