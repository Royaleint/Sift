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
-- Ceiling on how long one entry can resist eviction. Set above what Rank can
-- currently produce (4) so SFT-081's signal term has room to raise an entry
-- without immediately hitting the ceiling and flattening the ordering.
local MAX_CHANCES     = 6

-- Mirrors History.lua's IGNORED_BREAKDOWN_KEYS (the canonical set) so the
-- category recorded here matches what History and the config stats call dominant.
local IGNORED_BREAKDOWN_KEYS = {
  MixedScript = true,
  BlockedActor = true,
  Flood = true,
}

-- Every entry carries where it came from. Only one producer exists today; the
-- field is here so an audit lane can be told apart from corpus candidates
-- without rewriting stored entries later.
local SOURCE_FN_CANDIDATE = "fn-candidate"

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
function ShadowLog.Rank(entry)
  local rank = 0
  if (tonumber(entry.score) or 0) > 0 then
    rank = rank + 3
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

-- Cleansing folds case, symbols, and repeated letters away, so one key covers
-- many spellings -- but the spellings ARE the data being mined (a re-spelled ad
-- is what defeats a vocabulary rule). Keep a bounded handful of distinct raw
-- originals per key rather than only the first one seen.
-- Union, never replacement. Sightings of one message disagree about tags: an
-- obfuscated respelling of a handle loses the token match while keeping the
-- shape, and the next clean spelling gets it back. Assigning the newest result
-- would silently drop a tag the entry had already earned, which is the opposite
-- of what a mining record is for.
local function MergeTags(entry, tags)
  if not tags then
    return
  end
  local existing = entry.tags
  if not existing then
    entry.tags = tags
    return
  end
  for i = 1, #tags do
    local tag, seen = tags[i], false
    for j = 1, #existing do
      if existing[j] == tag then seen = true break end
    end
    if not seen then
      existing[#existing + 1] = tag
    end
  end
end

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

-- Records one message the filter did not block. `analysis` is the Cleanse result
-- and `score` the Scoring result (which may be nil if scoring was unavailable).
-- Returns the stored entry, or nil when the message was too short to be worth
-- keeping.
function ShadowLog.Capture(original, analysis, surface, score)
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
    source = SOURCE_FN_CANDIDATE,
  }
  RefreshChances(entry)
  store[#store + 1] = entry
  entries[cleansed] = entry
  return entry
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
