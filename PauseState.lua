-- Sift/PauseState.lua
-- Category and surface pause states (active / paused / off), the category
-- taxonomy, and the listeners notified when a state changes.
-- Also loaded outside the game by the pattern build: keep file scope free of WoW API and NS lookups.

local _, NS = ...
local PauseState = {}

local VALID_STATES = { active = true, paused = true, off = true }
local SURFACE_KEYS = { "chat", "whisper", "bn-whisper" }

-- The single declaration of the category taxonomy; other files read these
-- lists rather than keeping their own copies.
--
-- CATEGORY_KEYS are the categories a user can toggle. "Custom" is the user's
-- own keyword list, not a corpus category, and must not be retired: it has no
-- frozen state to fall back on. "Carrying" is paid raid, Mythic+ and dungeon
-- runs; "Boosting" is powerleveling and related services.
--
-- RETIRED_CATEGORY_STATES are still scored but have no button. Their states are
-- frozen at their shipped defaults; Commercial must stay "paused", since
-- "active" would start blocking messages that pass through today.
local CATEGORY_KEYS = { "RMT", "Boosting", "Carrying", "Custom" }
local RETIRED_CATEGORY_STATES = {
  Casino     = "active",
  Phishing   = "active",
  Commercial = "paused",
  Anti       = "paused",
}

local CYCLE_FORWARD = { active = "paused", paused = "off", off = "active" }
local CYCLE_BACKWARD = { active = "off", off = "paused", paused = "active" }

-- Reused on the per-message path instead of allocating a table per message.
local effectiveCategories = {}

local listeners = {}

local function GetSettings()
  return NS.DB and NS.DB.GetSettings and NS.DB.GetSettings()
end

function PauseState.GetSurface(key)
  local settings = GetSettings()
  if not settings or not settings.surfaces then return "active" end
  return settings.surfaces[key] or "active"
end

function PauseState.GetCategory(key)
  local retired = RETIRED_CATEGORY_STATES[key]
  if retired then return retired end
  local settings = GetSettings()
  if not settings or not settings.enabledCategories then return "active" end
  return settings.enabledCategories[key] or "active"
end

function PauseState.SetSurface(key, state)
  if not VALID_STATES[state] then return end
  if NS.DB and NS.DB.SetSurfaceState then
    NS.DB.SetSurfaceState(key, state)
  end
  PauseState._Notify("surface", key, state)
end

function PauseState.SetCategory(key, state)
  if not VALID_STATES[state] then return end
  -- Retired categories have no persisted state to write and no button to
  -- reach this from; a caller trying anyway is a bug, not a user action.
  if RETIRED_CATEGORY_STATES[key] then return end
  if NS.DB and NS.DB.SetCategoryState then
    NS.DB.SetCategoryState(key, state)
  end
  PauseState._Notify("category", key, state)
end

function PauseState.CycleSurface(key, direction)
  local current = PauseState.GetSurface(key)
  local nextState = (direction == "backward" and CYCLE_BACKWARD or CYCLE_FORWARD)[current]
  PauseState.SetSurface(key, nextState)
end

function PauseState.CycleCategory(key, direction)
  local current = PauseState.GetCategory(key)
  local nextState = (direction == "backward" and CYCLE_BACKWARD or CYCLE_FORWARD)[current]
  PauseState.SetCategory(key, nextState)
end

function PauseState.RegisterListener(callback)
  if type(callback) ~= "function" then return end
  listeners[#listeners + 1] = callback
end

function PauseState._Notify(axis, key, state)
  for i = 1, #listeners do
    -- Per-listener errors are swallowed; never let one listener break others.
    pcall(listeners[i], axis, key, state)
  end
end

function PauseState.GetSurfaceKeys() return SURFACE_KEYS end
function PauseState.GetCategoryKeys() return CATEGORY_KEYS end
function PauseState.GetRetiredCategoryStates() return RETIRED_CATEGORY_STATES end

-- The category-state table Scoring gates on. The frozen retired states are
-- merged over the persisted ones: a retired key missing from SavedVariables
-- would otherwise read as nil and its rules (Anti included) would stop counting.
function PauseState.GetEffectiveCategoryStates()
  for key in pairs(effectiveCategories) do effectiveCategories[key] = nil end
  local settings = GetSettings()
  local persisted = settings and settings.enabledCategories
  if type(persisted) == "table" then
    for key, state in pairs(persisted) do effectiveCategories[key] = state end
  end
  for key, state in pairs(RETIRED_CATEGORY_STATES) do effectiveCategories[key] = state end
  return effectiveCategories
end

NS.PauseState = PauseState
return PauseState
