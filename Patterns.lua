-- Hush/Patterns.lua
-- Hand-written decoder + Match API. Stable across pattern releases.

local Patterns = {}
local _compiled = {}
local _data = nil

local function _bxor(a, b)
  if bit and bit.bxor then return bit.bxor(a, b) end
  local r, p = 0, 1
  for _ = 1, 32 do
    local aBit, bBit = a % 2, b % 2
    if aBit ~= bBit then r = r + p end
    a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
  end
  return r
end

local function _decode(encoded, entryIndex, seedLow, seedHigh)
  local bytes = {}
  for j = 1, #encoded do
    local b = string.byte(encoded, j)
    -- NOTE: this mask formula MUST match build_patterns.lua's encoder exactly.
    -- A drift here would silently decode all patterns to garbage with no error.
    local mask = (seedLow + j + seedHigh * (entryIndex + 1)) % 256
    bytes[j] = string.char(_bxor(b, mask))
  end
  return table.concat(bytes)
end

function Patterns._InjectDataForTest(data)
  _data = data
  _compiled = {}
end

function Patterns._InjectCompiledForTest(compiled)
  _data = _data or { version = 2 }
  _compiled = compiled
end

function Patterns:LoadOnInit()
  if not _data then return false end
  assert(_data.version == 1 or _data.version == 2,
    "PatternData version mismatch: expected 1 or 2, got " .. tostring(_data.version))
  for i, entry in ipairs(_data.entries) do
    if type(entry.e) == "table" then
      local tokens = {}
      for k = 1, #entry.e do
        tokens[k] = _decode(entry.e[k], i, _data.seedLow, _data.seedHigh)
      end
      _compiled[i] = {
        category = entry.c, weight = entry.w, ruleId = entry.id, tokens = tokens,
      }
    else
      _compiled[i] = {
        category = entry.c, weight = entry.w, ruleId = entry.id,
        pattern  = _decode(entry.e, i, _data.seedLow, _data.seedHigh),
      }
    end
  end
  return true
end

function Patterns:Match(cleansedText)
  local hits = {}
  for i = 1, #_compiled do
    local p = _compiled[i]
    local hit
    if p.tokens then
      hit = true
      for k = 1, #p.tokens do
        if not string.find(cleansedText, p.tokens[k], 1, true) then
          hit = false
          break
        end
      end
    else
      hit = string.find(cleansedText, p.pattern, 1, true) ~= nil
    end
    if hit then
      hits[#hits + 1] = { category = p.category, weight = p.weight, ruleId = p.ruleId }
    end
  end
  return hits
end

local _, NS = ...
if NS then
  NS.Patterns = Patterns
  _data = NS.PatternsData  -- TOC loads PatternData.lua before this file
end
return Patterns
