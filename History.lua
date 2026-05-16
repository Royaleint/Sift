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

local function ShallowCopy(record)
  local copy = {}
  for key, value in pairs(record) do
    copy[key] = value
  end
  return copy
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

  char.history[#char.history + 1] = record

  local maxEntries = MaxEntries()
  while #char.history > maxEntries do
    table.remove(char.history, 1)
  end

  return record.id
end

function History.GetRecent(limit)
  local char = GetChar()
  local history = char and char.history or {}
  local count = tonumber(limit) or DEFAULT_RECENT_LIMIT
  if count < 1 then count = DEFAULT_RECENT_LIMIT end
  if count > MAX_PRINT_LIMIT then count = MAX_PRINT_LIMIT end

  local out = {}
  for index = #history, 1, -1 do
    out[#out + 1] = ShallowCopy(history[index])
    if #out >= count then break end
  end
  return out
end

function History.GetAll()
  local char = GetChar()
  local history = char and char.history or {}
  local out = {}
  for index = #history, 1, -1 do
    out[#out + 1] = ShallowCopy(history[index])
  end
  return out
end

function History.MarkRestored(id)
  local char = GetChar()
  local history = char and char.history or {}
  for index = 1, #history do
    local record = history[index]
    if record.id == id then
      record.outcome = "restored"
      return
    end
  end
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

NS.History = History
return History
