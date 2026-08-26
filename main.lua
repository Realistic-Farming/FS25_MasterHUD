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
-- Input: suite hide + shared layout edit
-- Proven FS25 pattern (Soil / FuelCosts / RWE):
--   1. Wrap PlayerInputComponent.registerActionEvents at MODULE LOAD.
--   2. Vehicle: hook InputBinding.endActionEventsModification
--      (Vehicle.registerActionEvents is copied onto instances at spawn —
--      class patches after that are silently ignored).
--   3. Callbacks ignore zero inputValue (key-up).
--   4. Defaults must be free keys — KEY_backslash collides with
--      TOGGLE_BULK_FILL and many companion HUD toggles (register fails).
-- ---------------------------------------------------------

local playerToggleEventId = nil
local playerEditEventId = nil
local vehicleToggleEventId = nil
local vehicleEditEventId = nil

local function onToggleAllHuds(_, _, inputValue)
    if (inputValue or 0) <= 0 then return end
    masterHUD:toggleHudsHidden()
end

local function onEditHuds(_, _, inputValue)
    if (inputValue or 0) <= 0 then return end
    masterHUD:toggleLayoutEditMode()
end

local function registerInPlayerContext()
    if g_inputBinding == nil then return end
    if InputAction.MH_TOGGLE_ALL_HUDS == nil or InputAction.MH_EDIT_HUDS == nil then
        MHLogger.warning("InputAction MH_TOGGLE_ALL_HUDS / MH_EDIT_HUDS missing — check modDesc <actions>")
        return
    end
    -- No stale-id early-return: the hook fires on player spawn, when the PLAYER
    -- context may have been rebuilt and any saved ids are dead. Registering into
    -- a context that already holds the action fails silently, so attempting on
    -- every spawn is safe (same rationale as the vehicle path).
    g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

    do
        local ok, eventId = g_inputBinding:registerActionEvent(
            InputAction.MH_TOGGLE_ALL_HUDS, masterHUD, onToggleAllHuds,
            false, true, false, true
        )
        if ok and eventId ~= nil then
            playerToggleEventId = eventId
            g_inputBinding:setActionEventActive(eventId, true)
            -- BUILD 21:53 (Sam DESIGN 21:50 item 1): the input-help legend is the one
            -- surface that always shows the LIVE binding - the same source Controls
            -- reads - so with the Function-key defaults gone these rows are visible
            -- there instead of hidden. A player who has not bound the action sees the
            -- engine's own unbound presentation plus the action name, which is the
            -- honest state; nothing here paints a cleared default. All six visibility
            -- flips in this file are this one decision.
            g_inputBinding:setActionEventTextVisibility(eventId, true)
        end
    end

    do
        local ok, eventId = g_inputBinding:registerActionEvent(
            InputAction.MH_EDIT_HUDS, masterHUD, onEditHuds,
            false, true, false, true
        )
        if ok and eventId ~= nil then
            playerEditEventId = eventId
            g_inputBinding:setActionEventActive(eventId, true)
            g_inputBinding:setActionEventTextVisibility(eventId, true)
        end
        -- No failure warning here: with the stale-id guard gone this runs on
        -- every spawn, and an attempt against a context that already holds the
        -- action fails by design.
    end

    g_inputBinding:endActionEventsModification()
end

local function registerInVehicleContext(binding)
    if binding == nil or InputAction.MH_TOGGLE_ALL_HUDS == nil then return end

    -- FuelCosts proven shape (live log: fires once per vehicle entry, no spam):
    -- register into the vehicle context every time the engine rebuilds it, with
    -- no teardown and no touching of the PLAYER slots. The old shape here
    -- early-returned once its saved ids were non-nil, so every vehicle context
    -- after the first was rebuilt WITHOUT these events (ids go stale when a
    -- context is destroyed, but the guard only checked non-nil) - that is the
    -- exact "keys dead in the cab" Wizard hit. A re-register into a context
    -- that already has the action simply fails and stays silent, so calling
    -- this on every VEHICLE endActionEventsModification is safe.
    binding:beginActionEventsModification(Vehicle.INPUT_CONTEXT_NAME)

    local okT, idT = binding:registerActionEvent(
        InputAction.MH_TOGGLE_ALL_HUDS, masterHUD, onToggleAllHuds,
        false, true, false, true
    )
    if okT and idT then
        vehicleToggleEventId = idT
        binding:setActionEventTextVisibility(idT, true)
        MHLogger.info("MH_TOGGLE_ALL_HUDS registered in VEHICLE context")
    end

    local okE, idE = binding:registerActionEvent(
        InputAction.MH_EDIT_HUDS, masterHUD, onEditHuds,
        false, true, false, true
    )
    if okE and idE then
        vehicleEditEventId = idE
        binding:setActionEventTextVisibility(idE, true)
        MHLogger.info("MH_EDIT_HUDS registered in VEHICLE context")
    end

    binding:endActionEventsModification()
end

-- Install player hook at module load (must wrap before first registerActionEvents).
do
    if PlayerInputComponent ~= nil and PlayerInputComponent.registerActionEvents ~= nil then
        local origFn = PlayerInputComponent.registerActionEvents
        PlayerInputComponent.registerActionEvents = function(inputComponent, ...)
            origFn(inputComponent, ...)
            local isOwner = inputComponent.player ~= nil and inputComponent.player.isOwner
            if isOwner then
                registerInPlayerContext()
            end
        end
        MHLogger.info("PlayerInputComponent hook installed (suite hide/edit)")
    else
        MHLogger.warning("PlayerInputComponent.registerActionEvents unavailable — on-foot suite keys disabled")
    end
end

-- Vehicle context via InputBinding.endActionEventsModification (Soil/Fuel/RWE).
do
    if InputBinding ~= nil and InputBinding.endActionEventsModification ~= nil then
        local hookActive = false
        local origEnd = InputBinding.endActionEventsModification
        InputBinding.endActionEventsModification = function(binding, ignoreCheck)
            local contextName = ""
            if binding.registrationContext ~= nil
                and binding.registrationContext ~= InputBinding.NO_REGISTRATION_CONTEXT then
                contextName = binding.registrationContext.name or ""
            end

            origEnd(binding, ignoreCheck)

            if Vehicle == nil or contextName ~= Vehicle.INPUT_CONTEXT_NAME then return end
            if hookActive then return end
            hookActive = true
            registerInVehicleContext(binding)
            hookActive = false
        end
        MHLogger.info("InputBinding VEHICLE hook installed (suite hide/edit)")
    else
        MHLogger.warning("InputBinding.endActionEventsModification unavailable — in-vehicle suite keys disabled")
    end
end

-- ---------------------------------------------------------
-- Mission lifecycle
-- ---------------------------------------------------------

local function onMissionLoad(mission)
    if mission ~= nil then
        mission.masterHUD = masterHUD
    end
    loadHidePreference()
    MHLogger.info("MasterHUD active (mod 3, UI renderer + suite hide/edit)")
end

local function onMissionDelete()
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
