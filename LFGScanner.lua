local _, NS = ...
local LFGScanner = {}

local LFG_EVENTS = {
  "LFG_LIST_SEARCH_RESULTS_RECEIVED",
  "LFG_LIST_SEARCH_RESULT_UPDATED",
  "LFG_LIST_APPLICANT_LIST_UPDATED",
  "LFG_LIST_APPLICANT_UPDATED",
}

local eventFrame = nil
local enabled = false
local renderHooksInstalled = false
local renderHideEnabled = false
local renderSweepFrame = nil
local renderSweepElapsed = 0

local RENDER_SWEEP_INTERVAL = 0.2
local IGNORED_BREAKDOWN_KEYS = {
  MixedScript = true,
  BlockedActor = true,
}

local function DevLog(message)
  if NS.DB and NS.DB.DevLog then
    NS.DB.DevLog(message)
  end
end

local function ServerTime()
  if type(GetServerTime) == "function" then
    return GetServerTime()
  end
  return time()
end

local function GetSettings()
  return NS.DB and NS.DB.GetSettings and NS.DB.GetSettings() or {}
end

local function BuildScoringOptions(settings)
  return {
    threshold = settings.threshold,
    enabledCategories = settings.enabledCategories,
    mixedScriptWeight = settings.mixedScriptEnabled == false and 0 or settings.mixedScriptWeight,
    antiSignalCap = settings.antiSignalCap,
    patterns = NS.Patterns,
  }
end

local function DominantCategory(breakdown)
  if type(breakdown) ~= "table" then
    return nil
  end

  local bestCat, bestVal
  for cat, val in pairs(breakdown) do
    local numeric = tonumber(val) or 0
    if not IGNORED_BREAKDOWN_KEYS[cat] and numeric > 0
       and (not bestVal or numeric > bestVal) then
      bestCat, bestVal = cat, numeric
    end
  end
  return bestCat
end

local function ResolveOutcome(surface, score)
  local surfaceState = (NS.PauseState and NS.PauseState.GetSurface and NS.PauseState.GetSurface(surface)) or "active"
  if surfaceState == "off" then
    return nil
  end

  local outcome = surfaceState == "paused" and "pass-thru" or "blocked"
  local dominantCategory = DominantCategory(score and score.breakdown)
  if dominantCategory then
    local categoryState = (NS.PauseState and NS.PauseState.GetCategory and NS.PauseState.GetCategory(dominantCategory)) or "active"
    if categoryState == "off" then
      return nil
    end
    if categoryState == "paused" then
      outcome = "pass-thru"
    end
  end

  return outcome
end

local function ShouldScanSurface(surface)
  local surfaceState = (NS.PauseState and NS.PauseState.GetSurface and NS.PauseState.GetSurface(surface)) or "active"
  return surfaceState ~= "off"
end

local function IsSecret(value)
  return type(issecretvalue) == "function" and issecretvalue(value) == true
end

local function GetElementData(row)
  if row and type(row.GetElementData) == "function" then
    return row:GetElementData()
  end
  return nil
end

local function ResolveSearchResultID(row)
  if not row then
    return nil
  end

  if row.resultID ~= nil then
    return row.resultID
  end

  local elementData = GetElementData(row)
  return elementData and elementData.resultID or nil
end

local function ResolveApplicantID(row)
  if not row then
    return nil
  end

  if row.applicantID ~= nil then
    return row.applicantID
  end

  local elementData = GetElementData(row)
  return elementData and elementData.id or nil
end

local function SetRowShown(row, shouldShow)
  if not row then
    return
  end

  if shouldShow then
    if type(row.Show) == "function" then
      row:Show()
    end
  elseif type(row.Hide) == "function" then
    row:Hide()
  end
end

local function RefreshSearchRow(row)
  local searchResultID = ResolveSearchResultID(row)
  local blocked = searchResultID ~= nil
    and NS.Suppression
    and NS.Suppression.IsLFGSearchResultBlocked
    and NS.Suppression.IsLFGSearchResultBlocked(searchResultID)
  SetRowShown(row, blocked ~= true)
end

local function RefreshApplicantRow(row)
  local applicantID = ResolveApplicantID(row)
  local blocked = applicantID ~= nil
    and NS.Suppression
    and NS.Suppression.IsLFGApplicantBlocked
    and NS.Suppression.IsLFGApplicantBlocked(applicantID)
  SetRowShown(row, blocked ~= true)
end

local function ForEachScrollBoxFrame(scrollBox, handler)
  if not scrollBox or type(scrollBox.ForEachFrame) ~= "function" then
    return
  end

  scrollBox:ForEachFrame(handler)
end

local function GetLFGListFrame()
  return _G and _G.LFGListFrame or nil
end

local function SweepVisibleRows()
  local lfgListFrame = GetLFGListFrame()
  if not lfgListFrame then
    return
  end

  local searchPanel = lfgListFrame.SearchPanel
  local searchScrollBox = searchPanel and searchPanel.ScrollBox
  if searchScrollBox and (type(searchScrollBox.IsShown) ~= "function" or searchScrollBox:IsShown()) then
    ForEachScrollBoxFrame(searchScrollBox, RefreshSearchRow)
  end

  local applicationViewer = lfgListFrame.ApplicationViewer
  local applicantScrollBox = applicationViewer and applicationViewer.ScrollBox
  if applicantScrollBox and (type(applicantScrollBox.IsShown) ~= "function" or applicantScrollBox:IsShown()) then
    ForEachScrollBoxFrame(applicantScrollBox, RefreshApplicantRow)
  end
end

local function InstallRenderHooks()
  if renderHooksInstalled then
    return
  end

  if type(hooksecurefunc) == "function" then
    pcall(hooksecurefunc, "LFGListSearchPanel_InitButton", function(button)
      RefreshSearchRow(button)
    end)
    pcall(hooksecurefunc, "LFGListSearchEntry_Update", function(row)
      RefreshSearchRow(row)
    end)
    pcall(hooksecurefunc, "LFGListApplicationViewer_InitButton", function(button)
      RefreshApplicantRow(button)
    end)
    pcall(hooksecurefunc, "LFGListApplicationViewer_UpdateApplicant", function(row)
      RefreshApplicantRow(row)
    end)
  end

  renderHooksInstalled = true
end

local function RenderSweepOnUpdate(_self, elapsed)
  if not renderHideEnabled then
    return
  end

  renderSweepElapsed = renderSweepElapsed + (tonumber(elapsed) or 0)
  if renderSweepElapsed < RENDER_SWEEP_INTERVAL then
    return
  end

  renderSweepElapsed = 0
  SweepVisibleRows()
end

local function EnsureRenderSweepFrame()
  if type(CreateFrame) ~= "function" then
    return nil
  end

  if not renderSweepFrame then
    renderSweepFrame = CreateFrame("Frame")
  end

  renderSweepFrame:SetScript("OnUpdate", RenderSweepOnUpdate)
  return renderSweepFrame
end

local function SetRenderHideEnabled(shouldEnable)
  renderHideEnabled = shouldEnable == true
  if renderHideEnabled then
    InstallRenderHooks()
    EnsureRenderSweepFrame()
  elseif renderSweepFrame then
    renderSweepFrame:SetScript("OnUpdate", nil)
    renderSweepElapsed = 0
  end
  SweepVisibleRows()
end

local function TextOrEmpty(value)
  if type(value) == "string" then
    return value
  end
  return ""
end

local function HasTrustedListingMember(info)
  return info.hasSelf == true
    or (tonumber(info.numBNetFriends) or 0) > 0
    or (tonumber(info.numCharFriends) or 0) > 0
    or (tonumber(info.numGuildMates) or 0) > 0
end

local function AppendBlockedHistory(record, transientID, kind, displayName)
  local entryID = NS.History and NS.History.Append and NS.History.Append(record)
  if not entryID then
    return
  end

  if kind == "lfg-search" then
    if record.outcome == "blocked" and NS.Suppression and NS.Suppression.MarkLFGSearchResult then
      NS.Suppression.MarkLFGSearchResult(transientID)
    end
    if NS.ReportFlow and NS.ReportFlow.QueueLFGAdvertisementReport then
      NS.ReportFlow.QueueLFGAdvertisementReport(entryID, transientID, displayName)
    end
  elseif kind == "lfg-applicant" then
    if record.outcome == "blocked" and NS.Suppression and NS.Suppression.MarkLFGApplicant then
      NS.Suppression.MarkLFGApplicant(transientID)
    end
    if NS.ReportFlow and NS.ReportFlow.QueueLFGApplicantReport then
      NS.ReportFlow.QueueLFGApplicantReport(entryID, transientID, displayName)
    end
  end
end

local function BuildHistoryRecord(surface, original, analysis, settings, score, transientKey, transientID, displayKey, displayName, outcome)
  local record = {
    ts = ServerTime(),
    surface = surface,
    outcome = outcome or "blocked",
    reason = "score",
    original = original,
    score = score.score,
    threshold = score.threshold,
    breakdown = score.breakdown,
    containsItemLinks = analysis.signals and analysis.signals.containsItemLinks == true,
  }

  record[transientKey] = transientID
  if displayKey and displayName then
    record[displayKey] = displayName
  end

  if settings.devMode == true then
    record.cleansed = analysis.normalized
  end

  return record
end

local function ScoreText(text)
  local analysis = NS.Cleanse and NS.Cleanse.Analyze and NS.Cleanse.Analyze(text)
  if not analysis then
    return nil, nil, nil
  end

  local settings = GetSettings()
  local score = NS.Scoring and NS.Scoring.Score and NS.Scoring.Score(analysis, BuildScoringOptions(settings))
  if not score or not score.blocked then
    return nil, nil, nil
  end

  return analysis, settings, score
end

local function ScanSearchResult(searchResultID)
  if not ShouldScanSurface("lfg-search") then
    return
  end

  if not C_LFGList or type(C_LFGList.HasSearchResultInfo) ~= "function"
      or type(C_LFGList.GetSearchResultInfo) ~= "function" then
    return
  end

  if not C_LFGList.HasSearchResultInfo(searchResultID) then
    return
  end

  local info = C_LFGList.GetSearchResultInfo(searchResultID)
  if not info or info.isDelisted then
    return
  end

  if IsSecret(info.name) or IsSecret(info.comment) or IsSecret(info.voiceChat) then
    return
  end

  if HasTrustedListingMember(info) then
    return
  end

  local name = TextOrEmpty(info.name)
  local corpus = name .. " " .. TextOrEmpty(info.comment) .. " " .. TextOrEmpty(info.voiceChat)
  if corpus == "  " then
    return
  end

  local analysis, settings, score = ScoreText(corpus)
  if not analysis then
    return
  end
  local outcome = ResolveOutcome("lfg-search", score)
  if not outcome then
    return
  end

  local record = BuildHistoryRecord(
    "lfg-search",
    corpus,
    analysis,
    settings,
    score,
    "searchResultID",
    searchResultID,
    "listingName",
    name ~= "" and name or nil,
    outcome
  )
  AppendBlockedHistory(record, searchResultID, "lfg-search", record.listingName)
end

local function GetApplicantInfo(applicantID)
  if not C_LFGList or type(C_LFGList.GetApplicantInfo) ~= "function" then
    return nil
  end

  local first, _, _, _, _, comment = C_LFGList.GetApplicantInfo(applicantID)
  if type(first) == "table" then
    return first
  end

  return {
    applicantID = first,
    comment = comment,
  }
end

local function GetApplicantDisplayName(applicantID)
  if not C_LFGList or type(C_LFGList.GetApplicantMemberInfo) ~= "function" then
    return nil
  end

  local first = C_LFGList.GetApplicantMemberInfo(applicantID, 1)
  if IsSecret(first) then
    return nil
  end
  if type(first) == "table" then
    if IsSecret(first.name) then
      return nil
    end
    return TextOrEmpty(first.name)
  end
  return TextOrEmpty(first)
end

local function ScanApplicant(applicantID)
  if not ShouldScanSurface("lfg-applicant") then
    return
  end

  local info = GetApplicantInfo(applicantID)
  if not info or IsSecret(info.comment) then
    return
  end

  local comment = TextOrEmpty(info.comment)
  if comment == "" then
    return
  end

  local analysis, settings, score = ScoreText(comment)
  if not analysis then
    return
  end
  local outcome = ResolveOutcome("lfg-applicant", score)
  if not outcome then
    return
  end

  local memberName = GetApplicantDisplayName(applicantID)
  if memberName == "" then
    memberName = nil
  end

  local record = BuildHistoryRecord(
    "lfg-applicant",
    comment,
    analysis,
    settings,
    score,
    "applicantID",
    applicantID,
    "memberName",
    memberName,
    outcome
  )
  AppendBlockedHistory(record, applicantID, "lfg-applicant", memberName)
end

local function ErrorHandler(err)
  if NS.DB and NS.DB.IsDevMode and NS.DB.IsDevMode() then
    print("[BawrSpam] LFGScanner xpcall: " .. tostring(err))
  end
  return err
end

local function SafeScan(fn, ...)
  local args = { ... }
  local ok = xpcall(function()
    fn(unpack(args))
  end, ErrorHandler)
  return ok
end

local function ScanAllSearchResults()
  if not C_LFGList or type(C_LFGList.GetSearchResults) ~= "function" then
    return
  end

  local _, results = C_LFGList.GetSearchResults()
  if type(results) ~= "table" then
    return
  end

  for i = 1, #results do
    SafeScan(ScanSearchResult, results[i])
  end
end

local function ScanAllApplicants()
  if not C_LFGList or type(C_LFGList.GetApplicants) ~= "function" then
    return
  end

  local applicants = C_LFGList.GetApplicants()
  if type(applicants) ~= "table" then
    return
  end

  for i = 1, #applicants do
    SafeScan(ScanApplicant, applicants[i])
  end
end

local function OnEvent(_self, event, ...)
  if not enabled then
    return
  end

  if event == "LFG_LIST_SEARCH_RESULTS_RECEIVED" then
    SafeScan(ScanAllSearchResults)
  elseif event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
    local searchResultID = ...
    SafeScan(ScanSearchResult, searchResultID)
  elseif event == "LFG_LIST_APPLICANT_LIST_UPDATED" then
    SafeScan(ScanAllApplicants)
  elseif event == "LFG_LIST_APPLICANT_UPDATED" then
    local applicantID = ...
    SafeScan(ScanApplicant, applicantID)
  end
end

local function EnsureFrame()
  if eventFrame then
    return eventFrame
  end

  if type(CreateFrame) ~= "function" then
    return nil
  end

  eventFrame = CreateFrame("Frame")
  eventFrame:SetScript("OnEvent", OnEvent)
  return eventFrame
end

local function ClearTransientLFG()
  if NS.Suppression and NS.Suppression.ClearLFG then
    NS.Suppression.ClearLFG()
  elseif NS.Suppression and NS.Suppression.SweepLFG then
    NS.Suppression.SweepLFG()
  end
  if NS.ReportFlow and NS.ReportFlow.ClearTransientLFG then
    NS.ReportFlow.ClearTransientLFG()
  end
end

function LFGScanner.SetEnabled(shouldEnable)
  shouldEnable = shouldEnable == true

  if shouldEnable then
    if NS.Compat and NS.Compat.isClassicFamily and not NS.Compat.hasLFGRenderHide then
      DevLog("LFG scanner disabled on Classic until render-hide is verified.")
      enabled = false
      ClearTransientLFG()
      SetRenderHideEnabled(false)
      return false
    end

    local frame = EnsureFrame()
    if not frame then
      DevLog("LFG scanner frame API unavailable; scanner not enabled.")
      enabled = false
      return false
    end

    for i = 1, #LFG_EVENTS do
      frame:RegisterEvent(LFG_EVENTS[i])
    end
    enabled = true
    SetRenderHideEnabled(true)
    return true
  end

  enabled = false
  if eventFrame then
    for i = 1, #LFG_EVENTS do
      eventFrame:UnregisterEvent(LFG_EVENTS[i])
    end
  end
  ClearTransientLFG()
  SetRenderHideEnabled(false)
  return true
end

function LFGScanner.RefreshEnabled()
  local settings = GetSettings()
  return LFGScanner.SetEnabled(settings.lfgScanEnabled ~= false)
end

function LFGScanner.RefreshVisibleRows()
  SweepVisibleRows()
end

function LFGScanner._ResolveOutcomeForTest(surface, score)
  return ResolveOutcome(surface, score)
end

function LFGScanner._ShouldScanSurfaceForTest(surface)
  return ShouldScanSurface(surface)
end

NS.LFGScanner = LFGScanner
return LFGScanner
