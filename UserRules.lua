local _, NS = ...
local UserRules = {}

-- BSP-052 / BSP-058: user-authored keyword rules. Two independent lists share
-- this module because their storage, guardrails, and matching are identical --
-- only their effect on the pipeline differs. Matching runs against the same
-- Cleanse-normalised text the corpus matcher sees, so a rule "gold" also catches
-- "g0ld", Cyrillic "gоld", and spaced "g o l d" with no work here.
--
-- The two lists stay separate arrays with separate caps rather than one list
-- with a kind field: dedup and cap are per-list invariants, and a user may
-- legitimately want the same phrase in neither, either, or (perversely) both.
local BLOCK = "block"
local ALLOW = "allow"

UserRules.BLOCK = BLOCK
UserRules.ALLOW = ALLOW

-- Cap rationale: well above any plausible hand-maintained list, far below any
-- performance ceiling (200 plain `find` calls against a cleansed line is low
-- microseconds, dwarfed by Cleanse itself), and small enough to show as "X / 200"
-- in the UI footer. On full we reject rather than evict -- these entries are
-- deliberate user data, unlike the auto-accumulated blockedActors table.
--
-- MIN_LENGTH 3 removes the worst false-positive band (2-char rules like "wt"
-- match "watch", "want", "white"). It does not promise zero false positives:
-- "wts" still sits inside "webtools", and because Cleanse strips whitespace a
-- multi-word rule matches across word boundaries. The UI says so out loud.
local LISTS = {
  [BLOCK] = { storeKey = "customBlocks",  cap = 200, minLength = 3 },
  [ALLOW] = { storeKey = "allowKeywords", cap = 200, minLength = 3 },
}

local testCleanse
local testStores = {}

local function GetList(kind)
  return LISTS[kind]
end

-- Resolved per call rather than captured at load time: this file loads before
-- DB.Initialize runs, so anything cached here would capture nil and never
-- recover. Cheap enough -- two table lookups off an already-warm path.
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
  return "added", entry
end

-- Accepts a raw string or an index. A string is cleansed first so removal works
-- from whatever the user typed, not only from the stored spelling.
--
-- The phrase match is tried BEFORE the argument is read as an index, because a
-- phrase can be all digits. Sniffing for a number first made those impossible to
-- remove from the UI: "15000" was read as an index, store[15000] held nothing,
-- and the call reported failure while the entry sat in the list.
function UserRules.Remove(kind, rawOrIndex)
  local store = GetStore(kind)
  if not store then return false end

  if type(rawOrIndex) == "string" then
    local cleansed = CleanseText(Trim(rawOrIndex))
    if cleansed and cleansed ~= "" then
      local _, found = FindByCleansed(store, cleansed)
      if found then
        table.remove(store, found)
        return true
      end
    end
  end

  local index = tonumber(rawOrIndex)
  if not index or not store[index] then return false end

  table.remove(store, index)
  return true
end

function UserRules.RemoveAll(kind)
  local store = GetStore(kind)
  if not store then return 0 end
  local removed = #store
  for index = removed, 1, -1 do
    store[index] = nil
  end
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
  return dropped
end

-- Test seams: the module is dofile-able so the standalone runners can exercise
-- it without a WoW environment, mirroring Cleanse's dual-mode pattern.
function UserRules.SetCleanseForTest(cleanse)
  testCleanse = cleanse
end

function UserRules.SetStoreForTest(kind, store)
  testStores[kind] = store
end

if NS then NS.UserRules = UserRules end
return UserRules
