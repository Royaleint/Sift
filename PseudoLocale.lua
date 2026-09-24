-- Sift/PseudoLocale.lua
-- Dev-only in-session i18n smoke check, run via /bdev pseudolocale.
-- Pads every stored Locales/enUS.lua value in place so a player-visible
-- string that reaches the screen still in plain English is easy to spot,
-- and a text box too narrow for a longer string overflows visibly instead
-- of clipping silently. Latin-1 Supplement accents only -- FRIZQT renders
-- these on an enUS client; Latin Extended glyphs would not.
--
-- Session-only: no SavedVariables, no global. Mutates the live NS.L table
-- in place; a panel already built keeps its old text (most of it is built
-- once and never redrawn), so seeing the padding everywhere needs /reload,
-- run this, then open a Sift panel for the first time. /reload also fully
-- restores English.
--
-- devMode-gated the way ShadowLog.Record is: BdevSlashHandler already gates
-- every /bdev subcommand on it, but the check lives here too so nothing
-- else that might call in later can forget it.

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

-- Exposed (not local) so an offline test can exercise the padding rule
-- directly. Targets ~35% growth in visible glyphs, not bytes -- an accent
-- is one glyph but two UTF-8 bytes, so sizing by byte length would
-- under-pad. Each edge gets at least 2 accent glyphs, so a short string
-- like "Reset" still visibly changes.
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

-- Latched once padding runs; /reload is the only way back to English, and
-- there's no other in-session event that would make padding an
-- already-padded table sensible, so a second call is a no-op rather than a
-- second, deeper pad.
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

-- Test-only: lets the offline suite exercise Apply() more than once per
-- process without a real /reload. Mirrors ShadowLog.Clear's inspection role.
function PseudoLocale._ResetForTests()
  applied = false
end

NS.PseudoLocale = PseudoLocale
return PseudoLocale
