local addonName, NS = ...
local Compat = {}

local function Detect(env)
  env = env or _G

  local projectID = env.WOW_PROJECT_ID
  local isRetail = projectID ~= nil and projectID == env.WOW_PROJECT_MAINLINE
  local isClassicEra = projectID ~= nil and projectID == env.WOW_PROJECT_CLASSIC
  local isTBCAnniversary = projectID ~= nil and projectID == env.WOW_PROJECT_BURNING_CRUSADE_CLASSIC
  -- Mists of Pandaria Classic (5.5.x) runs on the modern engine: it ships the
  -- ScrollBox suite, PortraitFrameTemplate, and the modern Settings API, so it
  -- takes the modern UI path and is deliberately NOT folded into isClassicFamily
  -- (which selects the reduced FauxScroll / plain-chrome / color-glyph
  -- fallbacks). Verified in-game on 5.5.x — the modern History panel renders
  -- correctly. (BSP-065)
  local isMistsClassic = projectID ~= nil and projectID == env.WOW_PROJECT_MISTS_CLASSIC
  local isClassicFamily = isClassicEra or isTBCAnniversary
  -- SFT-099: which clients get an opt-in content filter pre-ticked by default.
  -- Deliberately separate from isClassicFamily (which selects UI chrome/glyph
  -- fallbacks, and excludes MoP): this one is a content-defaults question, and
  -- Mists Classic ships the same era-appropriate content MoP's own filters
  -- target, so it belongs here despite staying out of isClassicFamily. WoW
  -- Forever content is not classic content and gets the retail default;
  -- it identifies as WOW_PROJECT_MAINLINE or an ID none of the known
  -- constants match, but that is unverified until the in-game P0 check
  -- (SFT-099 Gate 2) confirms it -- see run_compat_tests.lua's case 99.
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

local runtime = Detect(_G)
for key, value in pairs(runtime) do
  Compat[key] = value
end

if type(NS) == "table" then
  NS.Compat = Compat
end

return Compat
