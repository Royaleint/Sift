-- BSP-013: base locale table.
--
-- enUS is the base locale: it creates the shared L table on the addon
-- namespace and defines an identity entry ("English text" -> "English text")
-- for every literal key currently referenced with `L[...]` in the codebase.
-- A key that isn't listed below still reads back unchanged -- the metatable
-- returns whatever key it's asked for -- so this file only needs updating
-- when a new player-visible string is added, not for every call site.
--
-- A future translation file loads after this one and overrides individual
-- values without touching any call site, e.g. Locales/deDE.lua:
--
--   if GetLocale() ~= "deDE" then return end
--   local _, NS = ...
--   local L = NS.L
--   L["Restore"] = "Wiederherstellen"

local _, NS = ...

-- Pass-through only -- never stores into L. A stored fallback would leak
-- player-supplied text (sender names, custom keywords) into the shared
-- table for any string built by concatenating it in before the L[] lookup;
-- an unrecognized key with nothing to translate is also not an error case
-- worth remembering. Reading a nil key here is safe (Lua 5.1 only throws on
-- table index nil for a write); every current call site already guards
-- against it regardless.
local L = setmetatable({}, {
  __index = function(_, k) return k end,
})
NS.L = L

-- History panel: window chrome and section headers
L["Sift — History"] = "Sift — History"
L["DETECTION STATS"] = "DETECTION STATS"
L["BY SURFACE"] = "BY SURFACE"
L["BY CATEGORY"] = "BY CATEGORY"
L["PIPELINE"] = "PIPELINE"
L["Character"] = "Character"
L["Account"] = "Account"
L["Refresh"] = "Refresh"
L["History list is unavailable in this client."] = "History list is unavailable in this client."

-- History panel: category / stat-tile / pause-pill display labels, reached
-- via table lookups keyed by internal category or surface names
L["Gold selling"] = "Gold selling"
L["My Keywords"] = "My Keywords"
L["Boosting"] = "Boosting"
L["DETECTED"] = "DETECTED"
L["BLOCKED"] = "BLOCKED"
L["PASS-THRU"] = "PASS-THRU"
L["RESTORED"] = "RESTORED"
L["FALSE POSITIVES"] = "FALSE POSITIVES"
L["Chat"] = "Chat"
L["Whisp"] = "Whisp"
L["Bnet"] = "Bnet"

-- History panel: row badges and detail-pane status text
L["You"] = "You"
L["Flood"] = "Flood"
L["Throttled"] = "Throttled"
L["Bubbles suppressed"] = "Bubbles suppressed"
L["contains item link"] = "contains item link"
L["PASSED THROUGH"] = "PASSED THROUGH"
L["surface paused"] = "surface paused"
L["blocked by you"] = "blocked by you"
L["caught by your keyword"] = "caught by your keyword"

-- History panel: detail-pane action buttons
L["\226\156\147 Restored"] = "\226\156\147 Restored"
L["Allowlisted"] = "Allowlisted"
L["Block retroactively"] = "Block retroactively"
L["Always allow"] = "Always allow"
L["Restore"] = "Restore"
L["Restore + Always allow"] = "Restore + Always allow"
L["Restore only"] = "Restore only"

-- History panel: pause-surface right-click menu; the cycle-hint line is
-- shared with the Config panel's per-row pause tooltips below
L["Sift"] = "Sift"
L["Pause surface"] = "Pause surface"
L["Open config"] = "Open config"
L["Left-click cycles forward \194\183 Right-click cycles back."] = "Left-click cycles forward \194\183 Right-click cycles back."

-- Config panel: window chrome
L["Sift \226\128\148 Config"] = "Sift \226\128\148 Config"

-- Config panel: remove-row tooltips (format strings -- the row's own text,
-- a sender label or a keyword, is a %s argument, never part of the key)
L["Take %s off the allowlist. Use Undo above to revert."] = "Take %s off the allowlist. Use Undo above to revert."
L["Take %s off the blocked-actors list."] = "Take %s off the blocked-actors list."
L["Take \"%s\" out of this list."] = "Take \"%s\" out of this list."
