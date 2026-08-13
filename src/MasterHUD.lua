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
--   subscribe(id, { draw, isDirty, isFullscreen }) self-drawn display element
--   registerPanel(id, { draw, onMouse, onInput, isFullscreen, adminOnly })
--                                               self-draw + input
--
-- isFullscreen declares that an element currently owns the WHOLE screen. It may
-- be `true` (always) or a FUNCTION returning true only while the element's panel
-- is actually open, which is the useful form for a panel the player toggles.
-- While one element claims the screen, every other element stands down: see
-- getFullscreenOwner below for why that is the only correct response.
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

    -- Suite-wide hide / shared layout-edit (vanilla HUD is never touched).
    self.hudsHidden      = false
    self.layoutEditMode  = false
    self.editListeners   = {}   -- id -> { enter = fn, exit = fn }
    self.editListenerOrder = {}
    self.onHudsHiddenChanged = nil  -- optional persist callback set by main.lua

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
    -- isFullscreen is stored RAW so it can be a boolean or a function; see
    -- claimsScreen. Omitting it is the default and behaves exactly as before.
    self.selfDraws[id] = {
        draw = spec.draw,
        isDirty = spec.isDirty,
        isFullscreen = spec.isFullscreen,
        visible = true,
    }
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
        -- Kept RAW rather than coerced with `== true`, so a function is preserved
        -- as a function. A plain boolean behaves exactly as it did before.
        isFullscreen = spec.isFullscreen,
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
-- Suite-wide hide / shared layout-edit
-- =========================================================

function MasterHUD:areHudsHidden()
    return self.hudsHidden == true
end

function MasterHUD:setHudsHidden(hidden)
    hidden = hidden == true
    if self.hudsHidden == hidden then return end
    self.hudsHidden = hidden
    -- Leaving hide while edit is on keeps edit; entering hide exits edit so
    -- companions are not left in a drag state the player cannot see.
    if hidden and self.layoutEditMode then
        self:setLayoutEditMode(false)
    end
    if type(self.onHudsHiddenChanged) == "function" then
        pcall(self.onHudsHiddenChanged, hidden)
    end
    -- #region agent log
    Logging.info("[MH-DEBUG][E] setHudsHidden hidden=%s listeners=%d", tostring(hidden), #(self.editListenerOrder or {}))
    -- #endregion
    MHLogger.info("Suite HUDs %s", hidden and "hidden" or "shown")
end

function MasterHUD:toggleHudsHidden()
    -- #region agent log
    Logging.info("[MH-DEBUG][D] toggleHudsHidden invoked wasHidden=%s", tostring(self.hudsHidden == true))
    -- #endregion
    self:setHudsHidden(not self.hudsHidden)
end

function MasterHUD:isLayoutEditMode()
    return self.layoutEditMode == true
end

function MasterHUD:setLayoutEditMode(enabled)
    enabled = enabled == true
    if self.layoutEditMode == enabled then return end

    -- Edit needs the overlays visible so the player can find what to drag.
    if enabled and self.hudsHidden then
        self:setHudsHidden(false)
    end

    self.layoutEditMode = enabled
    for _, id in ipairs(self.editListenerOrder) do
        local listener = self.editListeners[id]
        if listener ~= nil then
            local fn = enabled and listener.enter or listener.exit
            if type(fn) == "function" then
                pcall(fn)
            end
        end
    end
    MHLogger.info("Suite HUD layout edit %s (Ctrl+#)", enabled and "ON" or "OFF")
end

function MasterHUD:toggleLayoutEditMode()
    -- #region agent log
    Logging.info("[MH-DEBUG][D] toggleLayoutEditMode invoked wasEdit=%s", tostring(self.layoutEditMode == true))
    -- #endregion
    self:setLayoutEditMode(not self.layoutEditMode)
end

function MasterHUD:registerEditListener(id, spec)
    if type(id) ~= "string" or id == "" or type(spec) ~= "table" then
        MHLogger.warning("registerEditListener('%s'): needs id + { enter, exit }", tostring(id))
        return false
    end
    if self.editListeners[id] == nil then
        table.insert(self.editListenerOrder, id)
    end
    self.editListeners[id] = {
        enter = spec.enter,
        exit = spec.exit,
    }
    -- If edit mode is already on, bring the new listener in immediately.
    if self.layoutEditMode and type(spec.enter) == "function" then
        pcall(spec.enter)
    end
    MHLogger.debug("Registered edit listener '%s'", id)
    return true
end

function MasterHUD:unregisterEditListener(id)
    if self.editListeners[id] == nil then return end
    if self.layoutEditMode and type(self.editListeners[id].exit) == "function" then
        pcall(self.editListeners[id].exit)
    end
    self.editListeners[id] = nil
    removeFromOrder(self.editListenerOrder, id)
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
    -- Suite hide: skip every RF overlay/self-draw/panel. Vanilla HUD is untouched.
    if self.hudsHidden then return end
    self:draw()
end

-- Does this entry currently claim the whole screen? `true` means always, a
-- function means "ask it", anything else means no. pcall'd because a companion's
-- callback must never be able to take down the draw loop.
local function claimsScreen(entry)
    local v = entry.isFullscreen
    if v == true then return true end
    if type(v) == "function" then
        local ok, r = pcall(v)
        return ok and r == true
    end
    return false
end

--- The element currently owning the whole screen, if any.
---
--- WHY THIS EXISTS. A panel background is an OVERLAY, and an overlay does not
--- cover text that was already rendered underneath it. So when a companion draws
--- a full-screen panel, every HUD drawn before it reads straight THROUGH the
--- panel, and every HUD drawn after it paints over the top. Neither is fixable
--- from the panel's side: the others have to not draw.
---
--- This is the same rule as the menu-suspend in onDraw, extended to the surfaces
--- g_gui cannot see. g_gui only knows about engine dialogs and menus; a companion
--- panel drawn with renderOverlay is invisible to it. The suspend guard was
--- copied from SoilFertilizer along with that blind spot, and this closes it.
---
---@return string|nil id, string|nil kind  kind is "selfDraw" or "panel"
function MasterHUD:getFullscreenOwner()
    for _, id in ipairs(self.selfDrawOrder) do
        local s = self.selfDraws[id]
        if s ~= nil and s.visible and claimsScreen(s) then return id, "selfDraw" end
    end
    for _, id in ipairs(self.panelOrder) do
        local p = self.panels[id]
        if p ~= nil and p.visible and claimsScreen(p) then return id, "panel" end
    end
    return nil, nil
end

function MasterHUD:draw()
    if self.hudsHidden then return end

    -- While one element owns the screen, only that element draws. Text overlays
    -- are skipped entirely rather than drawn and covered, because covering them
    -- is exactly what does not work.
    local ownerId, ownerKind = self:getFullscreenOwner()

    if ownerId ~= nil then
        if ownerKind == "selfDraw" then
            local s = self.selfDraws[ownerId]
            if s ~= nil then pcall(s.draw) end
        else
            local p = self.panels[ownerId]
            if p ~= nil and (not p.adminOnly or self:isLocalAdmin()) then pcall(p.draw) end
        end
        return
    end

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
    if self.suspended or self.hudsHidden then return end
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
    if self.suspended or self.hudsHidden then return end
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
    if self.layoutEditMode then
        self:setLayoutEditMode(false)
    end
    if self.renderer ~= nil then
        self.renderer:delete()
    end
    self.overlays = {}
    self.overlayOrder = {}
    self.selfDraws = {}
    self.selfDrawOrder = {}
    self.panels = {}
    self.panelOrder = {}
    self.editListeners = {}
    self.editListenerOrder = {}
end

-- =========================================================
-- Introspection (console command)
-- =========================================================

function MasterHUD:getStatus()
    local lines = {}
    table.insert(lines, string.format(
        "MasterHUD: %d overlay(s), %d self-draw(s), %d panel(s), suspended=%s, hudsHidden=%s, layoutEdit=%s, editListeners=%d",
        #self.overlayOrder, #self.selfDrawOrder, #self.panelOrder,
        tostring(self.suspended), tostring(self.hudsHidden),
        tostring(self.layoutEditMode), #self.editListenerOrder))
    -- Surfaced because "my HUD vanished" is the symptom of this working, and the
    -- owner is the first thing to check when someone reports it.
    local ownerId, ownerKind = self:getFullscreenOwner()
    table.insert(lines, string.format("  fullscreen owner: %s%s",
        ownerId or "none", ownerId and (" (" .. tostring(ownerKind) .. ")") or ""))
    for _, id in ipairs(self.overlayOrder) do
        local o = self.overlays[id]
        table.insert(lines, string.format("  overlay %s (anchor %s, visible %s)",
            id, o.config.anchor or "ANCHOR_TOP_RIGHT", tostring(o.visible)))
    end
    for _, id in ipairs(self.panelOrder) do
        table.insert(lines, string.format("  panel %s (adminOnly %s, visible %s)",
            id, tostring(self.panels[id].adminOnly), tostring(self.panels[id].visible)))
    end
    for _, id in ipairs(self.editListenerOrder) do
        table.insert(lines, string.format("  editListener %s", id))
    end
    return table.concat(lines, "\n")
end

function MasterHUD:consoleCommandStatus()
    return self:getStatus()
end
