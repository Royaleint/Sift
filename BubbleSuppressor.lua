local _, NS = ...
local BubbleSuppressor = {}

local disabledBubbles = false
local previousChatBubbles = nil
local cleanupFrame = nil

local function SetChatBubbles(value)
  if C_CVar and type(C_CVar.SetCVar) == "function" then
    return pcall(C_CVar.SetCVar, "chatBubbles", value)
  end
  return false
end

function BubbleSuppressor.MaybeRestore()
  if not disabledBubbles then
    return false
  end

  if SetChatBubbles(previousChatBubbles and "1" or "0") then
    disabledBubbles = false
    previousChatBubbles = nil
    return true
  end

  return false
end

function BubbleSuppressor.Engage(event, settings)
  if settings == nil or settings.filterBubbles ~= true then
    return false
  end

  if event ~= "CHAT_MSG_SAY" and event ~= "CHAT_MSG_YELL" then
    return false
  end

  if disabledBubbles then
    return true
  end

  if type(GetCVarBool) ~= "function" then
    return false
  end

  local current = GetCVarBool("chatBubbles") == true
  if not current then
    return false
  end

  if SetChatBubbles("0") then
    previousChatBubbles = current
    disabledBubbles = true
    return true
  end

  return false
end

function BubbleSuppressor.OnLogout()
  return BubbleSuppressor.MaybeRestore()
end

function BubbleSuppressor.RegisterCleanup()
  if cleanupFrame or type(CreateFrame) ~= "function" then
    return cleanupFrame ~= nil
  end

  cleanupFrame = CreateFrame("Frame")
  cleanupFrame:RegisterEvent("CHAT_MSG_MONSTER_SAY")
  cleanupFrame:RegisterEvent("CHAT_MSG_MONSTER_YELL")
  cleanupFrame:RegisterEvent("PLAYER_LOGOUT")
  cleanupFrame:SetScript("OnEvent", function(_self, event)
    if event == "PLAYER_LOGOUT" then
      BubbleSuppressor.OnLogout()
    else
      BubbleSuppressor.MaybeRestore()
    end
  end)

  return true
end

NS.BubbleSuppressor = BubbleSuppressor
return BubbleSuppressor
