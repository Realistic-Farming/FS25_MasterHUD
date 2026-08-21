-- =========================================================
-- FS25_MasterHUD - NoticeQueue  (BUILD 15:39, PB-13 / PB-14)
-- =========================================================
-- The suite's one non-blocking notice channel.
--
-- WHY. Two findings in Brian's GUI DEV 14:24 are the same defect wearing
-- different clothes. Market Dynamics fired Cold Snap, Root Crop Blight and
-- Regional Drought at the player inside one short session, interrupting an open
-- console (PB-13). NPC Favor announced itself in a red blinking warning that
-- also advertised a developer console command, competing with the Soil
-- changelog for the same first-load attention (PB-14). Neither mod was wrong on
-- its own: there was simply no shared channel with a cadence, so every mod
-- shouted directly at the HUD.
--
-- THE CONTRACT (DESIGN 15:00 §6)
--   * Non-blocking. No modal, no dialog, no focus steal, no pause. A notice is
--     a line, never a decision.
--   * One per in-game-day window, per topic key. Anything else that arrives in
--     the same window is folded into a single "+N more" line rather than queued
--     into a tower.
--   * Silent while a menu, a dialog, or a fullscreen claim (the tablet) is up.
--     Notices surface after that closes, sequentially, never stacked.
--   * Replace-in-place. One line on screen at a time, the scanner-readout
--     discipline the suite already uses.
--
-- Only a genuine player DECISION may escalate to a modal, and DESIGN 15:00 §6
-- records that no current market event qualifies. There is deliberately no
-- modal path in this file.
-- =========================================================

MHNoticeQueue = {}
local MHNoticeQueue_mt = Class(MHNoticeQueue)

-- How long a single notice holds the line before the next one is shown.
MHNoticeQueue.SHOW_MS = 6000
-- Gap between one notice clearing and the next appearing, so a run of notices
-- reads as separate lines instead of one flickering line.
MHNoticeQueue.GAP_MS = 700
-- Hard cap on the backlog. Beyond this the oldest are dropped and counted, so a
-- misbehaving producer can never grow this without bound.
MHNoticeQueue.MAX_QUEUE = 12

function MHNoticeQueue.new(hud)
    local self = setmetatable({}, MHNoticeQueue_mt)
    self.hud       = hud
    self.queue     = {}
    self.current   = nil
    self.timer     = 0
    self.dropped   = 0
    -- topic key -> the in-game day index that topic last spoke on.
    self.lastDay   = {}
    -- topic key -> how many were folded into that day's single line.
    self.foldCount = {}
    return self
end

--- Current in-game day. FS25 has no os.date in the sandbox; the environment's
--- day counter is the clock the whole suite uses.
local function currentDay()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil then return 0 end
    return env.currentDay or 0
end

--- True while something is covering the world: a menu or dialog, the suite hide
--- toggle, or an element claiming the whole screen (the tablet). Notices wait.
function MHNoticeQueue:isBlocked()
    if g_gui ~= nil then
        local ok, visible = pcall(function()
            return g_gui:getIsGuiVisible() or g_gui:getIsDialogVisible()
        end)
        if ok and visible then return true end
    end
    local hud = self.hud
    if hud ~= nil then
        if hud.hudsHidden then return true end
        if type(hud.getFullscreenOwner) == "function" then
            local ok, owner = pcall(hud.getFullscreenOwner, hud)
            if ok and owner ~= nil then return true end
        end
    end
    return false
end

--- Post a notice.
---
---@param spec table
---   text      string  the player-facing line. Required.
---   topic     string  pacing key; one line per in-game day per topic.
---                     Defaults to the text, i.e. pacing per distinct message.
---   title     string  optional short prefix.
---   foldable  boolean when true (default) a repeat inside the same day window
---                     increments a counter instead of queueing another line.
---@return boolean true when the notice was accepted (queued or folded)
function MHNoticeQueue:post(spec)
    if type(spec) ~= "table" or type(spec.text) ~= "string" or spec.text == "" then
        return false
    end

    local topic = spec.topic or spec.text
    local day   = currentDay()

    if spec.foldable ~= false and self.lastDay[topic] == day then
        -- Already spoke about this today. Fold rather than queue: the three
        -- market events in one session become one line with a count.
        self.foldCount[topic] = (self.foldCount[topic] or 0) + 1
        for _, q in ipairs(self.queue) do
            if q.topic == topic then
                q.folded = self.foldCount[topic]
                return true
            end
        end
        if self.current ~= nil and self.current.topic == topic then
            self.current.folded = self.foldCount[topic]
            return true
        end
        -- Nothing left on screen or in the queue to attach the count to, so the
        -- fold is recorded and surfaces with the topic's next window.
        return true
    end

    self.lastDay[topic]   = day
    self.foldCount[topic] = 0

    if #self.queue >= MHNoticeQueue.MAX_QUEUE then
        table.remove(self.queue, 1)
        self.dropped = self.dropped + 1
        MHLogger.warning(
            "NoticeQueue: backlog at %d, dropped the oldest (%d dropped this session)",
            MHNoticeQueue.MAX_QUEUE, self.dropped)
    end

    table.insert(self.queue, {
        topic  = topic,
        title  = spec.title,
        text   = spec.text,
        folded = 0,
    })
    return true
end

--- Render text for a notice, including the folded count when there is one.
local function lineFor(notice)
    local text = notice.text
    if notice.title ~= nil and notice.title ~= "" then
        text = notice.title .. ": " .. text
    end
    if (notice.folded or 0) > 0 then
        text = string.format("%s  (+%d more today)", text, notice.folded)
    end
    return text
end

--- Hand a notice to the game's own non-blocking notification line. This is the
--- ingame notification list, NOT showBlinkingWarning: the blinking warning is a
--- red alarm channel and using it for "a mod loaded" is exactly the PB-14
--- contrast complaint.
local function surface(notice)
    local text = lineFor(notice)
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
        local typ = (FSBaseMission ~= nil and FSBaseMission.INGAME_NOTIFICATION_INFO) or 1
        local ok = pcall(function()
            g_currentMission:addIngameNotification(typ, text)
        end)
        if ok then return true end
    end
    -- No notification list available: log it rather than escalate to a louder
    -- channel. A missed line is better than a red alarm for an info message.
    MHLogger.info("notice: %s", text)
    return false
end

--- Per-frame tick, driven by MasterHUD's update.
function MHNoticeQueue:update(dt)
    dt = tonumber(dt) or 0

    if self.current ~= nil then
        self.timer = self.timer - dt
        if self.timer <= 0 then
            self.current = nil
            self.timer   = MHNoticeQueue.GAP_MS
        end
        return
    end

    if self.timer > 0 then
        self.timer = self.timer - dt
        return
    end

    -- Queue silently while the tablet or a menu is up; surface after it closes.
    if self:isBlocked() then return end
    if #self.queue == 0 then return end

    self.current = table.remove(self.queue, 1)
    self.timer   = MHNoticeQueue.SHOW_MS
    surface(self.current)
end

--- BUILD 21:53 (Sam DESIGN 21:50 item 2): surface a line RIGHT NOW, skipping the
--- queue, the per-day pacing and - decisively - the isBlocked gate. The suite
--- hide/show confirmation is ABOUT the state isBlocked treats as blocked
--- (hudsHidden), so the paced path would hold the "hidden" line until the player
--- un-hides and then deliver it as a stale lie. The surface target is the game's
--- own notification list, which is vanilla HUD and therefore visible while suite
--- HUDs are hidden. Still non-modal, still auto-dismissing, still one line.
--- For anything that is not a state-change confirmation, post() with its pacing
--- remains the only correct channel - do not reach for this to skip the queue.
---@param spec table { text, title }
---@return boolean surfaced
function MHNoticeQueue:postImmediate(spec)
    if type(spec) ~= "table" or type(spec.text) ~= "string" or spec.text == "" then
        return false
    end
    return surface({ topic = spec.text, title = spec.title, text = spec.text, folded = 0 })
end

function MHNoticeQueue:getStatus()
    return {
        queued  = #self.queue,
        showing = self.current ~= nil and self.current.topic or nil,
        blocked = self:isBlocked(),
        dropped = self.dropped,
    }
end

getfenv(0)["MHNoticeQueue"] = MHNoticeQueue
