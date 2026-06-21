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

-- BSP-008 Commit 2: surface taxonomy lookup, consumed by the pause gate
-- in Pipeline() below and used to stamp record.surface on history writes.
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

local filterInstalled = {}
local eventFrame = nil
local filterAdd = nil
local BLOCKED_ACTOR_BOOST = 2
local IGNORED_BREAKDOWN_KEYS = {
  MixedScript = true,
  BlockedActor = true,
  Flood = true,
}

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

local function BuildHistoryRecord(event, message, sender, channelName, guid, analysis, settings, score, threshold, breakdown, reason, surface, outcome)
  local name, realm = SplitNameRealm(sender)
  local record = {
    ts = ServerTime(),
    surface = surface or EVENT_TO_SURFACE[event] or "chat",
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
    outcome = outcome or "blocked",
    reason = reason,
  }

  if settings.devMode == true then
    record.cleansed = analysis.normalized
  end

  return record
end

local function DominantCategory(breakdown)
  if type(breakdown) ~= "table" then
    return nil
  end

  local bestCat, bestVal
  for cat, val in pairs(breakdown) do
    local numeric = tonumber(val) or 0
    if not IGNORED_BREAKDOWN_KEYS[cat] and numeric > 0
       and (not bestVal or numeric > bestVal) then
      bestCat, bestVal = cat, numeric
    end
  end
  return bestCat
end

local function HasPositiveSpamEvidence(breakdown)
  return DominantCategory(breakdown) ~= nil
end

local function ApplyBlockedActorBoost(score, guid)
  if not score or score.blocked or not NS.DB or not NS.DB.GetBlockedActor then
    return
  end
  if not NS.DB.GetBlockedActor(guid) or not HasPositiveSpamEvidence(score.breakdown) then
    return
  end

  score.breakdown = type(score.breakdown) == "table" and score.breakdown or {}
  score.breakdown.BlockedActor = (tonumber(score.breakdown.BlockedActor) or 0) + BLOCKED_ACTOR_BOOST
  score.score = (tonumber(score.score) or 0) + BLOCKED_ACTOR_BOOST
  score.threshold = tonumber(score.threshold) or 4
  score.blocked = score.score >= score.threshold
end

-- BSP-027: pre-score flood boost. Repetition is a spam signal independent of
-- content — the same cleansed line seen >= TRIGGER times within the window
-- (ANY sender) accrues an escalating "Flood" weight so a flood blocks even at
-- content-score 0. Mirrors ApplyBlockedActorBoost: mutate-in-place, bail if
-- already blocked, recompute blocked against the carried threshold. Flood is a
-- meta key (in IGNORED_BREAKDOWN_KEYS) so it never becomes a content category.
local function ApplyFloodBoost(score, cleansed)
  if not score or score.blocked or not NS.Frequency or not NS.Frequency.RecordAndCount then
    return
  end
  local count = NS.Frequency.RecordAndCount(cleansed, ServerTime())
  local boost = NS.Frequency.BoostFor and NS.Frequency.BoostFor(count) or 0
  if boost <= 0 then
    return
  end
  score.breakdown = type(score.breakdown) == "table" and score.breakdown or {}
  score.breakdown.Flood = (tonumber(score.breakdown.Flood) or 0) + boost
  score.score = (tonumber(score.score) or 0) + boost
  score.threshold = tonumber(score.threshold) or 4
  score.blocked = score.score >= score.threshold
end

local function AppendBlockedHistory(record, counter)
  local entryID = NS.History and NS.History.Append and NS.History.Append(record)
  if record and record.outcome == "blocked" and NS.DB and NS.DB.RecordBlockedActor then
    NS.DB.RecordBlockedActor(record, DominantCategory(record.breakdown))
  end
  if entryID and NS.ReportFlow and NS.ReportFlow.QueueChatReport then
    NS.ReportFlow.QueueChatReport(entryID, counter, record.name)
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
    -- BSP-047 devmode diagnostic: name which trust source skipped this sender so
    -- a trust-bypass false-negative (gold-seller short-circuiting the filter) is
    -- visible live in chat. Diagnostic only — no change to filtering behavior.
    if NS.DB and NS.DB.IsDevMode and NS.DB.IsDevMode() then
      local reason = (NS.Trust.TrustReason and NS.Trust.TrustReason(guid, sender, flags)) or "?"
      DevLog("Trust skip [" .. reason .. "]: " .. tostring(sender))
    end
    return false
  end

  -- Surface state gate: off short-circuits the pipeline (no detection, no history).
  -- paused lets detection run but flips outcome to pass-thru and skips bubble suppression.
  local surface = EVENT_TO_SURFACE[event] or "chat"
  local surfaceState = (NS.PauseState and NS.PauseState.GetSurface and NS.PauseState.GetSurface(surface)) or "active"
  if surfaceState == "off" then
    return false
  end
  local blockSuppressed = (surfaceState == "paused")

  local analysis = NS.Cleanse and NS.Cleanse.Analyze and NS.Cleanse.Analyze(message)
  if not analysis then
    return false
  end

  local settings = GetSettings()
  local score = NS.Scoring and NS.Scoring.Score and NS.Scoring.Score(analysis, BuildScoringOptions(settings))
  ApplyBlockedActorBoost(score, guid)
  ApplyFloodBoost(score, analysis.normalized)
  if not score or not score.blocked then
    return false
  end

  -- Category state gate: find the dominant scoring category (excluding MixedScript meta).
  -- off short-circuits; paused flips outcome to pass-thru.
  local breakdown = score.breakdown
  local dominantCategory = DominantCategory(breakdown)
  if dominantCategory then
    local categoryState = (NS.PauseState and NS.PauseState.GetCategory and NS.PauseState.GetCategory(dominantCategory)) or "active"
    if categoryState == "off" then
      return false
    end
    if categoryState == "paused" then
      blockSuppressed = true
    end
  end

  -- Throttle runs ONLY on confirmed-spam (post-Score + post-category-gate). BSP-010 reorder
  -- folded into BSP-008 Commit 2: previously ran before Score and could over-fire on
  -- legitimate duplicates.
  if NS.Throttle and NS.Throttle.Check and NS.Throttle.Check(event, analysis.normalized, guid) then
    local throttleOutcome = blockSuppressed and "pass-thru" or "blocked"
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
      "throttle",
      surface,
      throttleOutcome
    ), counter)
    if NS.History and NS.History.IncrementThrottled then
      NS.History.IncrementThrottled()
    end
    if not blockSuppressed and NS.BubbleSuppressor and NS.BubbleSuppressor.Engage then
      local engaged = NS.BubbleSuppressor.Engage(event, settings)
      if engaged and NS.History and NS.History.IncrementBubblesSuppressed then
        NS.History.IncrementBubblesSuppressed()
      end
    end
    return not blockSuppressed
  end

  local outcome = blockSuppressed and "pass-thru" or "blocked"
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
    "score",
    surface,
    outcome
  ), counter)

  if not blockSuppressed and NS.BubbleSuppressor and NS.BubbleSuppressor.Engage then
    local engaged = NS.BubbleSuppressor.Engage(event, settings)
    if engaged and NS.History and NS.History.IncrementBubblesSuppressed then
      NS.History.IncrementBubblesSuppressed()
    end
  end

  return not blockSuppressed
end

local function ErrorHandler(err)
  if NS.DB and NS.DB.IsDevMode and NS.DB.IsDevMode() then
    print("[Sift] xpcall: " .. tostring(err))
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
