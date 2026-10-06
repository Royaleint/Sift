-- Sift/DB.lua
-- SavedVariables: defaults, shape repair, migrations, settings setters, the
-- blocked-actor store, and the one-time import of legacy BawrSpam data.

local ADDON_NAME, NS = ...
local DB = {}

-- SavedVariables global names, derived per build. They must equal the globals
-- the DevBuild's TOC declares ("SiftDB" -> "SiftDB_DevBuild"), or the build
-- stores its data in a global it never saves, or in the other build's.
-- "Sift_DevBuild" must yield "SiftDB_DevBuild", not "Sift_DevBuildDB".
-- The suffix also lives where the dev build's TOC is generated; nothing in Lua
-- enforces the match, so change both together.
local LIVE_ADDON_NAME = "Sift"
local BASE_SV_NAME = "SiftDB"
local LEGACY_SV_NAME = "BawrSpamDB"

-- Returns (svName, legacySvName) for a recognised folder, or (nil, reason).
-- Must never fall back to the live names: an unrecognised build pointed at the
-- live store would write into data it does not own. Pure, for tests.
function DB.DeriveSVNames(addonName)
  local name = tostring(addonName or "")
  local suffix = name:match("^" .. LIVE_ADDON_NAME .. "(.*)$")
  if not suffix then
    return nil, "addon folder '" .. name .. "' is neither '" .. LIVE_ADDON_NAME
      .. "' nor '" .. LIVE_ADDON_NAME .. "<suffix>'"
  end
  return BASE_SV_NAME .. suffix, LEGACY_SV_NAME .. suffix
end

-- Resolved at file scope but raised in Initialize: an error() during file load
-- would abort the rest of this file with no useful context.
local SV_NAME, SV_LEGACY_NAME = DB.DeriveSVNames(ADDON_NAME)
-- On failure DeriveSVNames returns (nil, reason), so the second value is the message.
local SV_NAME_ERROR = (not SV_NAME) and SV_LEGACY_NAME or nil

-- Bump only with a matching migrations[N]: a missing entry still stamps N.
-- A migration that returns false stops the loop before stamping and retries
-- at the next login; a permanently deferred migration would block every
-- later one, which is unreachable in the shipped load order.
local CURRENT_SCHEMA_VERSION = 6
local ADDON_VERSION = "1.5.0"
local BLOCKED_ACTOR_CAP = 5000

-- Bumped by every write to global.blockedActors (scanner block, manual
-- block, removal, clear all, legacy import). The Config panel's Blocked
-- list reads this to know whether its cached, sorted view is still current.
local blockedRevision = 0

local function TouchBlockedRevision()
  blockedRevision = blockedRevision + 1
end

local defaults = {
  global = {
    allowlist = {},
    blockedActors = {},
    -- Keyword rules: arrays so display order is stable; managed by UserRules.lua.
    customBlocks = {},
    allowKeywords = {},
    -- First-run chooser rows already decided, keyed by registry key; only `true`
    -- counts. Never seed a key here: defaults are copied into a fresh install,
    -- which would mark the row seen without ever showing it.
    chooserSeen = {},
    settings = {
      threshold = 4,
      -- Only user-facing categories are persisted; retired ones score at the
      -- frozen states in PauseState.lua.
      enabledCategories = {
        RMT        = "active",
        Boosting   = "active",
        Carrying   = "active",
        -- The user's keyword block list. Must be listed here: SetCategoryState
        -- rejects any category missing from this table.
        Custom     = "active",
      },
      surfaces = {
        chat              = "active",
        whisper           = "active",
        ["bn-whisper"]    = "active",
      },
      mixedScriptEnabled = true,
      mixedScriptWeight = 1,
      antiSignalCap = -5,
      -- Seconds. Only the seed value; the band is owned by Frequency.lua.
      floodWindow = 180,
      filterBubbles = false,
      showMinimapButton = true,
      historyMaxEntries = 300,
      historyGlobalMaxEntries = 1000,
      -- Repeat dedupe. `enabled` is kept in the saved shape but not read.
      throttle = {
        enabled = true,
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

-- Saved keys left behind by a removed feature, pruned on load. They must stay
-- byte-identical to the keys originally written, or the prune silently misses
-- them. Keep the prefix split: the joined token must not appear literally in source.
local DEFUNCT_KEY_PREFIX = "lf" .. "g"
local DEFUNCT_SURFACE_KEYS = { DEFUNCT_KEY_PREFIX .. "-search", DEFUNCT_KEY_PREFIX .. "-applicant" }
local DEFUNCT_SETTING_KEYS = { DEFUNCT_KEY_PREFIX .. "ScanEnabled" }

-- Retired categories: their rules still score at the frozen states in
-- PauseState.lua, so their stored states are pruned as dead weight.
local DEFUNCT_CATEGORY_KEYS = { "Casino", "Phishing", "Commercial", "Anti" }

local migrations = {}
-- migrations[3] onward are defined after Print and DevLog so they can call them.

migrations[2] = function(db)
  -- Whisper split: older saves filed whisper and Battle.net whisper entries
  -- under surface="chat". Move them to their own surface keys.
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
  message = "|cff33ff99Sift|r " .. tostring(message)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(message)
  else
    print(message)
  end
end

local function DevLog(message)
  local ext = NS.extension
  if ext and ext.enabled then
    Print(message)
  end
end

migrations[3] = function(db)
  -- Account-wide history cap: trim once and announce. Later trims are silent.
  if NS.History and NS.History.TrimAllCharacters then
    local perCharRemoved, globalRemoved = NS.History.TrimAllCharacters()
    local total = perCharRemoved + globalRemoved
    if total > 0 then
      Print(NS.L["enforcing new account-wide history cap: trimmed %d records (%d per-char excess, %d global). Open /sift config > History to adjust the caps."]:format(
        total, perCharRemoved, globalRemoved
      ))
    end
  end
end

-- Carrying splits out of Boosting and inherits Boosting's state, so nobody's
-- filtering changes on upgrade. Relies on RepairShape having already run and
-- validated Boosting (see DB.Initialize).
migrations[4] = function(db)
  local settings = (db.global and db.global.settings) or {}
  local categories = settings.enabledCategories
  if type(categories) == "table" and categories.Boosting then
    categories.Carrying = categories.Boosting
  end
end

-- Rebuilds every non-ASCII saved phrase once from its raw spelling: older saves
-- can hold a cleansed form (mostly CJK) that no longer matches.
-- Returns false (defer, retry next login) only when Cleanse is missing and a
-- stored rule needs it; with no UserRules at all, its own schema number is still stamped.
-- The same body serves as migration 6. A phrase whose rebuilt form is shorter
-- than the list minimum is removed and named in chat.
migrations[5] = function(db)
  local UserRules = NS.UserRules
  if not (UserRules and UserRules.RecleanseStore) then return end
  local L = NS.L
  local lists = {
    { db.global.customBlocks, L["My Keywords"], UserRules.GetMinLength(UserRules.BLOCK) },
    { db.global.allowKeywords, L["Never Block"], UserRules.GetMinLength(UserRules.ALLOW) },
  }
  local results = {}
  for index, list in ipairs(lists) do
    local changed, merged, kept, dropped = UserRules.RecleanseStore(list[1], list[3])
    if changed == false then return false end
    results[index] = { merged, kept, dropped }
  end
  for index, list in ipairs(lists) do
    local merged, kept, dropped = results[index][1], results[index][2], results[index][3]
    if #dropped > 0 then
      local quoted = {}
      for position, raw in ipairs(dropped) do
        quoted[position] = '"' .. raw .. '"'
      end
      Print(L["Removed from your %s because they are now too short to use: %s"]:format(list[2], table.concat(quoted, ", ")))
    end
    if merged > 0 then
      Print(L["%d of your %s phrases matched another phrase already in the list, so we combined the duplicates. What gets filtered has not changed."]:format(merged, list[2]))
    end
    if kept > 0 then
      DevLog("Kept " .. kept .. " keyword rule(s) unchanged: the phrase normalizes to nothing.")
    end
  end
end

-- A matching change means saved phrases containing certain characters need the same one-time rebuild as migration 5; a store that is already current comes through unchanged.
migrations[6] = migrations[5]

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

-- Alias; CopyDefaults is a general deep copy.
local DeepCopy = CopyDefaults

local function ClampNumber(value, minValue, maxValue, fallback)
  value = tonumber(value) or fallback
  if value < minValue then value = minValue end
  if value > maxValue then value = maxValue end
  return value
end

-- The band comes from Frequency. Without it, return the default rather than
-- an unclamped value.
local function ClampFloodWindow(value)
  if NS.Frequency and NS.Frequency.GetFloodWindowBounds then
    local minWindow, maxWindow = NS.Frequency.GetFloodWindowBounds()
    return ClampNumber(value, minWindow, maxWindow, defaults.global.settings.floodWindow)
  end
  return defaults.global.settings.floodWindow
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

-- Manual blocks are never evicted. Returns whether anything was removed, so a
-- trim loop stops once only manual entries remain.
local function EvictOldestBlockedActor(blockedActors)
  local oldestKey
  local oldestSeen
  for key, entry in pairs(blockedActors or {}) do
    if not (type(entry) == "table" and entry.manual == true) then
      local seen = type(entry) == "table" and tonumber(entry.lastBlockedAt) or nil
      if not oldestSeen or (seen or 0) < oldestSeen then
        oldestKey = key
        oldestSeen = seen or 0
      end
    end
  end
  if not oldestKey then
    return false
  end
  blockedActors[oldestKey] = nil
  return true
end

local function RepairSettings(settings)
  local defaultSettings = defaults.global.settings
  settings.threshold = ClampNumber(settings.threshold, 1, 10, defaultSettings.threshold)
  settings.mixedScriptWeight = ClampNumber(settings.mixedScriptWeight, 0, 3, defaultSettings.mixedScriptWeight)
  settings.antiSignalCap = ClampNumber(settings.antiSignalCap, -10, -1, defaultSettings.antiSignalCap)
  settings.floodWindow = ClampFloodWindow(settings.floodWindow)
  settings.historyMaxEntries = ClampNumber(settings.historyMaxEntries, 100, 5000, defaultSettings.historyMaxEntries)
  settings.historyGlobalMaxEntries = ClampNumber(settings.historyGlobalMaxEntries, 100, 5000, defaultSettings.historyGlobalMaxEntries)
  settings.mixedScriptEnabled = settings.mixedScriptEnabled ~= false
  settings.filterBubbles = settings.filterBubbles == true
  settings.showMinimapButton = settings.showMinimapButton ~= false
  -- Prune defunct setting keys (see DEFUNCT_SETTING_KEYS).
  for _, key in ipairs(DEFUNCT_SETTING_KEYS) do
    settings[key] = nil
  end
  settings.enabledCategories = type(settings.enabledCategories) == "table" and settings.enabledCategories or {}
  for category, defaultState in pairs(defaultSettings.enabledCategories) do
    local current = settings.enabledCategories[category]
    -- Reset when missing or not a valid enum (a stale boolean or junk).
    if current == nil or not (type(current) == "string" and VALID_AXIS_STATES[current]) then
      settings.enabledCategories[category] = defaultState
    end
  end
  -- Drop the states of retired categories.
  for _, key in ipairs(DEFUNCT_CATEGORY_KEYS) do
    settings.enabledCategories[key] = nil
  end
  settings.surfaces = type(settings.surfaces) == "table" and settings.surfaces or {}
  for surface, defaultState in pairs(defaultSettings.surfaces) do
    local current = settings.surfaces[surface]
    -- Reset when missing OR not a valid enum. Otherwise keep the existing value.
    if current == nil or not (type(current) == "string" and VALID_AXIS_STATES[current]) then
      settings.surfaces[surface] = defaultState
    end
  end
  -- Prune defunct surface keys (see DEFUNCT_SURFACE_KEYS).
  for _, key in ipairs(DEFUNCT_SURFACE_KEYS) do
    settings.surfaces[key] = nil
  end
  -- Repair the throttle subtree; junk values fall back to defaults.
  settings.throttle = type(settings.throttle) == "table" and settings.throttle or {}
  settings.throttle.enabled = settings.throttle.enabled ~= false
  -- Defunct key: pruned from saves that still carry it.
  settings.throttle.bufferSize = nil
end

local function RepairShape(global, char)
  global.schemaVersion = tonumber(global.schemaVersion) or CURRENT_SCHEMA_VERSION
  global.allowlist = global.allowlist or {}
  global.blockedActors = global.blockedActors or {}
  -- Keyword rules are matched against every scanned line, so drop malformed ones.
  global.customBlocks = type(global.customBlocks) == "table" and global.customBlocks or {}
  global.allowKeywords = type(global.allowKeywords) == "table" and global.allowKeywords or {}
  if NS.UserRules and NS.UserRules.RepairStore then
    local dropped = NS.UserRules.RepairStore(global.customBlocks)
      + NS.UserRules.RepairStore(global.allowKeywords)
    if dropped > 0 then
      DevLog("Dropped " .. dropped .. " malformed keyword rule(s).")
    end
  end
  -- Type-checked, not just presence-checked, so a junk saved value is repaired.
  global.chooserSeen = type(global.chooserSeen) == "table" and global.chooserSeen or {}
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
    if migration and migration(db) == false then
      DevLog("Migration " .. nextVersion .. " deferred; will retry next login.")
      return
    end
    db.global.schemaVersion = nextVersion
  end
end

function DB.Initialize()
  -- Unrecognised folder name: refuse loudly rather than guess a store, since a
  -- wrong guess writes into SavedVariables this build does not own.
  if SV_NAME_ERROR then
    error("Sift: " .. SV_NAME_ERROR
      .. ". Refusing to load saved data rather than risk writing into another build's store."
      .. " Supported folder names are '" .. LIVE_ADDON_NAME .. "' (the released build) and '"
      .. LIVE_ADDON_NAME .. "_DevBuild' (the generated dev build). Rename the folder to one of those.")
  end

  local F = _G.Foundry_1_0
  if not (F and F:HasModule("DB")) then
    NS._InitFailed = true
    Print(NS.L["could not initialize: Foundry.DB is missing."])
    return false
  end

  -- Both from the TOC vararg: `name` so a renamed folder passes Foundry's
  -- IsAddOnLoaded check, `sv` so the store matches this build's declared global.
  -- RepairShape runs twice: migrations read a validated shape, and the second
  -- pass repairs whatever they wrote.
  DB.db = F.DB:New({ name = ADDON_NAME, sv = SV_NAME, defaults = defaults, defaultProfile = true })
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
  elseif key == "floodWindow" then
    settings.floodWindow = ClampFloodWindow(value)
    if NS.Frequency and NS.Frequency.SetFloodWindow then
      NS.Frequency.SetFloodWindow(settings.floodWindow)
    end
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
    or key == "showMinimapButton" then
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

function DB.GetBlockedActor(guid)
  local global = DB.GetGlobal()
  if not global or not UsableString(guid) then
    return nil
  end
  local blockedActors = global.blockedActors
  return type(blockedActors) == "table" and blockedActors[guid] or nil
end

-- Each field keeps its older value when the new one is unusable. On WoW
-- Forever a usable name replaces the pair whole instead: its names carry no
-- realm, and an older stored realm would be shown after the full name.
local function WriteActorName(entry, name, realm)
  if UsableString(name) and NS.Compat and NS.Compat.RegionalNames and NS.Compat.RegionalNames() then
    entry.name, entry.realm = name, nil
    return
  end
  entry.name = UsableString(name) and name or entry.name
  entry.realm = UsableString(realm) and realm or entry.realm
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
  local isNewEntry = type(entry) ~= "table"
  if isNewEntry then
    entry = {
      guid = guid,
      firstBlockedAt = tonumber(record.ts) or Now(),
      count = 0,
      surfaces = {},
      categories = {},
    }
    blockedActors[guid] = entry
  end

  WriteActorName(entry, record.name, record.realm)
  entry.lastBlockedAt = tonumber(record.ts) or Now()
  entry.count = (tonumber(entry.count) or 0) + 1
  entry.surfaces = type(entry.surfaces) == "table" and entry.surfaces or {}
  entry.categories = type(entry.categories) == "table" and entry.categories or {}

  local surface = UsableString(record.surface) and record.surface or "chat"
  entry.surfaces[surface] = (tonumber(entry.surfaces[surface]) or 0) + 1

  if UsableString(category) then
    entry.categories[category] = (tonumber(entry.categories[category]) or 0) + 1
  end

  -- Only adding a new key can push the table past the cap, so a repeat
  -- sender's block skips the trim. The trim runs after the entry's fields
  -- are set, so the new entry is judged by its current lastBlockedAt.
  if isNewEntry then
    while CountTable(blockedActors) > BLOCKED_ACTOR_CAP do
      if not EvictOldestBlockedActor(blockedActors) then
        break
      end
    end
  end

  TouchBlockedRevision()
  return true
end

-- Blocks an actor by user action. Shares blockedActors with the scanner, so
-- both resolve to one entry and one undo path. `count` is left alone: it counts
-- suppressed messages. Returns false when already manually blocked.
function DB.BlockActorManually(guid, name, realm)
  local global = DB.GetGlobal()
  if not global or not UsableString(guid) then
    return false
  end
  if type(UnitGUID) == "function" and guid == UnitGUID("player") then
    return false
  end

  global.blockedActors = type(global.blockedActors) == "table" and global.blockedActors or {}
  local blockedActors = global.blockedActors
  local entry = blockedActors[guid]
  if type(entry) == "table" and entry.manual == true then
    return false
  end

  if type(entry) ~= "table" then
    entry = {
      guid = guid,
      firstBlockedAt = Now(),
      count = 0,
      surfaces = {},
      categories = {},
    }
    blockedActors[guid] = entry
  end

  entry.manual = true
  entry.manualBlockedAt = Now()
  WriteActorName(entry, name, realm)
  entry.lastBlockedAt = tonumber(entry.lastBlockedAt) or entry.manualBlockedAt

  TouchBlockedRevision()
  return true
end

function DB.IsManuallyBlocked(guid)
  local entry = DB.GetBlockedActor(guid)
  return type(entry) == "table" and entry.manual == true
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
  TouchBlockedRevision()
  return true
end

function DB.GetBlockedActorsRevision()
  return blockedRevision
end

-- Routes Config's Clear All through DB, so a full wipe bumps the same
-- revision every other blockedActors write does.
function DB.ClearBlockedActors()
  local global = DB.GetGlobal()
  if not global then
    return false
  end
  global.blockedActors = type(global.blockedActors) == "table" and global.blockedActors or {}
  if type(wipe) == "function" then
    wipe(global.blockedActors)
  else
    for key in pairs(global.blockedActors) do
      global.blockedActors[key] = nil
    end
  end
  TouchBlockedRevision()
  return true
end

function DB.ResetSettings()
  local global = DB.GetGlobal()
  if not global then
    return nil
  end

  global.settings = CopyDefaults(defaults.global.settings)
  RepairSettings(global.settings)
  -- A reset can lower the history caps; trim every character now rather than
  -- as each alt next logs in.
  if NS.History and NS.History.TrimAllCharacters then
    NS.History.TrimAllCharacters()
  end
  -- Likewise push the reset flood window now, not at next login.
  if NS.Frequency and NS.Frequency.SetFloodWindow then
    NS.Frequency.SetFloodWindow(global.settings.floodWindow)
  end
  return global.settings
end

-- Tidies saved data. `keep` is true when this load must leave it alone.
-- Returns whether anything changed.
function DB.PruneOnLogin(keep)
  if keep then
    return false
  end
  local global = DB.db and DB.db.global
  local settings = type(global) == "table" and global.settings
  if type(settings) ~= "table" then
    return false
  end

  local changed = false
  local wasOn = settings.devMode == true

  if global.shadowLog ~= nil then
    global.shadowLog = nil
    changed = true
  end

  if wasOn then
    local defaultSettings = defaults.global.settings
    settings.antiSignalCap = defaultSettings.antiSignalCap
    settings.mixedScriptWeight = defaultSettings.mixedScriptWeight
    settings.mixedScriptEnabled = defaultSettings.mixedScriptEnabled
    changed = true

    local chars = DB.db.sv and DB.db.sv.char
    if type(chars) == "table" then
      for _, char in pairs(chars) do
        local history = type(char) == "table" and char.history
        if type(history) == "table" then
          for _, record in pairs(history) do
            if type(record) == "table" and record.cleansed ~= nil then
              record.cleansed = nil
            end
          end
        end
      end
    end
  end

  -- Last: it is the flag that makes the steps above run, so a failure partway
  -- through leaves it set and the next login retries.
  if settings.devMode ~= nil then
    settings.devMode = nil
    changed = true
  end
  return changed
end

-- Returns the live table, or a disposable {} if the saved value is malformed.
function DB.GetChooserSeen()
  local global = DB.GetGlobal()
  local seen = global and global.chooserSeen
  return type(seen) == "table" and seen or {}
end

function DB.MarkChooserSeen(key)
  local global = DB.GetGlobal()
  if not global or not UsableString(key) then
    return false
  end
  global.chooserSeen = type(global.chooserSeen) == "table" and global.chooserSeen or {}
  global.chooserSeen[key] = true
  return true
end

function DB.Log(message)
  Print(message)
end

function DB.DevLog(message)
  DevLog(message)
end

local function CoerceBlockedActor(guid, raw)
  local entry = {
    guid = guid,
    name = UsableString(raw.name) and raw.name or nil,
    realm = UsableString(raw.realm) and raw.realm or nil,
    firstBlockedAt = tonumber(raw.firstBlockedAt) or 0,
    lastBlockedAt = tonumber(raw.lastBlockedAt) or 0,
    count = tonumber(raw.count) or 0,
    manual = raw.manual == true,
    manualBlockedAt = tonumber(raw.manualBlockedAt) or nil,
    surfaces = {},
    categories = {},
  }
  if type(raw.surfaces) == "table" then
    for key, value in pairs(raw.surfaces) do entry.surfaces[key] = tonumber(value) or 0 end
  end
  if type(raw.categories) == "table" then
    for key, value in pairs(raw.categories) do entry.categories[key] = tonumber(value) or 0 end
  end
  return entry
end

local function MergeCountMap(a, b, useMax)
  local out = {}
  for key, value in pairs(a) do out[key] = value end
  for key, value in pairs(b) do
    out[key] = useMax and math.max(out[key] or 0, value) or (out[key] or 0) + value
  end
  return out
end

-- A hand-block on either side stays a hand-block. Its time comes from the
-- manual side; when both are manual, the earlier real time wins.
local function MergedManualBlockedAt(sift, legacy)
  if legacy.manual and not sift.manual then
    return legacy.manualBlockedAt
  end
  if sift.manual and legacy.manual then
    local siftAt, legacyAt = sift.manualBlockedAt or 0, legacy.manualBlockedAt or 0
    if legacyAt > 0 and (siftAt <= 0 or legacyAt < siftAt) then
      return legacy.manualBlockedAt
    end
  end
  return sift.manualBlockedAt
end

-- Merges a Sift entry and a legacy entry for the same guid. An equal, positive
-- firstBlockedAt means both count the same original block, so counts take the
-- max; two missing (0) stamps are not a match and still sum.
local function MergeBlockedActorCollision(guid, sift, legacy)
  local sameOrigin = sift.firstBlockedAt == legacy.firstBlockedAt and sift.firstBlockedAt > 0
  local merged = {
    guid = guid,
    firstBlockedAt = math.min(sift.firstBlockedAt, legacy.firstBlockedAt),
    lastBlockedAt = math.max(sift.lastBlockedAt, legacy.lastBlockedAt),
    manual = (sift.manual == true) or (legacy.manual == true),
    manualBlockedAt = MergedManualBlockedAt(sift, legacy),
  }
  if sameOrigin then
    merged.count = math.max(sift.count, legacy.count)
    merged.surfaces = MergeCountMap(sift.surfaces, legacy.surfaces, true)
    merged.categories = MergeCountMap(sift.categories, legacy.categories, true)
  else
    merged.count = sift.count + legacy.count
    merged.surfaces = MergeCountMap(sift.surfaces, legacy.surfaces, false)
    merged.categories = MergeCountMap(sift.categories, legacy.categories, false)
  end
  -- Newer side names the entry (a tie keeps Sift's); an unusable name/realm
  -- falls back to the other side.
  local newer, older = sift, legacy
  if legacy.lastBlockedAt > sift.lastBlockedAt then
    newer, older = legacy, sift
  end
  merged.name = UsableString(newer.name) and newer.name or older.name
  merged.realm = UsableString(newer.realm) and newer.realm or older.realm
  return merged
end

local function DeepEqual(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for key, value in pairs(a) do
    if not DeepEqual(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

-- A missing schema stamp means the older layout (it dropped the stamp when it
-- equalled the default). Only nil and 3 are released legacy layouts, so only they
-- import settings and characters; any other stamp brings the lists over and nothing else.
local function LegacyStampAccepted(stamp)
  return stamp == nil or stamp == 3
end

-- Caller guarantees a still-default profile. Only keys present in the current
-- defaults are read (one level into the three subtrees), so retired keys never
-- come back.
local function OverlaySettings(defaultSettings, legacySettings)
  local out = DeepCopy(defaultSettings)
  for key, defaultValue in pairs(defaultSettings) do
    if type(defaultValue) == "table" and (key == "enabledCategories" or key == "surfaces" or key == "throttle") then
      local legacySubtree = legacySettings[key]
      if type(legacySubtree) == "table" then
        for innerKey in pairs(defaultValue) do
          if legacySubtree[innerKey] ~= nil then
            out[key][innerKey] = legacySubtree[innerKey]
          end
        end
        -- A legacy store with no Carrying key inherits its Boosting state instead of
        -- Carrying's default.
        if key == "enabledCategories" and legacySubtree.Carrying == nil and legacySubtree.Boosting ~= nil then
          out[key].Carrying = legacySubtree.Boosting
        end
      end
    elseif legacySettings[key] ~= nil then
      out[key] = legacySettings[key]
    end
  end
  return out
end

-- Empty means no history and zero detections and blocks, whether the fields are
-- absent (Foundry strips default values from a slot at logout) or zero (the
-- current character, which RepairShape has already backfilled).
local function IsEmptyCharSlot(char)
  if type(char) ~= "table" then return true end
  local history = char.history
  if type(history) == "table" and #history > 0 then return false end
  local stats = char.stats
  local detections = tonumber(stats and stats.detections) or 0
  local blocked = tonumber(stats and stats.blocked) or 0
  return detections == 0 and blocked == 0
end

-- Merges the legacy BawrSpam store into the Sift store, once. Pure (no NS, no
-- WoW API) so tests can run it, and never mutates legacySV. Build only reads and
-- copies; Commit is plain assignment that cannot raise, so a failed import
-- leaves siftSV untouched.
function DB.MergeLegacyStore(siftSV, legacySV, now)
  if type(siftSV) ~= "table" or type(siftSV.global) ~= "table" then
    return nil, "no Sift store"
  end
  if siftSV.global.legacyImport ~= nil then
    return nil, "already imported"
  end
  if type(legacySV) ~= "table" or type(legacySV.global) ~= "table" then
    return nil, "no legacy data"
  end

  -- ---- Build: read-only against both stores; writes only into fresh
  -- working tables below. Nothing above this comment, or below it up to the
  -- Commit marker, may touch siftSV or legacySV.
  local allowToAdd, allowCount = {}, 0
  for guid, raw in pairs(legacySV.global.allowlist or {}) do
    if type(guid) == "string" and type(raw) == "table" and siftSV.global.allowlist[guid] == nil then
      local blocked = siftSV.global.blockedActors[guid]
      if not (type(blocked) == "table" and blocked.manual == true) then
        allowToAdd[guid] = DeepCopy(raw)
        allowCount = allowCount + 1
      end
    end
  end

  local actorAdds, actorUpdates = {}, {}
  local actorCount, collidedCount = 0, 0
  for guid, raw in pairs(legacySV.global.blockedActors or {}) do
    if type(guid) == "string" and type(raw) == "table" then
      local legacyEntry = CoerceBlockedActor(guid, raw)
      local existing = siftSV.global.blockedActors[guid]
      if type(existing) == "table" then
        actorUpdates[guid] = MergeBlockedActorCollision(guid, CoerceBlockedActor(guid, existing), legacyEntry)
        collidedCount = collidedCount + 1
      else
        actorAdds[guid] = legacyEntry
      end
      actorCount = actorCount + 1
    end
  end

  -- Cap the union once, by age, the same way the running per-block eviction
  -- elsewhere in this file does -- manual entries are never dropped.
  local evict = {}
  local unionSize = CountTable(siftSV.global.blockedActors) + CountTable(actorAdds)
  if unionSize > BLOCKED_ACTOR_CAP then
    local candidates = {}
    for guid, entry in pairs(siftSV.global.blockedActors) do
      local updated = actorUpdates[guid]
      local manual = updated and updated.manual or (type(entry) == "table" and entry.manual == true)
      if not manual then
        local lastBlockedAt = updated and updated.lastBlockedAt or (tonumber(entry.lastBlockedAt) or 0)
        candidates[#candidates + 1] = { guid = guid, lastBlockedAt = lastBlockedAt }
      end
    end
    for guid, entry in pairs(actorAdds) do
      if not entry.manual then
        candidates[#candidates + 1] = { guid = guid, lastBlockedAt = entry.lastBlockedAt }
      end
    end
    table.sort(candidates, function(a, b) return a.lastBlockedAt < b.lastBlockedAt end)
    local toDrop = unionSize - BLOCKED_ACTOR_CAP
    for i = 1, math.min(toDrop, #candidates) do
      evict[candidates[i].guid] = true
    end
  end

  local settingsImported, newSettings = false, nil
  if LegacyStampAccepted(legacySV.global.schemaVersion) and type(legacySV.global.settings) == "table"
     and DeepEqual(siftSV.global.settings, CopyDefaults(defaults.global.settings)) then
    newSettings = OverlaySettings(defaults.global.settings, legacySV.global.settings)
    settingsImported = true
  end

  local charAdoptions, charCount = {}, 0
  if LegacyStampAccepted(legacySV.global.schemaVersion) and type(legacySV.char) == "table" then
    for charKey, legacyChar in pairs(legacySV.char) do
      if type(charKey) == "string" and type(legacyChar) == "table"
         and IsEmptyCharSlot(siftSV.char and siftSV.char[charKey]) then
        charAdoptions[charKey] = {
          history = DeepCopy(type(legacyChar.history) == "table" and legacyChar.history or {}),
          historyCursor = tonumber(legacyChar.historyCursor) or 0,
          stats = DeepCopy(type(legacyChar.stats) == "table" and legacyChar.stats or {}),
        }
        charCount = charCount + 1
      end
    end
  end

  -- ---- Commit: plain assignment only; nothing from here on can raise.
  for guid, entry in pairs(allowToAdd) do
    siftSV.global.allowlist[guid] = entry
  end
  for guid, entry in pairs(actorAdds) do
    if not evict[guid] then
      siftSV.global.blockedActors[guid] = entry
    end
  end
  for guid, entry in pairs(actorUpdates) do
    siftSV.global.blockedActors[guid] = entry
  end
  for guid in pairs(evict) do
    if actorAdds[guid] == nil then
      siftSV.global.blockedActors[guid] = nil
    end
  end
  TouchBlockedRevision()
  if settingsImported then
    for key, value in pairs(newSettings) do
      siftSV.global.settings[key] = value
    end
  end
  siftSV.char = siftSV.char or {}
  for charKey, adopt in pairs(charAdoptions) do
    local target = siftSV.char[charKey]
    if type(target) ~= "table" then
      target = {}
      siftSV.char[charKey] = target
    end
    target.history = adopt.history
    target.historyCursor = adopt.historyCursor
    target.stats = adopt.stats
  end

  local summary = {
    at = now,
    allow = allowCount,
    actors = actorCount,
    collided = collidedCount,
    settings = settingsImported,
    chars = charCount,
  }
  siftSV.global.legacyImport = summary
  return summary
end

-- Runs once at login, before the scanner installs. Does not pcall itself:
-- the caller wraps this call together with its own follow-up refresh in one
-- local pcall, so a raise here still lets the rest of login proceed.
function DB.ImportLegacyData()
  if not DB.db or not DB.db.global then
    return nil
  end
  if DB.db.global.legacyImport ~= nil then
    return nil
  end
  local legacy = _G[SV_LEGACY_NAME]
  if type(legacy) ~= "table" then
    return nil
  end

  -- The raw SV table, not DB.db: the merge needs every character's slot.
  local summary = DB.MergeLegacyStore(_G[SV_NAME], legacy, Now())
  if summary then
    RepairShape(DB.db.global, DB.db.char)
    Print(NS.L["brought back %d allowed players and %d blocked senders from BawrSpam"]:format(
      summary.allow, summary.actors
    ))
  end
  return summary
end

NS.DB = DB
return DB
