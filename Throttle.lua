-- BawrSpam/Throttle.lua
-- Confirmed-spam dedupe ring buffer, per surface. Pure Lua, dual-mode
-- (addon TOC + test runner dofile). Zero WoW API references — runs
-- identically in both contexts.
--
-- BSP-008 Commit 2: Check now runs INSIDE ChatScanner's `score.blocked`
-- branch, so legitimate sub-threshold repeats are never throttled.
-- BSP-010: enabled gate + configurable bufferSize + BN_WHISPER/EMOTE/
-- DND/AFK auto-create on first Check (previously bypassed because the
-- buffer table only seeded 4 events).

local Throttle = {}

local DEFAULT_BUFFER_SIZE = 20
local MIN_BUFFER_SIZE     = 5
local MAX_BUFFER_SIZE     = 50

local enabled    = true
local bufferSize = DEFAULT_BUFFER_SIZE

-- Pre-seeded for the historical 4 events. Other events (BN_WHISPER, EMOTE,
-- DND, AFK) auto-create lazily on first Check. Seeding is a no-op for
-- behavior; kept so a refactor that drops auto-create still works for the
-- common path.
local buffers = {
  CHAT_MSG_CHANNEL = { lines = {}, players = {} },
  CHAT_MSG_WHISPER = { lines = {}, players = {} },
  CHAT_MSG_YELL    = { lines = {}, players = {} },
  CHAT_MSG_SAY     = { lines = {}, players = {} },
}

local function ClampBufferSize(value)
  value = tonumber(value) or DEFAULT_BUFFER_SIZE
  if value < MIN_BUFFER_SIZE then value = MIN_BUFFER_SIZE end
  if value > MAX_BUFFER_SIZE then value = MAX_BUFFER_SIZE end
  return value
end

local function TrimBuffer(buffer)
  while #buffer.lines > bufferSize do
    table.remove(buffer.lines, 1)
    table.remove(buffer.players, 1)
  end
end

function Throttle.SetEnabled(value)
  enabled = value == true
  return enabled
end

function Throttle.IsEnabled()
  return enabled
end

function Throttle.SetBufferSize(value)
  bufferSize = ClampBufferSize(value)
  -- Existing buffers may now hold more entries than the new cap; trim
  -- on next Check rather than walking every buffer here. The cap is
  -- enforced as new entries arrive.
  return bufferSize
end

function Throttle.GetBufferSize()
  return bufferSize
end

function Throttle.Check(event, cleansed, guid)
  if not enabled then
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

function Throttle.Reset()
  for _, buffer in pairs(buffers) do
    for index = #buffer.lines, 1, -1 do
      buffer.lines[index] = nil
    end
    for index = #buffer.players, 1, -1 do
      buffer.players[index] = nil
    end
  end
end

-- Dual-mode export. MUST be the final statement so WoW's chunk loader gets
-- the table as the return value when running standalone (test runner) AND
-- attaches to NS.Throttle when loaded via TOC. Mirrors Cleanse.lua's pattern
-- (BSP-010 alignment).
local _, NS = ...
if NS then NS.Throttle = Throttle end
return Throttle
