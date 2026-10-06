-- Sift/Init.lua
-- Bootstrap: module initialization order, the login-time installers, and the
-- /sift slash command.

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

-- One optional add-on may attach here. Not offered by the released build.
if ADDON_NAME == "Sift_DevBuild" then
  function Sift_RegisterExtension(ext)
    if type(ext) ~= "table" or NS.extension ~= nil then
      return nil
    end
    NS.extension = ext
    return NS, ADDON_NAME
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
	Print(L["stats rebuilt from retained history: %s entries counted. Reload or reopen the History panel to refresh the stats display."]:format(tostring(total)))
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
	if NS.DB and NS.DB.PruneOnLogin then
		pcall(NS.DB.PruneOnLogin, ADDON_NAME == "Sift_DevBuild" or NS.extension ~= nil)
	end
	ImportLegacyDataOnLogin()
	InstallScanner()
	InstallPlayerMenu()
	InstallFirstRunChooser()
end)

SLASH_SIFT1 = "/sift"
SlashCmdList.SIFT = SlashHandler
