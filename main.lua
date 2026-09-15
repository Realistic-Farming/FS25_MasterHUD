-- =========================================================
-- FS25_MasterHUD - mod entry point
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Loads the MasterHUD modules, publishes the g_masterHUD handle, and hooks
-- the FS25 mission lifecycle:
--   Mission00.load          -> publish the cross-mod bridge handle
--   FSBaseMission.draw       -> the single ecosystem draw loop
--   FSBaseMission.mouseEvent -> route clicks to interactive panels
--   FSBaseMission.keyEvent   -> route keys to interactive panels
--   FSBaseMission.delete     -> free the shared overlay + drop the handle
--
-- Also owns suite-wide HUD hide and shared layout-edit (rebindable):
-- InputActions registered in BOTH player and vehicle contexts using the
-- CropStress / NPCFavor proven pattern (hook at module load, not after the
-- first PlayerInputComponent.registerActionEvents has already fired).
-- Hide preference persists client-local across sessions.
-- Vanilla FS25 HUD is never hooked or suppressed.
--
-- Load order: MasterHUD is mod 3 (after StateLedger and NetworkSync). The
-- handle is published as soon as this file runs so companions loading after
-- it can register during their own module load.
-- =========================================================

-- Hot-reload latch (FuelCosts reference): g_currentModDirectory and
-- g_currentModName are nil on a live re-source, so they are latched into
-- module globals on first load, with a g_modsDirectory loose-folder fallback.
MasterHUDModDirectory = MasterHUDModDirectory
    or g_currentModDirectory
    or (g_modsDirectory ~= nil and (g_modsDirectory .. "FS25_MasterHUD/") or nil)
MasterHUDModName = MasterHUDModName or g_currentModName or "FS25_MasterHUD"
local modDirectory = MasterHUDModDirectory
local modName = MasterHUDModName

source(modDirectory .. "src/Logger.lua")
source(modDirectory .. "src/OverlayRenderer.lua")
source(modDirectory .. "src/NoticeQueue.lua")
source(modDirectory .. "src/MasterHUD.lua")
source(modDirectory .. "src/MhContextInput.lua")

local masterHUD = MasterHUD.new()
getfenv(0)["g_masterHUD"] = masterHUD

-- BUILD 17:45: the agentDbg helper and every call to it are gone. It was a labelled
-- debug session (3f9f36) that outlived its investigation, and one of its call sites sat
-- inside the vehicle-context hook, which the engine drives off
-- InputBinding.endActionEventsModification. That fires constantly while the player is in a
-- cab, so a single debug line there wrote somewhere between seven and twenty eight thousand
-- lines into one client log.

-- ---------------------------------------------------------
-- Client-local hide preference
-- ---------------------------------------------------------

local function prefsPath()
    if getUserProfileAppPath ~= nil then
        return getUserProfileAppPath() .. "FS25_MasterHUD_prefs.xml"
    end
    return nil
end

local function loadHidePreference()
    local path = prefsPath()
    if path == nil or not fileExists(path) then return end
    local xml = loadXMLFile("MasterHUDPrefs", path)
    if xml == nil or xml == 0 then return end
    local hidden = getXMLBool(xml, "masterHUDPrefs.hudsHidden")
    delete(xml)
    if hidden == true then
        masterHUD.hudsHidden = true
        MHLogger.info("Restored suite HUD hide preference (hidden)")
    end
end

local function saveHidePreference(hidden)
    local path = prefsPath()
    if path == nil then return end
    local xml = createXMLFile("MasterHUDPrefs", path, "masterHUDPrefs")
    if xml == nil or xml == 0 then return end
    setXMLBool(xml, "masterHUDPrefs.hudsHidden", hidden == true)
    saveXMLFile(xml)
    delete(xml)
end

masterHUD.onHudsHiddenChanged = saveHidePreference

-- ---------------------------------------------------------
-- Input: suite hide + shared layout edit (RSF-F201 context-qualified)
-- Proven FS25 pattern (Soil / FuelCosts / RWE):
--   1. Wrap PlayerInputComponent.registerActionEvents at MODULE LOAD.
--   2. Vehicle: hook InputBinding.endActionEventsModification
--      (Vehicle.registerActionEvents is copied onto instances at spawn,
--      class patches after that are silently ignored).
--   3. Callbacks ignore zero inputValue (key-up).
--   4. Defaults must be free keys: KEY_backslash collides with
--      TOGGLE_BULK_FILL and many companion HUD toggles (register fails).
--
-- RSF-F201: each context registers through its own private forwarding target.
-- The engine keys an event by action, target and trigger shape only, so the
-- old shared `masterHUD` target made the PLAYER and VEHICLE registrations one
-- global slot that every cab rebuild wiped (the comment that used to sit on
-- the vehicle path records exactly that dead-cab-key shape). Membership is
-- now asked of the wrap's own context by walking the native lists; a complete
-- set means no transaction, so the constant VEHICLE closes while seated cost
-- nothing. The hook record lives on the MasterHUD class table (reused on hot
-- reload, see src/MasterHUD.lua:30-33) and is never restored per mission.
-- ---------------------------------------------------------

local inputRecord = MhContextInput.record(MasterHUD, "_f201Input")

-- Handlers resolved by name on the live owner at call time. Engine signature:
-- (target, actionName, inputValue, ...). Zero inputValue is key-up.
function MasterHUD:onToggleAllHudsInput(_, inputValue)
    if (inputValue or 0) <= 0 then return end
    self:toggleHudsHidden()
end

function MasterHUD:onEditHudsInput(_, inputValue)
    if (inputValue or 0) <= 0 then return end
    self:toggleLayoutEditMode()
end

-- BUILD 21:53 (Sam DESIGN 21:50 item 1): the input-help legend is the one
-- surface that always shows the LIVE binding, the same source Controls
-- reads, so with the Function-key defaults gone these rows are visible
-- there instead of hidden. A player who has not bound the action sees the
-- engine's own unbound presentation plus the action name, which is the
-- honest state; nothing here paints a cleared default.
local function showLegendRow(binding, eventId)
    binding:setActionEventActive(eventId, true)
    binding:setActionEventTextVisibility(eventId, true)
end

local function showCabRow(binding, eventId)
    binding:setActionEventTextVisibility(eventId, true)
end

local MH_PLAYER_SPECS = {
    { action = "MH_TOGGLE_ALL_HUDS", handler = "onToggleAllHudsInput", idField = "playerToggleEventId",
      up = false, down = true, always = false, startActive = true, after = showLegendRow },
    { action = "MH_EDIT_HUDS", handler = "onEditHudsInput", idField = "playerEditEventId",
      up = false, down = true, always = false, startActive = true, after = showLegendRow },
}

local MH_VEHICLE_SPECS = {
    { action = "MH_TOGGLE_ALL_HUDS", handler = "onToggleAllHudsInput", idField = "vehicleToggleEventId",
      up = false, down = true, always = false, startActive = true, after = showCabRow },
    { action = "MH_EDIT_HUDS", handler = "onEditHudsInput", idField = "vehicleEditEventId",
      up = false, down = true, always = false, startActive = true, after = showCabRow },
}

-- Install both wrappers at module load (must wrap before first registerActionEvents).
-- Installed once per loaded script environment; the record on the class table
-- makes a re-sourced copy adopt the existing wrappers instead of stacking.
do
    if InputAction == nil or InputAction.MH_TOGGLE_ALL_HUDS == nil or InputAction.MH_EDIT_HUDS == nil then
        MHLogger.warning("InputAction MH_TOGGLE_ALL_HUDS / MH_EDIT_HUDS missing - check modDesc <actions>")
    end
    if MhContextInput.installPlayerWrapper(inputRecord, MH_PLAYER_SPECS) then
        MHLogger.info("PlayerInputComponent hook installed (suite hide/edit)")
    else
        MHLogger.warning("PlayerInputComponent.registerActionEvents unavailable - on-foot suite keys disabled")
    end
    if MhContextInput.installVehicleWrapper(inputRecord, MH_VEHICLE_SPECS) then
        MHLogger.info("InputBinding VEHICLE hook installed (suite hide/edit)")
    else
        MHLogger.warning("InputBinding.endActionEventsModification unavailable - in-vehicle suite keys disabled")
    end
end

local function activateInput(mission)
    if PlayerInputComponent == nil or Vehicle == nil then return end
    MhContextInput.activate(inputRecord, masterHUD, mission, {
        [PlayerInputComponent.INPUT_CONTEXT_NAME] = MH_PLAYER_SPECS,
        [Vehicle.INPUT_CONTEXT_NAME]              = MH_VEHICLE_SPECS,
    })
end


-- ---------------------------------------------------------
-- Mission lifecycle
-- ---------------------------------------------------------

local function onMissionLoad(mission)
    if mission ~= nil then
        mission.masterHUD = masterHUD
    end
    -- RSF-F201: bind the surviving instance as input owner of this mission and
    -- mint fresh per-context forwarding targets. Wrappers are not reinstalled.
    activateInput(mission)
    loadHidePreference()
    MHLogger.info("MasterHUD active (mod 3, UI renderer + suite hide/edit)")
end

local function onMissionDelete()
    -- RSF-F201: retire the input owner first. Old targets go inert; the captured
    -- predecessors stay installed so no neighbour's wrapper is unhooked.
    MhContextInput.retire(inputRecord)
    masterHUD:delete()
    getfenv(0)["g_masterHUD"] = nil
    if g_currentMission ~= nil then
        g_currentMission.masterHUD = nil
    end
end

Mission00.load = Utils.appendedFunction(Mission00.load, onMissionLoad)

-- ---------------------------------------------------------
-- Realistic Farming Control Center: publish runnable delegates.
--
-- Registered from loadMission00Finished, not from onMissionLoad. MasterHUD is
-- mod 3 and SettingsHub is mod 4, so the registry does not exist yet while this
-- file loads, and SettingsHub only publishes it onto the mission handle during
-- its own Mission00.load. Every Mission00.load hook has run by the time any
-- loadMission00Finished hook does, so the handle is reliably there.
--
-- Reached through g_currentMission because that is the only channel that
-- carries live between mod environments.
-- ---------------------------------------------------------
local function registerControlCenterActions()
    -- RSF-F201 post-load catch-up, independent of the optional registry below:
    -- one PLAYER reconciliation if the local owning player and the native
    -- PLAYER context already exist. No-op when the set is complete.
    MhContextInput.catchUpPlayer(inputRecord, MH_PLAYER_SPECS)

    local registry = g_currentMission ~= nil and g_currentMission.rfActionRegistry or nil
    if registry == nil then return end

    registry.registerAction({
        action = "MH_TOGGLE_ALL_HUDS",
        button = "Toggle",
        order  = 1,
        run    = function() masterHUD:toggleHudsHidden() end,
    })

    registry.registerAction({
        action = "MH_EDIT_HUDS",
        button = "Edit",
        order  = 2,
        -- Layout edit needs the world visible, so the Control Center steps aside.
        closeFirst = true,
        run        = function() masterHUD:toggleLayoutEditMode() end,
    })

    MHLogger.info("MasterHUD registered 2 Control Center actions")
end

Mission00.loadMission00Finished = Utils.appendedFunction(
    Mission00.loadMission00Finished, registerControlCenterActions)

-- Draw after the base game HUD so overlays sit on top.
FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw, function(mission)
    masterHUD:onDraw()
end)

-- BUILD 15:39 (PB-13 / PB-14). Ticks the shared notice channel: paces the one
-- line per in-game-day window and holds everything back while a menu, dialog or
-- fullscreen claim covers the world.
FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)
    -- RSF-F201: admission reset is the first input act of every update interval.
    MhContextInput.resetAdmission(inputRecord)
    masterHUD:update(dt)
end)

-- Route mouse events to interactive panels (guarded: only if the hook exists).
if FSBaseMission.mouseEvent ~= nil then
    FSBaseMission.mouseEvent = Utils.appendedFunction(
        FSBaseMission.mouseEvent,
        function(mission, posX, posY, isDown, isUp, button)
            masterHUD:onMouseEvent(posX, posY, isDown, isUp, button)
        end
    )
end

-- Route key events to interactive panels (guarded: only if the hook exists).
if FSBaseMission.keyEvent ~= nil then
    FSBaseMission.keyEvent = Utils.appendedFunction(
        FSBaseMission.keyEvent,
        function(mission, action, value)
            masterHUD:onKeyEvent(action, value)
        end
    )
end

FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, onMissionDelete)

if addConsoleCommand ~= nil then
    addConsoleCommand("mhStatus", "Show MasterHUD registered overlays and panels",
        "consoleCommandStatus", masterHUD)
    addConsoleCommand("mhToggleHuds", "Toggle all Realistic Farming HUDs",
        "toggleHudsHidden", masterHUD)
    addConsoleCommand("mhEditHuds", "Toggle suite HUD layout edit",
        "toggleLayoutEditMode", masterHUD)
end
