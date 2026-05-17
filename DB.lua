local _, NS = ...
local DB = {}

local CURRENT_SCHEMA_VERSION = 2
local ADDON_VERSION = "1.1.0"

local defaults = {
  global = {
    schemaVersion = CURRENT_SCHEMA_VERSION,
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
        ["lfg-search"]    = "active",
        ["lfg-applicant"] = "active",
      },
      mixedScriptEnabled = true,
      mixedScriptWeight = 1,
      antiSignalCap = -5,
      filterBubbles = false,
      lfgScanEnabled = true,
      showMinimapButton = true,
      historyMaxEntries = 300,
      devMode = false,
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

local migrations = {}

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
  message = "|cff33ff99BawrSpam|r " .. tostring(message)
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

local function RepairSettings(settings)
  local defaultSettings = defaults.global.settings
  settings.threshold = ClampNumber(settings.threshold, 1, 10, defaultSettings.threshold)
  settings.mixedScriptWeight = ClampNumber(settings.mixedScriptWeight, 0, 3, defaultSettings.mixedScriptWeight)
  settings.antiSignalCap = ClampNumber(settings.antiSignalCap, -10, -1, defaultSettings.antiSignalCap)
  settings.historyMaxEntries = ClampNumber(settings.historyMaxEntries, 100, 5000, defaultSettings.historyMaxEntries)
  settings.mixedScriptEnabled = settings.mixedScriptEnabled ~= false
  settings.filterBubbles = settings.filterBubbles == true
  settings.lfgScanEnabled = settings.lfgScanEnabled ~= false
  settings.showMinimapButton = settings.showMinimapButton ~= false
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
end

local function RepairShape(db)
  db.global = db.global or {}
  db.char = db.char or {}
  db.global.schemaVersion = tonumber(db.global.schemaVersion) or CURRENT_SCHEMA_VERSION
  db.global.allowlist = db.global.allowlist or {}
  db.global.blockedActors = db.global.blockedActors or {}
  db.global.settings = db.global.settings or {}
  db.char.history = db.char.history or {}
  db.char.historyCursor = db.char.historyCursor or 0
  db.char.stats = db.char.stats or {}
  db.char.stats.initialized = db.char.stats.initialized == true
  db.char.stats.detections = tonumber(db.char.stats.detections) or 0
  db.char.stats.blocked = tonumber(db.char.stats.blocked) or 0
  db.char.stats.restored = tonumber(db.char.stats.restored) or 0
  db.char.stats.bySurface = type(db.char.stats.bySurface) == "table" and db.char.stats.bySurface or {}
  db.char.stats.passThru = tonumber(db.char.stats.passThru) or 0
  db.char.stats.byCategory = type(db.char.stats.byCategory) == "table" and db.char.stats.byCategory or {}
  db.char.stats.throttled = tonumber(db.char.stats.throttled) or 0
  db.char.stats.bubblesSuppressed = tonumber(db.char.stats.bubblesSuppressed) or 0
  db.char.lastSeenVersion = db.char.lastSeenVersion or ADDON_VERSION
  RepairSettings(db.global.settings)
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
  local AceDB = LibStub and LibStub("AceDB-3.0", true)
  if not AceDB then
    NS._InitFailed = true
    Print("could not initialize: AceDB-3.0 is missing.")
    return false
  end

  DB.db = AceDB:New("BawrSpamDB", defaults, true)
  RepairShape(DB.db)
  ApplyMigrations(DB.db)
  RepairShape(DB.db)
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
  elseif key == "mixedScriptEnabled" or key == "filterBubbles" or key == "lfgScanEnabled"
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

function DB.ResetSettings()
  local global = DB.GetGlobal()
  if not global then
    return nil
  end

  global.settings = CopyDefaults(defaults.global.settings)
  RepairSettings(global.settings)
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
