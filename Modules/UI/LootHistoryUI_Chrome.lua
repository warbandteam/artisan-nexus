--[[
    Loot History window chrome helpers (bounds, resize limits).
    Frame shell build remains in LootHistoryUI.lua; staged catalog in LootHistoryUI_Draw.lua.
]]

local ADDON_NAME, ns = ...

local M = ns.LootHistoryUI_Chrome or {}
ns.LootHistoryUI_Chrome = M

---@param minW number
---@param maxW number
---@param minH number
---@param maxH number
---@return number maxW
---@return number maxH
function M.GetFrameBounds(minW, maxW, minH, maxH)
    local p = UIParent
    local outW, outH = maxW, maxH
    if p and p.GetWidth and p.GetHeight then
        local pw = p:GetWidth() or 1200
        local ph = p:GetHeight() or 800
        outW = math.min(maxW, math.max(minW + 80, pw - 24))
        outH = math.min(maxH, math.max(minH + 80, ph - 24))
    end
    return outW, outH
end

function M.ApplyResizeBounds(frame, minW, minH, maxW, maxH)
    if not frame then
        return
    end
    local rbW, rbH = M.GetFrameBounds(minW, maxW, minH, maxH)
    if frame.SetResizeBounds then
        pcall(function()
            frame:SetResizeBounds(minW, minH, rbW, rbH)
        end)
    elseif frame.SetMinResize then
        frame:SetMinResize(minW, minH)
        frame:SetMaxResize(rbW, rbH)
    end
end

return M
