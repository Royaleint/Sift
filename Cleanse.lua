-- Sift/Cleanse.lua
-- 9-stage text normalization pipeline. Pure Lua, dual-mode (addon TOC + build tool dofile).
-- Zero WoW API references — runs identically in both contexts.

local Cleanse = {}

-- UTF-8 codepoint scanner. Decodes one codepoint at a time and applies transformFn(cp) → cp|nil.
-- nil return drops the codepoint. Returns the re-encoded string.
function Cleanse._ScanCodepoints(text, transformFn)
  if type(text) ~= "string" or text == "" then return text or "" end

  local out = {}
  local i, n = 1, #text
  local function isContinuation(byte)
    return byte and byte >= 0x80 and byte <= 0xBF
  end

  while i <= n do
    local b1 = string.byte(text, i)
    local cp, width
    if b1 < 0x80 then
      cp, width = b1, 1
    elseif b1 < 0xC0 then
      cp, width = 0xFFFD, 1  -- stray continuation byte; emit replacement, advance one
    elseif b1 < 0xE0 then
      local b2 = string.byte(text, i + 1)
      if b1 >= 0xC2 and isContinuation(b2) then
        cp = ((b1 - 0xC0) * 64) + (b2 - 0x80)
        width = 2
      else
        cp, width = 0xFFFD, 1
      end
    elseif b1 < 0xF0 then
      local b2 = string.byte(text, i + 1)
      local b3 = string.byte(text, i + 2)
      if isContinuation(b2) and isContinuation(b3)
          and not (b1 == 0xE0 and b2 < 0xA0)
          and not (b1 == 0xED and b2 > 0x9F) then
        cp = ((b1 - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80)
        width = 3
      else
        cp, width = 0xFFFD, 1
      end
    elseif b1 < 0xF5 then
      local b2 = string.byte(text, i + 1)
      local b3 = string.byte(text, i + 2)
      local b4 = string.byte(text, i + 3)
      if isContinuation(b2) and isContinuation(b3) and isContinuation(b4)
          and not (b1 == 0xF0 and b2 < 0x90)
          and not (b1 == 0xF4 and b2 > 0x8F) then
        cp = ((b1 - 0xF0) * 262144) + ((b2 - 0x80) * 4096) + ((b3 - 0x80) * 64) + (b4 - 0x80)
        width = 4
      else
        cp, width = 0xFFFD, 1
      end
    else
      cp, width = 0xFFFD, 1
    end

    local transformed = transformFn(cp)
    if transformed then
      if transformed < 0x80 then
        out[#out + 1] = string.char(transformed)
      elseif transformed < 0x800 then
        out[#out + 1] = string.char(0xC0 + math.floor(transformed / 64), 0x80 + (transformed % 64))
      elseif transformed < 0x10000 then
        out[#out + 1] = string.char(
          0xE0 + math.floor(transformed / 4096),
          0x80 + math.floor((transformed % 4096) / 64),
          0x80 + (transformed % 64)
        )
      else
        out[#out + 1] = string.char(
          0xF0 + math.floor(transformed / 262144),
          0x80 + math.floor((transformed % 262144) / 4096),
          0x80 + math.floor((transformed % 4096) / 64),
          0x80 + (transformed % 64)
        )
      end
    end

    i = i + width
  end

  return table.concat(out)
end

-- Stage 1: strip item-link wrappers (color codes + |H...|h[visible]|h → [visible]).
function Cleanse._Stage1_ItemLinks(text)
  text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
  text = string.gsub(text, "|r", "")
  text = string.gsub(text, "|H[^|]*|h(%b[])|h", "%1")
  return text
end

-- Stage 2: strip format / direction-override / zero-width / variation-selector codepoints.
function Cleanse._Stage2_FormatChars(text)
  return Cleanse._ScanCodepoints(text, function(cp)
    if cp == 0x00AD or cp == 0xFEFF or cp == 0x2060 then return nil end
    if cp >= 0x200B and cp <= 0x200D then return nil end
    if cp >= 0xFE00 and cp <= 0xFE0F then return nil end
    if cp >= 0x202A and cp <= 0x202E then return nil end
    if cp >= 0xE0000 and cp <= 0xE007F then return nil end
    return cp
  end)
end

-- Stage 3: strip combining marks.
function Cleanse._Stage3_CombiningMarks(text)
  return Cleanse._ScanCodepoints(text, function(cp)
    if cp >= 0x0300 and cp <= 0x036F then return nil end
    if cp >= 0x1AB0 and cp <= 0x1AFF then return nil end
    if cp >= 0x1DC0 and cp <= 0x1DFF then return nil end
    if cp >= 0x20D0 and cp <= 0x20FF then return nil end
    if cp >= 0xFE20 and cp <= 0xFE2F then return nil end
    return cp
  end)
end

-- Seed confusables. Keys: source codepoint; Values: ASCII target codepoint.
Cleanse._confusables = {
  -- Cyrillic small
  [0x0430] = 0x61, [0x0435] = 0x65, [0x043E] = 0x6F, [0x0440] = 0x70,
  [0x0441] = 0x63, [0x0443] = 0x79, [0x0445] = 0x78,
  -- Cyrillic capital
  [0x0410] = 0x41, [0x0412] = 0x42, [0x0415] = 0x45, [0x041A] = 0x4B,
  [0x041C] = 0x4D, [0x041D] = 0x48, [0x041E] = 0x4F, [0x0420] = 0x50,
  [0x0421] = 0x43, [0x0422] = 0x54, [0x0425] = 0x58,
  -- Greek small
  [0x03B1] = 0x61, [0x03B5] = 0x65, [0x03B9] = 0x69, [0x03BD] = 0x76,
  [0x03BF] = 0x6F, [0x03C1] = 0x70,
  -- Math symbols that visually equal ASCII
  [0x2044] = 0x2F,  -- ⁄ → /
}

function Cleanse._Stage4_Confusables(text)
  return Cleanse._ScanCodepoints(text, function(cp)
    return Cleanse._confusables[cp] or cp
  end)
end

-- Stage 5: explicit alphanumeric block ranges only. Each branch maps one contiguous block
-- whose semantics we've verified. Blocks with reserved holes (Italic, Bold-Italic, etc.)
-- are deferred to UTR #39 full-table generation in BSP-001.x.
function Cleanse._Stage5_StyledAlnum(text)
  return Cleanse._ScanCodepoints(text, function(cp)
    -- Math Bold A-Z (no holes): U+1D400-U+1D419
    if cp >= 0x1D400 and cp <= 0x1D419 then return 0x41 + (cp - 0x1D400) end
    -- Math Bold a-z (no holes): U+1D41A-U+1D433
    if cp >= 0x1D41A and cp <= 0x1D433 then return 0x61 + (cp - 0x1D41A) end
    -- Math Bold digits 0-9: U+1D7CE-U+1D7D7
    if cp >= 0x1D7CE and cp <= 0x1D7D7 then return 0x30 + (cp - 0x1D7CE) end
    -- Fullwidth A-Z: U+FF21-U+FF3A
    if cp >= 0xFF21 and cp <= 0xFF3A then return 0x41 + (cp - 0xFF21) end
    -- Fullwidth a-z: U+FF41-U+FF5A
    if cp >= 0xFF41 and cp <= 0xFF5A then return 0x61 + (cp - 0xFF41) end
    -- Fullwidth 0-9: U+FF10-U+FF19
    if cp >= 0xFF10 and cp <= 0xFF19 then return 0x30 + (cp - 0xFF10) end
    -- Enclosed Ⓐ-Ⓩ: U+24B6-U+24CF
    if cp >= 0x24B6 and cp <= 0x24CF then return 0x41 + (cp - 0x24B6) end
    -- Enclosed ⓐ-ⓩ: U+24D0-U+24E9
    if cp >= 0x24D0 and cp <= 0x24E9 then return 0x61 + (cp - 0x24D0) end
    return cp
  end)
end

-- Stage 6: in-word leetspeak via single-pass character loop.
-- Each candidate leet char gets substituted only if BOTH neighbors are ASCII letters.
-- The loop never revisits a position, so overlapping substitutions all fire correctly.
Cleanse._leetMap = {
  ["0"] = "o", ["1"] = "l", ["3"] = "e", ["4"] = "a", ["5"] = "s",
  ["7"] = "t", ["8"] = "b", ["@"] = "a", ["$"] = "s",
}
local function _isAsciiLetter(byte)
  return (byte >= 0x41 and byte <= 0x5A) or (byte >= 0x61 and byte <= 0x7A)
end
function Cleanse._Stage6_Leetspeak(text)
  local n = #text
  if n < 3 then return text end
  local out = {}
  for i = 1, n do
    local c = string.sub(text, i, i)
    local sub = Cleanse._leetMap[c]
    if sub and i > 1 and i < n then
      local prev = string.byte(text, i - 1)
      local next_ = string.byte(text, i + 1)
      if _isAsciiLetter(prev) and _isAsciiLetter(next_) then
        out[#out + 1] = sub
      else
        out[#out + 1] = c
      end
    else
      out[#out + 1] = c
    end
  end
  return table.concat(out)
end

-- Stage 7: lowercase (ASCII-only post-stages-4-5).
function Cleanse._Stage7_Lowercase(text)
  return string.lower(text)
end

-- Stage 8: run-length collapse. "goooold" → "gold".
-- Lua 5.1 patterns disallow quantifiers on back-references, so iterate (.)%1 to fixed point.
function Cleanse._Stage8_RunLength(text)
  local n
  repeat
    text, n = string.gsub(text, "(.)%1", "%1")
  until n == 0
  return text
end

-- Stage 9: symbol / whitespace strip.
function Cleanse._Stage9_Symbols(text)
  return (string.gsub(text, "[%*%-<>%(%)\"!%?=`'_%+#%%%^&;:~{}%[%]%s/\\|,.@]", ""))
end

local TOKEN_SEPARATORS = {
  [0x00D7] = true, -- × Multiplication Sign
  [0x2022] = true, -- • Bullet
  [0x25BA] = true, -- ► Black Right-Pointing Pointer
  [0x25C4] = true, -- ◄ Black Left-Pointing Pointer
}

local function _isTokenSeparator(cp)
  return TOKEN_SEPARATORS[cp] == true
end

function Cleanse._Stage9_UnicodeSeparators(text)
  return Cleanse._ScanCodepoints(text, function(cp)
    if _isTokenSeparator(cp) then return nil end
    return cp
  end)
end

-- Returns boolean. Flushes word state on any non-letter codepoint.
-- BSP-030: promoted from a file-local to a Cleanse member. Analyze no longer
-- calls it (the fused front-end below detects mixed-script inline); it is
-- retained as the executable spec the differential test reconstructs against.
function Cleanse._DetectMixedScript(text)
  if not text or text == "" then return false end
  local function scriptOf(cp)
    if (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A) then return "latin" end
    if cp >= 0x0400 and cp <= 0x04FF then return "cyrillic" end
    if cp >= 0x0370 and cp <= 0x03FF then return "greek" end
    if cp >= 0x0590 and cp <= 0x05FF then return "hebrew" end
    if cp >= 0x0600 and cp <= 0x06FF then return "arabic" end
    return nil
  end

  local mixed = false
  local wordHasLatin, wordHasOther = false, false
  local function flushWord()
    if wordHasLatin and wordHasOther then mixed = true end
    wordHasLatin, wordHasOther = false, false
  end

  Cleanse._ScanCodepoints(text, function(cp)
    local s = scriptOf(cp)
    if not s then
      flushWord()   -- any non-letter codepoint is a word boundary
    elseif s == "latin" then
      wordHasLatin = true
    else
      wordHasOther = true
    end
    return cp
  end)
  flushWord()
  return mixed
end

-- BSP-030: fused single-pass front-end. Collapses Stages 2-5 + mixed-script
-- detection — previously FIVE separate _ScanCodepoints rebuilds (Stages 2,3,4,5
-- + a _DetectMixedScript pass that built and threw away a whole copy) — into ONE
-- codepoint walk with one output buffer. Pure-ASCII input fast-paths past it
-- entirely (Stages 2-5 are identity on ASCII; ASCII is never mixed-script).
-- Byte-identical to the staged pipeline, locked by run_cleanse_differential in
-- Sift_Dev/tools/. The _Stage2..5 / _DetectMixedScript functions above are
-- retained as that spec and as unit-test targets — do not delete them.
local function _isFormatChar(cp)
  if cp == 0x00AD or cp == 0xFEFF or cp == 0x2060 then return true end
  if cp >= 0x200B and cp <= 0x200D then return true end
  if cp >= 0xFE00 and cp <= 0xFE0F then return true end
  if cp >= 0x202A and cp <= 0x202E then return true end
  if cp >= 0xE0000 and cp <= 0xE007F then return true end
  return false
end

local function _isCombiningMark(cp)
  if cp >= 0x0300 and cp <= 0x036F then return true end
  if cp >= 0x1AB0 and cp <= 0x1AFF then return true end
  if cp >= 0x1DC0 and cp <= 0x1DFF then return true end
  if cp >= 0x20D0 and cp <= 0x20FF then return true end
  if cp >= 0xFE20 and cp <= 0xFE2F then return true end
  return false
end

local function _styledFold(cp)
  if cp >= 0x1D400 and cp <= 0x1D419 then return 0x41 + (cp - 0x1D400) end
  if cp >= 0x1D41A and cp <= 0x1D433 then return 0x61 + (cp - 0x1D41A) end
  if cp >= 0x1D7CE and cp <= 0x1D7D7 then return 0x30 + (cp - 0x1D7CE) end
  if cp >= 0xFF21 and cp <= 0xFF3A then return 0x41 + (cp - 0xFF21) end
  if cp >= 0xFF41 and cp <= 0xFF5A then return 0x61 + (cp - 0xFF41) end
  if cp >= 0xFF10 and cp <= 0xFF19 then return 0x30 + (cp - 0xFF10) end
  if cp >= 0x24B6 and cp <= 0x24CF then return 0x41 + (cp - 0x24B6) end
  if cp >= 0x24D0 and cp <= 0x24E9 then return 0x61 + (cp - 0x24D0) end
  return cp
end

local function _scriptOf(cp)
  if (cp >= 0x41 and cp <= 0x5A) or (cp >= 0x61 and cp <= 0x7A) then return "latin" end
  if cp >= 0x0400 and cp <= 0x04FF then return "cyrillic" end
  if cp >= 0x0370 and cp <= 0x03FF then return "greek" end
  if cp >= 0x0590 and cp <= 0x05FF then return "hebrew" end
  if cp >= 0x0600 and cp <= 0x06FF then return "arabic" end
  return nil
end

local function _emit(out, n, cp)
  if cp < 0x80 then
    n = n + 1; out[n] = string.char(cp)
  elseif cp < 0x800 then
    n = n + 1; out[n] = string.char(0xC0 + math.floor(cp / 64), 0x80 + (cp % 64))
  elseif cp < 0x10000 then
    n = n + 1; out[n] = string.char(0xE0 + math.floor(cp / 4096),
      0x80 + math.floor((cp % 4096) / 64), 0x80 + (cp % 64))
  else
    n = n + 1; out[n] = string.char(0xF0 + math.floor(cp / 262144),
      0x80 + math.floor((cp % 262144) / 4096), 0x80 + math.floor((cp % 4096) / 64), 0x80 + (cp % 64))
  end
  return n
end

-- One codepoint walk = Stages 2,3,4,5 + mixed-script. Decoder mirrors
-- _ScanCodepoints exactly (incl. 0xFFFD on malformed UTF-8). Returns the folded
-- string and the mixedScript boolean. Format/combining codepoints are skipped
-- entirely (not emitted, and not treated as word boundaries) — matching the
-- staged order where Stages 2/3 strip them before mixed-script detection runs.
function Cleanse._FusedFrontPass(text)
  local out, n = {}, 0
  local i, len = 1, #text
  local mixed = false
  local wordHasLatin, wordHasOther = false, false
  local hasTokenSeparator = false

  while i <= len do
    local b1 = string.byte(text, i)
    local cp, width
    if b1 < 0x80 then
      cp, width = b1, 1
    elseif b1 < 0xC0 then
      cp, width = 0xFFFD, 1
    elseif b1 < 0xE0 then
      local b2 = string.byte(text, i + 1)
      if b1 >= 0xC2 and b2 and b2 >= 0x80 and b2 <= 0xBF then
        cp = ((b1 - 0xC0) * 64) + (b2 - 0x80); width = 2
      else cp, width = 0xFFFD, 1 end
    elseif b1 < 0xF0 then
      local b2 = string.byte(text, i + 1)
      local b3 = string.byte(text, i + 2)
      if b2 and b3 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF
          and not (b1 == 0xE0 and b2 < 0xA0) and not (b1 == 0xED and b2 > 0x9F) then
        cp = ((b1 - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80); width = 3
      else cp, width = 0xFFFD, 1 end
    elseif b1 < 0xF5 then
      local b2 = string.byte(text, i + 1)
      local b3 = string.byte(text, i + 2)
      local b4 = string.byte(text, i + 3)
      if b2 and b3 and b4 and b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF
          and b4 >= 0x80 and b4 <= 0xBF
          and not (b1 == 0xF0 and b2 < 0x90) and not (b1 == 0xF4 and b2 > 0x8F) then
        cp = ((b1 - 0xF0) * 262144) + ((b2 - 0x80) * 4096) + ((b3 - 0x80) * 64) + (b4 - 0x80); width = 4
      else cp, width = 0xFFFD, 1 end
    else
      cp, width = 0xFFFD, 1
    end

    if not (_isFormatChar(cp) or _isCombiningMark(cp)) then
      local s = _scriptOf(cp)                 -- mixed-script uses the ORIGINAL cp, pre-fold
      if not s then
        if wordHasLatin and wordHasOther then mixed = true end
        wordHasLatin, wordHasOther = false, false
      elseif s == "latin" then
        wordHasLatin = true
      else
        wordHasOther = true
      end
      if cp >= 0x80 and _isTokenSeparator(cp) then
        hasTokenSeparator = true
      end
      local folded = Cleanse._confusables[cp] or cp   -- Stage 4 then Stage 5
      folded = _styledFold(folded)
      n = _emit(out, n, folded)
    end

    i = i + width
  end
  if wordHasLatin and wordHasOther then mixed = true end

  return table.concat(out), mixed, hasTokenSeparator
end

function Cleanse.Analyze(text)
  if type(text) ~= "string" then
    return { normalized = "", signals = { mixedScript = false, containsItemLinks = false } }
  end

  local containsItemLinks = string.find(text, "|H", 1, true) ~= nil

  text = Cleanse._Stage1_ItemLinks(text)

  -- BSP-030: Stages 2-5 + mixed-script in one pass, with a pure-ASCII fast-path.
  local mixedScript, hasTokenSeparator
  if not string.find(text, "[\128-\255]") then
    mixedScript = false                       -- ASCII: stages 2-5 identity, never mixed
    hasTokenSeparator = false
  else
    text, mixedScript, hasTokenSeparator = Cleanse._FusedFrontPass(text)
  end

  text = Cleanse._Stage6_Leetspeak(text)
  text = Cleanse._Stage7_Lowercase(text)
  text = Cleanse._Stage8_RunLength(text)
  text = Cleanse._Stage9_Symbols(text)
  if hasTokenSeparator then
    text = Cleanse._Stage9_UnicodeSeparators(text)
  end

  return {
    normalized = text,
    signals = { mixedScript = mixedScript, containsItemLinks = containsItemLinks },
  }
end

function Cleanse.Text(text)
  return Cleanse.Analyze(text).normalized
end

-- Dual-mode export. MUST be the final statement so WoW's chunk loader gets the table as the
-- return value when running standalone (build tool) AND attaches to NS.Cleanse when loaded
-- via TOC. Smoke-test this dual-mode behavior in BSP-002 when the addon first loads in WoW.
local _, NS = ...
if NS then NS.Cleanse = Cleanse end
return Cleanse
