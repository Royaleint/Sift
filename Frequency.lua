-- Sift/Frequency.lua
-- BSP-027: chat flood / repetition detection. Pure Lua, dual-mode (addon TOC +
-- test runner dofile). Zero WoW API references — the clock is passed in by the
-- caller (ChatScanner passes ServerTime()), so this runs identically standalone.
--
-- BSP-029: absorbed the former Throttle.lua so message recency has ONE owner.
-- The two lanes stay distinct because they answer different questions at
-- different points in the scan, and neither key can be substituted for the
-- other:
--
--   Flood  (pre-score)  — keyed on cleansed text, ANY sender, TIME window.
--                         Returns a count that ChatScanner turns into a score
--                         boost, so a flood blocks even at content score 0.
--   Repeat (post-score) — keyed on (event, cleansed text, sender GUID), COUNT
--                         buffer, no time component. Returns a boolean and only
--                         ever sees messages already confirmed as spam.
--
-- Spam is also defined by BEHAVIOR (repetitive flooding), not just content. A
-- min-length guard keeps common short chatter ("ty", "gg", "lf tank") from ever
-- accumulating under the any-sender flood key. The repeat lane needs no such
-- guard: it runs after the block decision, so legitimate chat never reaches it.

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

-- Repeat lane (per-sender, per-surface, count-based).
local DEFAULT_BUFFER_SIZE = 20
local MIN_BUFFER_SIZE     = 5
local MAX_BUFFER_SIZE     = 50

local repeatEnabled = true
local repeatBufferSize = DEFAULT_BUFFER_SIZE

-- Pre-seeded for the historical 4 events. Other events (BN_WHISPER, EMOTE,
-- DND, AFK) auto-create lazily on first CheckRepeat. Seeding is a no-op for
-- behavior; kept so a refactor that drops auto-create still works for the
-- common path.
local buffers = {
  CHAT_MSG_CHANNEL = { lines = {}, players = {} },
  CHAT_MSG_WHISPER = { lines = {}, players = {} },
  CHAT_MSG_YELL    = { lines = {}, players = {} },
  CHAT_MSG_SAY     = { lines = {}, players = {} },
}

-- Exact match today. Isolated so a fuzzy / near-duplicate comparator can replace
-- this one function later without touching the rest of the module.
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
    if (stamps[#stamps] or 0) < cutoff then
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

  if distinctCount > SOFT_CAP then sweep(cutoff) end

  local key = Frequency._Key(cleansed)
  local stamps = seen[key]
  if not stamps then
    stamps = {}
    seen[key] = stamps
    distinctCount = distinctCount + 1
  end
  pruneFront(stamps, cutoff)
  stamps[#stamps + 1] = now
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

-- Capped at 240 as a false-positive guard (see BSP-039's tracker entry for the
-- band rationale).
function Frequency.SetFloodWindow(value)
  value = tonumber(value) or DEFAULT_WINDOW
  if value < MIN_WINDOW then value = MIN_WINDOW end
  if value > MAX_WINDOW then value = MAX_WINDOW end
  window = value
  return window
end

function Frequency.GetFloodWindow()
  return window
end

-- The band is defined once, here. DB and ConfigPanel read it through this
-- accessor instead of repeating the numbers, so the clamp, the SavedVariables
-- repair, and the slider bounds cannot drift apart.
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

-- BSP-029: the buffer size lost its Config slider (the flood window is now the
-- single user-facing timing knob), so nothing in the addon calls this. It stays
-- as the seam the harness uses to make buffer trimming observable without
-- inserting 21 distinct messages.
function Frequency.SetRepeatBufferSize(value)
  repeatBufferSize = ClampBufferSize(value)
  -- Existing buffers may now hold more entries than the new cap; trim on next
  -- CheckRepeat rather than walking every buffer here. The cap is enforced as
  -- new entries arrive.
  return repeatBufferSize
end

function Frequency.GetRepeatBufferSize()
  return repeatBufferSize
end

function Frequency.CheckRepeat(event, cleansed, guid)
  if not repeatEnabled then
    return false
  end

  -- BSP-010 polish (post-Argus): validate event before the buffers[event]
  -- lookup. ChatScanner always passes a string constant today, but a future
  -- caller passing nil would hit `buffers[nil]` → "table index is nil".
  if type(event) ~= "string" or event == "" then
    return false
  end

  if type(guid) ~= "string" or guid == "" or type(cleansed) ~= "string" or cleansed == "" then
    return false
  end

  -- BSP-010: auto-create unknown buffers so BN_WHISPER / EMOTE / DND / AFK
  -- (and any future ChatScanner event registration) participate in dedupe
  -- without a code change here.
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
  for _, buffer in pairs(buffers) do
    for index = #buffer.lines, 1, -1 do
      buffer.lines[index] = nil
    end
    for index = #buffer.players, 1, -1 do
      buffer.players[index] = nil
    end
  end
end

-- Inspection accessor (tests / future config). Not used by the addon at runtime.
function Frequency._Params()
  return {
    window = window, trigger = TRIGGER, minLen = MIN_LEN,
    boostBase = BOOST_BASE, boostStep = BOOST_STEP, boostCap = BOOST_CAP,
  }
end

-- Dual-mode export. MUST be the final statement so a standalone dofile gets the
-- table as the chunk return AND the TOC load attaches it to NS.Frequency.
local _, NS = ...
if NS then NS.Frequency = Frequency end
return Frequency
