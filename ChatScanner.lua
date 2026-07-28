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
  -- BSP-029: Throttle is a dedupe mechanism, not a spam category. It reaches
  -- DominantCategory only through the synthesized repeat record below, where
  -- crediting it as the dominant category tagged the sender's blocked-actor
  -- entry with a category they never actually posted.
  Throttle = true,
  -- BSP-037: same reasoning. A manual block is an identity decision, so it must
  -- never be credited as a content category the sender never posted.
  ManualBlock = true,
}

-- BSP-037: bounded lineID -> GUID cache. Blizzard's chat-name context menu
-- hands addons a lineID but no GUID, while this filter sees both on every
-- message. Recording the pair here is what lets the right-click "Block" entry
-- key on the same GUID the scanner already uses, instead of matching on a name
-- that another player could be wearing. Ring buffer with in-place slot reuse:
-- allocation stops after the first pass, so the chat hot path stays garbage-free.
local SENDER_CACHE_SIZE = 128
local senderCacheSlots = {}
local senderCacheByLine = {}
local senderCacheCursor = 0

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

-- 0 is what several chat events pass when a line carries no ID at all. Storing
-- it would make every such message collide on one key, and a menu lookup could
-- then hand back an unrelated player's GUID -- a block aimed at the wrong
-- person. Rejected on write and on read.
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

local function BuildScoringOptions(settings)
  return {
    threshold = settings.threshold,
    -- Not settings.enabledCategories directly: retired categories are no longer
    -- persisted, so the stored table alone would gate their rules off. A
    -- fallback to it would restore that bug quietly, so there is none.
    enabledCategories = NS.PauseState.GetEffectiveCategoryStates(),
    mixedScriptWeight = settings.mixedScriptEnabled == false and 0 or settings.mixedScriptWeight,
    antiSignalCap = settings.antiSignalCap,
    patterns = NS.Patterns,
  }
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

  -- BSP-052: copied by value, not referenced, so the History detail pane still
  -- names the rule after the user deletes it. The record is the source of truth.
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

-- suppressReport is set for manual blocks (BSP-037). Blocking someone by hand is
-- a personal-preference call, not an accusation of spam, so it must never queue
-- a Blizzard spam report. Users who do want to report get the deliberate path in
-- SFT-083.
-- BSP-052: the user's own keyword rules, applied only where the corpus has not
-- already decided -- the corpus path stays sovereign, so turning Custom off can
-- never suppress a real corpus block. Mirrors the two boosts above: mutate in
-- place, bail if already blocked. Returns the rule that fired, which the caller
-- needs both to gate on and to record.
--
-- Custom's own state is read before matching. That is correctness first -- a
-- list switched off must not match at all -- and it also skips up to 200
-- substring searches on every scanned line for as long as it stays off.
--
-- Unlike those boosts this one forces `blocked` rather than recomputing it
-- against the threshold. The weight is still added so the breakdown sums to the
-- recorded score, but a rule the user typed themselves has to block even when
-- negative anti-signal weight would otherwise hold the total under threshold.
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
    -- BSP-052: a user rule owns the attribution when it is what blocked. The
    -- dominant corpus weight can be the larger number without having blocked
    -- anything, and crediting it would file the actor under a category the user
    -- never involved.
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
  guid
)
  if type(message) ~= "string" or message == "" then
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

  -- BSP-037: a manual block suppresses on identity alone -- no content score,
  -- no category gate.
  --
  -- PRECEDENCE (studio-canonical, do not reorder without owner sign-off):
  --   1 manual block > 2 Trust.IsTrusted > 3 user keyword-allow
  --   > 4 corpus block > 5 user keyword-block > pass
  --
  -- Anchors for the links this branch does not own (BSP-052/058):
  --   link 1 is THIS branch, and stays directly above the link-2 Trust
  --     short-circuit immediately below.
  --   link 3 (keyword-allow) goes BELOW that Trust short-circuit and above the
  --     Cleanse/Score step -- never between link 1 and link 2, or a keyword
  --     allow would quietly outrank an explicit manual block.
  --   link 5 (keyword-block) goes after the Score call, before the category
  --     state gate. When it fires, that gate reads Custom's state rather than
  --     the dominant corpus category -- see the gate itself.
  --
  -- Manual block deliberately outranks Trust: a user who right-clicked Block on
  -- a guildmate meant it, and letting the trust rule win would make the menu
  -- entry a silent no-op for exactly the people they took the trouble to name.
  -- The check is a table lookup, so this ordering costs the hot path nothing.
  if IsUsableString(guid) and NS.DB and NS.DB.IsManuallyBlocked and NS.DB.IsManuallyBlocked(guid) then
    if NS.DB.IsDevMode and NS.DB.IsDevMode() then
      DevLog("Manual block: " .. tostring(sender))
    end

    local settings = GetSettings()
    local manualAnalysis = (NS.Cleanse and NS.Cleanse.Analyze and NS.Cleanse.Analyze(message))
      or { signals = {}, normalized = message }

    -- Route through the same dedupe every other block uses, so a chatty blocked
    -- player counts toward the throttled tally instead of looking like a fresh
    -- decision on every line. The reason stays "manual-block" either way: it is
    -- still why the message went, and nothing in History condenses on the
    -- "throttle" label, so relabelling would only cost the honest row render
    -- (score/threshold here are 0/0, which HistoryPanel replaces with "blocked
    -- by you" -- it would show a meaningless 0 / 0 under any other reason).
    local throttled = NS.Frequency and NS.Frequency.CheckRepeat
      and NS.Frequency.CheckRepeat(event, manualAnalysis.normalized, guid) or false

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

  local analysis = NS.Cleanse and NS.Cleanse.Analyze and NS.Cleanse.Analyze(message)
  if not analysis then
    return false
  end

  local settings = GetSettings()
  local score = NS.Scoring and NS.Scoring.Score and NS.Scoring.Score(analysis, BuildScoringOptions(settings))
  ApplyBlockedActorBoost(score, guid)
  ApplyFloodBoost(score, analysis.normalized)
  local customRule = ApplyCustomBlock(score, analysis.normalized)
  if not score or not score.blocked then
    -- BSP-032: shadow capture of the misses. Placed in the not-blocked branch so
    -- it sees everything the filter lets through, score-0 included -- the set no
    -- threshold setting can surface -- while blocked messages stay recorded in
    -- History alone. Capture gates itself on devMode and returns immediately
    -- when it is off; that check is deliberately not duplicated here, so every
    -- lane into the store obeys it whether or not its caller remembered to.
    if NS.ShadowLog then
      NS.ShadowLog.Capture(message, analysis, surface, score)
    end
    return false
  end

  -- Category state gate: off short-circuits; paused flips outcome to pass-thru.
  --
  -- BSP-052: when a user keyword rule is what blocked this message, ITS state
  -- governs, not the dominant corpus category. A corpus weight can be the larger
  -- number without having blocked anything -- negative anti-signal weight can
  -- hold the total under threshold -- and letting that category decide would hand
  -- control of the user's own rule to a category they never involved. It also
  -- means a category sitting at the shipped "paused" default could silently
  -- downgrade an explicit user block to pass-thru.
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

  -- The repeat lane runs ONLY on confirmed-spam (post-Score + post-category-gate). BSP-010
  -- reorder folded into BSP-008 Commit 2: previously ran before Score and could over-fire on
  -- legitimate duplicates. BSP-029 moved it into Frequency; the call site stays here so the
  -- category gate above still reads a breakdown with no repeat key in it.
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
    -- Cache the sender before Pipeline runs: Pipeline returns early for trusted
    -- senders, and those are exactly the players a user is most likely to want
    -- to block by hand. Inside the xpcall so a surprise here degrades to "no
    -- right-click entry" instead of killing the filter for every addon on the
    -- chain (BSP-037).
    RememberSender(counter, guid)

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
