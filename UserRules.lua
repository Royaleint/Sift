local _, NS = ...
local UserRules = {}
local revision = 0

local function TouchRevision()
  revision = revision + 1
end

-- User-authored keyword rules: two independent lists (block and allow) with
-- shared storage, guardrails and matching. Rules match Cleanse-normalized text,
-- so "gold" also catches "g0ld" and "g o l d". Dedup and cap are per list.
local BLOCK = "block"
local ALLOW = "allow"

UserRules.BLOCK = BLOCK
UserRules.ALLOW = ALLOW

-- A full list rejects new entries rather than evicting: these are deliberate
-- user data. MIN_LENGTH 3 keeps out 2-character rules that match inside
-- common words; it does not rule out false positives entirely.
local LISTS = {
  [BLOCK] = { storeKey = "customBlocks",  cap = 200, minLength = 3 },
  [ALLOW] = { storeKey = "allowKeywords", cap = 200, minLength = 3 },
}

local testCleanse
local testStores = {}

local function GetList(kind)
  return LISTS[kind]
end

-- Resolved per call, not cached: this file loads before DB.Initialize, so a
-- load-time capture would hold nil forever.
local function GetStore(kind)
  local list = GetList(kind)
  if not list then return nil end
  if testStores[kind] then return testStores[kind] end
  local global = NS and NS.DB and NS.DB.GetGlobal and NS.DB.GetGlobal()
  if type(global) ~= "table" then return nil end
  global[list.storeKey] = type(global[list.storeKey]) == "table" and global[list.storeKey] or {}
  return global[list.storeKey]
end

local function CleanseText(raw)
  local cleanse = testCleanse or (NS and NS.Cleanse)
  if not cleanse or type(cleanse.Text) ~= "function" then return nil end
  return cleanse.Text(raw)
end

local function Trim(value)
  return (string.gsub(tostring(value or ""), "^%s*(.-)%s*$", "%1"))
end

local function ServerTime()
  if type(GetServerTime) == "function" then
    return GetServerTime()
  end
  return os and os.time and os.time() or 0
end

local function FindByCleansed(store, cleansed)
  for index = 1, #store do
    local entry = store[index]
    if type(entry) == "table" and entry.cleansed == cleansed then
      return entry, index
    end
  end
  return nil, nil
end

-- Returns status, entry. status is one of:
--   "added" | "empty" | "too_short" | "already_exists" | "full" | "unavailable"
-- Every status has a user-facing string in ConfigPanel -- an Add never fails silently.
function UserRules.Add(kind, raw)
  local list = GetList(kind)
  local store = GetStore(kind)
  if not list or not store then return "unavailable", nil end

  local trimmed = Trim(raw)
  local cleansed = CleanseText(trimmed)
  if not cleansed or cleansed == "" then
    return "empty", nil
  end
  if #cleansed < list.minLength then
    return "too_short", nil
  end

  local existing = FindByCleansed(store, cleansed)
  if existing then
    return "already_exists", existing
  end
  if #store >= list.cap then
    return "full", nil
  end

  local entry = { raw = trimmed, cleansed = cleansed, added = ServerTime() }
  store[#store + 1] = entry
  TouchRevision()
  return "added", entry
end

-- Accepts a raw string (cleansed first) or an index. The phrase match must run
-- before the index read: an all-digit phrase such as "15000" is a valid rule.
function UserRules.Remove(kind, rawOrIndex)
  local store = GetStore(kind)
  if not store then return false end

  if type(rawOrIndex) == "string" then
    local cleansed = CleanseText(Trim(rawOrIndex))
    if cleansed and cleansed ~= "" then
      local _, found = FindByCleansed(store, cleansed)
      if found then
        table.remove(store, found)
        TouchRevision()
        return true
      end
    end
  end

  local index = tonumber(rawOrIndex)
  if not index or not store[index] then return false end

  table.remove(store, index)
  TouchRevision()
  return true
end

function UserRules.RemoveAll(kind)
  local store = GetStore(kind)
  if not store then return 0 end
  local removed = #store
  for index = removed, 1, -1 do
    store[index] = nil
  end
  if removed > 0 then TouchRevision() end
  return removed
end

-- Shallow copy: callers render and sort this, and must not be able to reorder
-- or drop the stored list by accident. The entry tables themselves are shared.
function UserRules.List(kind)
  local store = GetStore(kind)
  local out = {}
  if not store then return out end
  for index = 1, #store do
    out[index] = store[index]
  end
  return out
end

function UserRules.Count(kind)
  local store = GetStore(kind)
  return store and #store or 0
end

function UserRules.GetCap(kind)
  local list = GetList(kind)
  return list and list.cap or 0
end

function UserRules.GetMinLength(kind)
  local list = GetList(kind)
  return list and list.minLength or 0
end

-- Returns the first entry whose cleansed form is a substring of `text`.
-- Insertion order decides between overlapping rules ("wts" before "wts boost"),
-- which is deterministic and is what the UI tooltip promises.
function UserRules.Match(kind, text)
  if type(text) ~= "string" or text == "" then return nil end
  local store = GetStore(kind)
  if not store then return nil end
  for index = 1, #store do
    local entry = store[index]
    if type(entry) == "table" and type(entry.cleansed) == "string" and entry.cleansed ~= ""
       and string.find(text, entry.cleansed, 1, true) then
      return entry
    end
  end
  return nil
end

function UserRules.GetByCleansed(kind, cleansed)
  local store = GetStore(kind)
  if not store then return nil end
  return (FindByCleansed(store, cleansed))
end

-- Drops entries that survived a hand-edited or truncated SavedVariables file.
-- Called from DB.RepairShape; returns the number dropped so the caller can log.
function UserRules.RepairStore(store)
  if type(store) ~= "table" then return 0 end
  local kept, dropped = {}, 0
  local seen = {}
  for index = 1, #store do
    local entry = store[index]
    local cleansed = type(entry) == "table" and entry.cleansed or nil
    if type(cleansed) == "string" and cleansed ~= "" and type(entry.raw) == "string"
       and not seen[cleansed] then
      seen[cleansed] = true
      kept[#kept + 1] = entry
    else
      dropped = dropped + 1
    end
  end
  for index = #store, 1, -1 do
    store[index] = nil
  end
  for index = 1, #kept do
    store[index] = kept[index]
  end
  if dropped > 0 then TouchRevision() end
  return dropped
end

function UserRules.GetRevision()
  return revision
end

-- Test seams for running the module outside WoW.
function UserRules.SetCleanseForTest(cleanse)
  testCleanse = cleanse
end

function UserRules.SetStoreForTest(kind, store)
  testStores[kind] = store
  TouchRevision()
end

if NS then NS.UserRules = UserRules end
return UserRules
