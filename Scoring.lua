-- Sift/Scoring.lua
-- Pure scoring: weighted sum + anti-signal cap + mixed-script meta + dedup.
-- Dual-mode + dependency-injectable Patterns reference.

local Scoring = {}

local _, NS = ...
local _injectedPatterns = nil  -- test-only override; primary path is options.patterns or NS.Patterns
local EMPTY_HITS = {}  -- shared, never mutated: only #hits and hits[i] are read

-- Reused across calls: _ScoreHits runs once per scanned chat message and
-- seenRules is pure dedup scratch -- nothing outside this function ever reads
-- it -- so wiping and refilling one table beats allocating a fresh one.
local seenRules = {}

function Scoring.SetPatternsForTest(p)
  _injectedPatterns = p
end

function Scoring._ScoreHits(hits, analysis, options)
  options = options or {}
  local threshold = options.threshold or 4
  local enabled = options.enabledCategories or {}
  local mixedW = options.mixedScriptWeight or 0
  local cap = options.antiSignalCap or -5

  local breakdown = {}
  for key in pairs(seenRules) do seenRules[key] = nil end
  local antiRaw = 0
  local auditHits = {}
  local hasPositiveContentHit = false

  for i = 1, #hits do
    local h = hits[i]
    if not seenRules[h.ruleId] then
      seenRules[h.ruleId] = true
      auditHits[#auditHits + 1] = h.ruleId
      local categoryState = enabled[h.category]
      if categoryState == true or categoryState == "active" or categoryState == "paused" then
        if h.weight < 0 then
          antiRaw = antiRaw + h.weight
        elseif h.weight > 0 then
          breakdown[h.category] = (breakdown[h.category] or 0) + h.weight
          hasPositiveContentHit = true
        end
      end
    end
  end

  local antiApplied = (antiRaw < cap) and cap or antiRaw

  if hasPositiveContentHit and analysis.signals and analysis.signals.mixedScript and mixedW > 0 then
    breakdown.MixedScript = mixedW
  end

  local total = 0
  for _, v in pairs(breakdown) do total = total + v end
  if antiApplied ~= 0 then
    breakdown.Anti = antiApplied
    total = total + antiApplied
  end

  local result = {
    score = total,
    threshold = threshold,
    blocked = total >= threshold,
    breakdown = breakdown,
    audit = { hits = auditHits },
  }
  if antiRaw ~= antiApplied then
    result.audit.antiSignals = { raw = antiRaw, applied = antiApplied }
  end
  return result
end

-- Public entry. Resolves a Patterns-like object via:
--   1. options.patterns (explicit DI; preferred in tests and ChatScanner caller path)
--   2. _injectedPatterns (Scoring.SetPatternsForTest path)
--   3. NS.Patterns (in-addon default, set by TOC load order)
function Scoring.Score(analysis, options)
  options = options or {}
  local patterns = options.patterns or _injectedPatterns or (NS and NS.Patterns)
  local hits = EMPTY_HITS
  if patterns and patterns.Match then
    hits = patterns:Match(analysis.normalized or "") or EMPTY_HITS
  end
  return Scoring._ScoreHits(hits, analysis or { signals = {} }, options)
end

if NS then NS.Scoring = Scoring end
return Scoring
