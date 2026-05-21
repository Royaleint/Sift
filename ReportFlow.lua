local _, NS = ...
local ReportFlow = {}

local LFG_AD_QUEUE_CAP = 500
local LFG_APPLICANT_QUEUE_CAP = 500

local targetsByEntryID = {}

local function Now()
  if type(GetTime) == "function" then
    return GetTime()
  end
  return time()
end

local function DevLog(message)
  if NS.DB and NS.DB.DevLog then
    NS.DB.DevLog(message)
  end
end

local function CountKind(kind)
  local count = 0
  for _, target in pairs(targetsByEntryID) do
    if target.kind == kind then
      count = count + 1
    end
  end
  return count
end

local function EvictOldestKind(kind)
  local oldestEntryID = nil
  local oldestQueuedAt = nil
  for entryID, target in pairs(targetsByEntryID) do
    if target.kind == kind and (not oldestQueuedAt or target.queuedAt < oldestQueuedAt) then
      oldestEntryID = entryID
      oldestQueuedAt = target.queuedAt
    end
  end

  if oldestEntryID ~= nil then
    targetsByEntryID[oldestEntryID] = nil
  end
end

local function TrimKind(kind, cap)
  while CountKind(kind) > cap do
    EvictOldestKind(kind)
  end
end

local function QueueTarget(historyEntryID, target)
  if historyEntryID == nil or type(target) ~= "table" or type(target.kind) ~= "string" then
    return false
  end

  target.queuedAt = target.queuedAt or Now()
  targetsByEntryID[historyEntryID] = target
  if target.kind == "lfg-ad" then
    TrimKind(target.kind, LFG_AD_QUEUE_CAP)
  elseif target.kind == "lfg-applicant" then
    TrimKind(target.kind, LFG_APPLICANT_QUEUE_CAP)
  end
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

function ReportFlow.QueueLFGAdvertisementReport(historyEntryID, searchResultID, listingName)
  if searchResultID == nil then
    return false
  end

  return QueueTarget(historyEntryID, {
    kind = "lfg-ad",
    searchResultID = searchResultID,
    listingName = listingName,
  })
end

function ReportFlow.QueueLFGApplicantReport(historyEntryID, applicantID, memberName)
  if applicantID == nil then
    return false
  end

  return QueueTarget(historyEntryID, {
    kind = "lfg-applicant",
    applicantID = applicantID,
    memberName = memberName,
  })
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
  return target ~= nil and target.kind ~= "lfg-applicant"
end

function ReportFlow.GetReportKind(historyEntryID)
  local target = targetsByEntryID[historyEntryID]
  return target and target.kind or nil
end

function ReportFlow.CanReportChat()
  return CanReportChat()
end

function ReportFlow.ReportLFGAdvertisementNow(historyEntryID)
  local target = GetTarget(historyEntryID, "lfg-ad")
  if not target then
    return false
  end

  if not C_LFGList or type(C_LFGList.ReportGroupAsAdvertisement) ~= "function" then
    DevLog("LFG advertisement report API unavailable.")
    return false
  end

  if type(target.searchResultID) ~= "number" then
    DevLog("LFG advertisement report target missing numeric searchResultID.")
    return false
  end

  local ok = pcall(C_LFGList.ReportGroupAsAdvertisement, target.searchResultID)
  if ok then
    ClearTarget(historyEntryID)
    return true
  end

  DevLog("LFG advertisement report failed.")
  return false
end

function ReportFlow.ReportLFGApplicantNow(historyEntryID)
  if GetTarget(historyEntryID, "lfg-applicant") then
    DevLog("LFG applicant reports are unavailable in this version.")
  end
  return false
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

function ReportFlow.ClearTransientLFG()
  for entryID, target in pairs(targetsByEntryID) do
    if target.kind == "lfg-ad" or target.kind == "lfg-applicant" then
      targetsByEntryID[entryID] = nil
    end
  end
end

NS.ReportFlow = ReportFlow
return ReportFlow
