local ADDON_NAME, NS = ...

local initialized = false

local function Print(message)
  message = "|cff33ff99BawrSpam|r " .. tostring(message)
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

  -- BSP-010: push SavedVariables throttle settings into the runtime module
  -- so the first chat event uses the persisted values, not Throttle.lua's
  -- module-local defaults. DB.Initialize's RepairSettings pass guarantees
  -- settings.throttle is well-shaped by the time we read it here.
  local throttleSettings = NS.DB.GetSettings()
  if throttleSettings and throttleSettings.throttle and NS.Throttle then
    if NS.Throttle.SetEnabled then
      NS.Throttle.SetEnabled(throttleSettings.throttle.enabled)
    end
    if NS.Throttle.SetBufferSize then
      NS.Throttle.SetBufferSize(throttleSettings.throttle.bufferSize)
    end
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
  if NS.LFGScanner and NS.LFGScanner.RefreshEnabled then
    NS.LFGScanner.RefreshEnabled()
  end
end

local function ToggleHistory()
  if NS.HistoryPanel and NS.HistoryPanel.Toggle then
    NS.HistoryPanel.Toggle()
  else
    Print("history panel is unavailable.")
	end
end

local function OpenConfig(section)
	if NS.ConfigPanel and NS.ConfigPanel.Open then
		NS.ConfigPanel.Open(section)
	else
		Print("config panel is unavailable.")
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
    "BawrSpamTestLine",
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

local function ResolveHistorySender(nameRealm)
	local target = NormalizeSender(nameRealm)
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
		if NormalizeSender(label) == target and record.guid then
			return record.guid, record.name, record.realm
		end
	end
	return nil
end

local function AllowFromHistory(rest)
	local guid, name, realm = ResolveHistorySender(rest)
	if not guid then
		Print("allow requires a sender from History, formatted as Name-Realm.")
		return
	end

	if NS.Trust and NS.Trust.AddAllowlist and NS.Trust.AddAllowlist(guid, name, realm, "manual") then
		Print("allowlisted " .. tostring(name or rest) .. ".")
	else
		Print("sender is already allowlisted or cannot be allowlisted.")
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
		Print("config panel is unavailable.")
	end
end

local function ConfirmClearBlocked()
	if NS.ConfigPanel and NS.ConfigPanel.ConfirmClearBlocked then
		NS.ConfigPanel.ConfirmClearBlocked()
	else
		Print("config panel is unavailable.")
	end
end

local function RebuildStats()
	if not NS.History or not NS.History.RebuildByCategory then
		Print("rebuild API unavailable.")
		return
	end
	local total = NS.History.RebuildByCategory()
	Print("byCategory rebuilt from retained history: " .. tostring(total) .. " entries categorized. Reload or reopen History panel to refresh stats display.")
end

-- BSP-018: /bdev fpx — invoke FP-export dialog. Numeric arg limits to last N
-- restored History entries. devMode gate handled by BdevSlashHandler below.
-- BSP-018 polish (post-Argus): extract first whitespace-delimited token via
-- string.match so "/bdev fpx 20 garbage" honors the 20 instead of silently
-- dropping the limit (tonumber on the full rest string would return nil).
local function ExportFP(rest)
  local firstToken = string.match(rest or "", "^(%S+)")
  local limit = firstToken and tonumber(firstToken) or nil
  if NS.ConfigPanel and NS.ConfigPanel.OpenFPExportDialog then
    NS.ConfigPanel.OpenFPExportDialog(limit)
  else
    Print("FP export unavailable (ConfigPanel not loaded).")
  end
end

-- BSP-048: /bdev perf [label] — one-shot performance snapshot for the
-- perf-optimization pass. Prints two lines: memory (pre-GC / retained / churn)
-- and CPU (recent/peak/session avg ms + spike counts). devMode gate handled by
-- BdevSlashHandler below. Pure diagnostic — no filtering/behavior change.
-- The optional <label> (the rest arg, e.g. "/bdev perf trade") tags the four
-- sample moments Rawb captures during a profiling run.
-- NOTE: collectgarbage("collect") forces a full GC, which costs a one-frame
-- hitch. That's acceptable for a manual dev read — it's how we separate retained
-- memory from churn (transient garbage reclaimed by the collection).
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

  -- CPU: C_AddOnProfiler is newer client API — guard its existence (and the
  -- Enum table) so older/edge clients print a notice instead of erroring.
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
	-- BSP-018 polish (post-Argus): transitional discoverability hint after
	-- /bawrspam test → /bdev test migration. Remove this entry in a future
	-- cleanup once muscle memory has migrated; for now it's a one-line aid
	-- so a stale habit doesn't fall through to a generic usage line.
	test = function()
		Print("/bawrspam test moved to /bdev test (requires devMode).")
	end,
}

local function PrintUsage()
	Print("usage: /bawrspam [history|config|options|allow|export|import|clearhistory|clearblocked|rebuildstats]")
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

-- BSP-018: /bdev <subcommand> — namespace for devMode-gated commands.
-- Universal gate at the dispatcher level; individual handlers may still
-- defense-in-depth check IsDevMode() (e.g. RunSyntheticTest does).
local DEV_COMMANDS = {
	test = RunSyntheticTest,
	fpx  = ExportFP,
	perf = RunPerf,
}

local function PrintDevUsage()
	Print("usage: /bdev [test|fpx [N]|perf [label]]")
end

local function BdevSlashHandler(msg)
	if not NS.DB or not NS.DB.IsDevMode or not NS.DB.IsDevMode() then
		Print("/bdev commands require devMode. Enable in Config \194\187 Dev.")
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

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_self, event, ...)
  if event == "ADDON_LOADED" then
    local addonName = ...
    if addonName == ADDON_NAME then
      Initialize()
    end
  elseif event == "PLAYER_LOGIN" then
    InstallScanner()
    if C_Timer and C_Timer.After then
      C_Timer.After(1, InstallScanner)
    end
  end
end)

SLASH_BAWRSPAM1 = "/bawrspam"
SlashCmdList.BAWRSPAM = SlashHandler

SLASH_BDEV1 = "/bdev"
-- BSP-018 polish (post-Argus): defensive fallback alias against silent
-- collision if another addon registers /bdev — last-loader-wins in
-- SlashCmdList. /bawrspamdev is verbose enough to be effectively unique.
SLASH_BDEV2 = "/bawrspamdev"
SlashCmdList.BDEV = BdevSlashHandler
