-- Sift/PseudoLocale.lua
-- Dev-only i18n smoke check (/bdev pseudolocale). Pads every enUS locale value
-- in place so unlocalized strings and too-narrow text boxes stand out.
-- Latin-1 Supplement accents only: FRIZQT renders these on an enUS client;
-- Latin Extended glyphs would not.
--
-- Session-only: mutates the live NS.L table, no SavedVariables. Panels already
-- built keep their old text, so /reload, run this, then open a panel. /reload
-- restores English. The devMode check here is on purpose even though the
-- /bdev dispatcher also gates it.

local _, NS = ...
local PseudoLocale = {}

local ACCENTS = { "é", "à", "ü", "ñ", "ç", "ê", "ï", "ô" }

-- Builds a filler string of exactly `n` accent glyphs (each ACCENTS entry is
-- one glyph, though 2 UTF-8 bytes).
local function Fill(n)
  local parts = {}
  for i = 1, n do
    parts[i] = ACCENTS[(i - 1) % #ACCENTS + 1]
  end
  return table.concat(parts)
end

-- Number of visible glyphs in a UTF-8 string: counts lead bytes only
-- (< 0x80 is a one-byte ASCII glyph, >= 0xC0 starts a multi-byte one;
-- 0x80-0xBF are continuation bytes and don't count).
local function GlyphCount(value)
  local n = 0
  for i = 1, #value do
    local byte = value:byte(i)
    if byte < 0x80 or byte >= 0xC0 then
      n = n + 1
    end
  end
  return n
end

-- Exposed for tests. Targets ~35% growth in visible glyphs, not bytes (sizing
-- by bytes would under-pad), with at least 2 accents on each edge.
function PseudoLocale.Pad(value)
  if type(value) ~= "string" or value == "" then
    return value
  end
  local glyphs = GlyphCount(value)
  local targetExtra = math.max(4, math.floor(glyphs * 0.35 + 0.5))
  local perSide = math.max(2, math.floor((targetExtra - 4) / 2))
  local edge = Fill(perSide)
  return "[" .. edge .. " " .. value .. " " .. edge .. "]"
end

-- Latched once padding runs, so a second call cannot pad the table twice.
local applied = false

-- Returns true on success, or false plus a reason ("devMode" | "already-
-- applied" | "no-locale-table") on refusal.
function PseudoLocale.Apply()
  if not (NS.DB and NS.DB.IsDevMode and NS.DB.IsDevMode()) then
    return false, "devMode"
  end
  if applied then
    return false, "already-applied"
  end
  if type(NS.L) ~= "table" then
    return false, "no-locale-table"
  end
  for key, value in pairs(NS.L) do
    NS.L[key] = PseudoLocale.Pad(value)
  end
  applied = true
  return true
end

-- Test-only: lets tests run Apply() more than once without a /reload.
function PseudoLocale._ResetForTests()
  applied = false
end

NS.PseudoLocale = PseudoLocale
return PseudoLocale
