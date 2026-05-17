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
	test = RunSyntheticTest,
}

local function PrintUsage()
	Print("usage: /bawrspam [history|config|options|allow|export|import|clearhistory|clearblocked|test]")
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
