local _, NS = ...
local ChatScanner = {}

local CHAT_EVENTS = {
  "CHAT_MSG_SAY",
  "CHAT_MSG_YELL",
  "CHAT_MSG_WHISPER",
  "CHAT_MSG_CHANNEL",
  "CHAT_MSG_EMOTE",
  "CHAT_MSG_TEXT_EMOTE",
  "CHAT_MSG_DND",
  "CHAT_MSG_AFK",
}

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
  local score = NS.Scoring and NS.Scoring.Score and NS.Scoring.Score(analysis, BuildScoringOptions(settings))
  if not score or not score.blocked then
    return false
  end

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
    score = score.score,
    threshold = score.threshold,
    breakdown = score.breakdown,
    containsItemLinks = analysis.signals and analysis.signals.containsItemLinks == true,
    outcome = "blocked",
    reason = "score",
  }

  if settings.devMode == true then
    record.cleansed = analysis.normalized
  end

  local entryID = NS.History and NS.History.Append and NS.History.Append(record)
  if NS.Suppression and NS.Suppression.MarkChatLine then
    NS.Suppression.MarkChatLine(counter, entryID)
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
