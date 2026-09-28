--!load: tools/test/lua/f201_model_binding.lua, tools/test/lua/f201_boot.lua, ../FS25_SettingsHub/src/rf/RfActionRegistry.lua, src/Logger.lua, src/OverlayRenderer.lua, src/NoticeQueue.lua, src/MasterHUD.lua, src/MhContextInput.lua, main.lua
-- SP04 (Iris's answer, tracking 4cd6218): with MasterHUD present, MasterHUD
-- registers the seven companion HUD toggle keys the companions stand down, and a
-- press runs the companion's existing Control Center delegate.
--
-- ENTRY-POINT BAR: the REAL main.lua, driven by its own hooks in load order
-- (module load installs the wrappers; Mission00.load activates and subscribes the
-- loading-screen catch-up; loadMission00Finished runs MasterHUD's own catch-up), the
-- engine's player registration through the wrapped PlayerInputComponent, the cab
-- through InputBinding.endActionEventsModification, and CURRENT_MISSION_LOADED
-- through a model of the engine's MessageCenter (subscribeOneshot, unsubscribe,
-- target-first publish; MessageCenter.lua:24-111). Every delegate goes through
-- SettingsHub's REAL RfActionRegistry.registerAction (loaded from the sibling
-- ../FS25_SettingsHub checkout), which publishes the handle MasterHUD reads. No
-- `delegates` entry is written by hand. InputBinding is the F201 model binding.
--
--   L  load order: the owning player's first registration and MasterHUD's own
--      catch-up both run before the companions' delegates exist, and the
--      loading-screen catch-up registers the toggles for the first press
--   D  an action whose companion is absent (InputAction nil) gets no event
--   E  an action with no delegate gets no event; a delegate published later is
--      registered at the next PLAYER rebuild
--   A  all seven on foot, CS / RWE / SF in the cab, on MasterHUD's own targets,
--      F1 text hidden
--   C  TM_TOGGLE_HUD, declared and delegated, gets no MasterHUD event
--   B  one press runs that companion's delegate exactly once; key-up runs nothing
--   M  MasterHUD's own two keys are unchanged
--   U  mission delete clears the companion ids and drops a pending catch-up
--
-- Targeted mutations: drop the hide (A fails), present always true (E1 fails), add
-- TM_TOGGLE_HUD to the list (C fails), drop the key-up guard (B fails), drop the
-- loading-screen subscription (L3 fails).

local b = g_inputBinding
local wPlayer = PlayerInputComponent.registerActionEvents
local record = MasterHUD._f201Input
local hud = g_masterHUD

-- ── Engine model: MessageCenter (MessageCenter.lua, FS25 decompile) ──────────
local function newMessageCenter()
  local mc = { subscribers = {} }
  function mc:subscribe(messageType, callback, callbackTarget, argument, isOneShot)
    if messageType == nil or callback == nil then return end
    local list = self.subscribers[messageType]
    if list == nil then list = {}; self.subscribers[messageType] = list end
    table.insert(list, { callback = callback, callbackTarget = callbackTarget,
                         argument = argument, isOneShot = isOneShot == true })
  end
  function mc:subscribeOneshot(messageType, callback, callbackTarget, argument)
    self:subscribe(messageType, callback, callbackTarget, argument, true)
  end
  function mc:unsubscribe(messageType, callbackTarget, callback)
    local list = self.subscribers[messageType]
    if list == nil then return end
    for i = #list, 1, -1 do
      local info = list[i]
      if info.callbackTarget == callbackTarget and (callback == nil or info.callback == callback) then
        table.remove(list, i)
      end
    end
    if #list == 0 then self.subscribers[messageType] = nil end
  end
  function mc:publish(messageType, ...)
    local list = self.subscribers[messageType]
    if list == nil then return end
    local i = 1
    while true do
      local info = list[i]
      if info == nil then break end
      if info.callbackTarget == nil then
        if info.argument == nil then info.callback(...) else info.callback(info.argument, ...) end
      elseif info.argument == nil then
        info.callback(info.callbackTarget, ...)
      else
        info.callback(info.callbackTarget, info.argument, ...)
      end
      if info.isOneShot then table.remove(list, i) else i = i + 1 end
    end
  end
  return mc
end
local savedMc, savedMt = g_messageCenter, MessageType
g_messageCenter = newMessageCenter()
MessageType = { CURRENT_MISSION_LOADED = "CURRENT_MISSION_LOADED" }

local SEVEN = { "CS_TOGGLE_HUD", "FC_TOGGLE_HUD", "IM_TOGGLE_HUD", "NPC_TOGGLE_HUD",
                "RWE_TOGGLE_HUD", "SF_TOGGLE_HUD", "WT_TOGGLE_HUD" }
local CAB = { CS_TOGGLE_HUD = true, RWE_TOGGLE_HUD = true, SF_TOGGLE_HUD = true }

-- The companions' delegates, as each companion publishes it (run only; counted).
local runs = {}
local function companionPublishes(action)
  runs[action] = 0
  return RfActionRegistry.registerAction({ action = action, button = "Toggle",
    run = function() runs[action] = runs[action] + 1 end })
end

local function playerTarget() return record.targets and record.targets.PLAYER end
local function vehicleTarget() return record.targets and record.targets.VEHICLE end
--- MasterHUD's own event for an action in a context, or nil.
local function mhEvent(ctx, action, target)
  for _, ev in ipairs(b:list(ctx, action)) do
    if ev.targetObject == target then return ev end
  end
  return nil
end
local function companionEvents(ctx, target)
  local n = 0
  for _, a in ipairs(SEVEN) do if mhEvent(ctx, a, target) then n = n + 1 end end
  if mhEvent(ctx, "TM_TOGGLE_HUD", target) then n = n + 1 end
  return n
end

-- ── The load, in the engine's order ──────────────────────────────────────────
-- Every companion that is installed declares its action (modDesc). WT's companion
-- is not installed yet (group D).
for _, a in ipairs(SEVEN) do if a ~= "WT_TOGGLE_HUD" then InputAction[a] = a end end
InputAction.TM_TOGGLE_HUD = "TM_TOGGLE_HUD"

local mission = { getIsClient = function() return true end, getIsServer = function() return true end }
g_currentMission = mission
Mission00.load(mission)                                       -- MasterHUD: activate + subscribe
RfActionRegistry.publish()                                    -- SettingsHub's own Mission00.load
b:context("PLAYER")
wPlayer({ player = { isOwner = true } })                      -- the owning player loads (Player.lua:204-208)
T.eq("L1 [reached: the player's first registration during load has MasterHUD's own two keys]", mhEvent("PLAYER", "MH_TOGGLE_ALL_HUDS", playerTarget()) ~= nil, true)
T.eq("L2 no companion key yet: no delegate exists", companionEvents("PLAYER", playerTarget()), 0)
Mission00.loadMission00Finished(mission)                      -- MasterHUD's catch-up + its own delegates
for _, a in ipairs(SEVEN) do
  if a ~= "NPC_TOGGLE_HUD" then companionPublishes(a) end     -- the companions' loadMission00Finished (NPC late: group E)
end
companionPublishes("TM_TOGGLE_HUD")
T.eq("L2b [reached: MasterHUD's catch-up ran before the companions published]", companionEvents("PLAYER", playerTarget()), 0)
g_messageCenter:publish(MessageType.CURRENT_MISSION_LOADED)   -- the loading screen is dismissed
T.eq("L3 NAMED: the loading-screen catch-up registers the delegated, declared toggles for the first press (CS FC IM RWE SF)",
  companionEvents("PLAYER", playerTarget()), 5)

-- ── D: companion absent ──────────────────────────────────────────────────────
T.eq("D1 WT's companion absent (no InputAction): no event, although a delegate exists", mhEvent("PLAYER", "WT_TOGGLE_HUD", playerTarget()), nil)

-- ── E: no delegate, then a late delegate ─────────────────────────────────────
T.eq("E1 NAMED: NPC declared but not delegated: no event", mhEvent("PLAYER", "NPC_TOGGLE_HUD", playerTarget()), nil)
InputAction.WT_TOGGLE_HUD = "WT_TOGGLE_HUD"
companionPublishes("NPC_TOGGLE_HUD")
FSBaseMission.update(mission, 16)                             -- admission reset
wPlayer({ player = { isOwner = true } })                      -- the next PLAYER rebuild
T.ok("E2 a delegate published later is registered at the next PLAYER rebuild", mhEvent("PLAYER", "NPC_TOGGLE_HUD", playerTarget()) ~= nil)
T.ok("D2 and WT, once its action exists", mhEvent("PLAYER", "WT_TOGGLE_HUD", playerTarget()) ~= nil)

-- ── A: the full set ──────────────────────────────────────────────────────────
T.eq("A1 all seven toggles on foot", companionEvents("PLAYER", playerTarget()), 7)
local hidden = 0
for _, a in ipairs(SEVEN) do
  local ev = mhEvent("PLAYER", a, playerTarget())
  if ev and ev.displayIsVisible == false then hidden = hidden + 1 end
end
T.eq("A2 NAMED: F1 text hidden on all seven", hidden, 7)
T.eq("A3 on foot the ids sit on the instance", hud["companionHud_SF_TOGGLE_HUD_player"] ~= nil, true)
b:beginActionEventsModification("VEHICLE"); b:endActionEventsModification()
local cabN, cabHidden, cabWrong = 0, 0, 0
for _, a in ipairs(SEVEN) do
  local ev = mhEvent("VEHICLE", a, vehicleTarget())
  if ev then
    cabN = cabN + 1
    if ev.displayIsVisible == false then cabHidden = cabHidden + 1 end
    if not CAB[a] then cabWrong = cabWrong + 1 end
  end
end
T.eq("A4 three toggles in the cab", cabN, 3)
T.eq("A5 exactly CS, RWE and SF (the others are on-foot keys standalone)", cabWrong, 0)
T.eq("A6 F1 text hidden in the cab too", cabHidden, 3)
T.ok("A7 the cab events are MasterHUD's own cab target, not the on-foot one", vehicleTarget() ~= nil and vehicleTarget() ~= playerTarget())

-- ── C: TaxMod excluded ───────────────────────────────────────────────────────
T.eq("C1 NAMED: TM_TOGGLE_HUD, declared and delegated, gets no MasterHUD event on foot", mhEvent("PLAYER", "TM_TOGGLE_HUD", playerTarget()), nil)
T.eq("C2 nor in the cab", mhEvent("VEHICLE", "TM_TOGGLE_HUD", vehicleTarget()), nil)

-- ── B: a press ───────────────────────────────────────────────────────────────
local sf = mhEvent("PLAYER", "SF_TOGGLE_HUD", playerTarget())
sf.callback(sf.targetObject, sf.actionName, 0)
T.eq("B1 NAMED: key-up runs nothing", runs.SF_TOGGLE_HUD, 0)
sf.callback(sf.targetObject, sf.actionName, 1)
T.eq("B2 one press runs Soil's delegate exactly once", runs.SF_TOGGLE_HUD, 1)
T.eq("B3 and no other companion's", runs.CS_TOGGLE_HUD + runs.FC_TOGGLE_HUD + runs.IM_TOGGLE_HUD + runs.NPC_TOGGLE_HUD + runs.RWE_TOGGLE_HUD + runs.WT_TOGGLE_HUD + runs.TM_TOGGLE_HUD, 0)
local cs = mhEvent("VEHICLE", "CS_TOGGLE_HUD", vehicleTarget())
cs.callback(cs.targetObject, cs.actionName, 1)
T.eq("B4 a cab press runs Crop Stress's delegate once", runs.CS_TOGGLE_HUD, 1)
-- A delegate that throws is contained and logged; the key stays live.
RfActionRegistry.registerAction({ action = "FC_TOGGLE_HUD", run = function() error("synthetic") end })
local fc = mhEvent("PLAYER", "FC_TOGGLE_HUD", playerTarget())
local okPress = pcall(fc.callback, fc.targetObject, fc.actionName, 1)
T.eq("B5 a delegate that throws does not break the input callback", okPress, true)

-- ── M: MasterHUD's own keys ──────────────────────────────────────────────────
local own = mhEvent("PLAYER", "MH_TOGGLE_ALL_HUDS", playerTarget())
T.ok("M1 MasterHUD's own toggle is still registered on foot", own ~= nil and own.displayIsVisible == true)
T.ok("M2 and in the cab", mhEvent("VEHICLE", "MH_TOGGLE_ALL_HUDS", vehicleTarget()) ~= nil)

-- ── U: mission delete ────────────────────────────────────────────────────────
FSBaseMission.delete(mission)
T.eq("U1 delete clears the companion ids", hud["companionHud_SF_TOGGLE_HUD_player"], nil)
T.eq("U2 and the cab ones", hud["companionHud_RWE_TOGGLE_HUD_vehicle"], nil)
local mission2 = { getIsClient = function() return true end, getIsServer = function() return true end }
g_currentMission = mission2
Mission00.load(mission2)
T.eq("U3 [reached: the next load subscribes its catch-up]", g_messageCenter.subscribers[MessageType.CURRENT_MISSION_LOADED] ~= nil, true)
FSBaseMission.delete(mission2)
T.eq("U4 a mission deleted during load drops its pending catch-up", g_messageCenter.subscribers[MessageType.CURRENT_MISSION_LOADED], nil)

g_messageCenter, MessageType = savedMc, savedMt
