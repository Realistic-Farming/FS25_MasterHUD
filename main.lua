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

local modDirectory = g_currentModDirectory
local modName = g_currentModName

source(modDirectory .. "src/Logger.lua")
source(modDirectory .. "src/OverlayRenderer.lua")
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
    -- Already registered for this PLAYER context lifetime.
    if playerToggleEventId ~= nil and playerEditEventId ~= nil then return end

    g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)

    if playerToggleEventId == nil then
        local ok, eventId = g_inputBinding:registerActionEvent(
            InputAction.MH_TOGGLE_ALL_HUDS, masterHUD, onToggleAllHuds,
            false, true, false, true
        )
        if ok and eventId ~= nil then
            playerToggleEventId = eventId
            g_inputBinding:setActionEventActive(eventId, true)
            g_inputBinding:setActionEventTextVisibility(eventId, false)
        end
        if not (ok and eventId) then
            MHLogger.warning("MH_TOGGLE_ALL_HUDS PLAYER registration failed (key conflict? rebind in Controls)")
        end
    end

    if playerEditEventId == nil then
        local ok, eventId = g_inputBinding:registerActionEvent(
            InputAction.MH_EDIT_HUDS, masterHUD, onEditHuds,
            false, true, false, true
        )
        if ok and eventId ~= nil then
            playerEditEventId = eventId
            g_inputBinding:setActionEventActive(eventId, true)
            g_inputBinding:setActionEventTextVisibility(eventId, false)
        end
        if not (ok and eventId) then
            MHLogger.warning("MH_EDIT_HUDS PLAYER registration failed (key conflict? rebind in Controls)")
        end
    end

    g_inputBinding:endActionEventsModification()
end

local function registerInVehicleContext(binding)
    if binding == nil or InputAction.MH_TOGGLE_ALL_HUDS == nil then return end

    -- BUILD 17:45: this runs off endActionEventsModification, which the engine calls
    -- constantly in a cab, and it used to remove and re-register four action events every
    -- single time. When all four slots are already live there is nothing to repair, so the
    -- whole teardown is skipped. If ANY of them is missing the full path still runs, because
    -- a partial set is exactly the case the teardown exists for.
    if vehicleToggleEventId ~= nil and vehicleEditEventId ~= nil
        and playerToggleEventId ~= nil and playerEditEventId ~= nil then
        return
    end

    -- Drop stale vehicle (and player) slots — removeActionEvent can invalidate
    -- same-action PLAYER registrations (SoilFertilizer documented).
    local stale = { vehicleToggleEventId, vehicleEditEventId, playerToggleEventId, playerEditEventId }
    for i = 1, #stale do
        local id = stale[i]
        if id ~= nil then
            pcall(function() binding:removeActionEvent(id) end)
        end
    end
    vehicleToggleEventId = nil
    vehicleEditEventId = nil
    playerToggleEventId = nil
    playerEditEventId = nil

    binding:beginActionEventsModification(Vehicle.INPUT_CONTEXT_NAME)

    local okT, idT = binding:registerActionEvent(
        InputAction.MH_TOGGLE_ALL_HUDS, masterHUD, onToggleAllHuds,
        false, true, false, true
    )
    if okT and idT then
        vehicleToggleEventId = idT
        binding:setActionEventTextVisibility(idT, false)
    end

    local okE, idE = binding:registerActionEvent(
        InputAction.MH_EDIT_HUDS, masterHUD, onEditHuds,
        false, true, false, true
    )
    if okE and idE then
        vehicleEditEventId = idE
        binding:setActionEventTextVisibility(idE, false)
    end

    binding:endActionEventsModification()

    -- Re-register PLAYER — Vehicle remove can wipe the on-foot slots.
    binding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)
    local pOkT, pIdT = binding:registerActionEvent(
        InputAction.MH_TOGGLE_ALL_HUDS, masterHUD, onToggleAllHuds,
        false, true, false, true
    )
    if pOkT and pIdT then
        playerToggleEventId = pIdT
        binding:setActionEventTextVisibility(pIdT, false)
    end
    local pOkE, pIdE = binding:registerActionEvent(
        InputAction.MH_EDIT_HUDS, masterHUD, onEditHuds,
        false, true, false, true
    )
    if pOkE and pIdE then
        playerEditEventId = pIdE
        binding:setActionEventTextVisibility(pIdE, false)
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

-- Draw after the base game HUD so overlays sit on top.
FSBaseMission.draw = Utils.appendedFunction(FSBaseMission.draw, function(mission)
    masterHUD:onDraw()
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
