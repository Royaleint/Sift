-- BSP-013: base locale table.
--
-- enUS is the base locale: it creates the shared L table on the addon
-- namespace and defines an identity entry ("English text" -> "English text")
-- for every player-visible string that reaches an L[] lookup in the codebase
-- today -- whether the L[] call holds the literal directly, or reaches it
-- through a table lookup (e.g. CATEGORY_BADGE_LABELS) or a parameter threaded
-- through a shared helper (e.g. AttachTooltip's title/body/hint). A key that
-- isn't listed below still reads back unchanged -- the metatable returns
-- whatever key it's asked for -- so this file only needs updating when a new
-- player-visible string is added, not for every call site.
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

-- History panel: category badges not remapped by CATEGORY_BADGE_LABELS --
-- the retired categories display their own internal name as-is
L["Anti"] = "Anti"
L["Casino"] = "Casino"
L["Commercial"] = "Commercial"
L["Phishing"] = "Phishing"

-- History panel: breakdown-chip labels for signal keys that aren't a content
-- category (CATEGORY_BADGE_LABELS). Throttle reuses "Throttled" below.
L["Blocked sender"] = "Blocked sender"
L["Manual block"] = "Manual block"

-- History panel: row badges and detail-pane status text
L["You"] = "You"
L["Flood"] = "Flood"
L["Throttled"] = "Throttled"
L["Bubbles suppressed"] = "Bubbles suppressed"
L["Flood (recent)"] = "Flood (recent)"
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

-- History panel: detail-pane action tooltips (RenderActions' tipTitle /
-- tipBody, read by ActionOnEnter through L[self.tipTitle] / L[self.tipBody])
L["This block has already been undone. No further action needed."] = "This block has already been undone. No further action needed."
L["This sender is on the allowlist. Future messages from them bypass scanning."] = "This sender is on the allowlist. Future messages from them bypass scanning."
L["Mark this pass-thru as blocked. The original message stays in chat (can't un-print), but the entry is reclassified and a Blizzard report is sent if applicable."] = "Mark this pass-thru as blocked. The original message stays in chat (can't un-print), but the entry is reclassified and a Blizzard report is sent if applicable."
L["Add this sender to the allowlist. Future messages from them bypass scanning."] = "Add this sender to the allowlist. Future messages from them bypass scanning."
L["Un-block this message. Note: the original chat text was never injected, so it stays out of the chat scroll; restored entries appear here only."] = "Un-block this message. Note: the original chat text was never injected, so it stays out of the chat scroll; restored entries appear here only."
L["Report Spam"] = "Report Spam"
L["Send a Blizzard spam report for this message."] = "Send a Blizzard spam report for this message."
L["Un-block this message. Sender is already on the allowlist."] = "Un-block this message. Sender is already on the allowlist."
L["Un-block this message and add the sender to the allowlist so future messages from them bypass scanning."] = "Un-block this message and add the sender to the allowlist so future messages from them bypass scanning."
L["Un-block this message without changing the allowlist."] = "Un-block this message without changing the allowlist."
L["Un-block this message. This surface cannot be allowlisted."] = "Un-block this message. This surface cannot be allowlisted."

-- History panel: pause-surface right-click menu; the cycle-hint line is
-- shared with the Config panel's per-row pause tooltips below
L["Sift"] = "Sift"
L["Pause surface"] = "Pause surface"
L["Open config"] = "Open config"
L["Left-click cycles forward \194\183 Right-click cycles back."] = "Left-click cycles forward \194\183 Right-click cycles back."

-- History panel: pause state itself, and the pill/menu tooltip sentences it drives
L["active"] = "active"
L["paused"] = "paused"
L["off"] = "off"
L["Active \194\183 detected spam is blocked from chat."] = "Active \194\183 detected spam is blocked from chat."
L["Paused \194\183 detected spam is logged to History but stays in chat."] = "Paused \194\183 detected spam is logged to History but stays in chat."
L["Off \194\183 this surface is not scanned."] = "Off \194\183 this surface is not scanned."

-- History panel: char/account stats-scope button tooltips
L["Show detection stats for this character only."] = "Show detection stats for this character only."
L["Show detection stats summed across every character on this account."] = "Show detection stats summed across every character on this account."

-- History panel: stat-tile tooltips (STATS_TILE_TOOLTIPS title/body pairs)
L["Detected"] = "Detected"
L["Lifetime count of messages Sift scored as spam. Includes blocked, pass-thru, and restored entries."] = "Lifetime count of messages Sift scored as spam. Includes blocked, pass-thru, and restored entries."
L["Lifetime count of spam messages hidden from chat. Does not include pass-thru (paused surface/category) detections."] = "Lifetime count of spam messages hidden from chat. Does not include pass-thru (paused surface/category) detections."
L["Pass-thru"] = "Pass-thru"
L["Scored as spam but left visible because the surface or category was set to Paused. Still logged to History for review."] = "Scored as spam but left visible because the surface or category was set to Paused. Still logged to History for review."
L["Blocks you have manually undone via the action panel. These count against the false-positive rate."] = "Blocks you have manually undone via the action panel. These count against the false-positive rate."
L["False positives"] = "False positives"
L["Restored \195\183 Blocked. A rough false-positive rate. Lower is better."] = "Restored \195\183 Blocked. A rough false-positive rate. Lower is better."

-- History panel: category filter chips (CHIP_FULL_NAMES + the two hover bodies)
L["Gold selling (real-money trading)"] = "Gold selling (real-money trading)"
L["Boosting (paid carry ads)"] = "Boosting (paid carry ads)"
L["My Keywords (phrases you added yourself)"] = "My Keywords (phrases you added yourself)"
L["Currently included in the list. Click to hide entries in this category."] = "Currently included in the list. Click to hide entries in this category."
L["Currently hidden from the list. Click to show entries in this category."] = "Currently hidden from the list. Click to show entries in this category."

-- History panel: tab buttons, filter dropdowns, and their tooltips
L["History"] = "History"
L["View blocked, restored, and pass-thru detections."] = "View blocked, restored, and pass-thru detections."
L["Config"] = "Config"
L["Adjust thresholds, categories, surfaces, allowlist, and history settings."] = "Adjust thresholds, categories, surfaces, allowlist, and history settings."
L["Clear sender filter"] = "Clear sender filter"
L["Remove the active sender filter and show entries from all senders again."] = "Remove the active sender filter and show entries from all senders again."
L["Surface"] = "Surface"
L["Surface filter"] = "Surface filter"
L["Restrict the list to detections from one chat surface. \"All\" clears the filter."] = "Restrict the list to detections from one chat surface. \"All\" clears the filter."
L["Time"] = "Time"
L["Time window"] = "Time window"
L["Restrict the list to detections inside a recent time window."] = "Restrict the list to detections inside a recent time window."
L["Outcome"] = "Outcome"
L["Outcome filter"] = "Outcome filter"
L["Blocked = hidden from chat. Restored = un-blocked via the action panel. Pass-thru = scored as spam but logged-only because the surface or category was paused."] = "Blocked = hidden from chat. Restored = un-blocked via the action panel. Pass-thru = scored as spam but logged-only because the surface or category was paused."
L["Sort"] = "Sort"
L["Sort order"] = "Sort order"
L["Newest first \194\183 by Score (highest first) \194\183 by Sender (groups repeat offenders)."] = "Newest first \194\183 by Score (highest first) \194\183 by Sender (groups repeat offenders)."
L["Refresh list"] = "Refresh list"
L["Reload entries from history. Use after a Clear, Import, or external SavedVariables edit."] = "Reload entries from history. Use after a Clear, Import, or external SavedVariables edit."

-- History panel: dropdown value labels (SURFACE_LABELS / TIME_WINDOW_VALUES /
-- OUTCOME_VALUES / SORT_LABELS -- the display text for each dropdown's options)
L["All"] = "All"
L["Whisper"] = "Whisper"
L["Bnet whisper"] = "Bnet whisper"
L["Last hour"] = "Last hour"
L["Today"] = "Today"
L["Last 7 days"] = "Last 7 days"
L["Blocked"] = "Blocked"
L["Restored"] = "Restored"
L["Newest"] = "Newest"
L["Score"] = "Score"
L["Sender"] = "Sender"
-- History panel: list column header (the other three columns in this
-- header reuse Score/Sender/Time above)
L["Category"] = "Category"

-- History panel: chat-event channel fallback labels (CHAT_EVENT_LABELS).
-- Used only when entry.channelName wasn't captured live.
L["Say"] = "Say"
L["Yell"] = "Yell"
L["Emote"] = "Emote"
L["DND auto-response"] = "DND auto-response"
L["AFK auto-response"] = "AFK auto-response"
L["Channel"] = "Channel"

-- Config panel: window chrome
L["Sift \226\128\148 Config"] = "Sift \226\128\148 Config"

-- Config panel: Interface Options launcher stub (RegisterInterfaceOptions)
L["Sift Configuration"] = "Sift Configuration"
L["Open Sift Config..."] = "Open Sift Config..."

-- Config panel: remove-row tooltips (format strings -- the row's own text,
-- a sender label or a keyword, is a %s argument, never part of the key)
L["Take %s off the allowlist. Use Undo above to revert."] = "Take %s off the allowlist. Use Undo above to revert."
L["Take %s off the blocked-actors list."] = "Take %s off the blocked-actors list."
L["Take \"%s\" out of this list."] = "Take \"%s\" out of this list."
L["Remove from allowlist"] = "Remove from allowlist"
L["Remove blocked actor"] = "Remove blocked actor"
L["Remove phrase"] = "Remove phrase"

-- Config panel: left-nav section names and their hover tooltips (SECTIONS / NAV_TOOLTIPS)
L["Detection"] = "Detection"
L["Score threshold, mixed-script signal weight, anti-signal cap."] = "Score threshold, mixed-script signal weight, anti-signal cap."
L["Categories"] = "Categories"
L["Toggle each spam category between Active (block), Paused (log only), and Off (ignore)."] = "Toggle each spam category between Active (block), Paused (log only), and Off (ignore)."
L["Surfaces"] = "Surfaces"
L["Toggle each chat surface between Active, Paused, and Off. Also: filter bubbles."] = "Toggle each chat surface between Active, Paused, and Off. Also: filter bubbles."
L["Allowlist"] = "Allowlist"
L["Senders Sift will always trust. Add from History or import a saved list."] = "Senders Sift will always trust. Add from History or import a saved list."
L["Recently blocked actors. Manage repeat offenders."] = "Recently blocked actors. Manage repeat offenders."
L["Your own words and phrases to block, on top of Sift's filter."] = "Your own words and phrases to block, on top of Sift's filter."
L["Never Block"] = "Never Block"
L["Your own words and phrases that always come through, even past Sift's filter."] = "Your own words and phrases that always come through, even past Sift's filter."
L["Retained-history limit and clear control."] = "Retained-history limit and clear control."
L["UI"] = "UI"
L["Minimap launcher and panel-position resets."] = "Minimap launcher and panel-position resets."
L["Dev"] = "Dev"
L["Developer-only diagnostics and full settings reset."] = "Developer-only diagnostics and full settings reset."

-- Config panel: Detection section sliders and checkboxes
L["Block threshold"] = "Block threshold"
L["Messages scoring at or above this value are blocked. Higher = stricter."] = "Messages scoring at or above this value are blocked. Higher = stricter."
L["Anti-signal cap"] = "Anti-signal cap"
L["Maximum negative score one anti-signal (e.g. guild affiliation) can contribute. Limits how much a single trusted indicator offsets spam weight."] = "Maximum negative score one anti-signal (e.g. guild affiliation) can contribute. Limits how much a single trusted indicator offsets spam weight."
L["Mixed-script weight"] = "Mixed-script weight"
L["Score weight added when a message mixes Latin with another script (Cyrillic, etc.): the classic Unicode-confusable pattern. Set 0 to disable."] = "Score weight added when a message mixes Latin with another script (Cyrillic, etc.): the classic Unicode-confusable pattern. Set 0 to disable."
L["Reset"] = "Reset"
L["Use mixed-script detection"] = "Use mixed-script detection"
L["Enable Unicode-confusable script-mixing as a signal in scoring."] = "Enable Unicode-confusable script-mixing as a signal in scoring."
L["Flood window (seconds)"] = "Flood window (seconds)"
L["Throttle confirmed-spam repeats"] = "Throttle confirmed-spam repeats"
L["When the same sender repeats the same message on the same surface, the repeat is logged as one condensed history entry and counted as throttled. Only applies to messages already blocked as spam; it does not change what gets blocked."] = "When the same sender repeats the same message on the same surface, the repeat is logged as one condensed history entry and counted as throttled. Only applies to messages already blocked as spam; it does not change what gets blocked."

-- Config panel: per-surface / per-category pause rows (AddAxisPauseRow's
-- displayLabel dedupes against the History-panel entries above; stateBody
-- is new here because the surface/category wording differs from History's)
L["Active \194\183 detected spam on this surface is blocked from chat."] = "Active \194\183 detected spam on this surface is blocked from chat."
L["Active \194\183 messages in this category are blocked."] = "Active \194\183 messages in this category are blocked."
L["Paused \194\183 detected spam is logged to History but stays visible."] = "Paused \194\183 detected spam is logged to History but stays visible."
L["Off \194\183 this surface is not scanned at all."] = "Off \194\183 this surface is not scanned at all."
L["Off \194\183 this category is not scored against messages."] = "Off \194\183 this category is not scored against messages."

-- Config panel: Surfaces section
L["Filter bubbles"] = "Filter bubbles"
L["Hide blocked Say / Yell text from chat bubbles via a Blizzard cvar toggle. Auto-restores after each suppressed message and on logout."] = "Hide blocked Say / Yell text from chat bubbles via a Blizzard cvar toggle. Auto-restores after each suppressed message and on logout."

-- Config panel: Allowlist section
L["Search allowlist"] = "Search allowlist"
L["Type to match by sender name, realm, GUID, or source. Click Apply to filter the list below."] = "Type to match by sender name, realm, GUID, or source. Click Apply to filter the list below."
L["Apply"] = "Apply"
L["Apply the search box to the allowlist below and reset to page 1."] = "Apply the search box to the allowlist below and reset to page 1."
L["Export"] = "Export"
L["Export the entire allowlist to a text blob you can copy from a dialog."] = "Export the entire allowlist to a text blob you can copy from a dialog."
L["Import"] = "Import"
L["Paste a previously exported allowlist blob to merge entries into your current set."] = "Paste a previously exported allowlist blob to merge entries into your current set."
L["Add from History"] = "Add from History"
L["Enter as Name-Realm. The sender must already appear in your History. You can't allowlist arbitrary names, only ones Sift has actually seen."] = "Enter as Name-Realm. The sender must already appear in your History. You can't allowlist arbitrary names, only ones Sift has actually seen."
L["Add"] = "Add"
L["Add the Name-Realm in the box to the allowlist."] = "Add the Name-Realm in the box to the allowlist."
L["Undo"] = "Undo"
L["Restore the entry you just removed."] = "Restore the entry you just removed."
L["Prev"] = "Prev"
L["Show the previous page of allowlist entries."] = "Show the previous page of allowlist entries."
L["Next"] = "Next"
L["Show the next page of allowlist entries."] = "Show the next page of allowlist entries."

-- Config panel: Blocked section
L["Search blocked actors"] = "Search blocked actors"
L["Type to match by sender label or key. Click Apply to filter the list below."] = "Type to match by sender label or key. Click Apply to filter the list below."
L["Apply the search box to the blocked-actors list and reset to page 1."] = "Apply the search box to the blocked-actors list and reset to page 1."
L["Clear All"] = "Clear All"
L["Remove every blocked actor. Confirmation required."] = "Remove every blocked actor. Confirmation required."
L["Show the previous page of blocked actors."] = "Show the previous page of blocked actors."
L["Show the next page of blocked actors."] = "Show the next page of blocked actors."

-- Config panel: My Keywords / Never Block sections (KEYWORD_SECTIONS)
L["Block phrase"] = "Block phrase"
L["Type a word or phrase to block. Matching is forgiving about spacing and odd spellings."] = "Type a word or phrase to block. Matching is forgiving about spacing and odd spellings."
L["Allow phrase"] = "Allow phrase"
L["Type a word or phrase that should always come through. Matching works the same way as the block list."] = "Type a word or phrase that should always come through. Matching works the same way as the block list."
L["Search this list"] = "Search this list"
L["Type to match by phrase. Click Apply to filter the list below."] = "Type to match by phrase. Click Apply to filter the list below."
L["Apply the search box to the list below and reset to page 1."] = "Apply the search box to the list below and reset to page 1."
L["Remove All"] = "Remove All"
L["Remove every phrase in this list. Asks for confirmation first."] = "Remove every phrase in this list. Asks for confirmation first."
L["Add the phrase in the box to this list."] = "Add the phrase in the box to this list."
L["Show the previous page."] = "Show the previous page."
L["Show the next page."] = "Show the next page."

-- Config panel: History section
L["Maximum history entries"] = "Maximum history entries"
L["Cap retained History at this many entries. Oldest entries are trimmed first. Lifetime stats counters are unaffected."] = "Cap retained History at this many entries. Oldest entries are trimmed first. Lifetime stats counters are unaffected."
L["Account total"] = "Account total"
L["Maximum spam-history records retained across all characters combined. Lowering this trims oldest records account-wide on next login."] = "Maximum spam-history records retained across all characters combined. Lowering this trims oldest records account-wide on next login."
L["Clear History"] = "Clear History"
L["Delete all retained History entries. Lifetime stats counters are preserved. Confirmation required."] = "Delete all retained History entries. Lifetime stats counters are preserved. Confirmation required."

-- Config panel: UI section
L["Show minimap button"] = "Show minimap button"
L["Toggle the Sift launcher icon on the minimap."] = "Toggle the Sift launcher icon on the minimap."
L["Reset History Panel"] = "Reset History Panel"
L["Reset the History panel size and position to defaults (centered, 940 \195\151 560)."] = "Reset the History panel size and position to defaults (centered, 940 \195\151 560)."
L["Reset Config Panel"] = "Reset Config Panel"
L["Reset the Config panel size and position to defaults (centered, 700 \195\151 500)."] = "Reset the Config panel size and position to defaults (centered, 700 \195\151 500)."

-- Config panel: Dev section
L["Enable dev mode"] = "Enable dev mode"
L["Records recent chat from other players, whispers included, into your saved data so missed spam can be reviewed later. Also turns on extra logging and the /bdev diagnostic commands. Leave off unless you are helping test."] = "Records recent chat from other players, whispers included, into your saved data so missed spam can be reviewed later. Also turns on extra logging and the /bdev diagnostic commands. Leave off unless you are helping test."
L["Reset Settings"] = "Reset Settings"
L["Reset ALL settings to defaults. Does not touch History, Allowlist, or Blocked. Confirmation required."] = "Reset ALL settings to defaults. Does not touch History, Allowlist, or Blocked. Confirmation required."
L["Export FP fixtures"] = "Export FP fixtures"
L["Save the false-positive entries in History to a copy-paste window. Equivalent to /bdev fpx. Requires dev mode."] = "Save the false-positive entries in History to a copy-paste window. Equivalent to /bdev fpx. Requires dev mode."
L["Export FN candidates"] = "Export FN candidates"
L["Save the recent chat captured while dev mode is on to a copy-paste window for review. Equivalent to /bdev fnx. Requires dev mode."] = "Save the recent chat captured while dev mode is on to a copy-paste window for review. Equivalent to /bdev fnx. Requires dev mode."
L["Clear FN log"] = "Clear FN log"
L["Discard every captured false-negative candidate. Equivalent to /bdev fnx clear. Confirmation required."] = "Discard every captured false-negative candidate. Equivalent to /bdev fnx clear. Confirmation required."

-- Config panel: resize handle
L["Resize panel"] = "Resize panel"
L["Drag to resize the Config panel."] = "Drag to resize the Config panel."
L["Minimum size: 600 \195\151 400."] = "Minimum size: 600 \195\151 400."

-- Init.lua: /bdev pseudolocale command
L["pseudo-locale applied. Open a Sift panel now; a panel you already opened this session needs /reload, then run this again first."] = "pseudo-locale applied. Open a Sift panel now; a panel you already opened this session needs /reload, then run this again first."
L["pseudo-locale is already active this session. /reload to restore English, then run it again."] = "pseudo-locale is already active this session. /reload to restore English, then run it again."
L["the pseudolocale command is only available when devMode is enabled."] = "the pseudolocale command is only available when devMode is enabled."
L["pseudo-locale tool is unavailable (locale table not loaded)."] = "pseudo-locale tool is unavailable (locale table not loaded)."
