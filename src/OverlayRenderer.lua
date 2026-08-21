-- =========================================================
-- FS25_MasterHUD - OverlayRenderer
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Draws a text overlay (background panel + lines) with the FS25 Giants
-- rendering functions, using normalized 0-1 screen coordinates (origin
-- bottom-left). One shared background image is reused for every panel.
--
-- API confirmed from the shipped SoilFertilizer HUD:
--   createImageOverlay("dataS/menu/base/graph_pixel.dds")
--   setOverlayColor(ov, r, g, b, a) ; renderOverlay(ov, x, y, w, h)
--   setTextBold / setTextColor / setTextAlignment / renderText
--   RenderText.ALIGN_LEFT / ALIGN_RIGHT ; delete(ov)
-- =========================================================

OverlayRenderer = {}
local OverlayRenderer_mt = Class(OverlayRenderer)

OverlayRenderer.MARGIN = 0.010    -- gap from the screen edge
OverlayRenderer.GAP    = 0.006    -- gap between stacked panels
OverlayRenderer.BG     = { 0, 0, 0 }

function OverlayRenderer.new()
    local self = setmetatable({}, OverlayRenderer_mt)
    self.bgOverlay = nil
    return self
end

function OverlayRenderer:_ensureBg()
    if self.bgOverlay == nil and createImageOverlay ~= nil then
        self.bgOverlay = createImageOverlay("dataS/menu/base/graph_pixel.dds")
    end
    return self.bgOverlay ~= nil
end

function OverlayRenderer:delete()
    if self.bgOverlay ~= nil then
        delete(self.bgOverlay)
        self.bgOverlay = nil
    end
end

-- Normalized text height for a config fontSize (treated as ~pixels at 1080p).
local function textSizeOf(config)
    return (config.fontSize or 14) / 1000
end

-- Height (normalized) a text overlay will occupy for a given line count.
function OverlayRenderer:measure(config, lineCount)
    local ts = textSizeOf(config)
    local lineH = ts * 1.45
    local pad = config.padding or 0.005
    return pad * 2 + math.max(1, lineCount) * lineH
end

-- Render one text overlay. `lines` is a list of strings or { left, right }
-- tables. `stackOffset` is how far (normalized) this panel is inset from its
-- anchor along the vertical stack. Returns the height consumed (for stacking).
function OverlayRenderer:renderText(config, lines, stackOffset)
    lines = lines or {}
    local ts    = textSizeOf(config)
    local lineH = ts * 1.45
    local pad   = config.padding or 0.005
    local width = config.width or 0.25
    local height = self:measure(config, #lines)
    -- BUILD 06:43: default anchor is now the top-center glance stack (see below).
    local anchor = config.anchor or "ANCHOR_TOP_CENTER"

    -- Panel left edge and top edge from the anchor.
    local left, top
    local m = OverlayRenderer.MARGIN
    if anchor == "ANCHOR_TOP_LEFT" then
        left = m
        top  = 1 - m - stackOffset
    elseif anchor == "ANCHOR_BOTTOM_LEFT" then
        left = m
        top  = m + stackOffset + height
    elseif anchor == "ANCHOR_BOTTOM_RIGHT" then
        left = 1 - m - width
        top  = m + stackOffset + height
    elseif anchor == "ANCHOR_TOP_CENTER" then
        -- BUILD 06:43 (Sam DESIGN 06:42): the suite glance stack's home is top-center,
        -- x centered on 0.50 with the stack's top edge at y=0.92, drawing DOWN - clear
        -- of every vanilla corner (status top-right, minimap bottom-left, speedometer
        -- bottom-right). This is also the new DEFAULT anchor; a companion that
        -- explicitly chose a corner keeps it.
        left = 0.5 - width * 0.5
        top  = 0.92 - stackOffset
    else -- ANCHOR_TOP_RIGHT
        left = 1 - m - width
        top  = 1 - m - stackOffset
    end

    -- Background panel (renderOverlay takes the bottom-left corner).
    if self:_ensureBg() then
        local a = config.bgAlpha or 0.6
        setOverlayColor(self.bgOverlay, OverlayRenderer.BG[1], OverlayRenderer.BG[2], OverlayRenderer.BG[3], a)
        renderOverlay(self.bgOverlay, left, top - height, width, height)
    end

    -- Text lines, top to bottom.
    setTextBold(false)
    for i, line in ipairs(lines) do
        local baseY = top - pad - i * lineH + ts * 0.25
        local col = config.textColor or { 1, 1, 1, 1 }
        setTextColor(col[1], col[2], col[3], col[4] or 1)
        if type(line) == "table" then
            setTextAlignment(RenderText.ALIGN_LEFT)
            renderText(left + pad, baseY, ts, tostring(line.left or ""))
            setTextAlignment(RenderText.ALIGN_RIGHT)
            renderText(left + width - pad, baseY, ts, tostring(line.right or ""))
        else
            setTextAlignment(RenderText.ALIGN_LEFT)
            renderText(left + pad, baseY, ts, tostring(line))
        end
    end
    setTextAlignment(RenderText.ALIGN_LEFT)

    return height + OverlayRenderer.GAP
end
