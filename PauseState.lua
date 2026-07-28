local _, NS = ...
local PauseState = {}

local VALID_STATES = { active = true, paused = true, off = true }
local SURFACE_KEYS = { "chat", "whisper", "bn-whisper" }

-- SFT-080: this file is the single declaration of the category taxonomy.
-- ConfigPanel, HistoryPanel, and the corpus build tool read these lists rather
-- than keeping their own copies; four hand-maintained copies existed before and
-- nothing enforced their agreement.
--
-- CATEGORY_KEYS are the categories a user can toggle. RETIRED_CATEGORY_STATES
-- are categories the corpus still scores but that no longer earn a button: each
-- had two corpus rules and no recorded traffic, and Anti is a negative-weight
-- scoring meta-signal rather than a kind of spam anyone would choose to allow.
-- Their states are frozen at the values that shipped as defaults, so scoring and
-- the block/pass-thru gate behave exactly as they did while the buttons existed.
-- Commercial is frozen "paused", not "active", because paused is what it shipped
-- as: freezing it active would start blocking messages that pass through today.
-- BSP-052: "Custom" is the user's own keyword block list, not a corpus category.
-- It earns a button so the list can be paused without deleting it, and it is
-- deliberately NOT retired -- it has no frozen state to fall back on.
local CATEGORY_KEYS = { "RMT", "Boosting", "Custom" }
local RETIRED_CATEGORY_STATES = {
  Casino     = "active",
  Phishing   = "active",
  Commercial = "paused",
  Anti       = "paused",
}

local CYCLE_FORWARD = { active = "paused", paused = "off", off = "active" }
local CYCLE_BACKWARD = { active = "off", off = "paused", paused = "active" }

-- Reused across calls: GetEffectiveCategoryStates runs once per scanned chat
-- message, and a fresh table per message is garbage the scanner need not make.
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

-- The category-state table Scoring gates on. Scoring reads the persisted
-- settings table directly, so a retired key pruned from SavedVariables would
-- read as nil there and its rules would silently stop counting -- including the
-- negative-weight Anti rules. Merging the frozen states over the persisted ones
-- keeps every corpus rule scoring exactly as it does today.
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
