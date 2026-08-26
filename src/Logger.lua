-- =========================================================
-- FS25_MasterHUD - Logger
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Mod-prefixed logging so lines are greppable by "[MasterHUD]".
-- =========================================================

MHLogger = MHLogger or {}
MHLogger.PREFIX = "[MasterHUD] "
MHLogger.debugEnabled = false

function MHLogger.info(msg, ...)
    if select("#", ...) > 0 then Logging.info(MHLogger.PREFIX .. msg, ...)
    else Logging.info(MHLogger.PREFIX .. msg) end
end

function MHLogger.warning(msg, ...)
    if select("#", ...) > 0 then Logging.warning(MHLogger.PREFIX .. msg, ...)
    else Logging.warning(MHLogger.PREFIX .. msg) end
end

function MHLogger.error(msg, ...)
    if select("#", ...) > 0 then Logging.error(MHLogger.PREFIX .. msg, ...)
    else Logging.error(MHLogger.PREFIX .. msg) end
end

function MHLogger.debug(msg, ...)
    if not MHLogger.debugEnabled then return end
    if select("#", ...) > 0 then Logging.info(MHLogger.PREFIX .. "[debug] " .. msg, ...)
    else Logging.info(MHLogger.PREFIX .. "[debug] " .. msg) end
end
