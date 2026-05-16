local _, NS = ...
local Suppression = {}

local MAX_CHAT_LINES = 64
local blockedLines = {}
local lineOrder = {}

function Suppression.MarkChatLine(chatLineID, entryID)
  if chatLineID == nil then
    return
  end

  if blockedLines[chatLineID] == nil then
    lineOrder[#lineOrder + 1] = chatLineID
  end

  blockedLines[chatLineID] = entryID or true

  while #lineOrder > MAX_CHAT_LINES do
    local oldest = table.remove(lineOrder, 1)
    blockedLines[oldest] = nil
  end
end

function Suppression.IsChatLineBlocked(chatLineID)
  return chatLineID ~= nil and blockedLines[chatLineID] ~= nil
end

NS.Suppression = Suppression
return Suppression
