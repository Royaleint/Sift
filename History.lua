local _, NS = ...
local History = {}

local DEFAULT_RECENT_LIMIT = 10
local MAX_PRINT_LIMIT = 25
local IGNORED_BREAKDOWN_KEYS = {
  MixedScript = true,
  BlockedActor = true,
  Flood = true,
  -- BSP-029: repeat-dedupe blocks carry a synthesized { Throttle = threshold }
  -- breakdown, which counted as a spam category and dominated byCategory. The
  -- repeat count is already reported separately as stats.throttled.
  Throttle = true,
  -- BSP-037: manual blocks carry { ManualBlock = 1 } for the same reason, and
  -- must not land in byCategory as a category the sender never posted.
  ManualBlock = true,
}

-- Bumped by every function below that changes a stored record or a lifetime
-- counter, so a reader (HistoryPanel) can tell "nothing changed since I last
-- looked" apart from "go read it again" without diffing the data itself.
-- History is also written directly outside this file (legacy-store merge,
-- shape repair, migrations), but only at load/login, before anything could
-- have read a revision yet; any such direct write reachable later would need
-- its own bump here.
local dataRevision = 0

local function BumpRevision()
  dataRevision = dataRevision + 1
end

function History.GetRevision()
  return dataRevision
end

local function GetChar()
  return NS.DB and NS.DB.GetChar and NS.DB.GetChar()
end

local function GetSettings()
  return NS.DB and NS.DB.GetSettings and NS.DB.GetSettings()
end

local function MaxEntries()
  local settings = GetSettings()
  local value = settings and tonumber(settings.historyMaxEntries) or 1000
  if value < 100 then return 100 end
  if value > 5000 then return 5000 end
  return value
end

-- BSP-052: a phrase the player wrote owns the attribution when it is what caught
-- the message. The largest breakdown weight can belong to a category that never
-- blocked anything on its own -- negative trust weight can hold a bigger number
-- under the threshold -- so crediting it files the block under a category the
-- player never involved, and hides it from their own filter chip.
local function RecordCategory(record)
  if type(record) ~= "table" then return nil end
  if record.customRule then return "Custom" end

  local breakdown = record.breakdown
  if type(breakdown) ~= "table" then return nil end
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

-- SFT-085: Flood is deliberately excluded from byCategory (IGNORED_BREAKDOWN_KEYS
-- above) -- it's a reason, not a kind of spam -- so it has no lifetime counter the
-- way Throttle has stats.throttled. Two questions need two different predicates.
-- IsFloodBadgeRow reproduces HistoryPanel.lua's RenderRow badge condition (no
-- dominant category, a Flood weight, not a manual block) using RecordCategory
-- rather than RenderRow's own DominantCategory(breakdown) -- the two agree on
-- whether a category exists at all (never on which one, when they'd disagree)
-- because ApplyCustomBlock (ChatScanner.lua) always adds a Custom weight equal
-- to the block threshold (clamped 1-10) to a custom-rule row's breakdown, so
-- RecordCategory's customRule shortcut and DominantCategory's plain breakdown
-- loop both return SOME category for that row -- just not necessarily the same
-- one if another weight in the breakdown outscores Custom. Either way, "has a
-- category" excludes it from both predicates. RenderRow has no outcome check,
-- so a restored or pass-thru row can still badge "Flood" and stripe grey.
-- IsFloodOnlyBlock narrows that to blocked rows only, which is SFT-085's own
-- definition for the PIPELINE count. `category` lets a caller that already ran
-- RecordCategory (CountRetained, for byCategory) pass its result in instead of
-- paying for it twice -- pass `false` for "already computed, no category" or
-- omit it entirely to have it computed here (nil means "not supplied").
local function IsFloodBadgeRow(record, category)
  if type(record) ~= "table" then return false end
  if record.reason == "manual-block" then return false end
  if category == nil then category = RecordCategory(record) end
  if category then return false end
  local breakdown = record.breakdown
  return type(breakdown) == "table" and (tonumber(breakdown.Flood) or 0) > 0
end

local function IsFloodOnlyBlock(record, category)
  if type(record) ~= "table" then return false end
  if (record.outcome or "blocked") ~= "blocked" then return false end
  return IsFloodBadgeRow(record, category)
end

local function CountRetained(history)
  local retained = {
    detections = 0,
    blocked = 0,
    passThru = 0,
    restored = 0,
    bySurface = {},
    byCategory = {},
    floodCount = 0,
    floodBadgeCount = 0,
  }

  for index = 1, #history do
    local record = history[index]
    if type(record) == "table" then
      local surface = record.surface or "chat"
      retained.detections = retained.detections + 1
      retained.bySurface[surface] = (retained.bySurface[surface] or 0) + 1
      local outcome = record.outcome or "blocked"
      if outcome == "restored" then
        retained.restored = retained.restored + 1
      elseif outcome == "pass-thru" then
        retained.passThru = retained.passThru + 1
      else
        retained.blocked = retained.blocked + 1
      end
      local bestCat = RecordCategory(record)
      if bestCat then
        retained.byCategory[bestCat] = (retained.byCategory[bestCat] or 0) + 1
      end
      -- `or false`: bestCat is nil (a real, already-computed "no category"
      -- result) for exactly the rows these predicates care about, and nil
      -- means "not supplied, please compute" to them -- false says "already
      -- computed, and it's nothing" instead, so they don't redo the work.
      if IsFloodBadgeRow(record, bestCat or false) then
        retained.floodBadgeCount = retained.floodBadgeCount + 1
      end
      if IsFloodOnlyBlock(record, bestCat or false) then
        retained.floodCount = retained.floodCount + 1
      end
    end
  end

  return retained
end

local function CopyStats(stats)
  local copy = {
    detections = tonumber(stats and stats.detections) or 0,
    blocked = tonumber(stats and stats.blocked) or 0,
    passThru = tonumber(stats and stats.passThru) or 0,
    restored = tonumber(stats and stats.restored) or 0,
    bySurface = {},
    byCategory = {},
    throttled = tonumber(stats and stats.throttled) or 0,
    bubblesSuppressed = tonumber(stats and stats.bubblesSuppressed) or 0,
  }

  if stats and type(stats.bySurface) == "table" then
    for surface, count in pairs(stats.bySurface) do
      copy.bySurface[surface] = tonumber(count) or 0
    end
  end
  if stats and type(stats.byCategory) == "table" then
    for category, count in pairs(stats.byCategory) do
      copy.byCategory[category] = tonumber(count) or 0
    end
  end

  return copy
end

local function EnsureStats(char)
  char.stats = char.stats or {}
  local stats = char.stats
  stats.bySurface = type(stats.bySurface) == "table" and stats.bySurface or {}

  if stats.initialized ~= true then
    local retained = CountRetained(char.history or {})
    stats.detections = retained.detections
    stats.blocked = retained.blocked
    stats.restored = retained.restored
    stats.bySurface = retained.bySurface
    stats.passThru = retained.passThru
    stats.byCategory = retained.byCategory
    stats.throttled = stats.throttled or 0
    stats.bubblesSuppressed = stats.bubblesSuppressed or 0
    stats.initialized = true
  else
    stats.detections = tonumber(stats.detections) or 0
    stats.blocked = tonumber(stats.blocked) or 0
    stats.restored = tonumber(stats.restored) or 0
    stats.passThru = tonumber(stats.passThru) or 0
    stats.byCategory = type(stats.byCategory) == "table" and stats.byCategory or {}
    stats.throttled = tonumber(stats.throttled) or 0
    stats.bubblesSuppressed = tonumber(stats.bubblesSuppressed) or 0
  end

  return stats
end

local function IncrementStats(char, record)
  local stats = EnsureStats(char)
  local surface = record.surface or "chat"

  stats.detections = (tonumber(stats.detections) or 0) + 1
  local outcome = record.outcome or "blocked"
  if outcome == "restored" then
    stats.restored = (tonumber(stats.restored) or 0) + 1
  elseif outcome == "pass-thru" then
    stats.passThru = (tonumber(stats.passThru) or 0) + 1
  else
    stats.blocked = (tonumber(stats.blocked) or 0) + 1
  end
  stats.bySurface[surface] = (tonumber(stats.bySurface[surface]) or 0) + 1

  local bestCat = RecordCategory(record)
  if bestCat then
    stats.byCategory[bestCat] = (tonumber(stats.byCategory[bestCat]) or 0) + 1
  end
end

function History.Append(record)
  local char = GetChar()
  if not char or type(record) ~= "table" then
    return nil
  end

  char.history = char.history or {}
  char.historyCursor = (tonumber(char.historyCursor) or 0) + 1

  record.id = char.historyCursor
  record.surface = record.surface or "chat"
  record.outcome = record.outcome or "blocked"
  record.reason = record.reason or "score"
  IncrementStats(char, record)

  char.history[#char.history + 1] = record

  local maxEntries = MaxEntries()
  while #char.history > maxEntries do
    table.remove(char.history, 1)
  end

  BumpRevision()
  return record.id
end

-- BSP-023: returns references to the live records, not copies. Each call
-- previously allocated a fresh shallow-copy table per entry; with a 1000-
-- entry cap that's ~500 KB of per-call churn driving HistoryPanel's 2-3 MB
-- per Show/Hide cycle. All callers iterate read-only; mutations route through
-- MarkRestored / RetroactiveBlock / Append by id. Do not mutate returned
-- records.
function History.GetRecent(limit)
  local char = GetChar()
  local history = char and char.history or {}
  local count = tonumber(limit) or DEFAULT_RECENT_LIMIT
  if count < 1 then count = DEFAULT_RECENT_LIMIT end
  if count > MAX_PRINT_LIMIT then count = MAX_PRINT_LIMIT end

  local out = {}
  for index = #history, 1, -1 do
    out[#out + 1] = history[index]
    if #out >= count then break end
  end
  return out
end

function History.GetAll()
  local char = GetChar()
  local history = char and char.history or {}
  local out = {}
  for index = #history, 1, -1 do
    out[#out + 1] = history[index]
  end
  return out
end

function History.MarkRestored(id)
  local char = GetChar()
  local history = char and char.history or {}
  for index = 1, #history do
    local record = history[index]
    if record.id == id then
      if record.outcome ~= "restored" then
        record.outcome = "restored"
        local stats = EnsureStats(char)
        stats.restored = (tonumber(stats.restored) or 0) + 1
        BumpRevision()
      end
      return
    end
  end
end

function History.GetStats()
  local char = GetChar()
  local history = char and char.history or {}
  local lifetime = char and CopyStats(EnsureStats(char)) or CopyStats(nil)
  local retained = CountRetained(history)

  return {
    lifetime = lifetime,
    retained = retained,
  }
end

-- BSP-036: account-wide aggregate. char.stats is a running lifetime counter
-- (IncrementStats increments it forever; History.TrimToMax / TrimAllCharacters
-- only prune the retained `history` record array, never char.stats), so
-- summing char.stats across every stored character namespace is an accurate
-- account-wide lifetime total. Live aggregation, not a maintained db.global
-- running total: no SavedVariables migration, no double-count risk if a
-- counter and its source ever drift. This is the same cross-char loop
-- BSP-063's account-history-total already uses over `history`; here it sums
-- `stats` instead.
function History.GetAccountStats()
  local total = {
    detections = 0, blocked = 0, passThru = 0, restored = 0,
    throttled = 0, bubblesSuppressed = 0,
    bySurface = {}, byCategory = {},
  }
  local retainedTotal = 0
  local floodTotal = 0

  local charTable = NS.DB and NS.DB.db and NS.DB.db.sv and NS.DB.db.sv.char
  if type(charTable) == "table" then
    for _, charData in pairs(charTable) do
      if type(charData) == "table" then
        if type(charData.stats) == "table" then
          local stats = charData.stats
          total.detections = total.detections + (tonumber(stats.detections) or 0)
          total.blocked = total.blocked + (tonumber(stats.blocked) or 0)
          total.passThru = total.passThru + (tonumber(stats.passThru) or 0)
          total.restored = total.restored + (tonumber(stats.restored) or 0)
          total.throttled = total.throttled + (tonumber(stats.throttled) or 0)
          total.bubblesSuppressed = total.bubblesSuppressed + (tonumber(stats.bubblesSuppressed) or 0)
          if type(stats.bySurface) == "table" then
            for surface, count in pairs(stats.bySurface) do
              total.bySurface[surface] = (total.bySurface[surface] or 0) + (tonumber(count) or 0)
            end
          end
          if type(stats.byCategory) == "table" then
            for category, count in pairs(stats.byCategory) do
              total.byCategory[category] = (total.byCategory[category] or 0) + (tonumber(count) or 0)
            end
          end
        end
        if type(charData.history) == "table" then
          local history = charData.history
          retainedTotal = retainedTotal + #history
          -- SFT-085: this account view previously only counted rows (#history,
          -- above) and made no per-row pass. This adds one, per character,
          -- using the SAME IsFloodOnlyBlock predicate CountRetained uses for
          -- the per-character view, so the two views cannot define "Flood"
          -- differently. No floodBadgeCount here -- the legend swatch always
          -- reads the per-character NS.History.GetStats() (RefreshLegend has
          -- no account-scope path), so an account-wide badge count has no
          -- reader.
          for index = 1, #history do
            local record = history[index]
            if IsFloodOnlyBlock(record, RecordCategory(record) or false) then
              floodTotal = floodTotal + 1
            end
          end
        end
      end
    end
  end

  return {
    lifetime = total,
    retained = { detections = retainedTotal, floodCount = floodTotal },
  }
end

function History.Clear()
  local char = GetChar()
  if not char then
    return 0
  end

  local history = char.history or {}
  local count = #history
  if type(wipe) == "function" then
    wipe(history)
  else
    for index = #history, 1, -1 do
      history[index] = nil
    end
  end
  char.history = history
  BumpRevision()
  return count
end

function History.TrimToMax(maxEntries)
  local char = GetChar()
  local history = char and char.history or {}
  local max = tonumber(maxEntries) or MaxEntries()
  if max < 100 then max = 100 end
  if max > 5000 then max = 5000 end

  local removed = 0
  while #history > max do
    table.remove(history, 1)
    removed = removed + 1
  end
  if removed > 0 then BumpRevision() end
  return removed
end

local function BulkTrimOldest(history, max)
  local n = #history
  if n <= max then return 0 end
  local shift = n - max
  for i = 1, max do history[i] = history[i + shift] end
  for i = max + 1, n do history[i] = nil end
  return shift
end

local function EvictToGlobalCap(charTable, globalCap)
  local total = 0
  for _, charData in pairs(charTable) do
    if type(charData) == "table" and type(charData.history) == "table" then
      total = total + #charData.history
    end
  end
  if total <= globalCap then return 0 end

  local refs, refCount = {}, 0
  for charKey, charData in pairs(charTable) do
    if type(charData) == "table" and type(charData.history) == "table" then
      local h = charData.history
      for idx = 1, #h do
        if type(h[idx]) == "table" then
          refCount = refCount + 1
          refs[refCount] = {
            ts      = tonumber(h[idx].ts) or 0,
            charKey = charKey,
            idx     = idx,
          }
        end
      end
    end
  end
  if refCount <= globalCap then return 0 end

  table.sort(refs, function(a, b) return a.ts < b.ts end)
  local toDrop = refCount - globalCap
  local dropByChar = {}
  for i = 1, toDrop do
    local r = refs[i]
    dropByChar[r.charKey] = dropByChar[r.charKey] or {}
    dropByChar[r.charKey][r.idx] = true
  end

  for charKey, dropSet in pairs(dropByChar) do
    local h = charTable[charKey].history
    local kept, k = {}, 0
    for idx = 1, #h do
      if not dropSet[idx] then
        k = k + 1
        kept[k] = h[idx]
      end
    end
    for idx = 1, k do h[idx] = kept[idx] end
    for idx = k + 1, #h do h[idx] = nil end
  end

  return toDrop
end

function History.TrimAllCharacters()
  if not NS.DB or not NS.DB.db or not NS.DB.db.sv then return 0, 0 end
  local charTable = NS.DB.db.sv.char
  if type(charTable) ~= "table" then return 0, 0 end

  -- Caps are clamped at the data-layer boundary (DB.SetSetting on slider commit,
  -- RepairSettings on DB.Initialize, ResetSettings via CopyDefaults+RepairSettings).
  -- By the time we run, settings are already in range; defaults via `or N` cover
  -- nil / non-numeric. Trusting the input here lets unit tests exercise the
  -- algorithm at small scales (e.g. globalCap=2) without re-deriving the cap layer.
  local settings   = (NS.DB.GetSettings and NS.DB.GetSettings()) or {}
  local perCharCap = tonumber(settings.historyMaxEntries) or 300
  local globalCap  = tonumber(settings.historyGlobalMaxEntries) or 1000

  local perCharRemoved = 0
  for _, charData in pairs(charTable) do
    if type(charData) == "table" and type(charData.history) == "table" then
      perCharRemoved = perCharRemoved + BulkTrimOldest(charData.history, perCharCap)
    end
  end
  local globalRemoved = EvictToGlobalCap(charTable, globalCap)
  if perCharRemoved > 0 or globalRemoved > 0 then BumpRevision() end
  return perCharRemoved, globalRemoved
end

function History.IncrementThrottled()
  local char = GetChar()
  if not char then return end
  local stats = EnsureStats(char)
  stats.throttled = (tonumber(stats.throttled) or 0) + 1
  BumpRevision()
end

function History.IncrementBubblesSuppressed()
  local char = GetChar()
  if not char then return end
  local stats = EnsureStats(char)
  stats.bubblesSuppressed = (tonumber(stats.bubblesSuppressed) or 0) + 1
  BumpRevision()
end

function History.RetroactiveBlock(id)
  local char = GetChar()
  local history = char and char.history or {}
  for index = 1, #history do
    local record = history[index]
    if record.id == id and record.outcome == "pass-thru" then
      record.outcome = "blocked"
      local stats = EnsureStats(char)
      stats.passThru = math.max(0, (tonumber(stats.passThru) or 0) - 1)
      stats.blocked = (tonumber(stats.blocked) or 0) + 1
      BumpRevision()
      return true
    end
  end
  return false
end

function History.RebuildByCategory()
  local char = GetChar()
  if not char then return 0 end
  local retained = CountRetained(char.history or {})
  local stats = EnsureStats(char)
  stats.byCategory = retained.byCategory or {}
  local total = 0
  for _, count in pairs(stats.byCategory) do
    total = total + (tonumber(count) or 0)
  end
  BumpRevision()
  return total
end

NS.History = History
return History
