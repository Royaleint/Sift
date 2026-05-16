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

  initialized = true
end

local function InstallScanner()
  if not initialized or not NS.ChatScanner or not NS.ChatScanner.Install then
    return
  end

  NS.ChatScanner.Install()
end

local function ToggleHistory()
  if NS.HistoryPanel and NS.HistoryPanel.Toggle then
    NS.HistoryPanel.Toggle()
  else
    Print("history panel is unavailable.")
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

local function SlashHandler(msg)
  msg = msg or ""
  local command, rest = string.match(msg, "^(%S*)%s*(.-)%s*$")
  command = string.lower(command or "")

  if command == "" or command == "history" then
    ToggleHistory()
  elseif command == "test" then
    RunSyntheticTest(rest)
  else
    Print("usage: /bawrspam | /bawrspam history")
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
