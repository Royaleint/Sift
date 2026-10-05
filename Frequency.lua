-- Sift/Frequency.lua
-- Chat flood and repetition detection. Pure Lua, dual-mode (TOC load and
-- dofile), with no WoW API references: the caller passes in the clock.
--
-- Two lanes with different keys; neither can stand in for the other:
--
--   Flood  (pre-score):  keyed on cleansed text, ANY sender, TIME window.
--                         Returns a count that ChatScanner turns into a score
--                         boost, so a flood blocks even at content score 0.
--   Repeat (post-score): keyed on (event, cleansed text, sender GUID), COUNT
--                         buffer, no time component. Returns a boolean and only
--                         ever sees messages already confirmed as spam.
--
-- The flood lane's min-length guard keeps short chatter out of the any-sender
-- key; the repeat lane runs after the block decision and needs none.

local Frequency = {}

-- Flood lane (any-sender, time-windowed).
local DEFAULT_WINDOW = 180  -- seconds; rolling repeat window (rapid floods only)
local MIN_WINDOW     = 60
local MAX_WINDOW     = 240
local TRIGGER     = 3     -- nth identical occurrence that starts boosting
local MIN_LEN     = 24    -- min cleansed length to track (kills trivial chatter)
local BOOST_BASE  = 5     -- boost at the trigger count
local BOOST_STEP  = 2     -- added per repeat beyond the trigger
local BOOST_CAP   = 9
local SOFT_CAP    = 2000  -- distinct-key ceiling before a prune sweep

local floodEnabled = true
local window = DEFAULT_WINDOW
local seen = {}           -- key -> { ascending occurrence timestamps within window }
local distinctCount = 0
local nextSweepAt = nil
local lastFloodNow = nil

-- Repeat lane (per-sender, per-surface, count-based).
local DEFAULT_BUFFER_SIZE = 20
local MIN_BUFFER_SIZE     = 5
local MAX_BUFFER_SIZE     = 50

local repeatEnabled = true
local repeatBufferSize = DEFAULT_BUFFER_SIZE

-- Pre-seeded for the common events; others are created on first CheckRepeat.
local buffers = {
  CHAT_MSG_CHANNEL = { lines = {}, players = {} },
  CHAT_MSG_WHISPER = { lines = {}, players = {} },
  CHAT_MSG_YELL    = { lines = {}, players = {} },
  CHAT_MSG_SAY     = { lines = {}, players = {} },
}

-- Exact match. Isolated so a different comparator can replace just this function.
function Frequency._Key(cleansed)
  return cleansed
end

local function pruneFront(stamps, cutoff)
  local removed = 0
  for i = 1, #stamps do
    if stamps[i] >= cutoff then break end
    removed = removed + 1
  end
  if removed > 0 then
    local len = #stamps
    for i = 1, len - removed do stamps[i] = stamps[i + removed] end
    for i = len, len - removed + 1, -1 do stamps[i] = nil end
  end
end

local function sweep(cutoff)
  for key, stamps in pairs(seen) do
    local last = stamps[#stamps] or 0
    if last < cutoff then
      seen[key] = nil
      distinctCount = distinctCount - 1
    end
  end
end

-- Records one occurrence of `cleansed` at time `now` (seconds) and returns how
-- many occurrences fall within the window. Returns 0 (no tracking) when disabled
-- or below the min-length guard.
function Frequency.RecordAndCount(cleansed, now)
  if not floodEnabled then return 0 end
  if type(cleansed) ~= "string" or #cleansed < MIN_LEN then return 0 end
  now = tonumber(now) or 0
  local cutoff = now - window

  -- Clock moved backwards (caller-supplied time): drop the pending sweep.
  if lastFloodNow and now < lastFloodNow then
    nextSweepAt = nil
  end
  lastFloodNow = now
  if distinctCount > SOFT_CAP and nextSweepAt and now > nextSweepAt then
    sweep(cutoff)
    nextSweepAt = distinctCount > SOFT_CAP and now + window or nil
  end

  local key = Frequency._Key(cleansed)
  local stamps = seen[key]
  if not stamps then
    stamps = {}
    seen[key] = stamps
    distinctCount = distinctCount + 1
  end
  pruneFront(stamps, cutoff)
  stamps[#stamps + 1] = now
  if distinctCount > SOFT_CAP and not nextSweepAt then
    nextSweepAt = now + window
  end
  return #stamps
end

-- 0 below the trigger; escalates BOOST_BASE + step*(over) up to the cap.
function Frequency.BoostFor(count)
  count = tonumber(count) or 0
  if count < TRIGGER then return 0 end
  local boost = BOOST_BASE + (count - TRIGGER) * BOOST_STEP
  if boost > BOOST_CAP then boost = BOOST_CAP end
  return boost
end

function Frequency.SetFloodEnabled(value)
  floodEnabled = value == true
  return floodEnabled
end

function Frequency.IsFloodEnabled()
  return floodEnabled
end

-- Clamped to MIN_WINDOW..MAX_WINDOW; a longer window raises false positives.
function Frequency.SetFloodWindow(value)
  value = tonumber(value) or DEFAULT_WINDOW
  if value < MIN_WINDOW then value = MIN_WINDOW end
  if value > MAX_WINDOW then value = MAX_WINDOW end
  if nextSweepAt and distinctCount > SOFT_CAP and lastFloodNow then
    sweep(lastFloodNow - window)
  end
  window = value
  nextSweepAt = nil
  return window
end

function Frequency.GetFloodWindow()
  return window
end

-- The band is defined once, here; DB repair and the Config slider read it
-- through this accessor so the bounds cannot drift apart.
function Frequency.GetFloodWindowBounds()
  return MIN_WINDOW, MAX_WINDOW, DEFAULT_WINDOW
end

local function ClampBufferSize(value)
  value = tonumber(value) or DEFAULT_BUFFER_SIZE
  if value < MIN_BUFFER_SIZE then value = MIN_BUFFER_SIZE end
  if value > MAX_BUFFER_SIZE then value = MAX_BUFFER_SIZE end
  return value
end

local function TrimBuffer(buffer)
  while #buffer.lines > repeatBufferSize do
    table.remove(buffer.lines, 1)
    table.remove(buffer.players, 1)
  end
end

function Frequency.SetRepeatEnabled(value)
  repeatEnabled = value == true
  return repeatEnabled
end

function Frequency.IsRepeatEnabled()
  return repeatEnabled
end

-- Test seam: nothing in the addon calls this.
function Frequency.SetRepeatBufferSize(value)
  repeatBufferSize = ClampBufferSize(value)
  -- Existing buffers are trimmed to the new cap on their next CheckRepeat.
  return repeatBufferSize
end

function Frequency.GetRepeatBufferSize()
  return repeatBufferSize
end

function Frequency.CheckRepeat(event, cleansed, guid)
  if not repeatEnabled then
    return false
  end

  -- Validated before the buffers[event] lookup, which errors on a nil key.
  if type(event) ~= "string" or event == "" then
    return false
  end

  if type(guid) ~= "string" or guid == "" or type(cleansed) ~= "string" or cleansed == "" then
    return false
  end

  -- Auto-create, so any event ChatScanner registers participates without a
  -- change here.
  local buffer = buffers[event]
  if not buffer then
    buffer = { lines = {}, players = {} }
    buffers[event] = buffer
  end

  local blocked = false
  for index = 1, #buffer.lines do
    if buffer.lines[index] == cleansed and buffer.players[index] == guid then
      blocked = true
      break
    end
  end

  buffer.lines[#buffer.lines + 1] = cleansed
  buffer.players[#buffer.players + 1] = guid
  TrimBuffer(buffer)

  return blocked
end

-- Clears both lanes. Used by tests and available for logout cleanup.
function Frequency.Reset()
  seen = {}
  distinctCount = 0
  nextSweepAt = nil
  lastFloodNow = nil
  for _, buffer in pairs(buffers) do
    for index = #buffer.lines, 1, -1 do
      buffer.lines[index] = nil
    end
    for index = #buffer.players, 1, -1 do
      buffer.players[index] = nil
    end
  end
end


-- Inspection accessor for tests. Not used by the addon at runtime.
function Frequency._Params()
  return {
    window = window, trigger = TRIGGER, minLen = MIN_LEN,
    boostBase = BOOST_BASE, boostStep = BOOST_STEP, boostCap = BOOST_CAP,
  }
end

-- Dual-mode export: must stay the final statement (dofile return + NS attach).
local _, NS = ...
if NS then NS.Frequency = Frequency end
return Frequency
