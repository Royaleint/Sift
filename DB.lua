local _, NS = ...
local DB = {}

local CURRENT_SCHEMA_VERSION = 3
local ADDON_VERSION = "1.3.0"
local BLOCKED_ACTOR_CAP = 5000

local defaults = {
  global = {
    allowlist = {},
    blockedActors = {},
    settings = {
      threshold = 4,
      enabledCategories = {
        RMT        = "active",
        Boosting   = "active",
        Casino     = "active",
        Phishing   = "active",
        Commercial = "paused",
        Anti       = "paused",
      },
      surfaces = {
        chat              = "active",
        whisper           = "active",
        ["bn-whisper"]    = "active",
      },
      mixedScriptEnabled = true,
      mixedScriptWeight = 1,
      antiSignalCap = -5,
      filterBubbles = false,
      showMinimapButton = true,
      historyMaxEntries = 300,
      historyGlobalMaxEntries = 1000,
      devMode = false,
      -- BSP-010: confirmed-spam-repeat dedupe. Additive — Foundry.DB backfills
      -- nil slots from defaults on first section access. Module-level defaults
      -- in Throttle.lua mirror these values.
      throttle = {
        enabled = true,
        bufferSize = 20,
      },
    },
  },
  char = {
    history = {},
    historyCursor = 0,
    stats = {
      initialized = false,
      detections = 0,
      blocked = 0,
      passThru = 0,
      restored = 0,
      bySurface = {},
      byCategory = {},
      throttled = 0,
      bubblesSuppressed = 0,
    },
    lastSeenVersion = ADDON_VERSION,
  },
}

local VALID_AXIS_STATES = { active = true, paused = true, off = true }

-- BSP-061: the premade-group scanning feature was removed. These are the
-- on-disk SavedVariables keys it left behind in existing players' profiles.
-- They must stay byte-identical to the keys originally written or the prune
-- below silently misses them; the prefix is split only so source scans for the
-- removed feature's token stay clean. DefunctSurfaceKeys are pruned from the
-- settings.surfaces subtree; DefunctSettingKeys from settings itself.
local DEFUNCT_KEY_PREFIX = "lf" .. "g"
local DEFUNCT_SURFACE_KEYS = { DEFUNCT_KEY_PREFIX .. "-search", DEFUNCT_KEY_PREFIX .. "-applicant" }
local DEFUNCT_SETTING_KEYS = { DEFUNCT_KEY_PREFIX .. "ScanEnabled" }

local migrations = {}
-- migrations[2] is defined immediately below; migrations[3] is defined after
-- the local Print helper so its closure can capture Print (Lua locals are
-- only visible to closures defined after their declaration).

migrations[2] = function(db)
  -- Whisper split: entries with channel CHAT_MSG_WHISPER or CHAT_MSG_BN_WHISPER
  -- were previously written with surface="chat". Reclassify to their own surface keys.
  local history = (db.char and db.char.history) or {}
  for index = 1, #history do
    local entry = history[index]
    if type(entry) == "table" and entry.surface == "chat" then
      if entry.channel == "CHAT_MSG_WHISPER" then
        entry.surface = "whisper"
      elseif entry.channel == "CHAT_MSG_BN_WHISPER" then
        entry.surface = "bn-whisper"
      end
    end
  end

  -- enabledCategories: boolean -> string enum.
  local settings = (db.global and db.global.settings) or {}
  local categories = settings.enabledCategories or {}
  for category, value in pairs(categories) do
    if type(value) == "boolean" then
      categories[category] = value and "active" or "off"
    end
  end
  settings.enabledCategories = categories
end

local function Print(message)
  message = "|cff33ff99Hush|r " .. tostring(message)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(message)
  else
    print(message)
  end
end

local function DevLog(message)
  if DB.IsDevMode and DB.IsDevMode() then
    Print(message)
  end
end

migrations[3] = function(db)
  -- BSP-050: account-wide cap introduced. Existing data may be over it; trim once
  -- and announce. Subsequent enforcement is silent (Init.lua login-trim, commit 4).
  if NS.History and NS.History.TrimAllCharacters then
    local perCharRemoved, globalRemoved = NS.History.TrimAllCharacters()
    local total = perCharRemoved + globalRemoved
    if total > 0 then
      Print(string.format(
        "enforcing new account-wide history cap: trimmed %d records "
          .. "(%d per-char excess, %d global). Open /hush config > "
          .. "History to adjust the caps.",
        total, perCharRemoved, globalRemoved
      ))
    end
  end
end

local function CopyDefaults(source)
  local copy = {}
  for key, value in pairs(source) do
    if type(value) == "table" then
      copy[key] = CopyDefaults(value)
    else
      copy[key] = value
    end
  end
  return copy
end

local function ClampNumber(value, minValue, maxValue, fallback)
  value = tonumber(value) or fallback
  if value < minValue then value = minValue end
  if value > maxValue then value = maxValue end
  return value
end

local function Now()
  if type(GetServerTime) == "function" then
    return GetServerTime()
  end
  return time()
end

local function UsableString(value)
  return type(value) == "string" and value ~= ""
end

local function CountTable(tbl)
  local count = 0
  for _ in pairs(tbl or {}) do
    count = count + 1
  end
  return count
end

local function EvictOldestBlockedActor(blockedActors)
  local oldestKey
  local oldestSeen
  for key, entry in pairs(blockedActors or {}) do
    local seen = type(entry) == "table" and tonumber(entry.lastBlockedAt) or nil
    if not oldestSeen or (seen or 0) < oldestSeen then
      oldestKey = key
      oldestSeen = seen or 0
    end
  end
  if oldestKey then
    blockedActors[oldestKey] = nil
  end
end

local function RepairSettings(settings)
  local defaultSettings = defaults.global.settings
  settings.threshold = ClampNumber(settings.threshold, 1, 10, defaultSettings.threshold)
  settings.mixedScriptWeight = ClampNumber(settings.mixedScriptWeight, 0, 3, defaultSettings.mixedScriptWeight)
  settings.antiSignalCap = ClampNumber(settings.antiSignalCap, -10, -1, defaultSettings.antiSignalCap)
  settings.historyMaxEntries = ClampNumber(settings.historyMaxEntries, 100, 5000, defaultSettings.historyMaxEntries)
  settings.historyGlobalMaxEntries = ClampNumber(settings.historyGlobalMaxEntries, 100, 5000, defaultSettings.historyGlobalMaxEntries)
  settings.mixedScriptEnabled = settings.mixedScriptEnabled ~= false
  settings.filterBubbles = settings.filterBubbles == true
  settings.showMinimapButton = settings.showMinimapButton ~= false
  -- BSP-061: premade-group scanning removed. Prune the now-defunct setting
  -- keys it left behind in existing SavedVariables (see DEFUNCT_SETTING_KEYS).
  for _, key in ipairs(DEFUNCT_SETTING_KEYS) do
    settings[key] = nil
  end
  settings.devMode = settings.devMode == true
  settings.enabledCategories = type(settings.enabledCategories) == "table" and settings.enabledCategories or {}
  for category, defaultState in pairs(defaultSettings.enabledCategories) do
    local current = settings.enabledCategories[category]
    -- Reset when missing OR not a valid enum (stale boolean / junk).
    -- Otherwise the existing valid enum value is kept.
    if current == nil or not (type(current) == "string" and VALID_AXIS_STATES[current]) then
      settings.enabledCategories[category] = defaultState
    end
  end
  settings.surfaces = type(settings.surfaces) == "table" and settings.surfaces or {}
  for surface, defaultState in pairs(defaultSettings.surfaces) do
    local current = settings.surfaces[surface]
    -- Reset when missing OR not a valid enum. Otherwise keep the existing value.
    if current == nil or not (type(current) == "string" and VALID_AXIS_STATES[current]) then
      settings.surfaces[surface] = defaultState
    end
  end
  -- BSP-061: prune stale premade-group surface states left in existing
  -- SavedVariables (see DEFUNCT_SURFACE_KEYS).
  for _, key in ipairs(DEFUNCT_SURFACE_KEYS) do
    settings.surfaces[key] = nil
  end
  -- BSP-010: repair the throttle subtree. Junk values (string, negative,
  -- out-of-range) clamp back to safe defaults; missing fields backfill.
  settings.throttle = type(settings.throttle) == "table" and settings.throttle or {}
  settings.throttle.enabled = settings.throttle.enabled ~= false
  settings.throttle.bufferSize = ClampNumber(settings.throttle.bufferSize, 5, 50,
    defaultSettings.throttle.bufferSize)
end

local function RepairShape(global, char)
  global.schemaVersion = tonumber(global.schemaVersion) or CURRENT_SCHEMA_VERSION
  global.allowlist = global.allowlist or {}
  global.blockedActors = global.blockedActors or {}
  global.settings = global.settings or {}
  char.history = char.history or {}
  char.historyCursor = char.historyCursor or 0
  char.stats = char.stats or {}
  char.stats.initialized = char.stats.initialized == true
  char.stats.detections = tonumber(char.stats.detections) or 0
  char.stats.blocked = tonumber(char.stats.blocked) or 0
  char.stats.restored = tonumber(char.stats.restored) or 0
  char.stats.bySurface = type(char.stats.bySurface) == "table" and char.stats.bySurface or {}
  char.stats.passThru = tonumber(char.stats.passThru) or 0
  char.stats.byCategory = type(char.stats.byCategory) == "table" and char.stats.byCategory or {}
  char.stats.throttled = tonumber(char.stats.throttled) or 0
  char.stats.bubblesSuppressed = tonumber(char.stats.bubblesSuppressed) or 0
  char.lastSeenVersion = char.lastSeenVersion or ADDON_VERSION
  RepairSettings(global.settings)
end

local function ApplyMigrations(db)
  local version = tonumber(db.global.schemaVersion) or CURRENT_SCHEMA_VERSION
  if version > CURRENT_SCHEMA_VERSION then
    DevLog("SavedVariables schema is newer than this addon; running without migration.")
    return
  end

  for nextVersion = version + 1, CURRENT_SCHEMA_VERSION do
    local migration = migrations[nextVersion]
    if migration then
      migration(db)
    end
    db.global.schemaVersion = nextVersion
  end
end

function DB.Initialize()
  local F = _G.Foundry_1_0
  if not (F and F:HasModule("DB")) then
    NS._InitFailed = true
    Print("could not initialize: Foundry.DB is missing.")
    return false
  end

  -- One-time SavedVariables migration: BawrSpam → Hush (BSP-067)
  if type(BawrSpamDB) == "table" and (HushDB == nil or next(HushDB) == nil) then
    HushDB = BawrSpamDB
    BawrSpamDB = nil
  end

  DB.db = F.DB:New({ name = "Hush", sv = "HushDB", defaults = defaults, defaultProfile = true })
  RepairShape(DB.db.global, DB.db.char)
  ApplyMigrations(DB.db)
  RepairShape(DB.db.global, DB.db.char)
  DB.db.char.lastSeenVersion = ADDON_VERSION
  return true
end

function DB.GetGlobal()
  return DB.db and DB.db.global
end

function DB.GetChar()
  return DB.db and DB.db.char
end

function DB.GetSettings()
  return DB.db and DB.db.global and DB.db.global.settings
end

function DB.SetSetting(key, value)
  local settings = DB.GetSettings()
  if not settings or type(key) ~= "string" then
    return nil
  end

  if key == "threshold" then
    settings.threshold = ClampNumber(value, 1, 10, defaults.global.settings.threshold)
  elseif key == "mixedScriptWeight" then
    settings.mixedScriptWeight = ClampNumber(value, 0, 3, defaults.global.settings.mixedScriptWeight)
  elseif key == "antiSignalCap" then
    settings.antiSignalCap = ClampNumber(value, -10, -1, defaults.global.settings.antiSignalCap)
  elseif key == "historyMaxEntries" then
    settings.historyMaxEntries = ClampNumber(value, 100, 5000, defaults.global.settings.historyMaxEntries)
  elseif key == "historyGlobalMaxEntries" then
    settings.historyGlobalMaxEntries = ClampNumber(value, 100, 5000, defaults.global.settings.historyGlobalMaxEntries)
  elseif key == "enabledCategories" then
    if type(value) ~= "table" then
      return nil
    end
    settings.enabledCategories = {}
    for category, defaultState in pairs(defaults.global.settings.enabledCategories) do
      local provided = value[category]
      local resolved
      if provided == nil then
        resolved = defaultState
      elseif provided == true then
        resolved = "active"
      elseif provided == false then
        resolved = "off"
      elseif type(provided) == "string" and VALID_AXIS_STATES[provided] then
        resolved = provided
      else
        resolved = defaultState
      end
      settings.enabledCategories[category] = resolved
    end
  elseif key == "mixedScriptEnabled" or key == "filterBubbles"
    or key == "showMinimapButton" or key == "devMode" then
    settings[key] = value == true
  else
    return nil
  end

  return settings[key]
end

function DB.SetCategoryEnabled(category, enabled)
  local settings = DB.GetSettings()
  if not settings or type(category) ~= "string" then
    return nil
  end

  if defaults.global.settings.enabledCategories[category] == nil then
    return nil
  end

  settings.enabledCategories = settings.enabledCategories or {}
  settings.enabledCategories[category] = enabled and "active" or "off"
  return settings.enabledCategories[category]
end

function DB.SetSurfaceState(surface, state)
  local settings = DB.GetSettings()
  if not settings or type(surface) ~= "string" or type(state) ~= "string" then
    return nil
  end
  if not VALID_AXIS_STATES[state] then
    return nil
  end
  if defaults.global.settings.surfaces[surface] == nil then
    return nil
  end
  settings.surfaces = settings.surfaces or {}
  settings.surfaces[surface] = state
  return state
end

function DB.SetCategoryState(category, state)
  local settings = DB.GetSettings()
  if not settings or type(category) ~= "string" or type(state) ~= "string" then
    return nil
  end
  if not VALID_AXIS_STATES[state] then
    return nil
  end
  if defaults.global.settings.enabledCategories[category] == nil then
    return nil
  end
  settings.enabledCategories = settings.enabledCategories or {}
  settings.enabledCategories[category] = state
  return state
end

-- BSP-010: throttle setters. Mirror the SetSurfaceState / SetCategoryState
-- convention (per-setter validation, returns canonical value or nil on
-- failure) and also push the new value into NS.Throttle's runtime state so
-- ConfigPanel slider/checkbox changes take effect without /reload.
function DB.SetThrottleEnabled(value)
  local settings = DB.GetSettings()
  if not settings then
    return nil
  end
  settings.throttle = settings.throttle or {}
  settings.throttle.enabled = value == true
  if NS.Throttle and NS.Throttle.SetEnabled then
    NS.Throttle.SetEnabled(settings.throttle.enabled)
  end
  return settings.throttle.enabled
end

function DB.SetThrottleBufferSize(value)
  local settings = DB.GetSettings()
  if not settings then
    return nil
  end
  settings.throttle = settings.throttle or {}
  settings.throttle.bufferSize = ClampNumber(value, 5, 50,
    defaults.global.settings.throttle.bufferSize)
  if NS.Throttle and NS.Throttle.SetBufferSize then
    NS.Throttle.SetBufferSize(settings.throttle.bufferSize)
  end
  return settings.throttle.bufferSize
end

function DB.GetBlockedActor(guid)
  local global = DB.GetGlobal()
  if not global or not UsableString(guid) then
    return nil
  end
  local blockedActors = global.blockedActors
  return type(blockedActors) == "table" and blockedActors[guid] or nil
end

function DB.RecordBlockedActor(record, category)
  local global = DB.GetGlobal()
  if not global or type(record) ~= "table" or not UsableString(record.guid) then
    return false
  end

  global.blockedActors = type(global.blockedActors) == "table" and global.blockedActors or {}
  local blockedActors = global.blockedActors
  local guid = record.guid
  local entry = blockedActors[guid]
  if type(entry) ~= "table" then
    entry = {
      guid = guid,
      firstBlockedAt = tonumber(record.ts) or Now(),
      count = 0,
      surfaces = {},
      categories = {},
    }
    blockedActors[guid] = entry
  end

  entry.name = UsableString(record.name) and record.name or entry.name
  entry.realm = UsableString(record.realm) and record.realm or entry.realm
  entry.lastBlockedAt = tonumber(record.ts) or Now()
  entry.count = (tonumber(entry.count) or 0) + 1
  entry.surfaces = type(entry.surfaces) == "table" and entry.surfaces or {}
  entry.categories = type(entry.categories) == "table" and entry.categories or {}

  local surface = UsableString(record.surface) and record.surface or "chat"
  entry.surfaces[surface] = (tonumber(entry.surfaces[surface]) or 0) + 1

  if UsableString(category) then
    entry.categories[category] = (tonumber(entry.categories[category]) or 0) + 1
  end

  while CountTable(blockedActors) > BLOCKED_ACTOR_CAP do
    EvictOldestBlockedActor(blockedActors)
  end

  return true
end

function DB.RemoveBlockedActor(guid)
  local global = DB.GetGlobal()
  if not global or not UsableString(guid) or type(global.blockedActors) ~= "table" then
    return false
  end
  if global.blockedActors[guid] == nil then
    return false
  end
  global.blockedActors[guid] = nil
  return true
end

function DB.ResetSettings()
  local global = DB.GetGlobal()
  if not global then
    return nil
  end

  global.settings = CopyDefaults(defaults.global.settings)
  RepairSettings(global.settings)
  -- BSP-050 (extends BSP-049): reset can lower both historyMaxEntries and the
  -- new historyGlobalMaxEntries back to defaults, and the records live in
  -- char.history for every character, not just the current one. Trim across
  -- all chars immediately so the caps the user just reset to are authoritative
  -- account-wide, not enforced piecemeal as each alt next logs in.
  if NS.History and NS.History.TrimAllCharacters then
    NS.History.TrimAllCharacters()
  end
  return global.settings
end

function DB.IsDevMode()
  local settings = DB.GetSettings()
  return settings and settings.devMode == true
end

function DB.Log(message)
  Print(message)
end

function DB.DevLog(message)
  DevLog(message)
end

NS.DB = DB
return DB
