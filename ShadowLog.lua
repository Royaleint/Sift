-- Sift/ShadowLog.lua
-- Dev-only capture of messages the filter did not block, exported with
-- /bdev fnx. Senders the Trust layer skips never reach it.
--
-- Deliberately not History: History is the player-facing, per-character block
-- record, and reusing it would evict real blocks to make room for chatter.

local _, NS = ...
local ShadowLog = {}

local MAX_ENTRIES     = 1000  -- account-wide cap on distinct captured messages
local MIN_LEN         = 8     -- min cleansed length; shorter is chatter, not a candidate
local MAX_VARIANTS    = 3     -- distinct raw spellings kept per cleansed key
local REPEAT_INTEREST = 3     -- occurrences at which a message counts as repeated
-- Ceiling on eviction chances: must stay at least max Rank + 1 (currently 7),
-- or the top of the ranking flattens.
local MAX_CHANCES     = 7

-- Mirrors History.lua's IGNORED_BREAKDOWN_KEYS; keep the two in step.
local IGNORED_BREAKDOWN_KEYS = {
  MixedScript = true,
  BlockedActor = true,
  Flood = true,
  Throttle = true,
  ManualBlock = true,
}

-- Every entry records which lane captured it.
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

-- How interesting an entry is, 0 upward. The single ranking: it seeds eviction
-- chances and orders the export, so add new signals here, not in a second
-- comparator. A capture tag counts even when the score is zero or below.
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

-- Also seeds `chances` on any stored entry that lacks it; one read as zero
-- chances would be evicted on first sight.
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
      -- Older records stored provenance as a single string; lift it on restore.
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

-- Adds `value` to `list` if it is not already there. Tags and provenance are
-- unions across sightings; assigning would drop what earlier sightings recorded.
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

-- One cleansed key covers many raw spellings; keep a bounded handful of them.
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

-- Records that this lane saw the message; a record seen by both lanes keeps both.
local function MergeSource(entry, source)
  entry.sources = type(entry.sources) == "table" and entry.sources or {}
  AddUnique(entry.sources, source)
end

-- The allow-through lane also records which allow phrases let the message
-- through (a union, like tags and sources).
local function MergeAllowPhrase(entry, allowPhrase)
  if type(allowPhrase) ~= "string" or allowPhrase == "" then return end
  entry.allowPhrases = type(entry.allowPhrases) == "table" and entry.allowPhrases or {}
  AddUnique(entry.allowPhrases, allowPhrase)
end

-- CLOCK (second-chance) eviction. Every incoming message is admitted; the hand
-- walks the store, an entry with chances left spends one and survives, and the
-- first entry out of chances is evicted. Chances come from Rank.
--
-- Deliberately not recency: refreshing a timestamp on every repeat would make
-- the most repetitive chatter the last thing evicted.
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
  -- The dev-only gate lives here, not at the call sites, so no lane can skip it.
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

  -- Capture-only tags; Evaluate returns nil unless the message carries a sell signal.
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

-- Captures a message an allow keyword let through: same store, separate
-- provenance, so allowlist passes can be told apart from ordinary misses.
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

-- Shrinks an oversized store back to the cap at login, through the same
-- eviction used at runtime so there is only one retention policy.
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

-- Inspection accessor for tests, so they read the tuning rather than copy it.
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
