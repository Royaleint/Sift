local _, NS = ...
local Throttle = {}

local BUFFER_SIZE = 20

local buffers = {
  CHAT_MSG_CHANNEL = { lines = {}, players = {} },
  CHAT_MSG_WHISPER = { lines = {}, players = {} },
  CHAT_MSG_YELL = { lines = {}, players = {} },
  CHAT_MSG_SAY = { lines = {}, players = {} },
}

local function TrimBuffer(buffer)
  while #buffer.lines > BUFFER_SIZE do
    table.remove(buffer.lines, 1)
    table.remove(buffer.players, 1)
  end
end

function Throttle.Check(event, cleansed, guid)
  local buffer = buffers[event]
  if not buffer then
    return false
  end

  if type(guid) ~= "string" or guid == "" or type(cleansed) ~= "string" or cleansed == "" then
    return false
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

NS.Throttle = Throttle
return Throttle
