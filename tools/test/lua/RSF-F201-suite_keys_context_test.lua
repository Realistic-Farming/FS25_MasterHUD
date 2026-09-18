--!load: tools/test/lua/f201_model_binding.lua, tools/test/lua/f201_boot.lua, src/Logger.lua, src/OverlayRenderer.lua, src/NoticeQueue.lua, src/MasterHUD.lua, src/MhContextInput.lua, main.lua
-- RSF-F201, MasterHUD MH_TOGGLE_ALL_HUDS / MH_EDIT_HUDS through the REAL main.lua
-- driven by its own hooks: activate at Mission00.load, catch-up in
-- loadMission00Finished ahead of the registry early return, admission reset at
-- the top of update, retire at FSBaseMission.delete without restoring the
-- wrappers. Model binding, not the native InputBinding.

local b = g_inputBinding
local wPlayer, wVehicle = PlayerInputComponent.registerActionEvents, InputBinding.endActionEventsModification
T.ok("F201 MH A1 PLAYER wrapper installed at module load", wPlayer ~= F201Boot.nativePlayer)
T.ok("F201 MH A2 VEHICLE wrapper installed at module load", wVehicle ~= F201Boot.nativeVehicle)
local record = MasterHUD._f201Input
T.ok("F201 MH A3 record on the MasterHUD class table", record ~= nil)
T.eq("F201 MH A4 not active before a mission", record.active, false)

local mission = { getIsClient = function() return true end, getIsServer = function() return true end }
g_currentMission = mission
local hud = g_masterHUD
local toggles, edits = 0, 0
hud.toggleHudsHidden = function() toggles = toggles + 1 end
hud.toggleLayoutEditMode = function() edits = edits + 1 end

-- GROUP B: Mission00.load binds the surviving instance as owner
Mission00.load(mission)
T.eq("F201 MH B1 owner is the module instance", record.owner, hud)
T.eq("F201 MH B2 mission bound", record.mission, mission)
T.eq("F201 MH B3 nothing registered yet", b.attempts, 0)

-- GROUP C: post-load catch-up runs ahead of the registry early return
b:context("PLAYER")
T.eq("F201 MH C0 no registry published", g_currentMission.rfActionRegistry, nil)
Mission00.loadMission00Finished(mission)
T.eq("F201 MH C1 both PLAYER actions registered by the catch-up", b:totalIn("PLAYER"), 2)
T.ok("F201 MH C2 toggle handle on the instance", hud.playerToggleEventId ~= nil)
T.ok("F201 MH C3 edit handle on the instance", hud.playerEditEventId ~= nil)
local pev = b.events[hud.playerToggleEventId]
T.eq("F201 MH C4 legend row visible", pev.displayIsVisible, true)
T.eq("F201 MH C5 legend row active", pev.isActive, true)
wPlayer({ player = { isOwner = true } })
T.eq("F201 MH C6 predecessor called", F201Boot.nativeCalls, 1)
T.eq("F201 MH C7 complete PLAYER set: no registration", b.attempts, 2)

-- GROUP D: VEHICLE set, complete set costs nothing, keys reach the instance
b:beginActionEventsModification("VEHICLE"); b:endActionEventsModification()
T.eq("F201 MH D1 both cab actions registered", b:totalIn("VEHICLE"), 2)
T.ok("F201 MH D2 cab identity differs", hud.vehicleToggleEventId ~= hud.playerToggleEventId)
local begun = b.begun
b:beginActionEventsModification("VEHICLE"); b:endActionEventsModification()
T.eq("F201 MH D3 complete cab set: only the engine bracket", b.begun, begun + 1)
local vev = b.events[hud.vehicleToggleEventId]
vev.callback(vev.targetObject, vev.actionName, 0)
T.eq("F201 MH D4 key-up ignored", toggles, 0)
vev.callback(vev.targetObject, vev.actionName, 1)
T.eq("F201 MH D5 cab toggle reaches the instance", toggles, 1)
local eev = b.events[hud.playerEditEventId]
eev.callback(eev.targetObject, eev.actionName, 1)
T.eq("F201 MH D6 on-foot edit reaches the instance", edits, 1)

-- GROUP E: cab rebuild after update reset, PLAYER survives
b:deleteContext("VEHICLE")
FSBaseMission.update(mission, 16)
b:beginActionEventsModification("VEHICLE"); b:endActionEventsModification()
T.eq("F201 MH E1 rebuilt cab registers again", b:totalIn("VEHICLE"), 2)
T.ok("F201 MH E2 PLAYER events survive", b.events[hud.playerToggleEventId] ~= nil)

-- GROUP F: delete retires, clears ids, restores nothing
FSBaseMission.delete(mission)
T.eq("F201 MH F1 record inactive", record.active, false)
T.eq("F201 MH F2 player toggle id cleared", hud.playerToggleEventId, nil)
T.eq("F201 MH F3 vehicle edit id cleared", hud.vehicleEditEventId, nil)
T.eq("F201 MH F4 PLAYER wrapper not restored", PlayerInputComponent.registerActionEvents, wPlayer)
T.eq("F201 MH F5 VEHICLE wrapper not restored", InputBinding.endActionEventsModification, wVehicle)
toggles = 0
vev.callback(vev.targetObject, vev.actionName, 1)
T.eq("F201 MH F6 retired target forwards nothing", toggles, 0)

-- GROUP G: next mission re-binds the same instance, no stacking
local mission2 = { getIsClient = function() return true end, getIsServer = function() return true end }
g_currentMission = mission2
Mission00.load(mission2)
T.eq("F201 MH G1 rebound to the new mission", record.mission, mission2)
T.eq("F201 MH G2 still one PLAYER wrapper", PlayerInputComponent.registerActionEvents, wPlayer)
b:deleteContext("PLAYER"); b:context("PLAYER")
wPlayer({ player = { isOwner = true } })
T.eq("F201 MH G3 fresh targets register in the new mission", b:totalIn("PLAYER"), 2)
