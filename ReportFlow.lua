-- Sift/ReportFlow.lua
-- Remembers the chat line behind each blocked History entry so the player can
-- open Blizzard's spam report for it later.

local _, NS = ...
local ReportFlow = {}

local targetsByEntryID = {}

-- History entry IDs are monotonic per character, and History never holds more
-- than this many entries, so an older ID can no longer be in History.
local MAX_TRACKED_TARGETS = 5000

-- Low-water mark: every id below this is already absent from targetsByEntryID.
-- Queued ids are not contiguous (some rows queue no target), so each call clears
-- the whole range up to the limit and never revisits an id already cleared.
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

  if not C_ChatInfo or type(C_ChatInfo.IsValidChatLine) ~= "function" then
    DevLog("chat report line-validity API unavailable.")
    return false
  end

  -- History rows outlive chat lines: an old row's lineID can fall out of the
  -- client's chat buffer before the player acts on it. Once that happens it
  -- never becomes valid again, so drop the target -- the button/menu entry
  -- disappears on the next render instead of staying dead.
  if not C_ChatInfo.IsValidChatLine(target.lineID) then
    DevLog("chat report line has expired.")
    ClearTarget(historyEntryID)
    return false
  end

  if not PlayerLocation or type(PlayerLocation.CreateFromChatLineID) ~= "function" then
    DevLog("chat report location API unavailable.")
    return false
  end

  local locationOk, location = pcall(PlayerLocation.CreateFromChatLineID, PlayerLocation, target.lineID)
  if not locationOk or not location then
    DevLog("chat report location unavailable.")
    return false
  end

  if not C_ReportSystem or type(C_ReportSystem.CanReportPlayer) ~= "function" then
    DevLog("chat report eligibility API unavailable.")
    return false
  end

  local canCheck, canReport = pcall(C_ReportSystem.CanReportPlayer, location)
  if not canCheck or not canReport then
    DevLog("chat report target is not reportable.")
    ClearTarget(historyEntryID)
    return false
  end

  if not ReportInfo or type(ReportInfo.CreateReportInfoFromType) ~= "function"
      or not ReportFrame or type(ReportFrame.InitiateReport) ~= "function"
      or type(Enum) ~= "table" or type(Enum.ReportType) ~= "table" or Enum.ReportType.Chat == nil then
    DevLog("chat report dialog API unavailable.")
    return false
  end

  local reportInfo = ReportInfo:CreateReportInfoFromType(Enum.ReportType.Chat)
  local ok = pcall(ReportFrame.InitiateReport, ReportFrame, reportInfo, target.senderName, location)
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
