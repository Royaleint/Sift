-- Sift/Signals.lua
-- Capture-only signals for the shadow log: the script-island shape (a mostly
-- CJK message carrying an embedded Latin run) and contact-channel tokens.
-- Nothing in this file can block a message; do not add a blocking path here.
--
-- Neither signal fires on language alone: Evaluate returns nothing unless the
-- message also carries a sell signal. Keep that rule an early return, not a
-- weight.

local _, NS = ...
local Signals = {}

Signals.SCRIPT_ISLAND = "script-island"
Signals.CONTACT_TOKEN = "contact-token"

-- Matched against Cleanse's normalized text, so every entry must already be
-- cleansed output (lower case, no symbols, repeats collapsed). Nothing shorter
-- than three characters: run-length collapse would make it match most of chat.
local CONTACT_TOKENS = {
  "discord",
  "telegram",
  "whatsap",
  "wechat",
  "weixin",
  "kakao",
  "snapchat",
  "skype",
  "viber",
}

-- Meta breakdown keys, none of which is a sell signal. Copies in ChatScanner,
-- History, HistoryPanel, ShadowLog, Signals, ConfigPanel: keep all six in step.
-- This copy fails open: a meta key missing here reads as a sell signal.
local IGNORED_BREAKDOWN_KEYS = {
  MixedScript = true,
  BlockedActor = true,
  Flood = true,
  Throttle = true,
  ManualBlock = true,
  -- Anti is absent on purpose: its weight is negative, so it never passes "> 0".
}

-- True when the corpus scored a real content category on this message.
function Signals.HasSellSignal(breakdown)
  if type(breakdown) ~= "table" then
    return false
  end
  for category, value in pairs(breakdown) do
    if not IGNORED_BREAKDOWN_KEYS[category] and (tonumber(value) or 0) > 0 then
      return true
    end
  end
  return false
end

-- Private: callers go through Evaluate so the sell-signal gate always applies.
function Signals._HasContactToken(normalized)
  if type(normalized) ~= "string" then
    return false
  end
  for i = 1, #CONTACT_TOKENS do
    if string.find(normalized, CONTACT_TOKENS[i], 1, true) then
      return true
    end
  end
  return false
end

-- Returns an array of tag names present on this message, or nil for none.
-- The sell-signal gate must stay the first line.
function Signals.Evaluate(analysis, score)
  if not Signals.HasSellSignal(score and score.breakdown) then
    return nil
  end

  local tags
  if analysis and analysis.signals and analysis.signals.scriptIsland then
    tags = { Signals.SCRIPT_ISLAND }
  end
  if Signals._HasContactToken(analysis and analysis.normalized) then
    tags = tags or {}
    tags[#tags + 1] = Signals.CONTACT_TOKEN
  end
  return tags
end

-- Inspection accessor (tests). Copy, so a caller cannot edit the live list.
function Signals._Tokens()
  local copy = {}
  for i = 1, #CONTACT_TOKENS do
    copy[i] = CONTACT_TOKENS[i]
  end
  return copy
end

-- Dual-mode export: must stay the final statement (dofile return + NS attach).
if NS then NS.Signals = Signals end
return Signals
