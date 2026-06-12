-- community_image_fit.lua — pure aspect-preserving fit math, shared by the
-- Community-tab thumbnail and the enlarge window. No dxgui; unit-tested.
local M = {}

-- Scale native (nW × nH) to fit inside (boxW × boxH), preserving aspect ratio.
-- Returns integer (w, h). Returns (0, 0) if any input is non-positive.
function M.fit(nW, nH, boxW, boxH)
    nW = tonumber(nW) or 0; nH = tonumber(nH) or 0
    boxW = tonumber(boxW) or 0; boxH = tonumber(boxH) or 0
    if nW <= 0 or nH <= 0 or boxW <= 0 or boxH <= 0 then return 0, 0 end
    local scale = math.min(boxW / nW, boxH / nH)
    return math.floor(nW * scale), math.floor(nH * scale)
end

return M
