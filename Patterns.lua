-- Sift/Patterns.lua
-- Hand-written decoder + Match API. Stable across pattern releases.

local Patterns = {}
local _compiled = {}
local _data = nil
local _hasOrdered = false

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
  _hasOrdered = false
end

function Patterns._InjectCompiledForTest(compiled)
  _data = _data or { version = 2 }
  _compiled = compiled
  _hasOrdered = false
  for i = 1, #compiled do
    if compiled[i].mode == "ordered" then _hasOrdered = true; break end
  end
end

function Patterns:LoadOnInit()
  if not _data then return false end
  _hasOrdered = false
  assert(_data.version == 1 or _data.version == 2 or _data.version == 3,
    "PatternData version mismatch: expected 1, 2, or 3, got " .. tostring(_data.version))
  for i, entry in ipairs(_data.entries) do
    local ordered = entry.m ~= nil or entry.x ~= nil
    if ordered then
      _hasOrdered = true
      assert(_data.version == 3 and entry.m == "ordered" and type(entry.x) == "number"
        and entry.x > 0 and entry.x < math.huge and entry.x == math.floor(entry.x) and type(entry.e) == "table"
        and #entry.e >= 2, "PatternData ordered rule metadata is invalid")
    end
    if type(entry.e) == "table" then
      local tokens = {}
      for k = 1, #entry.e do
        tokens[k] = _decode(entry.e[k], i, _data.seedLow, _data.seedHigh)
      end
      _compiled[i] = {
        category = entry.c, weight = entry.w, ruleId = entry.id, tokens = tokens,
        mode = entry.m, window = entry.x,
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

local function orderedMatch(text, tokens, window)
  local firstStart = 1
  while true do
    firstStart = string.find(text, tokens[1], firstStart, true)
    if not firstStart then return false end
    local lastEnd = firstStart + #tokens[1] - 1
    local matched = true
    for k = 2, #tokens do
      local nextStart = string.find(text, tokens[k], lastEnd + 1, true)
      if not nextStart then
        return false
      end
      lastEnd = nextStart + #tokens[k] - 1
      if lastEnd - firstStart + 1 > window then
        matched = false
        break
      end
    end
    if matched and lastEnd - firstStart + 1 <= window then return true end
    firstStart = firstStart + 1
  end
end

function Patterns:Match(cleansedText)
  local hits = {}
  if not _hasOrdered then
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
  for i = 1, #_compiled do
    local p = _compiled[i]
    local hit
    if p.tokens then
      if p.mode == "ordered" then
        hit = orderedMatch(cleansedText, p.tokens, p.window)
      else
        hit = true
        for k = 1, #p.tokens do
          if not string.find(cleansedText, p.tokens[k], 1, true) then
            hit = false
            break
          end
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
