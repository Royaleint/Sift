-- Sift/ChatScanner.lua
-- Installs Sift's message event filter on the scanned chat events and runs each
-- line through the block pipeline: manual block, trust, scoring, keyword rules,
-- pause states, repeat dedupe, then the History record.

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

-- Surface for each event, used by the pause gate and stamped on history records.
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

-- One filter per event: a second add would stack a duplicate on the chat chain.
local filterInstalled = {}
local filterAdd = nil
local BLOCKED_ACTOR_BOOST = 2
-- Meta keys, never a category. Copies in ChatScanner, History, HistoryPanel, ShadowLog, Signals, ConfigPanel:
-- keep all six in step.
local IGNORED_BREAKDOWN_KEYS = {
  MixedScript = true,
  BlockedActor = true,
  Flood = true,
  -- Not a category; older saved rows still carry it, so keep it excluded.
  Throttle = true,
  -- A manual block is an identity decision, never a content category.
  ManualBlock = true,
}

-- Bounded lineID -> GUID ring for the chat-name menu, which gets a lineID but no
-- GUID. Slots are reused in place so the hot path stays garbage-free.
local SENDER_CACHE_SIZE = 128
local senderCacheSlots = {}
local senderCacheByLine = {}
local senderCacheCursor = 0
-- Per-line decision cache: the filter runs once per chat frame showing a line,
-- and only the first call in a frame may run the pipeline (history, flood counts).
local DECISION_CACHE_SIZE = 64
local decisionCacheSlots = {}
local decisionCacheByID = {}
local decisionCacheCursor = 0

-- Mirrors the guard in Trust.lua: chat-event payloads can carry secret values,
-- and any string or comparison operation on one raises.
local function IsSecret(value)
  if type(issecretvalue) ~= "function" then
    return false
  end

  local ok, result = pcall(issecretvalue, value)
  return ok and result == true
end

local function IsUsableString(value)
  if IsSecret(value) then
    return false
  end
  return type(value) == "string" and value ~= ""
end

-- Several events pass 0 for "no line ID"; storing it would collide every such
-- line on one key and misdirect a block. Rejected on write and on read.
local function IsUsableLineID(lineID)
  if IsSecret(lineID) then
    return nil
  end
  lineID = tonumber(lineID)
  if not lineID or lineID <= 0 then
    return nil
  end
  return lineID
end

local function IsFinitePositiveNumber(value)
  if IsSecret(value) or type(value) ~= "number" then return nil end
  if value <= 0 or value ~= value or value == math.huge or value == -math.huge then return nil end
  return value
end

local function IsSafePayloadValue(value)
  if IsSecret(value) then return false end
  local kind = type(value)
  return value == nil or kind == "string" or kind == "number" or kind == "boolean"
end

local function GetFrameStamp()
  if type(GetTime) ~= "function" then return nil end
  local ok, stamp = pcall(GetTime)
  if not ok or IsSecret(stamp) or type(stamp) ~= "number" then return nil end
  if stamp ~= stamp or stamp == math.huge or stamp == -math.huge then return nil end
  return stamp
end

local function SameCategories(slot, categories)
  if type(categories) ~= "table" then return false end
  for key, value in pairs(slot.categories) do
    if categories[key] ~= value then return false end
  end
  for key, value in pairs(categories) do
    if slot.categories[key] ~= value then return false end
  end
  return true
end

-- Any settings field Pipeline reads must be compared here and copied in CopyState.
local function SameSettings(slot, settings)
  if type(settings) ~= "table" then return false end
  return slot.threshold == settings.threshold and slot.mixedScriptEnabled == settings.mixedScriptEnabled
    and slot.mixedScriptWeight == settings.mixedScriptWeight and slot.antiSignalCap == settings.antiSignalCap
    and slot.filterBubbles == settings.filterBubbles and slot.devMode == settings.devMode
end

local function CopyState(slot, settings, categories)
  slot.threshold, slot.mixedScriptEnabled, slot.mixedScriptWeight = settings.threshold, settings.mixedScriptEnabled, settings.mixedScriptWeight
  slot.antiSignalCap, slot.filterBubbles, slot.devMode = settings.antiSignalCap, settings.filterBubbles, settings.devMode
  local categoryCopy = slot.categories or {}
  slot.categories = categoryCopy
  for key in pairs(categoryCopy) do categoryCopy[key] = nil end
  for key, value in pairs(categories) do categoryCopy[key] = value end
end

local function GetFrequencyState()
  local frequency = NS.Frequency
  return frequency and frequency.IsFloodEnabled and frequency.IsFloodEnabled() or nil,
    frequency and frequency.GetFloodWindow and frequency.GetFloodWindow() or nil,
    frequency and frequency.IsRepeatEnabled and frequency.IsRepeatEnabled() or nil,
    frequency and frequency.GetRepeatBufferSize and frequency.GetRepeatBufferSize() or nil
end

local function GetRuleRevision()
  return NS.UserRules and NS.UserRules.GetRevision and NS.UserRules.GetRevision() or nil
end

local function DecisionCacheHit(id, stamp, event, message, sender, flags, channelName, guid,
  manualBlocked, trusted, surfaceState, settings, categories, floodEnabled, floodWindow, repeatEnabled, repeatBufferSize, ruleRevision)
  local slot = decisionCacheByID[id]
  if not slot or slot.inProgress or slot.stamp ~= stamp then return nil end
  if slot.event ~= event or slot.message ~= message or slot.sender ~= sender or slot.flags ~= flags
    or slot.channelName ~= channelName or slot.guid ~= guid or slot.manualBlocked ~= manualBlocked
    or slot.trusted ~= trusted or slot.surfaceState ~= surfaceState or slot.floodEnabled ~= floodEnabled
    or slot.floodWindow ~= floodWindow or slot.repeatEnabled ~= repeatEnabled or slot.repeatBufferSize ~= repeatBufferSize or slot.ruleRevision ~= ruleRevision then
    return nil
  end
  if not SameSettings(slot, settings) or not SameCategories(slot, categories) then return nil end
  return slot.decision
end

local function ClaimDecisionSlot(id)
  local existing = decisionCacheByID[id]
  if existing and existing.inProgress then return nil end
  decisionCacheCursor = (decisionCacheCursor % DECISION_CACHE_SIZE) + 1
  local slot = decisionCacheSlots[decisionCacheCursor]
  for _ = 1, DECISION_CACHE_SIZE do
    if not slot or not slot.inProgress then break end
    decisionCacheCursor = (decisionCacheCursor % DECISION_CACHE_SIZE) + 1
    slot = decisionCacheSlots[decisionCacheCursor]
  end
  if slot and slot.inProgress then return nil end
  if not slot then
    slot = {}
    decisionCacheSlots[decisionCacheCursor] = slot
  elseif slot.id and decisionCacheByID[slot.id] == slot then
    decisionCacheByID[slot.id] = nil
  end
  slot.id = id
  slot.inProgress = true
  slot.generation = (slot.generation or 0) + 1
  decisionCacheByID[id] = slot
  return slot, slot.generation
end

local function FinishDecisionSlot(slot, generation, stamp, event, message, sender, flags, channelName, guid,
  manualBlocked, trusted, surfaceState, settings, categories, floodEnabled, floodWindow, repeatEnabled, repeatBufferSize, ruleRevision, decision)
  if decisionCacheByID[slot.id] ~= slot or slot.generation ~= generation then return end
  slot.stamp, slot.event, slot.message, slot.sender, slot.flags = stamp, event, message, sender, flags
  slot.channelName, slot.guid = channelName, guid
  slot.manualBlocked, slot.trusted, slot.surfaceState = manualBlocked, trusted, surfaceState
  slot.floodEnabled, slot.floodWindow, slot.repeatEnabled, slot.repeatBufferSize, slot.ruleRevision = floodEnabled, floodWindow, repeatEnabled, repeatBufferSize, ruleRevision
  slot.decision = decision == true
  slot.inProgress = false
end

local function RememberSender(lineID, guid)
  lineID = IsUsableLineID(lineID)
  if not lineID or not IsUsableString(guid) or senderCacheByLine[lineID] then
    return
  end

  senderCacheCursor = (senderCacheCursor % SENDER_CACHE_SIZE) + 1
  local slot = senderCacheSlots[senderCacheCursor]
  if slot then
    senderCacheByLine[slot.lineID] = nil
  else
    slot = {}
    senderCacheSlots[senderCacheCursor] = slot
  end

  slot.lineID = lineID
  slot.guid = guid
  senderCacheByLine[lineID] = slot
end

-- Returns the GUID of the sender of a chat line, or nil when the line arrived on
-- an event Sift does not scan, carried no usable line ID, or has already been
-- pushed out of the ring by SENDER_CACHE_SIZE newer messages.
function ChatScanner.GetSenderGUIDByLineID(lineID)
  lineID = IsUsableLineID(lineID)
  local slot = lineID and senderCacheByLine[lineID]
  return slot and slot.guid or nil
end

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

-- Reused per message; safe because Scoring.Score never retains the table.
local scoringOptions = {}

local function BuildScoringOptions(settings, categories)
  scoringOptions.threshold = settings.threshold
  -- Never fall back to settings.enabledCategories: retired categories are not
  -- persisted there, so their rules would silently stop counting.
  scoringOptions.enabledCategories = categories or NS.PauseState.GetEffectiveCategoryStates()
  scoringOptions.mixedScriptWeight = settings.mixedScriptEnabled == false and 0 or settings.mixedScriptWeight
  scoringOptions.antiSignalCap = settings.antiSignalCap
  scoringOptions.patterns = NS.Patterns
  return scoringOptions
end

local function BuildHistoryRecord(event, message, sender, channelName, guid, analysis, settings, score, threshold, breakdown, reason, surface, outcome, customRule)
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

  -- Copied by value so History still names the rule after the user deletes it.
  if customRule then
    record.customRule = { raw = customRule.raw, cleansed = customRule.cleansed }
  end

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

-- Adds an escalating Flood weight for a line repeated by any sender within the
-- window, so a flood blocks even at content score 0. Flood is a meta key, never
-- a content category.
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

-- The user's keyword block rules, applied only when the corpus has not already
-- blocked, so turning Custom off can never suppress a corpus block. Returns the
-- rule that fired. A list switched off must not match at all. Forces `blocked`
-- rather than comparing to the threshold: a user rule blocks even when
-- anti-signal weight holds the total down.
local function ApplyCustomBlock(score, cleansed)
  if not score or score.blocked or not NS.UserRules or not NS.UserRules.Match then
    return nil
  end
  local state = (NS.PauseState and NS.PauseState.GetCategory
    and NS.PauseState.GetCategory("Custom")) or "active"
  if state == "off" then
    return nil
  end

  local matched = NS.UserRules.Match(NS.UserRules.BLOCK, cleansed)
  if not matched then
    return nil
  end

  local threshold = tonumber(score.threshold) or 4
  score.breakdown = type(score.breakdown) == "table" and score.breakdown or {}
  score.breakdown.Custom = (tonumber(score.breakdown.Custom) or 0) + threshold
  score.score = (tonumber(score.score) or 0) + threshold
  score.threshold = threshold
  score.blocked = true
  return matched
end

local function AppendBlockedHistory(record, counter, suppressReport)
  local entryID = NS.History and NS.History.Append and NS.History.Append(record)
  if record and record.outcome == "blocked" and NS.DB and NS.DB.RecordBlockedActor then
    -- A user rule that blocked owns the attribution, whatever the largest weight.
    local category = record.customRule and "Custom" or DominantCategory(record.breakdown)
    NS.DB.RecordBlockedActor(record, category)
  end
  if entryID and not suppressReport and NS.ReportFlow and NS.ReportFlow.QueueChatReport then
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
  guid,
  settings,
  manualBlocked,
  trusted,
  surface,
  surfaceState,
  categories
)
  if type(message) ~= "string" or message == "" then
    return false
  end

  -- Surface state gate: off short-circuits the pipeline (no detection, no history).
  -- paused lets detection run but flips outcome to pass-thru and skips bubble suppression.
  surface = surface or EVENT_TO_SURFACE[event] or "chat"
  surfaceState = surfaceState or ((NS.PauseState and NS.PauseState.GetSurface and NS.PauseState.GetSurface(surface)) or "active")
  if surfaceState == "off" then
    return false
  end
  local blockSuppressed = (surfaceState == "paused")

  -- PRECEDENCE (do not reorder):
  --   1 manual block > 2 Trust.IsTrusted > 3 user keyword-allow
  --   > 4 corpus block > 5 user keyword-block > pass
  --
  -- A manual block suppresses on identity alone (no score, no category gate) and
  -- deliberately outranks Trust. The keyword-allow check must stay below the
  -- Trust short-circuit, never between it and this branch.
  if manualBlocked == nil then
    manualBlocked = IsUsableString(guid) and NS.DB and NS.DB.IsManuallyBlocked and NS.DB.IsManuallyBlocked(guid)
  end
  if manualBlocked then
    if NS.DB.IsDevMode and NS.DB.IsDevMode() then
      DevLog("Manual block: " .. tostring(sender))
    end

    settings = settings or GetSettings()
    local manualAnalysis = (NS.Cleanse and NS.Cleanse.Analyze and NS.Cleanse.Analyze(message))
      or { signals = {}, normalized = message }

    -- Counted by the same repeat dedupe as other blocks, but the reason stays
    -- "manual-block": HistoryPanel renders its 0/0 score as "blocked by you".
    local throttled = NS.Frequency and NS.Frequency.CheckRepeat
      and NS.Frequency.CheckRepeat(event, manualAnalysis.normalized, guid) or false

    -- Last arg suppresses the spam report: a manual block is a personal choice, not a spam accusation.
    AppendBlockedHistory(BuildHistoryRecord(
      event,
      message,
      sender,
      channelName,
      guid,
      manualAnalysis,
      settings,
      0,
      0,
      { ManualBlock = 1 },
      "manual-block",
      surface,
      blockSuppressed and "pass-thru" or "blocked"
    ), counter, true)

    if throttled and NS.History and NS.History.IncrementThrottled then
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

  if trusted == nil then
    trusted = NS.Trust and NS.Trust.IsTrusted and NS.Trust.IsTrusted(guid, sender, flags)
  end
  if trusted then
    -- Dev diagnostic: name the trust source that skipped this sender.
    if NS.DB and NS.DB.IsDevMode and NS.DB.IsDevMode() then
      local reason = (NS.Trust.TrustReason and NS.Trust.TrustReason(guid, sender, flags)) or "?"
      DevLog("Trust skip [" .. reason .. "]: " .. tostring(sender))
    end
    return false
  end

  local analysis = NS.Cleanse and NS.Cleanse.Analyze and NS.Cleanse.Analyze(message)
  if not analysis then
    return false
  end

  settings = settings or GetSettings()
  local score = NS.Scoring and NS.Scoring.Score and NS.Scoring.Score(analysis, BuildScoringOptions(settings, categories))
  ApplyBlockedActorBoost(score, guid)
  ApplyFloodBoost(score, analysis.normalized)
  local customRule = ApplyCustomBlock(score, analysis.normalized)
  if not score or not score.blocked then
    -- Shadow capture of everything let through, score 0 included. Capture gates
    -- itself on devMode, so the check is deliberately not repeated here.
    if NS.ShadowLog then
      NS.ShadowLog.Capture(message, analysis, surface, score)
    end
    return false
  end

  -- Precedence 3: an allow keyword overrides a corpus block. It is a bypass
  -- surface, so the override is captured to the shadow log rather than silent.
  local allowRule = NS.UserRules and NS.UserRules.Match
    and NS.UserRules.Match(NS.UserRules.ALLOW, analysis.normalized)
  if allowRule then
    -- Self-gated on devMode like Capture above.
    if NS.ShadowLog then
      -- The phrase as the player typed it, not its cleansed form.
      NS.ShadowLog.CaptureAllowThrough(message, analysis, surface, score, allowRule.raw)
    end
    return false
  end

  -- Category state gate: off short-circuits; paused flips outcome to pass-thru.
  --
  -- When a user keyword rule blocked, Custom's state governs, not the dominant
  -- corpus category; otherwise a paused category could downgrade a user block.
  local breakdown = score.breakdown
  local gateCategory = customRule and "Custom" or DominantCategory(breakdown)
  if gateCategory then
    local categoryState = (NS.PauseState and NS.PauseState.GetCategory and NS.PauseState.GetCategory(gateCategory)) or "active"
    if categoryState == "off" then
      return false
    end
    if categoryState == "paused" then
      blockSuppressed = true
    end
  end

  -- The repeat lane runs only on confirmed spam, after the category gate, so it
  -- never fires on legitimate duplicates and the gate never sees a repeat key.
  if NS.Frequency and NS.Frequency.CheckRepeat
     and NS.Frequency.CheckRepeat(event, analysis.normalized, guid) then
    local throttleOutcome = blockSuppressed and "pass-thru" or "blocked"
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
      "throttle",
      surface,
      throttleOutcome,
      customRule
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
    customRule and "custom" or "score",
    surface,
    outcome,
    customRule
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
    print("[Sift] filter error: " .. tostring(err))
  end
  return err
end

-- File-scope on purpose: an inline closure in Filter would allocate on every
-- delivery to every chat frame.
local function FilterBody(event, message, sender, language, channelString, target, flags, unknown, channelNumber, channelName, unknown2, counter, guid)
  -- Before Pipeline, which returns early for trusted senders (the players most
  -- likely to be blocked by hand). Inside the protected call so a failure only
  -- loses the menu entry.
  RememberSender(counter, guid)

  local settings = GetSettings()
  local surface = EVENT_TO_SURFACE[event] or "chat"
  local surfaceState = (NS.PauseState and NS.PauseState.GetSurface and NS.PauseState.GetSurface(surface)) or "active"
  if surfaceState == "off" then
    return Pipeline(event, message, sender, language, channelString, target, flags, unknown,
      channelNumber, channelName, unknown2, counter, guid, settings, false, false, surface, surfaceState)
  end
  local manualBlocked = IsUsableString(guid) and NS.DB and NS.DB.IsManuallyBlocked
    and NS.DB.IsManuallyBlocked(guid) == true or false
  local trusted = not manualBlocked and NS.Trust and NS.Trust.IsTrusted
    and NS.Trust.IsTrusted(guid, sender, flags) == true or false
  if trusted then
    return Pipeline(event, message, sender, language, channelString, target, flags, unknown,
      channelNumber, channelName, unknown2, counter, guid, settings, manualBlocked, trusted, surface, surfaceState)
  end
  local lineID = IsFinitePositiveNumber(counter)
  local stamp = GetFrameStamp()
  local cacheable = lineID and stamp and type(event) == "string" and IsSafePayloadValue(message)
    and IsSafePayloadValue(sender) and IsSafePayloadValue(flags) and IsSafePayloadValue(channelName)
    and IsSafePayloadValue(guid)
  if not cacheable then
    return Pipeline(event, message, sender, language, channelString, target, flags, unknown,
      channelNumber, channelName, unknown2, counter, guid, settings, manualBlocked, trusted, surface, surfaceState)
  end
  local categories = NS.PauseState and NS.PauseState.GetEffectiveCategoryStates
    and NS.PauseState.GetEffectiveCategoryStates() or {}
  if type(settings) ~= "table" or type(categories) ~= "table" then
    return Pipeline(event, message, sender, language, channelString, target, flags, unknown,
      channelNumber, channelName, unknown2, counter, guid, settings, manualBlocked, trusted, surface, surfaceState)
  end
  local floodEnabled, floodWindow, repeatEnabled, repeatBufferSize = GetFrequencyState()
  local ruleRevision = GetRuleRevision()
  local cached = DecisionCacheHit(lineID, stamp, event, message, sender, flags, channelName, guid,
    manualBlocked, trusted, surfaceState, settings, categories, floodEnabled, floodWindow, repeatEnabled, repeatBufferSize, ruleRevision)
  if cached ~= nil then return cached end

  local slot, generation = ClaimDecisionSlot(lineID)
  if slot then CopyState(slot, settings, categories) end
  local pipelineOK, decision = pcall(Pipeline, event, message, sender, language, channelString, target, flags, unknown,
    channelNumber, channelName, unknown2, counter, guid, settings, manualBlocked, trusted, surface, surfaceState, categories)
  if not pipelineOK then
    if slot and decisionCacheByID[lineID] == slot and slot.generation == generation then
      decisionCacheByID[lineID] = nil
      slot.inProgress = false
    end
    error(decision)
  end
  local stable = slot and SameSettings(slot, GetSettings())
  local currentCategories = NS.PauseState and NS.PauseState.GetEffectiveCategoryStates
    and NS.PauseState.GetEffectiveCategoryStates() or nil
  stable = stable and SameCategories(slot, currentCategories)
  if slot and stable then
    FinishDecisionSlot(slot, generation, stamp, event, message, sender, flags, channelName, guid,
      manualBlocked, trusted, surfaceState, settings, categories, floodEnabled, floodWindow, repeatEnabled, repeatBufferSize, ruleRevision, decision)
  elseif slot and decisionCacheByID[lineID] == slot and slot.generation == generation then
    decisionCacheByID[lineID] = nil
    slot.inProgress = false
  end
  return decision
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

  local ok, result = pcall(FilterBody, event, message, sender, language, channelString, target, flags, unknown,
    channelNumber, channelName, unknown2, counter, guid)
  if not ok then
    -- ErrorHandler can raise too; pcall it so nothing escapes into Blizzard's
    -- filter loop.
    pcall(ErrorHandler, result)
    return false
  end
  return result == true
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
