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

  initialized = true
end

local function InstallScanner()
  if not initialized or not NS.ChatScanner or not NS.ChatScanner.Install then
    return
  end

  NS.ChatScanner.Install()
end

local function FormatHistoryLine(record)
  local sender = record.name or "(unknown)"
  if record.realm then
    sender = sender .. "-" .. record.realm
  end

  return string.format(
    "#%s [%s] %s score %s/%s: %s",
    tostring(record.id or "?"),
    tostring(record.channel or record.surface or "?"),
    sender,
    tostring(record.score or "?"),
    tostring(record.threshold or "?"),
    tostring(record.original or "")
  )
end

local function PrintHistory(limit)
  if not NS.History or not NS.History.GetRecent then
    Print("history is unavailable.")
    return
  end

  local records = NS.History.GetRecent(limit)
  if #records == 0 then
    Print("history is empty.")
    return
  end

  Print("recent blocked messages:")
  for i = 1, #records do
    Print(FormatHistoryLine(records[i]))
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

  if command == "history" then
    PrintHistory(tonumber(rest))
  elseif command == "test" then
    RunSyntheticTest(rest)
  elseif command == "" then
    PrintHistory(10)
  else
    Print("usage: /bawrspam history [count]")
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
