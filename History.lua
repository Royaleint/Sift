local _, NS = ...
local History = {}

local DEFAULT_RECENT_LIMIT = 10
local MAX_PRINT_LIMIT = 25

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

local function CountRetained(history)
  local retained = {
    detections = 0,
    blocked = 0,
    passThru = 0,
    restored = 0,
    bySurface = {},
    byCategory = {},
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
      local breakdown = record.breakdown
      if type(breakdown) == "table" then
        local bestCat, bestVal
        for cat, val in pairs(breakdown) do
          if cat ~= "MixedScript" and (not bestVal or val > bestVal) then
            bestCat, bestVal = cat, val
          end
        end
        if bestCat then
          retained.byCategory[bestCat] = (retained.byCategory[bestCat] or 0) + 1
        end
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

  local breakdown = record.breakdown
  if type(breakdown) == "table" then
    local bestCat, bestVal
    for cat, val in pairs(breakdown) do
      if cat ~= "MixedScript" and (not bestVal or val > bestVal) then
        bestCat, bestVal = cat, val
      end
    end
    if bestCat then
      stats.byCategory[bestCat] = (tonumber(stats.byCategory[bestCat]) or 0) + 1
    end
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
  return removed
end

function History.IncrementThrottled()
  local char = GetChar()
  if not char then return end
  local stats = EnsureStats(char)
  stats.throttled = (tonumber(stats.throttled) or 0) + 1
end

function History.IncrementBubblesSuppressed()
  local char = GetChar()
  if not char then return end
  local stats = EnsureStats(char)
  stats.bubblesSuppressed = (tonumber(stats.bubblesSuppressed) or 0) + 1
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
  return total
end

NS.History = History
return History
