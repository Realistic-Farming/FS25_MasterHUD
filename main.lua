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
--   FSBaseMission.delete     -> free the shared overlay + drop the handle
--
-- Load order: MasterHUD is mod 3 (after StateLedger and NetworkSync). The
-- handle is published as soon as this file runs so companions loading after
-- it can register during their own module load.
-- =========================================================

local modDirectory = g_currentModDirectory

source(modDirectory .. "src/Logger.lua")
source(modDirectory .. "src/OverlayRenderer.lua")
source(modDirectory .. "src/MasterHUD.lua")

local masterHUD = MasterHUD.new()
getfenv(0)["g_masterHUD"] = masterHUD

local function onMissionLoad(mission)
    if mission ~= nil then
        mission.masterHUD = masterHUD
    end
    MHLogger.info("MasterHUD active (mod 3, UI renderer)")
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

FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, onMissionDelete)

if addConsoleCommand ~= nil then
    addConsoleCommand("mhStatus", "Show MasterHUD registered overlays and panels",
        "consoleCommandStatus", masterHUD)
end
