local ADDON_NAME, NS = ...
local DB = {}

-- SavedVariables global names, derived per build (SFT-077).
--
-- CROSS-LANGUAGE CONTRACT with the DevBuild TOC generator.
-- That generator writes the DevBuild's TOC and appends its SV_SUFFIX to every
-- declared global ("SiftDB" -> "SiftDB_DevBuild"). The names derived here MUST
-- equal what it emits, or this build declares one global in its TOC and stores
-- its data in another -- an empty store, and writes landing in the OTHER build's
-- global. Nothing in Lua can enforce the agreement, so both sides carry this
-- comment and both sides carry a contract check:
--   Lua  -- a test against this file's derived names
--   Node -- a matching check against the TOC generator's output
-- Change the suffix on one side and the matching check goes red.
--
-- The suffix is taken from the FOLDER name relative to the live addon name, not
-- built from the folder name directly: the generator suffixes the GLOBAL, so
-- "Sift_DevBuild" must yield "SiftDB_DevBuild", NOT "Sift_DevBuildDB".
local LIVE_ADDON_NAME = "Sift"
local BASE_SV_NAME = "SiftDB"
local LEGACY_SV_NAME = "BawrSpamDB"

-- Exposed for the contract test. Pure: no upvalues beyond the constants above.
--
-- Returns (svName, legacySvName) for a recognised folder, or (nil, reason) for
-- anything else. It does NOT fall back to the live names. An earlier draft did,
-- and that was wrong: a folder we do not recognise, silently pointed at the LIVE
-- store, is a build writing into data it does not own -- the same shape of
-- failure BSP-070's C1 test proved destroys SavedVariables. There is no safe
-- guess here, so it refuses instead. The caller raises; this stays pure so the
-- contract test can exercise it outside the client.
function DB.DeriveSVNames(addonName)
  local name = tostring(addonName or "")
  local suffix = name:match("^" .. LIVE_ADDON_NAME .. "(.*)$")
  if not suffix then
    return nil, "addon folder '" .. name .. "' is neither '" .. LIVE_ADDON_NAME
      .. "' nor '" .. LIVE_ADDON_NAME .. "<suffix>'"
  end
  return BASE_SV_NAME .. suffix, LEGACY_SV_NAME .. suffix
end

-- Resolved at file scope but NOT raised here: an error() during file load aborts
-- the rest of this file with no useful context for the player. Initialize raises.
local SV_NAME, SV_LEGACY_NAME = DB.DeriveSVNames(ADDON_NAME)
local SV_NAME_ERROR = (not SV_NAME) and SV_LEGACY_NAME or nil

local CURRENT_SCHEMA_VERSION = 3
local ADDON_VERSION = "1.4.0"
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
    -- BSP-052 / BSP-058: user-authored keyword rules. Arrays so display order is
    -- stable; contents managed entirely by UserRules.lua.
    customBlocks = {},
    allowKeywords = {},
    -- BSP-032: dev-only false-negative capture store. A sibling of `settings`,
    -- not a member of it -- ResetSettings replaces the whole settings subtree,
    -- and the captured corpus candidates must survive a settings reset.
    -- Additive, so no schema bump: absent on existing profiles, backfilled here.
    shadowLog = {},
    -- SFT-099: which first-run chooser rows this player has already decided
    -- (Apply or Keep current settings), keyed by the row's registry key. Only
    -- a value of `true` counts as seen; never a key with any other value, and
    -- never seeded with a key here -- Foundry's applyDefaults backfills a
    -- fresh SavedVariables table by copying this default in wholesale, so a
    -- pre-populated key here would mark that row seen on a fresh install that
    -- never showed the panel.
    chooserSeen = {},
    settings = {
      threshold = 4,
      -- SFT-080: only the user-facing categories are persisted. The retired
      -- ones keep scoring at frozen states declared in PauseState.lua.
      enabledCategories = {
        RMT        = "active",
        Boosting   = "active",
        -- BSP-052: the user's own keyword block list, sharing the
        -- active/paused/off axis. It must be here or SetCategoryState rejects
        -- the toggle -- that setter gate-checks against this table.
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
      -- BSP-039: flood window in seconds. The band is owned by Frequency.lua
      -- and read through GetFloodWindowBounds; this is only the seed value.
      floodWindow = 180,
      filterBubbles = false,
      showMinimapButton = true,
      historyMaxEntries = 300,
      historyGlobalMaxEntries = 1000,
      devMode = false,
      -- BSP-010: confirmed-spam-repeat dedupe. Additive — Foundry.DB backfills
      -- nil slots from defaults on first section access. The module-level
      -- default in Frequency.lua mirrors this value. BSP-029 retired
      -- bufferSize as a setting; the default now lives only in Frequency.
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

-- BSP-061: the premade-group scanning feature was removed. These are the
-- on-disk SavedVariables keys it left behind in existing players' profiles.
-- They must stay byte-identical to the keys originally written or the prune
-- below silently misses them; the prefix is split only so source scans for the
-- removed feature's token stay clean. DefunctSurfaceKeys are pruned from the
-- settings.surfaces subtree; DefunctSettingKeys from settings itself.
local DEFUNCT_KEY_PREFIX = "lf" .. "g"
local DEFUNCT_SURFACE_KEYS = { DEFUNCT_KEY_PREFIX .. "-search", DEFUNCT_KEY_PREFIX .. "-applicant" }
local DEFUNCT_SETTING_KEYS = { DEFUNCT_KEY_PREFIX .. "ScanEnabled" }

-- SFT-080: these categories lost their Config buttons. Their rules still score,
-- at states frozen in PauseState.lua, so nothing about detection changes -- but
-- there is no longer a toggle to reach the stored value, which makes it dead
-- weight in every existing profile. Pruned from settings.enabledCategories the
-- same way BSP-061's surface keys are pruned below.
local DEFUNCT_CATEGORY_KEYS = { "Casino", "Phishing", "Commercial", "Anti" }

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
  message = "|cff33ff99Sift|r " .. tostring(message)
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
          .. "(%d per-char excess, %d global). Open /sift config > "
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

-- CopyDefaults is a plain recursive table copy; the legacy-data merge below
-- reuses it under a name that reads correctly for copying arbitrary data,
-- not only the defaults table.
local DeepCopy = CopyDefaults

local function ClampNumber(value, minValue, maxValue, fallback)
  value = tonumber(value) or fallback
  if value < minValue then value = minValue end
  if value > maxValue then value = maxValue end
  return value
end

-- BSP-039: Frequency owns the flood-window band, so read it from there rather
-- than repeating the numbers here. Frequency loads before this ever runs (TOC
-- order, and every caller is post-init). If it somehow has not, return the
-- default rather than an unclamped number — without the bounds there is no way
-- to tell whether a supplied value is inside the band.
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

-- BSP-037: entries the user blocked by hand are exempt from eviction. Dropping
-- one would silently undo an explicit choice the user has no way to notice.
-- Returns whether anything was removed, so a caller trimming to the cap can
-- stop once only manual entries remain rather than looping forever.
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
  -- SFT-080: drop the states of categories that no longer have a button.
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
  -- BSP-061: prune stale premade-group surface states left in existing
  -- SavedVariables (see DEFUNCT_SURFACE_KEYS).
  for _, key in ipairs(DEFUNCT_SURFACE_KEYS) do
    settings.surfaces[key] = nil
  end
  -- BSP-010: repair the throttle subtree. Junk values clamp back to safe
  -- defaults; missing fields backfill.
  settings.throttle = type(settings.throttle) == "table" and settings.throttle or {}
  settings.throttle.enabled = settings.throttle.enabled ~= false
  -- BSP-029: the buffer size is no longer user-configurable (the flood window
  -- is the single timing knob). Prune the key existing SavedVariables still
  -- carry — the matching default is gone, so nothing backfills it again.
  settings.throttle.bufferSize = nil
end

local function RepairShape(global, char)
  global.schemaVersion = tonumber(global.schemaVersion) or CURRENT_SCHEMA_VERSION
  global.allowlist = global.allowlist or {}
  global.blockedActors = global.blockedActors or {}
  -- BSP-052 / BSP-058: keyword rule stores. A malformed entry here would be
  -- matched against every scanned line, so drop anything without a usable
  -- cleansed form rather than carrying it.
  global.customBlocks = type(global.customBlocks) == "table" and global.customBlocks or {}
  global.allowKeywords = type(global.allowKeywords) == "table" and global.allowKeywords or {}
  if NS.UserRules and NS.UserRules.RepairStore then
    local dropped = NS.UserRules.RepairStore(global.customBlocks)
      + NS.UserRules.RepairStore(global.allowKeywords)
    if dropped > 0 then
      DevLog("Dropped " .. dropped .. " malformed keyword rule(s).")
    end
  end
  global.shadowLog = global.shadowLog or {}
  -- SFT-099: type-checked, not just presence-checked, like customBlocks above
  -- -- a second line of defense lives in DB.GetChooserSeen too, but this is
  -- what actually fixes a junk value in the saved store.
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
    if migration then
      migration(db)
    end
    db.global.schemaVersion = nextVersion
  end
end

function DB.Initialize()
  -- Unrecognised folder name: refuse loudly rather than guess a store. Guessing
  -- means writing into SavedVariables this build does not own, and BSP-070's C1
  -- test showed that loss is unrecoverable. Raised here, not at file scope, so
  -- the message reaches the player instead of aborting the file's remaining
  -- definitions.
  if SV_NAME_ERROR then
    error("Sift: " .. SV_NAME_ERROR
      .. ". Refusing to load saved data rather than risk writing into another build's store."
      .. " Supported folder names are '" .. LIVE_ADDON_NAME .. "' (the released build) and '"
      .. LIVE_ADDON_NAME .. "_DevBuild' (the generated dev build). Rename the folder to one of those.")
  end

  local F = _G.Foundry_1_0
  if not (F and F:HasModule("DB")) then
    NS._InitFailed = true
    Print("could not initialize: Foundry.DB is missing.")
    return false
  end

  -- Both identity arguments derive from the TOC vararg (SFT-077): `name` so a
  -- renamed folder still passes Foundry's IsAddOnLoaded gate, `sv` so the store
  -- matches the global this build's TOC actually declares.
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

-- BSP-037: block an actor by explicit user action rather than by detection.
-- Shares the blockedActors key space with the scanner so both surfaces resolve
-- to one entry and one undo path (Config > Blocked). `count` is left alone
-- here: it counts messages actually suppressed, and blocking someone has not
-- suppressed one yet. Every message the block goes on to catch increments it
-- through RecordBlockedActor, exactly like a scanner block. Returns false when
-- the actor is already manually blocked, so a repeat click is a no-op.
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
  entry.name = UsableString(name) and name or entry.name
  entry.realm = UsableString(realm) and realm or entry.realm
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
  -- BSP-050 (extends BSP-049): reset can lower both historyMaxEntries and the
  -- new historyGlobalMaxEntries back to defaults, and the records live in
  -- char.history for every character, not just the current one. Trim across
  -- all chars immediately so the caps the user just reset to are authoritative
  -- account-wide, not enforced piecemeal as each alt next logs in.
  if NS.History and NS.History.TrimAllCharacters then
    NS.History.TrimAllCharacters()
  end
  -- BSP-039: same reasoning as the trim above — a reset value is authoritative
  -- immediately, not at next login. Without this the slider snaps back to 180
  -- while the runtime keeps scanning on whatever window was set before.
  if NS.Frequency and NS.Frequency.SetFloodWindow then
    NS.Frequency.SetFloodWindow(global.settings.floodWindow)
  end
  return global.settings
end

function DB.IsDevMode()
  local settings = DB.GetSettings()
  return settings and settings.devMode == true
end

-- SFT-099: second line of defense alongside RepairShape's chooserSeen backfill
-- -- returns the live table when it's already well-shaped, or a disposable
-- {} otherwise rather than handing a caller a non-table to index into.
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

-- Merges the legacy BawrSpam store into an already-populated Sift store,
-- once. Pure: no NS and no WoW API, so it is exercised outside the client. It
-- never mutates legacySV. Two phases: Build reads both stores (siftSV only to
-- detect collisions) and deep-copies whatever it needs into fresh working
-- tables; Commit is then plain assignment with nothing left that can raise.
-- A raise during Build therefore leaves siftSV untouched -- a failed import
-- assigns nothing.
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

-- One collision between an existing Sift entry and a legacy entry for the
-- same guid. Equal-and-positive firstBlockedAt means both sides are counting
-- the same original block, so counts take the max instead of summing; the
-- "greater than zero" guard keeps two entries that are both simply missing
-- firstBlockedAt (coerced to 0 above) on the sum branch instead.
local function MergeBlockedActorCollision(guid, sift, legacy)
  local sameOrigin = sift.firstBlockedAt == legacy.firstBlockedAt and sift.firstBlockedAt > 0
  local merged = {
    guid = guid,
    firstBlockedAt = math.min(sift.firstBlockedAt, legacy.firstBlockedAt),
    lastBlockedAt = math.max(sift.lastBlockedAt, legacy.lastBlockedAt),
    manual = sift.manual,
    manualBlockedAt = sift.manualBlockedAt,
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
  -- The most recently active side names the entry; a tie keeps Sift's own
  -- name/realm, matching every other tie in this merge favouring Sift. If
  -- that side's own name or realm is unusable, the other side's value is
  -- used instead of losing it -- the same "or entry.name" fallback
  -- DB.RecordBlockedActor uses when only one side has a real value.
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

-- Legacy settings only ever overlay onto a still-default profile (the caller
-- already checked that), and even then only one level into the three subtree
-- settings. A retired category or throttle key that no longer exists in the
-- current defaults is simply never read here, so it never comes back.
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
      end
    elseif legacySettings[key] ~= nil then
      out[key] = legacySettings[key]
    end
  end
  return out
end

-- A slot with no history and nothing detected or blocked yet counts as
-- empty whether those fields are simply absent (a sparse alt Foundry never
-- wrote defaults into) or present at zero (the character currently logging
-- in, whose slot RepairShape already backfilled before this ever runs).
local function IsEmptyCharSlot(char)
  if type(char) ~= "table" then return true end
  local history = char.history
  if type(history) == "table" and #history > 0 then return false end
  local stats = char.stats
  local detections = tonumber(stats and stats.detections) or 0
  local blocked = tonumber(stats and stats.blocked) or 0
  return detections == 0 and blocked == 0
end

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
  if legacySV.global.schemaVersion == 3 and type(legacySV.global.settings) == "table"
     and DeepEqual(siftSV.global.settings, CopyDefaults(defaults.global.settings)) then
    newSettings = OverlaySettings(defaults.global.settings, legacySV.global.settings)
    settingsImported = true
  end

  local charAdoptions, charCount = {}, 0
  if legacySV.global.schemaVersion == 3 and type(legacySV.char) == "table" then
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

  local summary = DB.MergeLegacyStore(_G[SV_NAME], legacy, Now())
  if summary then
    RepairShape(DB.db.global, DB.db.char)
    Print(string.format(
      "brought back %d allowed players and %d blocked senders from BawrSpam",
      summary.allow, summary.actors
    ))
  end
  return summary
end

NS.DB = DB
return DB
