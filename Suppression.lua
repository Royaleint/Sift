local _, NS = ...
local Suppression = {}

local MAX_CHAT_LINES = 64
local SEARCH_RESULT_TTL = 300
local APPLICANT_TTL = 120
local SWEEP_INTERVAL = 60

local blockedLines = {}
local lineOrder = {}
local blockedSearchResults = {}
local blockedApplicants = {}
local lfgSweepTickerStarted = false

local function Now()
  if type(GetTime) == "function" then
    return GetTime()
  end
  return time()
end

local function StartLFGSweepTicker()
  if lfgSweepTickerStarted then
    return
  end

  if C_Timer and type(C_Timer.NewTicker) == "function" then
    lfgSweepTickerStarted = true
    C_Timer.NewTicker(SWEEP_INTERVAL, function()
      Suppression.SweepLFG()
    end)
  end
end

local function MarkTransient(map, transientID, ttl)
  if transientID == nil then
    return
  end

  map[transientID] = Now() + ttl
  StartLFGSweepTicker()
end

local function IsTransientBlocked(map, transientID)
  if transientID == nil then
    return false
  end

  local expiresAt = map[transientID]
  if not expiresAt then
    return false
  end

  if expiresAt <= Now() then
    map[transientID] = nil
    return false
  end

  return true
end

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

function Suppression.MarkLFGSearchResult(searchResultID)
  MarkTransient(blockedSearchResults, searchResultID, SEARCH_RESULT_TTL)
end

function Suppression.IsLFGSearchResultBlocked(searchResultID)
  return IsTransientBlocked(blockedSearchResults, searchResultID)
end

function Suppression.MarkLFGApplicant(applicantID)
  MarkTransient(blockedApplicants, applicantID, APPLICANT_TTL)
end

function Suppression.IsLFGApplicantBlocked(applicantID)
  return IsTransientBlocked(blockedApplicants, applicantID)
end

function Suppression.SweepLFG()
  local now = Now()
  for searchResultID, expiresAt in pairs(blockedSearchResults) do
    if expiresAt <= now then
      blockedSearchResults[searchResultID] = nil
    end
  end

  for applicantID, expiresAt in pairs(blockedApplicants) do
    if expiresAt <= now then
      blockedApplicants[applicantID] = nil
    end
  end
end

function Suppression.ClearLFG()
  for searchResultID in pairs(blockedSearchResults) do
    blockedSearchResults[searchResultID] = nil
  end

  for applicantID in pairs(blockedApplicants) do
    blockedApplicants[applicantID] = nil
  end
end

NS.Suppression = Suppression
return Suppression
