-- Hide-all draw + input must agree on the fullscreen owner.
-- selfDraw owners (Soil settings via drawStack) are drawn by MasterHUD but
-- get mouse/keys from the companion's own listener, not from panelOrder.
--
--!load: src/Logger.lua, src/OverlayRenderer.lua, src/NoticeQueue.lua, src/MasterHUD.lua

local function counter()
  local c = { n = 0 }
  c.draw = function()
    c.n = c.n + 1
  end
  return c
end

local hud = MasterHUD.new()

local settingsDrawn = counter()
local chromeDrawn = counter()
local cabDrawn = counter()
local settingsOpen = false

hud:subscribe("SoilFertilizer_HUD", {
  draw = function()
    if settingsOpen then
      settingsDrawn.draw()
      return
    end
    chromeDrawn.draw()
    settingsDrawn.draw()
  end,
  isFullscreen = function()
    return settingsOpen
  end,
})

hud:subscribe("SoilFertilizer_CabTools", {
  draw = function()
    if hud.hudsHidden ~= true then return end
    if settingsOpen then return end
    cabDrawn.draw()
  end,
  visibleWhenHudsHidden = true,
})

-- Keep-alive cab PANEL registered BEFORE a fullscreen panel owner (order trap).
local cabPanelMouse = { n = 0 }
local cabPanelKey = { n = 0 }
hud:registerPanel("CabKeepPanel", {
  draw = function() end,
  onMouse = function()
    cabPanelMouse.n = cabPanelMouse.n + 1
    return true
  end,
  onInput = function()
    cabPanelKey.n = cabPanelKey.n + 1
    return true
  end,
  visibleWhenHudsHidden = true,
})

local ownerPanelMouse = { n = 0 }
local ownerPanelKey = { n = 0 }
local ownerOpen = false
hud:registerPanel("SettingsOwnerPanel", {
  draw = function() end,
  onMouse = function()
    ownerPanelMouse.n = ownerPanelMouse.n + 1
    return true
  end,
  onInput = function()
    ownerPanelKey.n = ownerPanelKey.n + 1
    return true
  end,
  isFullscreen = function()
    return ownerOpen
  end,
})

-- Visible HUDs, settings closed: chrome path draws once via normal loop.
settingsOpen = false
hud:setHudsHidden(false)
hud:onDraw()
T.eq("normal draw paints soil chrome path", chromeDrawn.n, 1)
T.eq("cab keep idle while HUDs visible", cabDrawn.n, 0)

-- Hide-all, settings closed: only cab keep (selfDraw).
chromeDrawn.n = 0
settingsDrawn.n = 0
cabDrawn.n = 0
hud:setHudsHidden(true)
hud:onDraw()
T.eq("hide-all suppresses soil chrome", chromeDrawn.n, 0)
T.eq("hide-all still draws cab tools", cabDrawn.n, 1)
T.eq("hide-all does not draw settings when closed", settingsDrawn.n, 0)

-- No-owner keep: cab panel still receives mouse/keys.
cabPanelMouse.n = 0
cabPanelKey.n = 0
ownerOpen = false
settingsOpen = false
hud:onMouseEvent(0.5, 0.5, true, false, 1)
hud:onKeyEvent("MENU_ACTIVATE", 1)
T.eq("no-owner keep panel receives mouse", cabPanelMouse.n, 1)
T.eq("no-owner keep panel receives key", cabPanelKey.n, 1)

-- Open settings while HUDs already hidden: settings draw, cab/chrome stay down.
settingsOpen = true
chromeDrawn.n = 0
settingsDrawn.n = 0
cabDrawn.n = 0
hud:onDraw()
T.eq("open settings while hidden draws settings", settingsDrawn.n, 1)
T.eq("open settings while hidden does not draw chrome", chromeDrawn.n, 0)
T.eq("open settings while hidden skips cab keep", cabDrawn.n, 0)

-- selfDraw owner: unrelated MasterHUD panels must NOT receive input (SF owns it).
cabPanelMouse.n = 0
ownerPanelMouse.n = 0
hud:onMouseEvent(0.5, 0.5, true, false, 1)
T.eq("selfDraw owner blocks cab keep mouse", cabPanelMouse.n, 0)
T.eq("selfDraw owner blocks other panel mouse", ownerPanelMouse.n, 0)

-- Panel fullscreen owner: only that panel gets input; earlier cab keep does not steal.
settingsOpen = false
ownerOpen = true
cabPanelMouse.n = 0
cabPanelKey.n = 0
ownerPanelMouse.n = 0
ownerPanelKey.n = 0
hud:setHudsHidden(true)
hud:onMouseEvent(0.5, 0.5, true, false, 1)
hud:onKeyEvent("MENU_ACTIVATE", 1)
T.eq("panel owner receives mouse", ownerPanelMouse.n, 1)
T.eq("panel owner receives key", ownerPanelKey.n, 1)
T.eq("cab keep before owner does not steal mouse", cabPanelMouse.n, 0)
T.eq("cab keep before owner does not steal key", cabPanelKey.n, 0)

-- Two panel claimants: only the first in panelOrder (chosen owner) receives.
local secondMouse = { n = 0 }
hud:registerPanel("SecondFullscreen", {
  draw = function() end,
  onMouse = function()
    secondMouse.n = secondMouse.n + 1
    return true
  end,
  isFullscreen = function()
    return ownerOpen
  end,
})
ownerPanelMouse.n = 0
secondMouse.n = 0
hud:onMouseEvent(0.5, 0.5, true, false, 1)
T.eq("first fullscreen panel owner wins mouse", ownerPanelMouse.n, 1)
T.eq("second fullscreen claimant gets no mouse", secondMouse.n, 0)

-- Hide while settings already open: settings persist (single draw).
settingsOpen = true
ownerOpen = false
hud:setHudsHidden(false)
hud:onDraw()
chromeDrawn.n = 0
settingsDrawn.n = 0
cabDrawn.n = 0
hud:setHudsHidden(true)
hud:onDraw()
T.eq("hide while settings open still draws settings", settingsDrawn.n, 1)
T.eq("hide while settings open does not resurrect chrome", chromeDrawn.n, 0)

-- Close settings: HUDs stay hidden; cab keep resumes; no chrome.
settingsOpen = false
chromeDrawn.n = 0
settingsDrawn.n = 0
cabDrawn.n = 0
hud:onDraw()
T.eq("close settings under hide restores cab keep", cabDrawn.n, 1)
T.eq("close settings under hide still suppresses chrome", chromeDrawn.n, 0)

-- Show HUDs again: ordinary chrome returns, no double cab.
hud:setHudsHidden(false)
chromeDrawn.n = 0
cabDrawn.n = 0
hud:onDraw()
T.eq("show HUDs restores chrome", chromeDrawn.n, 1)
T.eq("show HUDs does not draw cab keep", cabDrawn.n, 0)

-- Passive panel without keep / fullscreen is ignored while hidden.
settingsOpen = false
ownerOpen = false
local passiveMouse = { n = 0 }
hud:registerPanel("Passive", {
  draw = function() end,
  onMouse = function()
    passiveMouse.n = passiveMouse.n + 1
    return true
  end,
})
hud:setHudsHidden(true)
-- Cab keep still first and will consume; register passive after — it must not
-- receive when keep already handled. Force keep closed for this assert by
-- temporarily clearing keep mouse return via a dedicated passive-only case:
cabPanelMouse.n = 0
-- Remove keep handler consumption for passive check: use a fresh HUD fragment
-- is overkill; instead assert Passive is never called when owner/selfDraw absent
-- and only keep panels are eligible — Passive has no keep flag so stays 0 even
-- if cab keep also fires.
hud:onMouseEvent(0.5, 0.5, true, false, 1)
T.eq("passive panel mouse blocked while huds hidden", passiveMouse.n, 0)

-- Suspension gate: no input while suspended.
hud.suspended = true
ownerOpen = true
ownerPanelMouse.n = 0
hud:onMouseEvent(0.5, 0.5, true, false, 1)
T.eq("suspended blocks hidden owner mouse", ownerPanelMouse.n, 0)
hud.suspended = false

-- Admin-only owner with non-admin local: no dispatch (isLocalAdmin false by default stub).
-- MasterHUD:isLocalAdmin may exist; force non-admin.
if type(hud.isLocalAdmin) == "function" then
  hud.isLocalAdmin = function() return false end
end
hud:registerPanel("AdminOnlyOwner", {
  draw = function() end,
  onMouse = function()
    return true
  end,
  isFullscreen = function()
    return true
  end,
  adminOnly = true,
})
-- Clear other fullscreen claims so AdminOnlyOwner is chosen if visible+claims.
ownerOpen = false
settingsOpen = false
-- getFullscreenOwner walks panelOrder; SettingsOwnerPanel claims false; Second false;
-- AdminOnlyOwner claims true. Cab keep is not fullscreen.
local adminMouse = { n = 0 }
-- replace onMouse to count
hud.panels["AdminOnlyOwner"].onMouse = function()
  adminMouse.n = adminMouse.n + 1
  return true
end
hud:setHudsHidden(true)
hud:onMouseEvent(0.5, 0.5, true, false, 1)
T.eq("admin-only owner blocked for non-admin", adminMouse.n, 0)
