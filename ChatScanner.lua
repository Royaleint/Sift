local _, NS = ...
local ChatScanner = {}

local CHAT_EVENTS = {
  "CHAT_MSG_SAY",
  "CHAT_MSG_YELL",
  "CHAT_MSG_WHISPER",
  "CHAT_MSG_BN_WHISPER",
  "CHAT_MSG_CHANNEL",
  "CHAT_MSG_EMOTE",
  "CHAT_MSG_DND",
  "CHAT_MSG_AFK",
}

-- luacheck: push ignore 211/EVENT_TO_SURFACE
-- Dormant in Commit 1 of BSP-008; consumed by the pause gate in Commit 2.
local EVENT_TO_SURFACE = {
  CHAT_MSG_SAY        = "chat",
  CHAT_MSG_YELL       = "chat",
  CHAT_MSG_CHANNEL    = "chat",
  CHAT_MSG_EMOTE      = "chat",
  CHAT_MSG_DND        = "chat",
  CHAT_MSG_AFK        = "chat",
  CHAT_MSG_WHISPER    = "whisper",
  CHAT_MSG_BN_WHISPER = "bn-whisper",
}
-- luacheck: pop

local filterInstalled = {}
local eventFrame = nil
local filterAdd = nil

local function DevLog(message)
  if NS.DB and NS.DB.DevLog then
    NS.DB.DevLog(message)
  end
end

local function ResolveAddFilter()
  if ChatFrameUtil and type(ChatFrameUtil.AddMessageEventFilter) == "function" then
    return ChatFrameUtil.AddMessageEventFilter
  end

  if type(ChatFrame_AddMessageEventFilter) == "function" then
    return ChatFrame_AddMessageEventFilter
  end

  return nil
end

local function ServerTime()
  if type(GetServerTime) == "function" then
    return GetServerTime()
  end
  return time()
end

local function SplitNameRealm(sender)
  if type(sender) ~= "string" then
    return nil, nil
  end

  local name, realm = string.match(sender, "^([^-]+)%-(.+)$")
  return name or sender, realm
end

local function GetSettings()
  return NS.DB and NS.DB.GetSettings and NS.DB.GetSettings() or {}
end

local function BuildScoringOptions(settings)
  return {
    threshold = settings.threshold,
    enabledCategories = settings.enabledCategories,
    mixedScriptWeight = settings.mixedScriptEnabled == false and 0 or settings.mixedScriptWeight,
    antiSignalCap = settings.antiSignalCap,
    patterns = NS.Patterns,
  }
end

local function BuildHistoryRecord(event, message, sender, channelName, guid, analysis, settings, score, threshold, breakdown, reason)
  local name, realm = SplitNameRealm(sender)
  local record = {
    ts = ServerTime(),
    surface = "chat",
    channel = event,
    channelName = (type(channelName) == "string" and channelName ~= "") and channelName or nil,
    guid = guid,
    name = name,
    realm = realm,
    original = message,
    score = score,
    threshold = threshold,
    breakdown = breakdown,
    containsItemLinks = analysis.signals and analysis.signals.containsItemLinks == true,
    outcome = "blocked",
    reason = reason,
  }

  if settings.devMode == true then
    record.cleansed = analysis.normalized
  end

  return record
end

local function AppendBlockedHistory(record, counter)
  local entryID = NS.History and NS.History.Append and NS.History.Append(record)
  if entryID and NS.ReportFlow and NS.ReportFlow.QueueChatReport then
    NS.ReportFlow.QueueChatReport(entryID, counter, record.name)
  end
  if NS.Suppression and NS.Suppression.MarkChatLine then
    NS.Suppression.MarkChatLine(counter, entryID)
  end
end

local function Pipeline(
  event,
  message,
  sender,
  _language,
  _channelString,
  _target,
  flags,
  _unknown,
  _channelNumber,
  channelName,
  _unknown2,
  counter,
  guid
)
  if type(message) ~= "string" or message == "" then
    return false
  end

  if NS.Trust and NS.Trust.IsTrusted and NS.Trust.IsTrusted(guid, sender, flags) then
    return false
  end

  local analysis = NS.Cleanse and NS.Cleanse.Analyze and NS.Cleanse.Analyze(message)
  if not analysis then
    return false
  end

  local settings = GetSettings()
  if NS.Throttle and NS.Throttle.Check and NS.Throttle.Check(event, analysis.normalized, guid) then
    AppendBlockedHistory(BuildHistoryRecord(
      event,
      message,
      sender,
      channelName,
      guid,
      analysis,
      settings,
      settings.threshold,
      settings.threshold,
      { Throttle = settings.threshold },
      "throttle"
    ), counter)
    if NS.BubbleSuppressor and NS.BubbleSuppressor.Engage then
      NS.BubbleSuppressor.Engage(event, settings)
    end
    return true
  end

  local score = NS.Scoring and NS.Scoring.Score and NS.Scoring.Score(analysis, BuildScoringOptions(settings))
  if not score or not score.blocked then
    return false
  end

  AppendBlockedHistory(BuildHistoryRecord(
    event,
    message,
    sender,
    channelName,
    guid,
    analysis,
    settings,
    score.score,
    score.threshold,
    score.breakdown,
    "score"
  ), counter)

  if NS.BubbleSuppressor and NS.BubbleSuppressor.Engage then
    NS.BubbleSuppressor.Engage(event, settings)
  end

  return true
end

local function ErrorHandler(err)
  if NS.DB and NS.DB.IsDevMode and NS.DB.IsDevMode() then
    print("[BawrSpam] xpcall: " .. tostring(err))
  end
  return err
end

function ChatScanner.Filter(
  event,
  message,
  sender,
  language,
  channelString,
  target,
  flags,
  unknown,
  channelNumber,
  channelName,
  unknown2,
  counter,
  guid
)
  if NS.BubbleSuppressor and NS.BubbleSuppressor.MaybeRestore then
    NS.BubbleSuppressor.MaybeRestore()
  end

  local ok, blocked = xpcall(function()
    return Pipeline(
      event,
      message,
      sender,
      language,
      channelString,
      target,
      flags,
      unknown,
      channelNumber,
      channelName,
      unknown2,
      counter,
      guid
    )
  end, ErrorHandler)
  if not ok then
    return false
  end
  return blocked == true
end

local function ChatFrameFilter(
  _self,
  event,
  message,
  sender,
  language,
  channelString,
  target,
  flags,
  unknown,
  channelNumber,
  channelName,
  unknown2,
  counter,
  guid
)
  return ChatScanner.Filter(
    event,
    message,
    sender,
    language,
    channelString,
    target,
    flags,
    unknown,
    channelNumber,
    channelName,
    unknown2,
    counter,
    guid
  )
end

function ChatScanner.Install()
  filterAdd = filterAdd or ResolveAddFilter()
  if not filterAdd then
    DevLog("chat filter API unavailable; scanner not installed.")
    return false
  end

  if not eventFrame and type(CreateFrame) == "function" then
    eventFrame = CreateFrame("Frame")
    eventFrame:SetScript("OnEvent", function() end)
  end

  for i = 1, #CHAT_EVENTS do
    local event = CHAT_EVENTS[i]
    if not filterInstalled[event] then
      local ok = pcall(filterAdd, event, ChatFrameFilter)
      if ok then
        filterInstalled[event] = true
      else
        DevLog("failed to install chat filter for " .. event .. ".")
      end
    end

    if eventFrame then
      pcall(eventFrame.UnregisterEvent, eventFrame, event)
      pcall(eventFrame.RegisterEvent, eventFrame, event)
    end
  end

  return true
end

function ChatScanner.GetInstalledFilters()
  local copy = {}
  for event, installed in pairs(filterInstalled) do
    copy[event] = installed
  end
  return copy
end

NS.ChatScanner = ChatScanner
return ChatScanner
