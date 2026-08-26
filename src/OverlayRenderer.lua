-- =========================================================
-- FS25_MasterHUD - OverlayRenderer
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Draws suite overlays with the same chrome primitives used by the base-game
-- vehicle HUD: hudExtension top/middle/bottom panels and the three-part trailer
-- fill-level progress bar. Coordinates are normalized 0-1 screen coordinates
-- (origin bottom-left). The overlay objects are shared and repositioned for each
-- panel/bar, just as the vanilla HUD extensions do.
--
-- API confirmed from the shipped SoilFertilizer HUD:
--   createImageOverlay("dataS/menu/base/graph_pixel.dds")
--   setOverlayColor(ov, r, g, b, a) ; renderOverlay(ov, x, y, w, h)
--   setTextBold / setTextColor / setTextAlignment / renderText
--   RenderText.ALIGN_LEFT / ALIGN_RIGHT ; delete(ov)
-- =========================================================

-- BUILD 17:57 + ATTN 18:02 (Wizard hot-reload law, FS25-HotReload-Guide.md Part 1):
-- reuse the existing class table on Ctrl+R reload so updated methods land on the
-- table live metatables already reference, instead of orphaning it.
OverlayRenderer = OverlayRenderer or {}
local OverlayRenderer_mt = Class(OverlayRenderer)

OverlayRenderer.MARGIN = 0.010    -- gap from the screen edge
OverlayRenderer.GAP    = 0.006    -- gap between stacked panels
OverlayRenderer.BG     = { 0, 0, 0 }

function OverlayRenderer.new()
    local self = setmetatable({}, OverlayRenderer_mt)
    self.bgOverlay = nil
    self.panelTop = nil
    self.panelMiddle = nil
    self.panelBottom = nil
    self.progressBar = nil
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
    if self.panelTop ~= nil then
        self.panelTop:delete()
        self.panelTop = nil
    end
    if self.panelMiddle ~= nil then
        self.panelMiddle:delete()
        self.panelMiddle = nil
    end
    if self.panelBottom ~= nil then
        self.panelBottom:delete()
        self.panelBottom = nil
    end
    if self.progressBar ~= nil then
        self.progressBar:delete()
        self.progressBar = nil
    end
end

-- Lazily create the exact three-piece background used by the base-game feed
-- mixer, stationary baler and yarder HUD extensions. Lazy creation is important
-- for live reload: constructor changes cannot reach an already-running instance.
function OverlayRenderer:_ensureVanillaPanel()
    if self.panelTop ~= nil and self.panelMiddle ~= nil and self.panelBottom ~= nil then
        return true
    end
    if g_overlayManager == nil or g_overlayManager.createOverlay == nil then
        return false
    end

    local top, middle, bottom
    local ok = pcall(function()
        top = g_overlayManager:createOverlay("gui.hudExtension_top", 0, 0, 0, 0)
        middle = g_overlayManager:createOverlay("gui.hudExtension_middle", 0, 0, 0, 0)
        bottom = g_overlayManager:createOverlay("gui.hudExtension_bottom", 0, 0, 0, 0)
    end)
    if not ok or top == nil or middle == nil or bottom == nil then
        if top ~= nil then top:delete() end
        if middle ~= nil then middle:delete() end
        if bottom ~= nil then bottom:delete() end
        return false
    end

    self.panelTop = top
    self.panelMiddle = middle
    self.panelBottom = bottom
    return true
end

-- Render a base-game HUD-extension panel. x/y are the bottom-left corner.
-- Returns true when native slices rendered, false so a standalone caller can
-- retain its former graph_pixel fallback.
function OverlayRenderer:renderPanel(x, y, width, height, alpha)
    if width == nil or height == nil or width <= 0 or height <= 0 then
        return false
    end
    if not self:_ensureVanillaPanel() then
        return false
    end

    local uiScale = 1
    if g_gameSettings ~= nil and g_gameSettings.getValue ~= nil
    and GameSettings ~= nil and GameSettings.SETTING ~= nil then
        uiScale = g_gameSettings:getValue(GameSettings.SETTING.UI_SCALE) or 1
    end
    local edgeHeight = 6 / 1080 * uiScale
    if getNormalizedScreenValues ~= nil then
        local _, normalizedHeight = getNormalizedScreenValues(0, 6 * uiScale)
        edgeHeight = normalizedHeight or edgeHeight
    end
    edgeHeight = math.min(edgeHeight, height * 0.5)

    local color = HUD ~= nil and HUD.COLOR ~= nil and HUD.COLOR.BACKGROUND
               or { 0, 0, 0, 0.75 }
    local panelAlpha = alpha
    if panelAlpha == nil then panelAlpha = color[4] or 0.75 end

    self.panelTop:setColor(color[1], color[2], color[3], panelAlpha)
    self.panelMiddle:setColor(color[1], color[2], color[3], panelAlpha)
    self.panelBottom:setColor(color[1], color[2], color[3], panelAlpha)

    self.panelBottom:setDimension(width, edgeHeight)
    self.panelBottom:setPosition(x, y)
    self.panelMiddle:setDimension(width, math.max(0, height - edgeHeight * 2))
    self.panelMiddle:setPosition(x, y + edgeHeight)
    self.panelTop:setDimension(width, edgeHeight)
    self.panelTop:setPosition(x, y + height - edgeHeight)

    self.panelBottom:render()
    self.panelMiddle:render()
    self.panelTop:render()
    return true
end

function OverlayRenderer:_ensureProgressBar()
    if self.progressBar ~= nil then return true end
    if ThreePartOverlay == nil or ThreePartOverlay.new == nil then return false end

    local bar
    local ok = pcall(function()
        bar = ThreePartOverlay.new()
        bar:setLeftPart("gui.progressbar_left", 0, 0)
        bar:setMiddlePart("gui.progressbar_middle", 0, 0)
        bar:setRightPart("gui.progressbar_right", 0, 0)
    end)
    if not ok or bar == nil or bar.leftPart == nil
    or bar.middlePart == nil or bar.rightPart == nil then
        if bar ~= nil and bar.delete ~= nil then bar:delete() end
        return false
    end
    self.progressBar = bar
    return true
end

local function setThreePartGeometry(bar, width, height, value)
    local aspect = g_screenAspectRatio or (16 / 9)
    local partWidth = math.min(width * 0.5, height / (2 * aspect))
    local middleWidth = math.max(0, width - partWidth * 2)
    bar:setLeftPart(nil, partWidth, height)
    bar:setMiddlePart(nil, middleWidth * (value or 1), height)
    bar:setRightPart(nil, partWidth, height)
end

-- Render the exact three-piece track/fill construction used by
-- FillLevelsDisplay. ghostValue optionally draws a translucent projected value
-- behind the solid value (Soil's application preview) without changing the
-- native rounded silhouette.
function OverlayRenderer:renderProgressBar(x, y, width, height, value, color, ghostValue, ghostColor)
    if width == nil or height == nil or width <= 0 or height <= 0 then
        return false
    end
    if not self:_ensureProgressBar() then return false end

    value = math.max(0, math.min(1, value or 0))
    ghostValue = math.max(value, math.min(1, ghostValue or value))

    local bg = HUD ~= nil and HUD.COLOR ~= nil and HUD.COLOR.BACKGROUND_DARK
            or { 0.08, 0.08, 0.08, 0.9 }
    local active = HUD ~= nil and HUD.COLOR ~= nil and HUD.COLOR.ACTIVE
                or { 0.33, 0.78, 0.05, 1 }
    color = color or active
    ghostColor = ghostColor or color

    setThreePartGeometry(self.progressBar, width, height, 1)
    self.progressBar:setColor(bg[1], bg[2], bg[3], bg[4] or 1)
    self.progressBar:setPosition(x, y)
    self.progressBar:render()

    if ghostValue > value then
        setThreePartGeometry(self.progressBar, width, height, ghostValue)
        self.progressBar:setColor(ghostColor[1], ghostColor[2], ghostColor[3],
            (ghostColor[4] or 1) * 0.35)
        self.progressBar:setPosition(x, y)
        self.progressBar:render()
    end

    if value > 0 then
        setThreePartGeometry(self.progressBar, width, height, value)
        self.progressBar:setColor(color[1], color[2], color[3], color[4] or 1)
        self.progressBar:setPosition(x, y)
        self.progressBar:render()
    end
    return true
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
        -- x centered on 0.50 with the stack drawing DOWN - clear of every vanilla
        -- corner (status top-right, minimap bottom-left, speedometer bottom-right).
        -- This is also the DEFAULT anchor; a companion that explicitly chose a corner
        -- keeps it. BUILD 12:25 (Sam DESIGN 12:23): top edge raised to y=0.94.
        left = 0.5 - width * 0.5
        top  = 0.94 - stackOffset
    else -- ANCHOR_TOP_RIGHT
        left = 1 - m - width
        top  = 1 - m - stackOffset
    end

    -- Background panel. Prefer the same three-piece chrome as base-game vehicle
    -- HUD extensions; graph_pixel remains a defensive fallback only.
    if not self:renderPanel(left, top - height, width, height, config.bgAlpha)
    and self:_ensureBg() then
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

-- =========================================================
-- BUILD 17:57 + ATTN 18:02 (hot-reload guide Part 2): force-patch the live
-- instance after a Ctrl+R reload - the singleton's renderer.
if g_masterHUD ~= nil and g_masterHUD.renderer ~= nil then
    local inst = g_masterHUD.renderer
    for k, v in pairs(OverlayRenderer) do
        if type(v) == "function" then
            inst[k] = v
        end
    end
end
