local _, NS = ...
local ReportFlow = {}

local targetsByEntryID = {}

-- History entry IDs are a per-character monotonic cursor, so once an ID
-- falls this far behind the newest queued one it can no longer be in
-- History (whose per-character cap tops out at this value either way).
local MAX_TRACKED_TARGETS = 5000

-- Low-water mark: every id below this is already known absent from
-- targetsByEntryID. Not every appended row queues a target (a manual block
-- or a missing chat line id skips it), so the ids reaching QueueTarget are
-- not contiguous; the sweep below only has to make sure that, after each
-- call, nothing at or below the current id minus the tracked width is left
-- behind, and it never revisits an id it already cleared.
local pruneBelow

local function PruneTargetsBelow(limit)
  if pruneBelow == nil then
    pruneBelow = limit + 1
    return
  end
  if limit < pruneBelow then
    return
  end
  if limit - pruneBelow < MAX_TRACKED_TARGETS then
    for id = pruneBelow, limit do
      if targetsByEntryID[id] ~= nil then
        targetsByEntryID[id] = nil
      end
    end
  else
    for id in pairs(targetsByEntryID) do
      if id <= limit then
        targetsByEntryID[id] = nil
      end
    end
  end
  pruneBelow = limit + 1
end

local function DevLog(message)
  if NS.DB and NS.DB.DevLog then
    NS.DB.DevLog(message)
  end
end

local function QueueTarget(historyEntryID, target)
  if historyEntryID == nil or type(target) ~= "table" or type(target.kind) ~= "string" then
    return false
  end

  targetsByEntryID[historyEntryID] = target
  PruneTargetsBelow(historyEntryID - MAX_TRACKED_TARGETS)
  return targetsByEntryID[historyEntryID] ~= nil
end

local function ClearTarget(historyEntryID)
  targetsByEntryID[historyEntryID] = nil
end

local function GetTarget(historyEntryID, expectedKind)
  local target = targetsByEntryID[historyEntryID]
  if not target then
    return nil
  end

  if expectedKind and target.kind ~= expectedKind then
    return nil
  end

  return target
end

local function CanReportChat()
  return not (NS.Compat and NS.Compat.hasChatReportDialog == false)
end

function ReportFlow.QueueChatReport(historyEntryID, lineID, senderName)
  if lineID == nil or not CanReportChat() then
    return false
  end

  return QueueTarget(historyEntryID, {
    kind = "chat",
    lineID = lineID,
    senderName = senderName,
  })
end

function ReportFlow.HasReport(historyEntryID)
  local target = targetsByEntryID[historyEntryID]
  return target ~= nil
end

function ReportFlow.GetReportKind(historyEntryID)
  local target = targetsByEntryID[historyEntryID]
  return target and target.kind or nil
end

function ReportFlow.CanReportChat()
  return CanReportChat()
end

function ReportFlow.ReportChatNow(historyEntryID)
  local target = GetTarget(historyEntryID, "chat")
  if not target then
    return false
  end

  if not ReportFlow.CanReportChat() then
    DevLog("chat report dialog unavailable in this client.")
    return false
  end

  if not PlayerLocation or type(PlayerLocation.CreateFromChatLineID) ~= "function" then
    DevLog("chat report location API unavailable.")
    return false
  end

  if not C_ReportSystem or type(C_ReportSystem.OpenReportPlayerDialog) ~= "function" then
    DevLog("chat report dialog API unavailable.")
    return false
  end

  if PLAYER_REPORT_TYPE_SPAM == nil then
    DevLog("chat report type unavailable.")
    return false
  end

  local locationOk, location = pcall(PlayerLocation.CreateFromChatLineID, PlayerLocation, target.lineID)
  if not locationOk or not location then
    DevLog("chat report location unavailable.")
    return false
  end

  if type(C_ReportSystem.CanReportPlayer) == "function" then
    local canCheck, canReport = pcall(C_ReportSystem.CanReportPlayer, PLAYER_REPORT_TYPE_SPAM, location)
    if canCheck and canReport == false then
      DevLog("chat report target is not reportable.")
      return false
    end
  end

  local ok = pcall(C_ReportSystem.OpenReportPlayerDialog, PLAYER_REPORT_TYPE_SPAM, location, target.senderName)
  if ok then
    ClearTarget(historyEntryID)
    return true
  end

  DevLog("chat report dialog failed.")
  return false
end

function ReportFlow.Clear(historyEntryID)
  ClearTarget(historyEntryID)
end

NS.ReportFlow = ReportFlow
return ReportFlow
