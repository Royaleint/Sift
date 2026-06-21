-- Sift/Frequency.lua
-- BSP-027: chat flood / repetition detection. Pure Lua, dual-mode (addon TOC +
-- test runner dofile). Zero WoW API references — the clock is passed in by the
-- caller (ChatScanner passes ServerTime()), so this runs identically standalone.
--
-- Spam is also defined by BEHAVIOR (repetitive flooding), not just content. This
-- module tracks recent message occurrences keyed on the cleansed text (ANY
-- sender) within a short rolling window and reports a repeat count. ChatScanner
-- turns that count into an escalating pre-score "Flood" boost, so a flood blocks
-- even when its content score is below threshold. A min-length guard keeps
-- common short chatter ("ty", "gg", "lf tank") from ever accumulating under the
-- any-sender key.

local Frequency = {}

local WINDOW      = 180   -- seconds; rolling repeat window (rapid floods only)
local TRIGGER     = 3     -- nth identical occurrence that starts boosting
local MIN_LEN     = 24    -- min cleansed length to track (kills trivial chatter)
local BOOST_BASE  = 5     -- boost at the trigger count
local BOOST_STEP  = 2     -- added per repeat beyond the trigger
local BOOST_CAP   = 9
local SOFT_CAP    = 2000  -- distinct-key ceiling before a prune sweep

local enabled = true
local seen = {}           -- key -> { ascending occurrence timestamps within window }
local distinctCount = 0

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
  if not enabled then return 0 end
  if type(cleansed) ~= "string" or #cleansed < MIN_LEN then return 0 end
  now = tonumber(now) or 0
  local cutoff = now - WINDOW

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

function Frequency.SetEnabled(value)
  enabled = value == true
  return enabled
end

function Frequency.IsEnabled()
  return enabled
end

function Frequency.Reset()
  seen = {}
  distinctCount = 0
end

-- Inspection accessor (tests / future config). Not used by the addon at runtime.
function Frequency._Params()
  return {
    window = WINDOW, trigger = TRIGGER, minLen = MIN_LEN,
    boostBase = BOOST_BASE, boostStep = BOOST_STEP, boostCap = BOOST_CAP,
  }
end

-- Dual-mode export. MUST be the final statement so a standalone dofile gets the
-- table as the chunk return AND the TOC load attaches it to NS.Frequency.
local _, NS = ...
if NS then NS.Frequency = Frequency end
return Frequency
