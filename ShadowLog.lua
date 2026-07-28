-- Sift/ShadowLog.lua
-- BSP-032 Phase 1: dev-only capture of messages the filter did NOT block.
--
-- The pipeline drops every below-threshold message without recording it, so the
-- corpus can only ever grow from spam that was already caught. False negatives
-- are invisible, and novel spam that scores 0 cannot be surfaced by lowering the
-- threshold either (threshold clamps at 1, and 0 never reaches it). This module
-- keeps the misses in a dev-only store so they can be exported (/bdev fnx) and
-- hand-triaged into the corpus.
--
-- WHAT THIS DOES NOT SEE: senders the Trust layer skips. Pipeline returns before
-- scoring for guild members, friends, and the allowlist, so a trusted sender's
-- spam never reaches capture. That is a real hole in the mining set -- it is the
-- exact gap BSP-058's allow-keyword walkthrough exists to audit -- and closing it
-- means a second call site above the trust gate, which is not this ticket.
--
-- Deliberately NOT History. History is the player-facing block record: FIFO,
-- per-character, and capped. Reusing it would evict real blocked entries to make
-- room for chatter, and it never sees the score-0 messages that are the point.
--
-- devMode gates capture at the CALL SITE in ChatScanner, not in here. With
-- devMode off nothing calls in, so a normal player pays one boolean compare per
-- chat line and no allocation at all.

local _, NS = ...
local ShadowLog = {}

local MAX_ENTRIES     = 1000  -- account-wide cap on distinct captured messages
local MIN_LEN         = 8     -- min cleansed length; shorter is chatter, not a candidate
local MAX_VARIANTS    = 3     -- distinct raw spellings kept per cleansed key
local REPEAT_INTEREST = 3     -- occurrences at which a message counts as repeated
-- Ceiling on how long one entry can resist eviction. Kept one above the highest
-- chance count Rank can produce (max Rank 6, so 7 chances) -- if it clamped, the
-- top of the range would flatten and the repeat term would stop distinguishing
-- the entries that matter most.
local MAX_CHANCES     = 7

-- Mirrors History.lua's IGNORED_BREAKDOWN_KEYS (the canonical set) so the
-- category recorded here matches what History and the config stats call dominant.
local IGNORED_BREAKDOWN_KEYS = {
  MixedScript = true,
  BlockedActor = true,
  Flood = true,
  Throttle = true,
  ManualBlock = true,
}

-- Every entry carries where it came from, so an audit lane can be told apart
-- from ordinary corpus candidates without rewriting stored entries later.
local SOURCE_FN_CANDIDATE = "fn-candidate"
local SOURCE_ALLOW_AUDIT  = "allow-audit"

-- cleansed text -> entry reference, rebuilt from the store on first use. Held
-- outside SavedVariables so it never persists; Clear() drops it.
local index = nil

-- Eviction hand, in the CLOCK sense below. Position in the store, not an id.
local hand = 0

local function Now()
  if type(GetServerTime) == "function" then
    return GetServerTime()
  end
  return time()
end

local function GetStore()
  local global = NS.DB and NS.DB.GetGlobal and NS.DB.GetGlobal()
  if not global then
    return nil
  end
  global.shadowLog = type(global.shadowLog) == "table" and global.shadowLog or {}
  return global.shadowLog
end

-- How interesting an entry is for corpus mining, 0 upward. ONE definition, three
-- consumers: it seeds how long an entry resists eviction, it orders the export,
-- and it is where a new signal gets added rather than in a second comparator.
--
-- Scoring at all is the strongest cue we have (something in the corpus already
-- half-matched); repetition is the next, because an advert is repeated and an
-- ordinary question usually is not.
--
-- SFT-081: a capture tag counts on its own, independent of score. The near-miss
-- worth mining most is often the one the score cannot see -- a message with real
-- selling weight held under the line by anti-signal weight scores at or below
-- zero, which ranks it with the chatter and gets it evicted on first sight. The
-- tag is exactly the evidence that says otherwise, so it must not be conditional
-- on a positive score.
function ShadowLog.Rank(entry)
  local rank = 0
  if (tonumber(entry.score) or 0) > 0 then
    rank = rank + 3
  end
  if type(entry.tags) == "table" and #entry.tags > 0 then
    rank = rank + 2
  end
  if (tonumber(entry.count) or 0) >= REPEAT_INTEREST then
    rank = rank + 1
  end
  return rank
end

local function RefreshChances(entry)
  local chances = 1 + ShadowLog.Rank(entry)
  entry.chances = chances > MAX_CHANCES and MAX_CHANCES or chances
end

-- Also seeds `chances` on any entry that lacks it. A store written before CLOCK
-- eviction existed has none, and an entry read as zero chances is evicted on
-- first sight -- which would throw away exactly the entries a previous session
-- thought worth keeping. Seeding on restore keeps the priority order intact.
local function GetIndex(store)
  if index then
    return index
  end
  index = {}
  for i = 1, #store do
    local entry = store[i]
    if type(entry) == "table" and type(entry.cleansed) == "string" then
      if tonumber(entry.chances) == nil then
        RefreshChances(entry)
      end
      -- Provenance was a single string before it could hold more than one lane.
      -- Lift it on restore so an old record is not quietly treated as having none.
      if type(entry.sources) ~= "table" then
        entry.sources = type(entry.source) == "string" and { entry.source } or {}
        entry.source = nil
      end
      index[entry.cleansed] = entry
    end
  end
  return index
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

-- Adds `value` to `list` if it is not already there. Both the tag set and the
-- provenance set are unions for the same reason: sightings of one message
-- disagree, and whichever sighting happened to be last is not the truth. An
-- obfuscated respelling of a handle loses the token match while keeping the
-- shape; a message the allowlist let through may already be recorded from the
-- ordinary lane. Assigning would drop what the record had already earned, which
-- is the opposite of what a mining record is for -- and for provenance it would
-- hide exactly the case an allowlist audit exists to reveal.
local function AddUnique(list, value)
  for i = 1, #list do
    if list[i] == value then
      return
    end
  end
  list[#list + 1] = value
end

local function MergeTags(entry, tags)
  if not tags then
    return
  end
  if not entry.tags then
    entry.tags = tags
    return
  end
  for i = 1, #tags do
    AddUnique(entry.tags, tags[i])
  end
end

-- Cleansing folds case, symbols, and repeated letters away, so one key covers
-- many spellings -- but the spellings ARE the data being mined (a re-spelled ad
-- is what defeats a vocabulary rule). Keep a bounded handful of distinct raw
-- originals per key rather than only the first one seen.
local function AddVariant(entry, original)
  local originals = entry.originals
  for i = 1, #originals do
    if originals[i] == original then
      return
    end
  end
  if #originals < MAX_VARIANTS then
    originals[#originals + 1] = original
  end
end

-- Records that this lane saw the message. A record shared by both lanes carries
-- both, because "the allowlist also let this through" is a fact about the record
-- that a first-writer-wins field would silently swallow.
local function MergeSource(entry, source)
  entry.sources = type(entry.sources) == "table" and entry.sources or {}
  AddUnique(entry.sources, source)
end

-- The audit lane also records WHICH allow phrase let the message through --
-- that phrase is the actionable datum: an allowlist you cannot attribute a
-- bypass to is an allowlist you cannot prune. Union, like tags and sources
-- (different phrases can pass the same line over time).
local function MergeAllowPhrase(entry, allowPhrase)
  if type(allowPhrase) ~= "string" or allowPhrase == "" then return end
  entry.allowPhrases = type(entry.allowPhrases) == "table" and entry.allowPhrases or {}
  AddUnique(entry.allowPhrases, allowPhrase)
end

-- CLOCK (second-chance) eviction.
--
-- The store sees every line the filter lets through, so in a busy channel it is
-- full within minutes and everything after that depends on what gets evicted.
-- Two rules matter and they pull against each other: a novel zero-scoring
-- message must ALWAYS be able to get in (it is the whole reason the store
-- exists, and no threshold setting can surface it), while a near-miss already
-- captured must not be pushed out by chatter.
--
-- So: every incoming message is admitted, and the victim is chosen by walking a
-- hand around the store. An entry with chances left spends one and survives;
-- the first entry out of chances is evicted. Chances come from Rank, so a
-- scoring or repeated entry survives several full passes while a one-off line
-- survives one -- and because every visit spends a chance, nothing is immortal.
-- Cost is amortised O(1): each spent chance was paid for by an earlier arrival.
--
-- Deliberately NOT recency. Ranking by timestamp is what made an earlier draft
-- wrong: refreshing the timestamp on every repeat made the most repetitive
-- chatter the LAST thing evicted.
local function EvictOne(store, entries)
  local count = #store
  if count == 0 then
    return
  end

  for _ = 1, count do
    hand = hand + 1
    if hand > count then hand = 1 end
    local entry = store[hand]
    local chances = tonumber(entry and entry.chances) or 0
    if chances > 0 then
      entry.chances = chances - 1
    else
      break
    end
  end

  local victim = store[hand]
  if type(victim) == "table" and type(victim.cleansed) == "string" then
    entries[victim.cleansed] = nil
  end
  table.remove(store, hand)
  hand = hand - 1
end

local function Record(original, analysis, surface, score, source, allowPhrase)
  -- The dev-only gate lives HERE, not at the call sites. Every lane into this
  -- store has the same obligation, and a caller wiring in from somewhere else in
  -- the pipeline must not be able to forget it -- so the property is structural
  -- rather than something you have to read each call site to confirm.
  if not (NS.DB and NS.DB.IsDevMode and NS.DB.IsDevMode()) then
    return nil
  end

  local store = GetStore()
  if not store or type(original) ~= "string" then
    return nil
  end

  local cleansed = analysis and analysis.normalized
  if type(cleansed) ~= "string" or #cleansed < MIN_LEN then
    return nil
  end

  local total = tonumber(score and score.score) or 0

  -- SFT-079: capture-only tags. Evaluate answers nil unless the message already
  -- carries a sell signal, so a message in another language is never tagged for
  -- being in another language. Nothing here can block: the tag is written into a
  -- store a human reads.
  local tags = NS.Signals and NS.Signals.Evaluate and NS.Signals.Evaluate(analysis, score)

  local entries = GetIndex(store)
  local entry = entries[cleansed]

  if entry then
    entry.count = (tonumber(entry.count) or 0) + 1
    entry.ts = Now()
    if total > (tonumber(entry.score) or 0) then
      entry.score = total
      entry.category = DominantCategory(score and score.breakdown)
    end
    MergeTags(entry, tags)
    MergeSource(entry, source)
    MergeAllowPhrase(entry, allowPhrase)
    AddVariant(entry, original)
    RefreshChances(entry)
    return entry
  end

  if #store >= MAX_ENTRIES then
    EvictOne(store, entries)
  end

  entry = {
    ts = Now(),
    surface = surface or "chat",
    cleansed = cleansed,
    originals = { original },
    count = 1,
    score = total,
    category = DominantCategory(score and score.breakdown),
    tags = tags,
    sources = { source },
  }
  MergeAllowPhrase(entry, allowPhrase)
  RefreshChances(entry)
  store[#store + 1] = entry
  entries[cleansed] = entry
  return entry
end

-- Records one message the filter did not block. `analysis` is the Cleanse result
-- and `score` the Scoring result (which may be nil if scoring was unavailable).
-- Returns the stored entry, or nil when the message was too short to be worth
-- keeping.
function ShadowLog.Capture(original, analysis, surface, score)
  return Record(original, analysis, surface, score, SOURCE_FN_CANDIDATE)
end

-- The seam BSP-058's allow-keyword walkthrough calls, from above the trust gate
-- where Capture never runs. Same store, different provenance: these are messages
-- an allow rule let through, and telling them apart from ordinary misses is the
-- whole point of auditing an allowlist. Unused until that ticket wires it up.
function ShadowLog.CaptureAllowThrough(original, analysis, surface, score, allowPhrase)
  return Record(original, analysis, surface, score, SOURCE_ALLOW_AUDIT, allowPhrase)
end

-- Returns references to the live records, in capture order. Callers iterate
-- read-only; the export sorts its own copy.
function ShadowLog.GetAll()
  return GetStore() or {}
end

function ShadowLog.Count()
  local store = GetStore()
  return store and #store or 0
end

-- Converges an oversized store back to the cap. Runs at login the way
-- History.TrimAllCharacters does: a store carried over from a build with a
-- larger cap would otherwise only shrink one entry per capture.
--
-- Sheds through the same eviction the store uses at runtime, so there is one
-- retention policy rather than a second one that discards by arrival order and
-- would throw away near-misses to keep chatter.
function ShadowLog.TrimToCap()
  local store = GetStore()
  if not store then
    return 0
  end
  local entries = GetIndex(store)
  local removed = 0
  while #store > MAX_ENTRIES do
    EvictOne(store, entries)
    removed = removed + 1
  end
  return removed
end

-- Inspection accessor (tests). Mirrors Frequency._Params: the tuning lives here,
-- and a test that hard-codes its own copy of the cap stops testing this module.
function ShadowLog._Params()
  return {
    maxEntries = MAX_ENTRIES,
    minLen = MIN_LEN,
    maxVariants = MAX_VARIANTS,
    repeatInterest = REPEAT_INTEREST,
    maxChances = MAX_CHANCES,
    sourceFnCandidate = SOURCE_FN_CANDIDATE,
    sourceAllowAudit = SOURCE_ALLOW_AUDIT,
  }
end

function ShadowLog.Clear()
  local store = GetStore()
  if not store then
    return 0
  end
  local count = #store
  for i = count, 1, -1 do
    store[i] = nil
  end
  index = nil
  hand = 0
  return count
end

NS.ShadowLog = ShadowLog
return ShadowLog
