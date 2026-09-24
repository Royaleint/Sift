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
L["Mark this message as blocked. It already appeared in chat and stays there, but Sift opens Blizzard's spam report window for it when it can."] = "Mark this message as blocked. It already appeared in chat and stays there, but Sift opens Blizzard's spam report window for it when it can."
L["Add this sender to the allowlist. Future messages from them bypass scanning."] = "Add this sender to the allowlist. Future messages from them bypass scanning."
L["Undo this block. The message won't reappear in chat, only here in History, and you can no longer report it."] = "Undo this block. The message won't reappear in chat, only here in History, and you can no longer report it."
L["Report Spam"] = "Report Spam"
L["Open Blizzard's spam report window for this message."] = "Open Blizzard's spam report window for this message."
L["Undo this block. The message won't reappear in chat, and the sender is already on the allowlist."] = "Undo this block. The message won't reappear in chat, and the sender is already on the allowlist."
L["Undo this block and add the sender to the allowlist, so Sift stops checking their messages. The message won't reappear in chat."] = "Undo this block and add the sender to the allowlist, so Sift stops checking their messages. The message won't reappear in chat."
L["Undo this block without changing the allowlist. The message won't reappear in chat."] = "Undo this block without changing the allowlist. The message won't reappear in chat."
L["Undo this block. The message won't reappear in chat, and this surface can't be allowlisted."] = "Undo this block. The message won't reappear in chat, and this surface can't be allowlisted."

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
-- History panel: sender-history footer label (SFT-104). Not routed through
-- L[] at its call site (string.format builds it directly), so it carries no
-- tracked entry here -- pre-existing gap, not introduced by this change.

-- History panel: char/account stats-scope button tooltips
L["Show detection stats for this character only."] = "Show detection stats for this character only."
L["Show detection stats summed across every character on this account."] = "Show detection stats summed across every character on this account."

-- History panel: stat-tile tooltips (STATS_TILE_TOOLTIPS title/body pairs)
L["Detected"] = "Detected"
L["Lifetime count of messages Sift caught, including messages from players you blocked yourself. Includes blocked, pass-thru, and restored entries."] = "Lifetime count of messages Sift caught, including messages from players you blocked yourself. Includes blocked, pass-thru, and restored entries."
L["Lifetime count of messages Sift blocked. Messages left in chat because a category or surface was Paused are not counted, unless you later used Block retroactively on them."] = "Lifetime count of messages Sift blocked. Messages left in chat because a category or surface was Paused are not counted, unless you later used Block retroactively on them."
L["Pass-thru"] = "Pass-thru"
L["Scored as spam but left visible because the surface or category was set to Paused. Still logged to History for review."] = "Scored as spam but left visible because the surface or category was set to Paused. Still logged to History for review."
L["Blocks you have undone in History. These count toward the false-positive rate."] = "Blocks you have undone in History. These count toward the false-positive rate."
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
L["Restrict the list to detections from one chat surface. \"All\" clears the filter."] = "Restrict the list to detections from one chat surface. \"All\" clears the filter."
L["Time"] = "Time"
L["Restrict the list to detections inside a recent time window."] = "Restrict the list to detections inside a recent time window."
L["Outcome"] = "Outcome"
L["Blocked means hidden from chat. Restored means you undid the block. Pass-thru means it looked like spam but was left in chat because its surface or category was Paused."] = "Blocked means hidden from chat. Restored means you undid the block. Pass-thru means it looked like spam but was left in chat because its surface or category was Paused."
L["Sort"] = "Sort"
L["Newest first \194\183 by Score (highest first) \194\183 by Sender (groups repeat offenders)."] = "Newest first \194\183 by Score (highest first) \194\183 by Sender (groups repeat offenders)."
L["Reload the list to show messages Sift caught since you opened this window, or after clearing History."] = "Reload the list to show messages Sift caught since you opened this window, or after clearing History."

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
L["Remove"] = "Remove"

-- Config panel: left-nav section names and their hover tooltips (SECTIONS / NAV_TOOLTIPS)
L["Detection"] = "Detection"
L["How strict Sift is when deciding what counts as spam. Also covers look-alike letters, wording that lowers a message's score, and repeated messages."] = "How strict Sift is when deciding what counts as spam. Also covers look-alike letters, wording that lowers a message's score, and repeated messages."
L["Categories"] = "Categories"
L["Toggle each spam category between Active (block), Paused (log only), and Off (ignore)."] = "Toggle each spam category between Active (block), Paused (log only), and Off (ignore)."
L["Surfaces"] = "Surfaces"
L["Choose how Sift handles each kind of chat: Chat, Whisper, and Bnet whisper. Also has the option to hide chat bubbles for blocked messages."] = "Choose how Sift handles each kind of chat: Chat, Whisper, and Bnet whisper. Also has the option to hide chat bubbles for blocked messages."
L["Allowlist"] = "Allowlist"
L["Players whose messages Sift doesn't check. Add them from History or import a saved list. If you block one of them yourself, their messages are still hidden."] = "Players whose messages Sift doesn't check. Add them from History or import a saved list. If you block one of them yourself, their messages are still hidden."
L["Players Sift has blocked before, plus anyone you blocked yourself. Sift is a little stricter with messages from players on this list."] = "Players Sift has blocked before, plus anyone you blocked yourself. Sift is a little stricter with messages from players on this list."
L["Your own words and phrases to block, on top of Sift's filter."] = "Your own words and phrases to block, on top of Sift's filter."
L["Never Block"] = "Never Block"
L["Your own words and phrases that let a message through, even past Sift's filter. Messages from players you blocked yourself are still hidden."] = "Your own words and phrases that let a message through, even past Sift's filter. Messages from players you blocked yourself are still hidden."
L["How much History Sift keeps, your lifetime totals, and the button to clear it."] = "How much History Sift keeps, your lifetime totals, and the button to clear it."
L["UI"] = "UI"
L["Show or hide the minimap button, and reset the Config and History panels to their default size and position."] = "Show or hide the minimap button, and reset the Config and History panels to their default size and position."
L["Dev"] = "Dev"
L["Developer-only diagnostics and full settings reset."] = "Developer-only diagnostics and full settings reset."

-- Config panel: Detection section sliders and checkboxes
L["Block threshold"] = "Block threshold"
L["Messages that score at or above this number are blocked. A lower number blocks more messages, and a higher number blocks fewer."] = "Messages that score at or above this number are blocked. A lower number blocks more messages, and a higher number blocks fewer."
L["Anti-signal cap"] = "Anti-signal cap"
L["Some wording makes a message less likely to be spam and lowers its score. This sets the most that wording can lower a score, all together. Closer to 0 makes Sift stricter."] = "Some wording makes a message less likely to be spam and lowers its score. This sets the most that wording can lower a score, all together. Closer to 0 makes Sift stricter."
L["Mixed-script weight"] = "Mixed-script weight"
L["Adds this much to the score of a message that already looks like spam when its words mix alphabets, such as Latin letters swapped for look-alike Cyrillic or Greek ones. Set to 0 to turn this off."] = "Adds this much to the score of a message that already looks like spam when its words mix alphabets, such as Latin letters swapped for look-alike Cyrillic or Greek ones. Set to 0 to turn this off."
L["Reset"] = "Reset"
L["Use mixed-script detection"] = "Use mixed-script detection"
L["Watch for words that mix alphabets, such as Latin letters swapped for look-alike Cyrillic ones. When this is off, Mixed-script weight has no effect."] = "Watch for words that mix alphabets, such as Latin letters swapped for look-alike Cyrillic ones. When this is off, Mixed-script weight has no effect."
L["Flood window (seconds)"] = "Flood window (seconds)"
L["Throttle confirmed-spam repeats"] = "Throttle confirmed-spam repeats"
L["When the same sender repeats spam Sift already caught, in the same kind of chat, the repeat is counted under Throttled in the History stats. Each repeat still gets its own History entry. This never changes what gets blocked."] = "When the same sender repeats spam Sift already caught, in the same kind of chat, the repeat is counted under Throttled in the History stats. Each repeat still gets its own History entry. This never changes what gets blocked."

-- Config panel: per-surface / per-category pause rows (AddAxisPauseRow's
-- displayLabel dedupes against the History-panel entries above; the Paused
-- body now reuses the History-panel key above verbatim)
L["Active \194\183 detected spam on this surface is blocked from chat."] = "Active \194\183 detected spam on this surface is blocked from chat."
L["Active \194\183 messages in this category are blocked."] = "Active \194\183 messages in this category are blocked."
L["Off \194\183 this surface is not scanned at all."] = "Off \194\183 this surface is not scanned at all."
L["Off \194\183 this category is not scored against messages."] = "Off \194\183 this category is not scored against messages."

-- Config panel: Surfaces section
L["Filter bubbles"] = "Filter bubbles"
L["Also hides the chat bubble for blocked Say and Yell messages. To do this, Sift briefly turns off the game's chat bubbles, then turns them back on with the next chat message and when you log out."] = "Also hides the chat bubble for blocked Say and Yell messages. To do this, Sift briefly turns off the game's chat bubbles, then turns them back on with the next chat message and when you log out."

-- Config panel: Allowlist section
L["Search allowlist"] = "Search allowlist"
L["Type part of a name or realm, then click Apply to filter the list below. You can also search the word shown under each name: manual, history, or import."] = "Type part of a name or realm, then click Apply to filter the list below. You can also search the word shown under each name: manual, history, or import."
L["Apply"] = "Apply"
L["Apply the search box to the allowlist below and reset to page 1."] = "Apply the search box to the allowlist below and reset to page 1."
L["Export"] = "Export"
L["Open a window with your entire allowlist as text you can copy and save."] = "Open a window with your entire allowlist as text you can copy and save."
L["Import"] = "Import"
L["Paste in a previously exported allowlist to add those entries to your current one."] = "Paste in a previously exported allowlist to add those entries to your current one."
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
L["Type part of a name to filter the list below, then click Apply."] = "Type part of a name to filter the list below, then click Apply."
L["Apply the search box to the blocked-actors list and reset to page 1."] = "Apply the search box to the blocked-actors list and reset to page 1."
L["Clear All"] = "Clear All"
L["Remove every blocked actor. Confirmation required."] = "Remove every blocked actor. Confirmation required."
L["Show the previous page of blocked actors."] = "Show the previous page of blocked actors."
L["Show the next page of blocked actors."] = "Show the next page of blocked actors."

-- Config panel: My Keywords / Never Block sections (KEYWORD_SECTIONS)
L["Block phrase"] = "Block phrase"
L["Type a word or phrase to block. Matching is forgiving about spacing and odd spellings."] = "Type a word or phrase to block. Matching is forgiving about spacing and odd spellings."
L["Allow phrase"] = "Allow phrase"
L["Type a word or phrase that should always come through, unless you blocked the sender yourself. Matching works the same way as My Keywords."] = "Type a word or phrase that should always come through, unless you blocked the sender yourself. Matching works the same way as My Keywords."
L["Search"] = "Search"
L["Type to match by phrase. Click Apply to filter the list below."] = "Type to match by phrase. Click Apply to filter the list below."
L["Apply the search box to the list below and reset to page 1."] = "Apply the search box to the list below and reset to page 1."
L["Remove All"] = "Remove All"
L["Remove every phrase in this list. Asks for confirmation first."] = "Remove every phrase in this list. Asks for confirmation first."
L["Add the phrase in the box to this list."] = "Add the phrase in the box to this list."
L["Show the previous page."] = "Show the previous page."
L["Show the next page."] = "Show the next page."

-- Config panel: History section
L["Total detections"] = "Total detections"
L["Every message Sift has caught, including messages from players you blocked yourself, ones left in chat because a category or surface was Paused, and ones you restored. Clearing History does not reset this."] = "Every message Sift has caught, including messages from players you blocked yourself, ones left in chat because a category or surface was Paused, and ones you restored. Clearing History does not reset this."
L["Total blocks"] = "Total blocks"
L["Spam messages Sift hid from chat on this character. Messages left in chat because a category or surface was Paused are not counted, unless you later used Block retroactively on them."] = "Spam messages Sift hid from chat on this character. Messages left in chat because a category or surface was Paused are not counted, unless you later used Block retroactively on them."
L["Total restores"] = "Total restores"
L["Blocked messages you restored in History on this character."] = "Blocked messages you restored in History on this character."
L["Maximum history entries"] = "Maximum history entries"
L["The most History entries Sift keeps for each character. The oldest are removed first, and lifetime totals are not affected."] = "The most History entries Sift keeps for each character. The oldest are removed first, and lifetime totals are not affected."
L["Account total"] = "Account total"
L["The most History entries Sift keeps across all your characters combined. If lowering it would remove entries, Sift asks first and then trims the oldest right away. The limit is also checked each time you log in."] = "The most History entries Sift keeps across all your characters combined. If lowering it would remove entries, Sift asks first and then trims the oldest right away. The limit is also checked each time you log in."
L["Clear History"] = "Clear History"
L["Delete all retained History entries. Lifetime stats counters are preserved. Confirmation required."] = "Delete all retained History entries. Lifetime stats counters are preserved. Confirmation required."

-- Config panel: UI section
L["Show minimap button"] = "Show minimap button"
L["Toggle the Sift launcher icon on the minimap."] = "Toggle the Sift launcher icon on the minimap."
L["Reset History Panel"] = "Reset History Panel"
L["Moves this panel back to the middle of the screen at its normal size. History and Config share one panel, so this resets both."] = "Moves this panel back to the middle of the screen at its normal size. History and Config share one panel, so this resets both."
L["Reset Config Panel"] = "Reset Config Panel"
L["Moves this panel back to the middle of the screen at its normal size. Config and History share one panel, so this does the same as Reset History Panel."] = "Moves this panel back to the middle of the screen at its normal size. Config and History share one panel, so this does the same as Reset History Panel."

-- Config panel: Dev section
L["Enable dev mode"] = "Enable dev mode"
L["Records recent chat from other players, whispers included, into your saved data so missed spam can be reviewed later. Also turns on extra logging and the /bdev diagnostic commands. Leave off unless you are helping test."] = "Records recent chat from other players, whispers included, into your saved data so missed spam can be reviewed later. Also turns on extra logging and the /bdev diagnostic commands. Leave off unless you are helping test."
L["Reset Settings"] = "Reset Settings"
L["Puts every setting back to its default, and asks first. Your Allowlist, Blocked list, My Keywords, and Never Block are kept, but if you had raised Maximum history entries or Account total, the oldest History entries are removed right away."] = "Puts every setting back to its default, and asks first. Your Allowlist, Blocked list, My Keywords, and Never Block are kept, but if you had raised Maximum history entries or Account total, the oldest History entries are removed right away."
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

-- FirstRunChooser panel (SFT-099). LIVE = false today (FirstRunChooser.lua),
-- so reached only through /bdev chooser -- see that module for the invariant.
L["Sift: choose what to hide"] = "Sift: choose what to hide"
L["Pick what Sift hides. You can change these any time with /sift config."] = "Pick what Sift hides. You can change these any time with /sift config."
L["Keep current settings"] = "Keep current settings"
L["%s (paused)"] = "%s (paused)"
L["Filter choices not saved. Sift will ask again next login; change them any time with /sift config."] = "Filter choices not saved. Sift will ask again next login; change them any time with /sift config."

-- Init.lua: /bdev pseudolocale command
L["pseudo-locale applied. Open a Sift panel now; a panel you already opened this session needs /reload, then run this again first."] = "pseudo-locale applied. Open a Sift panel now; a panel you already opened this session needs /reload, then run this again first."
L["pseudo-locale is already active this session. /reload to restore English, then run it again."] = "pseudo-locale is already active this session. /reload to restore English, then run it again."
L["the pseudolocale command is only available when devMode is enabled."] = "the pseudolocale command is only available when devMode is enabled."
L["pseudo-locale tool is unavailable (locale table not loaded)."] = "pseudo-locale tool is unavailable (locale table not loaded)."
