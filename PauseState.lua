local _, NS = ...
local PauseState = {}

local VALID_STATES = { active = true, paused = true, off = true }
local SURFACE_KEYS = { "chat", "whisper", "bn-whisper", "lfg-search", "lfg-applicant" }
local CATEGORY_KEYS = { "RMT", "Boosting", "Casino", "Phishing", "Commercial", "Anti" }
local CYCLE_FORWARD = { active = "paused", paused = "off", off = "active" }
local CYCLE_BACKWARD = { active = "off", off = "paused", paused = "active" }

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

NS.PauseState = PauseState
return PauseState
