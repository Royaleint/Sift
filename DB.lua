local _, NS = ...
local DB = {}

local CURRENT_SCHEMA_VERSION = 1
local ADDON_VERSION = "1.0.0"

local defaults = {
  global = {
    schemaVersion = CURRENT_SCHEMA_VERSION,
    allowlist = {},
    blockedActors = {},
    settings = {
      threshold = 4,
      enabledCategories = {
        RMT = true,
        Boosting = true,
        Casino = true,
        Phishing = true,
        Commercial = true,
        Anti = true,
      },
      mixedScriptEnabled = true,
      mixedScriptWeight = 1,
      antiSignalCap = -5,
      filterBubbles = false,
      lfgScanEnabled = true,
      historyMaxEntries = 1000,
      devMode = false,
    },
  },
  char = {
    history = {},
    historyCursor = 0,
    lastSeenVersion = ADDON_VERSION,
  },
}

local migrations = {}

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

local function ClampHistoryMax(settings)
  local value = tonumber(settings.historyMaxEntries) or defaults.global.settings.historyMaxEntries
  if value < 100 then value = 100 end
  if value > 5000 then value = 5000 end
  settings.historyMaxEntries = value
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
  db.char.lastSeenVersion = db.char.lastSeenVersion or ADDON_VERSION
  ClampHistoryMax(db.global.settings)
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
