-- Sift/Cleanse.lua
-- 9-stage text normalization pipeline. Pure Lua, dual-mode (TOC load and dofile).
-- No WoW API references: it must run identically outside the game.

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
  -- Latin-script additions (U+00C0-U+017F).
  [0x00C0] = 0x41, [0x00C1] = 0x41, [0x00C2] = 0x41, [0x00C3] = 0x41, [0x00C4] = 0x41, [0x00C5] = 0x41,
  [0x00C7] = 0x43, [0x00C8] = 0x45, [0x00C9] = 0x45, [0x00CA] = 0x45, [0x00CB] = 0x45, [0x00CC] = 0x49,
  [0x00CD] = 0x49, [0x00CE] = 0x49, [0x00CF] = 0x49, [0x00D1] = 0x4E, [0x00D2] = 0x4F, [0x00D3] = 0x4F,
  [0x00D4] = 0x4F, [0x00D5] = 0x4F, [0x00D6] = 0x4F, [0x00D8] = 0x4F, [0x00D9] = 0x55, [0x00DA] = 0x55,
  [0x00DB] = 0x55, [0x00DC] = 0x55, [0x00DD] = 0x59, [0x00E0] = 0x61, [0x00E1] = 0x61, [0x00E2] = 0x61,
  [0x00E3] = 0x61, [0x00E4] = 0x61, [0x00E5] = 0x61, [0x00E7] = 0x63, [0x00E8] = 0x65, [0x00E9] = 0x65,
  [0x00EA] = 0x65, [0x00EB] = 0x65, [0x00EC] = 0x69, [0x00ED] = 0x69, [0x00EE] = 0x69, [0x00EF] = 0x69,
  [0x00F1] = 0x6E, [0x00F2] = 0x6F, [0x00F3] = 0x6F, [0x00F4] = 0x6F, [0x00F5] = 0x6F, [0x00F6] = 0x6F,
  [0x00F8] = 0x6F, [0x00F9] = 0x75, [0x00FA] = 0x75, [0x00FB] = 0x75, [0x00FC] = 0x75, [0x00FD] = 0x79,
  [0x00FF] = 0x79, [0x0100] = 0x41, [0x0101] = 0x61, [0x0102] = 0x41, [0x0103] = 0x61, [0x0104] = 0x41,
  [0x0105] = 0x61, [0x0106] = 0x43, [0x0107] = 0x63, [0x0108] = 0x43, [0x0109] = 0x63, [0x010A] = 0x43,
  [0x010B] = 0x63, [0x010C] = 0x43, [0x010D] = 0x63, [0x010E] = 0x44, [0x010F] = 0x64, [0x0110] = 0x44,
  [0x0111] = 0x64, [0x0112] = 0x45, [0x0113] = 0x65, [0x0114] = 0x45, [0x0115] = 0x65, [0x0116] = 0x45,
  [0x0117] = 0x65, [0x0118] = 0x45, [0x0119] = 0x65, [0x011A] = 0x45, [0x011B] = 0x65, [0x011C] = 0x47,
  [0x011D] = 0x67, [0x011E] = 0x47, [0x011F] = 0x67, [0x0120] = 0x47, [0x0121] = 0x67, [0x0122] = 0x47,
  [0x0123] = 0x67, [0x0124] = 0x48, [0x0125] = 0x68, [0x0126] = 0x48, [0x0127] = 0x68, [0x0128] = 0x49,
  [0x0129] = 0x69, [0x012A] = 0x49, [0x012B] = 0x69, [0x012C] = 0x49, [0x012D] = 0x69, [0x012E] = 0x49,
  [0x012F] = 0x69, [0x0130] = 0x49, [0x0134] = 0x4A, [0x0135] = 0x6A, [0x0136] = 0x4B, [0x0137] = 0x6B,
  [0x0139] = 0x4C, [0x013A] = 0x6C, [0x013B] = 0x4C, [0x013C] = 0x6C, [0x013D] = 0x4C, [0x013E] = 0x6C,
  [0x013F] = 0x4C, [0x0140] = 0x6C, [0x0141] = 0x4C, [0x0142] = 0x6C, [0x0143] = 0x4E, [0x0144] = 0x6E,
  [0x0145] = 0x4E, [0x0146] = 0x6E, [0x0147] = 0x4E, [0x0148] = 0x6E, [0x014C] = 0x4F, [0x014D] = 0x6F,
  [0x014E] = 0x4F, [0x014F] = 0x6F, [0x0150] = 0x4F, [0x0151] = 0x6F, [0x0154] = 0x52, [0x0155] = 0x72,
  [0x0156] = 0x52, [0x0157] = 0x72, [0x0158] = 0x52, [0x0159] = 0x72, [0x015A] = 0x53, [0x015B] = 0x73,
  [0x015C] = 0x53, [0x015D] = 0x73, [0x015E] = 0x53, [0x015F] = 0x73, [0x0160] = 0x53, [0x0161] = 0x73,
  [0x0162] = 0x54, [0x0163] = 0x74, [0x0164] = 0x54, [0x0165] = 0x74, [0x0166] = 0x54, [0x0167] = 0x74,
  [0x0168] = 0x55, [0x0169] = 0x75, [0x016A] = 0x55, [0x016B] = 0x75, [0x016C] = 0x55, [0x016D] = 0x75,
  [0x016E] = 0x55, [0x016F] = 0x75, [0x0170] = 0x55, [0x0171] = 0x75, [0x0172] = 0x55, [0x0173] = 0x75,
  [0x0174] = 0x57, [0x0175] = 0x77, [0x0176] = 0x59, [0x0177] = 0x79, [0x0178] = 0x59, [0x0179] = 0x5A,
  [0x017A] = 0x7A, [0x017B] = 0x5A, [0x017C] = 0x7A, [0x017D] = 0x5A, [0x017E] = 0x7A, [0x017F] = 0x73,
}

function Cleanse._Stage4_Confusables(text)
  return Cleanse._ScanCodepoints(text, function(cp)
    return Cleanse._confusables[cp] or cp
  end)
end

-- Stage 5: explicit alphanumeric block ranges only, each one contiguous. Blocks with
-- reserved holes (Italic, Bold-Italic, etc.) are not mapped.
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

-- Stage 6: in-word leetspeak. A leet char is replaced only when both neighbors
-- in the original text are ASCII letters. _leetSource is a file-level upvalue
-- so the gsub callback is not a new closure per message.
Cleanse._leetMap = {
  ["0"] = "o", ["1"] = "l", ["3"] = "e", ["4"] = "a", ["5"] = "s",
  ["7"] = "t", ["8"] = "b", ["@"] = "a", ["$"] = "s",
}
local _LEET_CHARS = "0134578@$"
local _LEET_NEIGHBOR_PATTERN = "[A-Za-z][" .. _LEET_CHARS .. "][A-Za-z]"
local _LEET_GSUB_PATTERN = "()([" .. _LEET_CHARS .. "])"
local function _isAsciiLetter(byte)
  return byte ~= nil and ((byte >= 0x41 and byte <= 0x5A) or (byte >= 0x61 and byte <= 0x7A))
end
local _leetSource
local function _LeetReplace(pos, c)
  if _isAsciiLetter(string.byte(_leetSource, pos - 1)) and _isAsciiLetter(string.byte(_leetSource, pos + 1)) then
    return Cleanse._leetMap[c]
  end
  return nil
end
function Cleanse._Stage6_Leetspeak(text)
  local n = #text
  if n < 3 then return text end
  if not string.find(text, _LEET_NEIGHBOR_PATTERN) then return text end
  _leetSource = text
  local result = string.gsub(text, _LEET_GSUB_PATTERN, _LeetReplace)
  _leetSource = nil
  return result
end

-- Stage 7: lowercase (ASCII-only post-stages-4-5).
function Cleanse._Stage7_Lowercase(text)
  return string.lower(text)
end

-- Stage 8: run-length collapse. "goooold" → "gold". Collapses runs of the same
-- ASCII character only (letters, digits, punctuation) -- a byte >= 0x80 is
-- never collapsed, because two equal adjacent bytes there are always the two
-- continuation bytes of one multi-byte character, not a repeated character.
-- Lua 5.1 patterns disallow quantifiers on back-references, so iterate to a
-- fixed point either way.
function Cleanse._Stage8_RunLength(text)
  local n
  if not string.find(text, "[\128-\255]") then
    repeat
      text, n = string.gsub(text, "(.)%1", "%1")
    until n == 0
    return text
  end
  repeat
    text, n = string.gsub(text, "([%z\1-\127])%1", "%1")
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
-- Not called by Analyze; kept as the fused pass's test reference.
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

-- Fused front-end: Stages 2-5 plus mixed-script detection in one codepoint walk,
-- skipped entirely for pure-ASCII input. Must stay byte-identical to the staged
-- pipeline; the _Stage2..5 / _DetectMixedScript functions above are its test
-- reference, so do not delete them.
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

-- Script-island shape: a mostly-CJK message carrying an embedded Latin run.
-- Measured here because this walk already decodes every codepoint; the reader
-- of analysis.signals decides what it means.
local ISLAND_MIN_CJK = 4  -- ignore a stray ideograph or two
local ISLAND_MIN_RUN = 4  -- a handle-length run, not an incidental letter

local function _isCJK(cp)
  if cp >= 0x3040 and cp <= 0x30FF then return true end  -- Hiragana + Katakana
  if cp >= 0x3400 and cp <= 0x4DBF then return true end  -- CJK Unified Ext A
  if cp >= 0x4E00 and cp <= 0x9FFF then return true end  -- CJK Unified
  if cp >= 0xAC00 and cp <= 0xD7AF then return true end  -- Hangul syllables
  if cp >= 0xF900 and cp <= 0xFAFF then return true end  -- CJK compatibility
  return false
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

-- Returns the folded string and the mixedScript boolean. The decoder must mirror
-- _ScanCodepoints exactly (incl. 0xFFFD on malformed UTF-8). Format/combining
-- codepoints are skipped, not treated as word boundaries, to match the staged order.
function Cleanse._FusedFrontPass(text)
  local out, n = {}, 0
  local i, len = 1, #text
  local mixed = false
  local wordHasLatin, wordHasOther = false, false
  local hasTokenSeparator = false
  local cjkCount, latinCount, latinRun, maxLatinRun = 0, 0, 0, 0

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

      -- Counted on the folded codepoint, so fullwidth Latin counts as Latin.
      -- Digits extend a run but do not count toward latinCount.
      if _isCJK(cp) then
        cjkCount = cjkCount + 1
        latinRun = 0
      elseif (folded >= 0x41 and folded <= 0x5A) or (folded >= 0x61 and folded <= 0x7A) then
        latinCount = latinCount + 1
        latinRun = latinRun + 1
        if latinRun > maxLatinRun then maxLatinRun = latinRun end
      elseif folded >= 0x30 and folded <= 0x39 then
        latinRun = latinRun + 1
        if latinRun > maxLatinRun then maxLatinRun = latinRun end
      else
        latinRun = 0
      end

      n = _emit(out, n, folded)
    end

    i = i + width
  end
  if wordHasLatin and wordHasOther then mixed = true end

  -- latinCount > 0 is load-bearing: a digits-only run (a quoted price) is not an
  -- island.
  local scriptIsland = cjkCount >= ISLAND_MIN_CJK
    and cjkCount > latinCount
    and latinCount > 0
    and maxLatinRun >= ISLAND_MIN_RUN

  return table.concat(out), mixed, hasTokenSeparator, scriptIsland
end

-- Output is saved by keyword rules, so a change here needs a matching migration.
function Cleanse.Analyze(text)
  if type(text) ~= "string" then
    return {
      normalized = "",
      signals = { mixedScript = false, containsItemLinks = false, scriptIsland = false },
    }
  end

  -- Read before Stage 1, which strips the link markup this looks for.
  local containsItemLinks = string.find(text, "|H", 1, true) ~= nil

  text = Cleanse._Stage1_ItemLinks(text)

  -- Stages 2-5 + mixed-script in one pass, with a pure-ASCII fast-path.
  local mixedScript, hasTokenSeparator, scriptIsland
  if not string.find(text, "[\128-\255]") then
    mixedScript = false                       -- ASCII: stages 2-5 identity, never mixed
    hasTokenSeparator = false
    scriptIsland = false                      -- ASCII: no CJK, so no script island
  else
    text, mixedScript, hasTokenSeparator, scriptIsland = Cleanse._FusedFrontPass(text)
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
    signals = {
      mixedScript = mixedScript,
      containsItemLinks = containsItemLinks,
      scriptIsland = scriptIsland,
    },
  }
end

function Cleanse.Text(text)
  return Cleanse.Analyze(text).normalized
end

-- Dual-mode export: must stay the final statement (dofile return + NS attach).
local _, NS = ...
if NS then NS.Cleanse = Cleanse end
return Cleanse
