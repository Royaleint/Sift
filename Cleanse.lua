-- BawrSpam/Cleanse.lua
-- 9-stage text normalization pipeline. Pure Lua, dual-mode (addon TOC + build tool dofile).
-- Zero WoW API references — runs identically in both contexts.

local Cleanse = {}

-- UTF-8 codepoint scanner. Decodes one codepoint at a time and applies transformFn(cp) → cp|nil.
-- nil return drops the codepoint. Returns the re-encoded string.
function Cleanse._ScanCodepoints(text, transformFn)
  if type(text) ~= "string" or text == "" then return text or "" end

  local out = {}
  local i, n = 1, #text
  while i <= n do
    local b1 = string.byte(text, i)
    local cp, width
    if b1 < 0x80 then
      cp, width = b1, 1
    elseif b1 < 0xC0 then
      cp, width = 0xFFFD, 1  -- stray continuation byte; emit replacement, advance one
    elseif b1 < 0xE0 then
      local b2 = string.byte(text, i + 1) or 0
      cp = ((b1 - 0xC0) * 64) + (b2 - 0x80)
      width = 2
    elseif b1 < 0xF0 then
      local b2 = string.byte(text, i + 1) or 0
      local b3 = string.byte(text, i + 2) or 0
      cp = ((b1 - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80)
      width = 3
    else
      local b2 = string.byte(text, i + 1) or 0
      local b3 = string.byte(text, i + 2) or 0
      local b4 = string.byte(text, i + 3) or 0
      cp = ((b1 - 0xF0) * 262144) + ((b2 - 0x80) * 4096) + ((b3 - 0x80) * 64) + (b4 - 0x80)
      width = 4
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

-- Dual-mode export. MUST be the final statement so WoW's chunk loader gets the table as the
-- return value when running standalone (build tool) AND attaches to NS.Cleanse when loaded
-- via TOC. Smoke-test this dual-mode behavior in BSP-002 when the addon first loads in WoW.
local _, NS = ...
if NS then NS.Cleanse = Cleanse end
return Cleanse
