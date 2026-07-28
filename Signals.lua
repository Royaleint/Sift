-- Sift/Signals.lua
-- SFT-079: the capture-only signal inventory. Shared with SFT-081 -- one
-- inventory, no second copy.
--
-- Sift's coverage of non-English spam is built almost entirely out of
-- vocabulary, so every new language, and every new spelling within a language,
-- is a fresh round of corpus work. Nothing generalises. These are the two cheap
-- signals that do, and their only consumer is the shadow log:
--
--   * the structural script-mix shape -- a mostly-CJK message carrying an
--     embedded Latin run, which is what an off-platform contact handle looks
--     like dropped into an otherwise non-Latin advert. Measured in Cleanse's
--     existing codepoint walk as analysis.signals.scriptIsland.
--   * contact-channel tokens -- the off-platform handles an advert needs in
--     order to convert.
--
-- Structural first, tokens second, deliberately. Round 29 (SFT-075) showed
-- vocabulary coverage has to be re-cut every time a seller changes spelling,
-- while a shape survives respelling. The token list is the supporting half and
-- is expected to go stale; the shape is not.
--
-- THE HARD CONSTRAINT: neither signal ever fires on language alone. Evaluate
-- returns nothing unless the message also carries an existing sell signal -- a
-- positive content-category hit from the corpus. A message being in another
-- language is not evidence of spam, and a layer that drifted toward treating it
-- as such would be wrong. The rule lives in an early return here, not in a
-- weight someone can retune.
--
-- Nothing in this file can block a message. The shadow log is a capture store:
-- these tags mark what a human then reads. That is also why a plaintext token
-- list is safe in a public repo -- knowing what gets captured tells nobody how
-- to avoid being blocked. Promoting any of these to a blocking signal means
-- moving it into the encoded corpus first (CLAUDE.md critical rule 2).

local _, NS = ...
local Signals = {}

Signals.SCRIPT_ISLAND = "script-island"
Signals.CONTACT_TOKEN = "contact-token"

-- Hand-maintained, and matched against Cleanse's normalized text -- so every
-- entry must already BE cleansed output (lower case, symbols gone, repeated
-- letters collapsed). run_signals_tests asserts that fixed point for each one,
-- which is what stops a plausible-looking entry that can never match.
--
-- Nothing shorter than three characters: run-length collapse turns a doubled
-- two-letter handle into a single letter, which would match most of chat.
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

-- Meta breakdown keys: they describe the sender, the shape of the message, or a
-- decision already taken about it. None says anything is being sold, so none is
-- a sell signal. Mirrors HistoryPanel.lua's IGNORED_BREAKDOWN_KEYS, which is the
-- canonical set.
--
-- Listed by name, and that matters more here than in the other copies of this
-- set, because this one fails OPEN. A meta key nobody adds here is not merely
-- miscategorised: it reads as evidence of selling, and lets both capture signals
-- fire on a message carrying none. Adding a meta key anywhere means adding it
-- here too.
local IGNORED_BREAKDOWN_KEYS = {
  MixedScript = true,
  BlockedActor = true,
  Flood = true,
  Throttle = true,
  ManualBlock = true,
  -- Anti is deliberately absent: anti-signal weight is negative, so it cannot
  -- satisfy the "> 0" test below by itself. That is an invariant of the scorer,
  -- not of this table -- if anti-signals ever went positive, it needs a line.
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

-- Private: Evaluate is the only supported way in, so the sell-signal gate cannot
-- be stepped around by a caller reaching for a bare signal test.
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
-- Structural tag first. The sell-signal gate is the first line on purpose.
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

-- Dual-mode export. MUST be the final statement so a standalone dofile gets the
-- table as the chunk return AND the TOC load attaches it to NS.Signals.
if NS then NS.Signals = Signals end
return Signals
