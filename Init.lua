-- Sift/Init.lua
-- Bootstrap: module initialization order, the login-time installers, and the
-- /sift and /bdev slash commands.

local ADDON_NAME, NS = ...

-- Foundry-1.0 loads before this file (embedded, or standalone via OptionalDeps).
-- A nil F means Foundry failed to load; fail loud here rather than with an
-- opaque nil-index at the Lifecycle bootstrap below.
local F = _G.Foundry_1_0
if not F then
  error("Sift requires Foundry-1.0. Please install or enable it.")
end

local L = NS.L

local initialized = false

local function Print(message)
  message = "|cff33ff99Sift|r " .. tostring(message)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(message)
  else
    print(message)
  end
end

local function Initialize()
  if initialized then
    return
  end

  if not NS.DB or not NS.DB.Initialize or not NS.DB.Initialize() then
    return
  end

  -- Enforces the per-character and account-wide history caps across every
  -- character on each load; per-append trimming never reaches other alts.
  if NS.History and NS.History.TrimAllCharacters then
    NS.History.TrimAllCharacters()
  end

  -- The same for the shadow log: Capture only evicts one entry at a time.
  if NS.ShadowLog and NS.ShadowLog.TrimToCap then
    NS.ShadowLog.TrimToCap()
  end

  -- Repeat counting is always on; settings.throttle.enabled is intentionally
  -- not read.
  local settings = NS.DB.GetSettings()
  -- Pushed before the first chat event, which would otherwise use the default.
  if settings and NS.Frequency and NS.Frequency.SetFloodWindow then
    NS.Frequency.SetFloodWindow(settings.floodWindow)
  end

  if NS.Patterns and NS.Patterns.LoadOnInit then
    local loaded = NS.Patterns:LoadOnInit()
    if loaded == false and NS.DB and NS.DB.DevLog then
      NS.DB.DevLog("PatternData missing; detection will return zero hits.")
    end
  end

  if NS.Trust and NS.Trust.Initialize then
    NS.Trust.Initialize()
  end

	if NS.HistoryPanel and NS.HistoryPanel.Initialize then
		NS.HistoryPanel.Initialize()
	end

	if NS.ConfigPanel and NS.ConfigPanel.Initialize then
		NS.ConfigPanel.Initialize()
	end

  if NS.BubbleSuppressor and NS.BubbleSuppressor.RegisterCleanup then
    NS.BubbleSuppressor.RegisterCleanup()
  end

	initialized = true
end

local function InstallScanner()
  if not initialized or not NS.ChatScanner or not NS.ChatScanner.Install then
    return
  end

  NS.ChatScanner.Install()
end

-- Registered at login, not in Initialize(): the Blizzard Menu addon is not
-- guaranteed to be loaded at the addon-loaded hook.
local function InstallPlayerMenu()
  if not initialized or not NS.PlayerMenu or not NS.PlayerMenu.Initialize then
    return
  end

  NS.PlayerMenu.Initialize()
end

-- Registered at login, gated on `initialized` like InstallPlayerMenu above.
local function InstallFirstRunChooser()
  if not initialized or not NS.FirstRunChooser or not NS.FirstRunChooser.OnLogin then
    return
  end

  NS.FirstRunChooser.OnLogin()
end

local function ToggleHistory()
  if NS.HistoryPanel and NS.HistoryPanel.Toggle then
    NS.HistoryPanel.Toggle()
  else
    Print(L["history panel is unavailable."])
	end
end

local function OpenConfig(section)
	if NS.ConfigPanel and NS.ConfigPanel.Open then
		NS.ConfigPanel.Open(section)
	else
		Print(L["config panel is unavailable."])
	end
end

local function RunSyntheticTest(message)
  if not NS.DB or not NS.DB.IsDevMode or not NS.DB.IsDevMode() then
    Print("test command is only available when devMode is enabled.")
    return
  end

  if type(message) ~= "string" or message == "" then
    message = "wts gold cheap"
  end

  local blocked = NS.ChatScanner and NS.ChatScanner.Filter and NS.ChatScanner.Filter(
    "CHAT_MSG_CHANNEL",
    message,
    "TestSpammer-TestRealm",
    nil,
    "Trade",
    nil,
    nil,
    nil,
    2,
    "Trade",
    nil,
    "SiftTestLine",
    "Player-9999-FFFFFFFF"
  )

	Print("synthetic test " .. (blocked and "blocked" or "passed") .. ".")
end

local function NormalizeSender(value)
	if type(value) ~= "string" then
		return nil
	end
	value = string.gsub(value, "^%s+", "")
	value = string.gsub(value, "%s+$", "")
	if value == "" then
		return nil
	end
	return string.lower(value)
end

local function IsRegionalNames()
	return NS.Compat and NS.Compat.RegionalNames and NS.Compat.RegionalNames() or false
end

local function ResolveHistorySender(nameRealm)
	-- A Forever name matches in either separator form, whichever one the
	-- History record was stored with.
	local regional = IsRegionalNames()
	local target = NormalizeSender(regional and NS.Compat.NormalizeFullName(nameRealm) or nameRealm)
	if not target or not NS.History or not NS.History.GetAll then
		return nil
	end

	local records = NS.History.GetAll()
	for i = 1, #records do
		local record = records[i]
		local label = record.name or ""
		if record.realm and record.realm ~= "" then
			label = label .. "-" .. record.realm
		end
		if regional then
			label = NS.Compat.NormalizeFullName(label)
		end
		if NormalizeSender(label) == target and record.guid then
			return record.guid, record.name, record.realm
		end
	end
	return nil
end

local function AllowFromHistory(rest)
	local guid, name, realm = ResolveHistorySender(rest)
	if not guid then
		Print(IsRegionalNames() and L["allow requires a sender from History, by their full name."]
			or L["allow requires a sender from History, formatted as Name-Realm."])
		return
	end

	if not NS.Trust or not NS.Trust.AddAllowlist then
		Print(L["sender is already allowlisted or cannot be allowlisted."])
		return
	end

	local added, clearedManualBlock = NS.Trust.AddAllowlist(guid, name, realm, "manual")
	local unblocked = clearedManualBlock and L[" Your manual block on them was removed."] or ""
	if added then
		Print(L["allowlisted %s."]:format(tostring(name or rest)) .. unblocked)
	else
		Print(L["sender is already allowlisted or cannot be allowlisted."] .. unblocked)
	end
end

local function OpenExport()
	if NS.ConfigPanel and NS.ConfigPanel.OpenExportDialog then
		NS.ConfigPanel.OpenExportDialog()
	else
		OpenConfig("Allowlist")
	end
end

local function OpenImport()
	if NS.ConfigPanel and NS.ConfigPanel.OpenImportDialog then
		NS.ConfigPanel.OpenImportDialog()
	else
		OpenConfig("Allowlist")
	end
end

local function ConfirmClearHistory()
	if NS.ConfigPanel and NS.ConfigPanel.ConfirmClearHistory then
		NS.ConfigPanel.ConfirmClearHistory()
	else
		Print(L["config panel is unavailable."])
	end
end

local function ConfirmClearBlocked()
	if NS.ConfigPanel and NS.ConfigPanel.ConfirmClearBlocked then
		NS.ConfigPanel.ConfirmClearBlocked()
	else
		Print(L["config panel is unavailable."])
	end
end

local function RebuildStats()
	if not NS.History or not NS.History.RebuildByCategory then
		Print(L["rebuild API unavailable."])
		return
	end
	local total = NS.History.RebuildByCategory()
	Print(L["byCategory rebuilt from retained history: %s entries categorized. Reload or reopen History panel to refresh stats display."]:format(tostring(total)))
end

-- /bdev fpx [N]: false-positive export dialog, limited to the last N restored
-- entries. Reads the first token only, so "/bdev fpx 20 extra" still honors 20.
local function ExportFP(rest)
  local firstToken = string.match(rest or "", "^(%S+)")
  local limit = firstToken and tonumber(firstToken) or nil
  if NS.ConfigPanel and NS.ConfigPanel.OpenFPExportDialog then
    NS.ConfigPanel.OpenFPExportDialog(limit)
  else
    Print("FP export unavailable (ConfigPanel not loaded).")
  end
end

-- /bdev hx [N]: export of every History original, deduped and sorted by count,
-- optionally capped to the top N. Read-only.
local function ExportHistory(rest)
  local firstToken = string.match(rest or "", "^(%S+)")
  local limit = firstToken and tonumber(firstToken) or nil
  if NS.ConfigPanel and NS.ConfigPanel.OpenHistoryExportDialog then
    NS.ConfigPanel.OpenHistoryExportDialog(limit)
  else
    Print("history export unavailable (ConfigPanel not loaded).")
  end
end

-- /bdev fnx [N|clear]: export the shadow log of messages the filter let
-- through, optionally capped to the top N; `clear` empties it.
local function ExportFN(rest)
  local firstToken = string.match(rest or "", "^(%S+)")
  if firstToken and string.lower(firstToken) == "clear" then
    local cleared = NS.ShadowLog and NS.ShadowLog.Clear and NS.ShadowLog.Clear() or 0
    Print("shadow log cleared: " .. tostring(cleared) .. " entries removed.")
    return
  end
  local limit = firstToken and tonumber(firstToken) or nil
  if NS.ConfigPanel and NS.ConfigPanel.OpenFNExportDialog then
    NS.ConfigPanel.OpenFNExportDialog(limit)
  else
    Print("FN export unavailable (ConfigPanel not loaded).")
  end
end

-- /bdev perf [label]: one-shot memory, CPU and history-size snapshot, tagged
-- with the optional label. The forced full GC costs a one-frame hitch; it is
-- how retained memory is separated from churn.
local function RunPerf(rest)
  local label = string.match(rest or "", "^(%S+)") or ""

  -- Memory: read after UpdateAddOnMemoryUsage(), force a full GC, then read
  -- again. pre - retained = churn (transient garbage that GC reclaimed).
  UpdateAddOnMemoryUsage()
  local preGC = GetAddOnMemoryUsage(ADDON_NAME) or 0
  collectgarbage("collect")
  UpdateAddOnMemoryUsage()
  local retained = GetAddOnMemoryUsage(ADDON_NAME) or 0
  local churn = preGC - retained
  Print(format(
    "perf %s: mem %d KB pre-GC | %d KB retained | %d KB churn",
    label, preGC, retained, churn
  ))

  -- C_AddOnProfiler is missing on older clients; print a notice instead.
  if C_AddOnProfiler and C_AddOnProfiler.GetAddOnMetric
    and Enum and Enum.AddOnProfilerMetric then
    local M = Enum.AddOnProfilerMetric
    local recent  = C_AddOnProfiler.GetAddOnMetric(ADDON_NAME, M.RecentAverageTime) or 0
    local peak    = C_AddOnProfiler.GetAddOnMetric(ADDON_NAME, M.PeakTime) or 0
    local session = C_AddOnProfiler.GetAddOnMetric(ADDON_NAME, M.SessionAverageTime) or 0
    local over1   = C_AddOnProfiler.GetAddOnMetric(ADDON_NAME, M.CountTimeOver1Ms) or 0
    local over5   = C_AddOnProfiler.GetAddOnMetric(ADDON_NAME, M.CountTimeOver5Ms) or 0
    local over10  = C_AddOnProfiler.GetAddOnMetric(ADDON_NAME, M.CountTimeOver10Ms) or 0
    Print(format(
      "perf %s: ms recent=%.3f peak=%.3f session=%.3f | spikes >1ms=%d >5ms=%d >10ms=%d",
      label, recent, peak, session, over1, over5, over10
    ))
  else
    Print("perf: C_AddOnProfiler unavailable on this client")
  end

  -- History size for this character and across all characters, against the
  -- caps. Prints "?" for anything missing rather than erroring.
  local current, global, perCharCap, globalCap = "?", "?", "?", "?"
  local settings = NS.DB and NS.DB.GetSettings and NS.DB.GetSettings()
  if settings then
    perCharCap = tonumber(settings.historyMaxEntries) or 300
    globalCap  = tonumber(settings.historyGlobalMaxEntries) or 1000
  end
  local charView = NS.DB and NS.DB.GetChar and NS.DB.GetChar()
  if type(charView) == "table" and type(charView.history) == "table" then
    current = #charView.history
  end
  if NS.DB and NS.DB.db and type(NS.DB.db.sv) == "table"
    and type(NS.DB.db.sv.char) == "table" then
    local total = 0
    for _, charData in pairs(NS.DB.db.sv.char) do
      if type(charData) == "table" and type(charData.history) == "table" then
        total = total + #charData.history
      end
    end
    global = total
  end
  Print(format(
    "perf %s: history current=%s global=%s (cap perChar=%s, global=%s)",
    label, tostring(current), tostring(global),
    tostring(perCharCap), tostring(globalCap)
  ))
end

-- /bdev pseudolocale: dev-only i18n smoke check (see PseudoLocale.lua).
local function RunPseudoLocale()
  if not (NS.PseudoLocale and NS.PseudoLocale.Apply) then
    Print(L["pseudo-locale tool is unavailable (locale table not loaded)."])
    return
  end
  local ok, reason = NS.PseudoLocale.Apply()
  if ok then
    Print(L["pseudo-locale applied. Open a Sift panel now; a panel you already opened this session needs /reload, then run this again first."])
  elseif reason == "already-applied" then
    Print(L["pseudo-locale is already active this session. /reload to restore English, then run it again."])
  elseif reason == "devMode" then
    Print(L["the pseudolocale command is only available when devMode is enabled."])
  else
    Print(L["pseudo-locale tool is unavailable (locale table not loaded)."])
  end
end

local COMMANDS = {
	[""] = function() ToggleHistory() end,
	history = function() ToggleHistory() end,
	config = function() OpenConfig("Detection") end,
	options = function() OpenConfig("Detection") end,
	allow = AllowFromHistory,
	export = OpenExport,
	import = OpenImport,
	clearhistory = ConfirmClearHistory,
	clearblocked = ConfirmClearBlocked,
	rebuildstats = RebuildStats,
	-- Transitional hint for the old /sift test command.
	test = function()
		Print("/sift test moved to /bdev test (requires devMode).")
	end,
}

local function PrintUsage()
	Print(L["usage: %s"]:format("/sift [history|config|options|allow|export|import|clearhistory|clearblocked|rebuildstats]"))
end

local function SlashHandler(msg)
	msg = msg or ""
	local command, rest = string.match(msg, "^(%S*)%s*(.-)%s*$")
	command = string.lower(command or "")

	local handler = COMMANDS[command]
	if handler then
		handler(rest)
	else
		PrintUsage()
	end
end

-- /bdev chooser: preview the first-run chooser. Display ignores the seen set,
-- but Apply/Keep still run the real write paths.
local function RunChooserPreview()
  if NS.FirstRunChooser and NS.FirstRunChooser.Show then
    NS.FirstRunChooser.Show(true)
  else
    Print("first-run chooser is unavailable.")
  end
end

-- /bdev <subcommand>: dev-mode commands, gated in BdevSlashHandler; handlers
-- may re-check.
local DEV_COMMANDS = {
	test = RunSyntheticTest,
	fpx  = ExportFP,
	fnx  = ExportFN,
	hx   = ExportHistory,
	perf = RunPerf,
	pseudolocale = RunPseudoLocale,
	chooser = RunChooserPreview,
}

local function PrintDevUsage()
	Print("usage: /bdev [test|fpx [N]|fnx [N|clear]|hx [N]|perf [label]|pseudolocale|chooser]")
end

local function BdevSlashHandler(msg)
	if not NS.DB or not NS.DB.IsDevMode or not NS.DB.IsDevMode() then
		Print("These commands need dev mode. Turn it on in Config \194\187 Dev.")
		return
	end
	msg = msg or ""
	local command, rest = string.match(msg, "^(%S*)%s*(.-)%s*$")
	command = string.lower(command or "")

	if command == "" then
		PrintDevUsage()
		return
	end

	local handler = DEV_COMMANDS[command]
	if handler then
		handler(rest)
	else
		PrintDevUsage()
	end
end

-- Refresh after a BawrSpam data import; runs only on the login the import ran.
local function RefreshAfterLegacyImport(settings)
  if NS.Trust and NS.Trust.RefreshAllowlistFromDB then
    NS.Trust.RefreshAllowlistFromDB()
  end
  if settings then
    -- settings.throttle.enabled is intentionally not read, as in Initialize().
    if NS.Frequency and NS.Frequency.SetFloodWindow then
      NS.Frequency.SetFloodWindow(settings.floodWindow)
    end
    if NS.HistoryPanel and NS.HistoryPanel.SetMinimapShown then
      NS.HistoryPanel.SetMinimapShown(settings.showMinimapButton ~= false)
    end
  end
  if NS.History and NS.History.TrimAllCharacters then
    NS.History.TrimAllCharacters()
  end
end

-- Own pcall, so a failure here cannot skip the installers that follow it in
-- OnLogin. The failure message keys on global.legacyImport (set when the merge
-- commits), not on whether the call returned: a raise after the commit still
-- means the data came back and will not be retried.
local function ImportLegacyDataOnLogin()
  local ok, err = pcall(function()
    local summary = NS.DB and NS.DB.ImportLegacyData and NS.DB.ImportLegacyData()
    if not summary then
      return
    end
    RefreshAfterLegacyImport(NS.DB.GetSettings and NS.DB.GetSettings())
  end)
  if not ok then
    local global = NS.DB and NS.DB.GetGlobal and NS.DB.GetGlobal()
    local imported = global and global.legacyImport ~= nil
    if imported then
      Print(L["brought your BawrSpam data back, but a follow-up step failed. A /reload should finish it."])
    else
      Print(L["could not bring back your BawrSpam data this time. It will try again next login."])
    end
    if NS.DB and NS.DB.DevLog then
      NS.DB.DevLog("legacy import/refresh error: " .. tostring(err))
    end
  end
end

-- Bootstrap via Foundry.Lifecycle. Subscription order is load-bearing:
-- OnAddonLoaded (Initialize) must be registered before OnLogin, because the
-- installers no-op until `initialized` is set and a late load replays both
-- hooks in registration order. No Lifecycle OnLogout; BubbleSuppressor registers
-- its own logout restore.
local controller = F:RequireModule("Lifecycle", 1):New(NS, ADDON_NAME)
controller:OnAddonLoaded(function() Initialize() end)
controller:OnLogin(function()
	ImportLegacyDataOnLogin()
	InstallScanner()
	InstallPlayerMenu()
	InstallFirstRunChooser()
end)

SLASH_SIFT1 = "/sift"
SlashCmdList.SIFT = SlashHandler

SLASH_BDEV1 = "/bdev"
-- Fallback alias in case another addon also claims /bdev.
SLASH_BDEV2 = "/siftdev"
SlashCmdList.BDEV = BdevSlashHandler
