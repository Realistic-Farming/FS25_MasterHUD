-- =========================================================
-- FS25_MasterHUD - core class
-- =========================================================
-- Author: TisonK
-- =========================================================
-- UI renderer bedrock for the Realistic Farming ecosystem. Owns the single
-- draw listener that renders every companion overlay in a pull model:
-- companions flip a dirty flag; MasterHUD calls their fetch callback once
-- per draw frame when dirty, so string.format work is decoupled from the
-- per-frame simulation math.
--
-- Three registration paths (A1 / F11):
--   registerOverlay(id, config, fetchCallback)  simple text MasterHUD renders
--   subscribe(id, { draw, isDirty })            self-drawn display element
--   registerPanel(id, { draw, onMouse, onInput, isFullscreen, adminOnly })
--                                               self-draw + input
-- MasterHUD owns the single draw loop, menu-suspend, and unload cleanup for
-- all three. Positional / world-space overlays (e.g. SoilFertilizer's spray /
-- harvest / tillage trails) do NOT fit the corner-anchored overlay model;
-- they register through subscribe() and draw their own world-space content,
-- so MasterHUD still owns ordering and suspend but does not lay them out.
-- =========================================================

MasterHUD = {}
local MasterHUD_mt = Class(MasterHUD)

local VALID_ANCHORS = {
    ANCHOR_TOP_LEFT = true, ANCHOR_TOP_RIGHT = true,
    ANCHOR_BOTTOM_LEFT = true, ANCHOR_BOTTOM_RIGHT = true,
}

function MasterHUD.new()
    local self = setmetatable({}, MasterHUD_mt)

    self.overlays      = {}   -- id -> { config, fetchCallback, cachedLines, isDirty, visible }
    self.overlayOrder  = {}
    self.selfDraws     = {}   -- id -> { draw, isDirty, visible }
    self.selfDrawOrder = {}
    self.panels        = {}   -- id -> { draw, onMouse, onInput, isFullscreen, adminOnly, visible }
    self.panelOrder    = {}
    self.suspended     = false

    self.renderer = OverlayRenderer.new()
    return self
end

-- =========================================================
-- Registration: simple text overlay
-- =========================================================

function MasterHUD:registerOverlay(id, config, fetchCallback)
    if type(id) ~= "string" or id == "" then
        MHLogger.warning("registerOverlay: invalid id '%s'", tostring(id)); return false
    end
    if type(fetchCallback) ~= "function" then
        MHLogger.warning("registerOverlay('%s'): fetchCallback must be a function", id); return false
    end
    config = config or {}
    if config.anchor ~= nil and not VALID_ANCHORS[config.anchor] then
        MHLogger.warning("registerOverlay('%s'): unknown anchor '%s', using ANCHOR_TOP_RIGHT", id, tostring(config.anchor))
        config.anchor = "ANCHOR_TOP_RIGHT"
    end
    if self.overlays[id] == nil then table.insert(self.overlayOrder, id) end
    self.overlays[id] = {
        config = config,
        fetchCallback = fetchCallback,
        cachedLines = {},
        isDirty = true,
        visible = config.visible ~= false,
    }
    MHLogger.debug("Registered overlay '%s'", id)
    return true
end

-- =========================================================
-- Registration: self-drawn element
-- =========================================================

function MasterHUD:subscribe(id, spec)
    if type(id) ~= "string" or id == "" or type(spec) ~= "table" or type(spec.draw) ~= "function" then
        MHLogger.warning("subscribe('%s'): needs { draw = fn }", tostring(id)); return false
    end
    if self.selfDraws[id] == nil then table.insert(self.selfDrawOrder, id) end
    self.selfDraws[id] = { draw = spec.draw, isDirty = spec.isDirty, visible = true }
    MHLogger.debug("Subscribed self-draw '%s'", id)
    return true
end

-- =========================================================
-- Registration: interactive panel
-- =========================================================

function MasterHUD:registerPanel(id, spec)
    if type(id) ~= "string" or id == "" or type(spec) ~= "table" or type(spec.draw) ~= "function" then
        MHLogger.warning("registerPanel('%s'): needs { draw = fn }", tostring(id)); return false
    end
    if self.panels[id] == nil then table.insert(self.panelOrder, id) end
    self.panels[id] = {
        draw = spec.draw,
        onMouse = spec.onMouse,
        onInput = spec.onInput,
        isFullscreen = spec.isFullscreen == true,
        adminOnly = spec.adminOnly == true,
        visible = true,
    }
    MHLogger.debug("Registered panel '%s'", id)
    return true
end

-- =========================================================
-- Dirty / visibility / unregister
-- =========================================================

function MasterHUD:markDirty(id)
    local o = self.overlays[id]
    if o ~= nil then o.isDirty = true end
end

function MasterHUD:setOverlayVisible(id, visible)
    local entry = self.overlays[id] or self.selfDraws[id] or self.panels[id]
    if entry ~= nil then
        entry.visible = visible == true
        if type(entry.isDirty) == "boolean" and visible then entry.isDirty = true end
    end
end

local function removeFromOrder(order, id)
    for i = #order, 1, -1 do
        if order[i] == id then table.remove(order, i) end
    end
end

function MasterHUD:unregisterOverlay(id)
    if self.overlays[id] ~= nil then
        self.overlays[id] = nil
        removeFromOrder(self.overlayOrder, id)
    end
    if self.selfDraws[id] ~= nil then
        self.selfDraws[id] = nil
        removeFromOrder(self.selfDrawOrder, id)
    end
end

function MasterHUD:unregisterPanel(id)
    if self.panels[id] ~= nil then
        self.panels[id] = nil
        removeFromOrder(self.panelOrder, id)
    end
end

-- =========================================================
-- Admin gate (interactive adminOnly panels)
-- =========================================================

function MasterHUD:isLocalAdmin()
    if g_currentMission == nil then return false end
    if g_currentMission:getIsServer() then return true end
    local ok, res = pcall(function()
        local um = g_currentMission.userManager
        if um ~= nil and um.getUserByUserId ~= nil and g_currentMission.playerUserId ~= nil then
            local u = um:getUserByUserId(g_currentMission.playerUserId)
            return u ~= nil and u.getIsMasterUser ~= nil and u:getIsMasterUser()
        end
        return false
    end)
    return ok and res == true
end

-- =========================================================
-- Draw loop
-- =========================================================

function MasterHUD:onDraw()
    -- Suspend while any menu or dialog is up (proven guard from SoilFertilizer).
    self.suspended = g_gui ~= nil and (g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible())
    if self.suspended then return end
    self:draw()
end

function MasterHUD:draw()
    -- Text overlays: refresh dirty caches, group by anchor, stack by priority.
    local byAnchor = {
        ANCHOR_TOP_LEFT = {}, ANCHOR_TOP_RIGHT = {},
        ANCHOR_BOTTOM_LEFT = {}, ANCHOR_BOTTOM_RIGHT = {},
    }
    for _, id in ipairs(self.overlayOrder) do
        local o = self.overlays[id]
        if o ~= nil and o.visible then
            if o.isDirty then
                local ok, lines = pcall(o.fetchCallback)
                if ok and type(lines) == "table" then
                    o.cachedLines = lines
                    o.isDirty = false
                elseif not ok then
                    MHLogger.error("overlay '%s' fetch failed: %s (keeping last cache)", id, tostring(lines))
                end
            end
            local a = o.config.anchor or "ANCHOR_TOP_RIGHT"
            table.insert(byAnchor[a], o)
        end
    end
    for _, list in pairs(byAnchor) do
        table.sort(list, function(x, y)
            return (x.config.priority or 10) < (y.config.priority or 10)
        end)
        local offset = 0
        for _, o in ipairs(list) do
            offset = offset + self.renderer:renderText(o.config, o.cachedLines or {}, offset)
        end
    end

    -- Self-drawn elements.
    for _, id in ipairs(self.selfDrawOrder) do
        local s = self.selfDraws[id]
        if s ~= nil and s.visible then
            pcall(s.draw)
        end
    end

    -- Interactive panels (admin-gated ones only draw for the local admin).
    for _, id in ipairs(self.panelOrder) do
        local p = self.panels[id]
        if p ~= nil and p.visible and (not p.adminOnly or self:isLocalAdmin()) then
            pcall(p.draw)
        end
    end
end

-- =========================================================
-- Input dispatch (interactive panels)
-- =========================================================

function MasterHUD:onMouseEvent(posX, posY, isDown, isUp, button)
    if self.suspended then return end
    for _, id in ipairs(self.panelOrder) do
        local p = self.panels[id]
        if p ~= nil and p.visible and type(p.onMouse) == "function"
            and (not p.adminOnly or self:isLocalAdmin()) then
            local ok, handled = pcall(p.onMouse, posX, posY, isDown, isUp, button)
            if ok and handled then return end
        end
    end
end

function MasterHUD:onKeyEvent(action, value)
    if self.suspended then return end
    for _, id in ipairs(self.panelOrder) do
        local p = self.panels[id]
        if p ~= nil and p.visible and type(p.onInput) == "function"
            and (not p.adminOnly or self:isLocalAdmin()) then
            local ok, handled = pcall(p.onInput, action, value)
            if ok and handled then return end
        end
    end
end

function MasterHUD:delete()
    if self.renderer ~= nil then
        self.renderer:delete()
    end
    self.overlays = {}
    self.overlayOrder = {}
    self.selfDraws = {}
    self.selfDrawOrder = {}
    self.panels = {}
    self.panelOrder = {}
end

-- =========================================================
-- Introspection (console command)
-- =========================================================

function MasterHUD:getStatus()
    local lines = {}
    table.insert(lines, string.format("MasterHUD: %d overlay(s), %d self-draw(s), %d panel(s), suspended=%s",
        #self.overlayOrder, #self.selfDrawOrder, #self.panelOrder, tostring(self.suspended)))
    for _, id in ipairs(self.overlayOrder) do
        local o = self.overlays[id]
        table.insert(lines, string.format("  overlay %s (anchor %s, visible %s)",
            id, o.config.anchor or "ANCHOR_TOP_RIGHT", tostring(o.visible)))
    end
    for _, id in ipairs(self.panelOrder) do
        table.insert(lines, string.format("  panel %s (adminOnly %s, visible %s)",
            id, tostring(self.panels[id].adminOnly), tostring(self.panels[id].visible)))
    end
    return table.concat(lines, "\n")
end

function MasterHUD:consoleCommandStatus()
    return self:getStatus()
end
