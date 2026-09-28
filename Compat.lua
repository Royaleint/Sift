-- Sift/Compat.lua
-- Client detection: which WoW flavor is running and which UI paths and content
-- defaults it gets.

local addonName, NS = ...
local Compat = {}

local function Detect(env)
  env = env or _G

  local projectID = env.WOW_PROJECT_ID
  local isRetail = projectID ~= nil and projectID == env.WOW_PROJECT_MAINLINE
  local isClassicEra = projectID ~= nil and projectID == env.WOW_PROJECT_CLASSIC
  local isTBCAnniversary = projectID ~= nil and projectID == env.WOW_PROJECT_BURNING_CRUSADE_CLASSIC
  -- Mists Classic runs the modern UI (ScrollBox, PortraitFrameTemplate, Settings
  -- API), so it is deliberately not in isClassicFamily, which selects the
  -- reduced FauxScroll / plain-chrome / color-glyph fallbacks.
  local isMistsClassic = projectID ~= nil and projectID == env.WOW_PROJECT_MISTS_CLASSIC
  local isClassicFamily = isClassicEra or isTBCAnniversary
  -- Which clients get an opt-in content filter pre-ticked by default. A content
  -- question, deliberately separate from isClassicFamily (UI fallbacks): Mists
  -- Classic belongs here.
  -- WoW Forever should get the retail default; its WOW_PROJECT_ID is unverified
  -- in-game.
  local classicContentDefaults = isClassicEra or isTBCAnniversary or isMistsClassic

  local hasModernHistoryList =
    type(env.CreateScrollBoxListLinearView) == "function"
    and type(env.CreateDataProvider) == "function"
    and type(env.ScrollUtil) == "table"
    and type(env.ScrollUtil.InitScrollBoxListWithScrollBar) == "function"

  local hasClassicHistoryList =
    type(env.FauxScrollFrame_Update) == "function"
    and type(env.FauxScrollFrame_OnVerticalScroll) == "function"
    and type(env.FauxScrollFrame_GetOffset) == "function"

  local hasChatReportDialog =
    type(env.PlayerLocation) == "table"
    and type(env.PlayerLocation.CreateFromChatLineID) == "function"
    and type(env.C_ReportSystem) == "table"
    and type(env.C_ReportSystem.OpenReportPlayerDialog) == "function"
    and env.PLAYER_REPORT_TYPE_SPAM ~= nil

  return {
    addonName = addonName,
    isRetail = isRetail,
    isClassicEra = isClassicEra,
    isTBCAnniversary = isTBCAnniversary,
    isMistsClassic = isMistsClassic,
    isClassicFamily = isClassicFamily,
    classicContentDefaults = classicContentDefaults,
    hasModernHistoryList = hasModernHistoryList,
    hasClassicHistoryList = hasClassicHistoryList,
    hasChatReportDialog = hasChatReportDialog,
  }
end

function Compat.Detect(env)
  return Detect(env)
end

-- WoW Forever names are regionally unique: a character is "First Surname",
-- with no realm. Sift stores that full name in `name` and leaves `realm` nil,
-- the same form Foundry keys the character by.
--
-- Only a true answer is cached: a false one read early in login must not
-- stick, so it is asked again until it turns true. Where the function does
-- not exist this costs a lookup and a type check.
local regionalNames = false

function Compat.RegionalNames()
  if not regionalNames then
    local enabled = rawget(_G, "RegionalUniqueNamesEnabled")
    if type(enabled) == "function" then
      local ok, result = pcall(enabled)
      regionalNames = ok and result == true
    end
  end
  return regionalNames
end

function Compat.FullName(firstName, surname)
  if type(surname) == "string" and surname ~= "" then
    return firstName .. " " .. surname
  end
  return firstName
end

-- Chat and name-only menus hand over the full name as one string. Its
-- separator is not known to be the same on every surface, so accept a hyphen
-- or a space.
function Compat.NormalizeFullName(text)
  if type(text) ~= "string" then
    return nil
  end
  text = string.match(text, "^%s*(.-)%s*$")
  if text == "" then
    return nil
  end
  local firstName, surname = string.match(text, "^([^%s%-]+)[%s%-]+(.+)$")
  if firstName then
    return Compat.FullName(firstName, surname)
  end
  return text
end

local runtime = Detect(_G)
for key, value in pairs(runtime) do
  Compat[key] = value
end

if type(NS) == "table" then
  NS.Compat = Compat
end

return Compat
