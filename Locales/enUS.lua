-- Base locale. Creates the shared L table and an identity entry for every
-- player-visible string that reaches an L[] lookup, directly or through a table
-- or helper parameter. An unlisted key still reads back unchanged.
--
-- A future translation file loads after this one and overrides individual
-- values without touching any call site, e.g. Locales/deDE.lua:
--
--   if GetLocale() ~= "deDE" then return end
--   local _, NS = ...
--   local L = NS.L
--   L["Restore"] = "Wiederherstellen"

local _, NS = ...

-- Pass-through only; never stores into L, or player-supplied text (sender
-- names, keywords) concatenated into a key would accumulate in the table.
local L = setmetatable({}, {
  __index = function(_, k) return k end,
})
NS.L = L

-- History panel: window chrome and section headers
L["Sift History"] = "Sift History"
L["DETECTION STATS"] = "DETECTION STATS"
L["BY SURFACE"] = "BY SURFACE"
L["BY CATEGORY"] = "BY CATEGORY"
L["OTHER"] = "OTHER"
L["Character"] = "Character"
L["Account"] = "Account"
L["Refresh"] = "Refresh"
L["History list is unavailable in this client."] = "History list is unavailable in this client."
L["Left-click to toggle the History panel."] = "Left-click to toggle the History panel."
L["Right-click for the Pause-surface menu and config."] = "Right-click for the Pause-surface menu and config."

-- History panel: category / stat-tile / pause-pill display labels, reached
-- via table lookups keyed by internal category or surface names
L["Gold selling"] = "Gold selling"
L["My Keywords"] = "My Keywords"
L["Boosting"] = "Boosting"
L["Carrying"] = "Carrying"
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
-- category (CATEGORY_BADGE_LABELS). Flood reuses "Spam wave" and Throttle
-- reuses "Repeat", both below.
L["Blocked sender"] = "Blocked sender"
L["Manual block"] = "Manual block"

-- History panel: row badges and detail-pane status text
L["You"] = "You"
L["Spam wave"] = "Spam wave"
L["Repeat"] = "Repeat"
L["Repeats"] = "Repeats"
L["Bubbles suppressed"] = "Bubbles suppressed"
L["Spam wave (recent)"] = "Spam wave (recent)"
L["contains item link"] = "contains item link"
L["PASSED THROUGH"] = "PASSED THROUGH"
L["surface paused"] = "surface paused"
L["blocked by you"] = "blocked by you"
L["caught by your keyword"] = "caught by your keyword"
L["%s entries filtered out."] = "%s entries filtered out."
L["%s lifetime detections; retained history is empty."] = "%s lifetime detections; retained history is empty."
L["0 detections recorded."] = "0 detections recorded."
L["In History: %d   \194\183   First seen: %s   \194\183   Last seen: %s"] = "In History: %d   \194\183   First seen: %s   \194\183   Last seen: %s"
L["No blocks yet."] = "No blocks yet."
L["Sift is watching."] = "Sift is watching."
L["0 blocks recorded."] = "0 blocks recorded."
L["%ds"] = "%ds"
L["%dm"] = "%dm"
L["%dh"] = "%dh"
L["%dd"] = "%dd"
L["(pass-thru)"] = "(pass-thru)"
L["(truncated)"] = "(truncated)"

-- History panel: hover tooltips for the row badges, column headers,
-- breakdown chips, legend swatches, and stats lines.
L["How long ago Sift caught this message. Entries older than 90 days show the date instead."] = "How long ago Sift caught this message. Entries older than 90 days show the date instead."
L["The player who sent the message. A check mark means you restored it, and (pass-thru) means it was left in chat."] = "The player who sent the message. A check mark means you restored it, and (pass-thru) means it was left in chat."
L["The kind of spam Sift found. Spam wave means a flood of the same spam, and You means you blocked the sender yourself."] = "The kind of spam Sift found. Spam wave means a flood of the same spam, and You means you blocked the sender yourself."
L["How suspicious the message looked to Sift. Higher means more suspicious."] = "How suspicious the message looked to Sift. Higher means more suspicious."
L["You blocked this player yourself with Block (Sift) on their right-click menu."] = "You blocked this player yourself with Block (Sift) on their right-click menu."
L["Sift caught this as part of a spam wave, sent by one player or many."] = "Sift caught this as part of a spam wave, sent by one player or many."
L["Kind of spam not saved"] = "Kind of spam not saved"
L["Sift caught this but didn't save which kind of spam it was. Older versions of Sift sometimes left that out."] = "Sift caught this but didn't save which kind of spam it was. Older versions of Sift sometimes left that out."
L["A kind of spam Sift still catches, but it no longer has its own button to pause it or filter by it."] = "A kind of spam Sift still catches, but it no longer has its own button to pause it or filter by it."
L["Part of why Sift caught this message."] = "Part of why Sift caught this message."
L["This player is on your Blocked list."] = "This player is on your Blocked list."
L["You blocked this player yourself, so Sift caught this message no matter what it said."] = "You blocked this player yourself, so Sift caught this message no matter what it said."
L["This message was part of a spam wave."] = "This message was part of a spam wave."
L["This message repeated one Sift had already caught from the same sender."] = "This message repeated one Sift had already caught from the same sender."
L["Gray marks messages Sift caught as part of a spam wave, with no spam category of their own. Players you blocked yourself, and entries marked ?, also show in gray."] = "Gray marks messages Sift caught as part of a spam wave, with no spam category of their own. Players you blocked yourself, and entries marked ?, also show in gray."
L["Lifetime detections split by where they came from: Chat, Whisper, and Bnet whisper. Shows this character or the whole account, depending on the Character or Account button."] = "Lifetime detections split by where they came from: Chat, Whisper, and Bnet whisper. Shows this character or the whole account, depending on the Character or Account button."
L["Lifetime detections split by spam category, for this character or the whole account. A gray number means that category is currently Paused or Off."] = "Lifetime detections split by spam category, for this character or the whole account. A gray number means that category is currently Paused or Off."
L["Repeats counts messages that repeat spam Sift already caught from the same sender. Bubbles suppressed counts the times Sift hid a chat bubble for a blocked Say or Yell. Spam wave (recent) counts blocked messages still in your History that were caught only as part of a spam wave, so it drops as old entries are removed."] = "Repeats counts messages that repeat spam Sift already caught from the same sender. Bubbles suppressed counts the times Sift hid a chat bubble for a blocked Say or Yell. Spam wave (recent) counts blocked messages still in your History that were caught only as part of a spam wave, so it drops as old entries are removed."

-- History panel: detail-pane action buttons
L["\226\156\147 Restored"] = "\226\156\147 Restored"
L["Allowlisted"] = "Allowlisted"
L["Block retroactively"] = "Block retroactively"
L["Always allow"] = "Always allow"
L["Restore"] = "Restore"
L["Restore + Always allow"] = "Restore + Always allow"
L["Restore only"] = "Restore only"
L["Sender name (Ctrl+C to copy):"] = "Sender name (Ctrl+C to copy):"
L["%s removed your manual block on %s."] = "%s removed your manual block on %s."
L["that player"] = "that player"
L["Filter by this sender"] = "Filter by this sender"
L["Copy sender name"] = "Copy sender name"

-- History panel: detail-pane action tooltips (RenderActions' tipTitle /
-- tipBody, read by ActionOnEnter through L[self.tipTitle] / L[self.tipBody])
L["This block has already been undone. No further action needed."] = "This block has already been undone. No further action needed."
L["This sender is on the allowlist. Sift won't block messages from them."] = "This sender is on the allowlist. Sift won't block messages from them."
L["Mark this message as blocked. It already appeared in chat and stays there, but Sift opens Blizzard's report window for it when it can."] = "Mark this message as blocked. It already appeared in chat and stays there, but Sift opens Blizzard's report window for it when it can."
L["Add this sender to the allowlist. Sift won't block messages from them."] = "Add this sender to the allowlist. Sift won't block messages from them."
L["Undo this block. The message won't reappear in chat, only here in History, and you can no longer report it."] = "Undo this block. The message won't reappear in chat, only here in History, and you can no longer report it."
L["Report"] = "Report"
L["Open Blizzard's report window for this message."] = "Open Blizzard's report window for this message."
L["Undo this block. The message won't reappear in chat, and the sender is already on the allowlist."] = "Undo this block. The message won't reappear in chat, and the sender is already on the allowlist."
L["Undo this block and add the sender to the allowlist. The message won't reappear in chat."] = "Undo this block and add the sender to the allowlist. The message won't reappear in chat."
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
L["Off \194\183 Sift won't block messages on this surface."] = "Off \194\183 Sift won't block messages on this surface."

-- History panel: char/account stats-scope button tooltips
L["Show detection stats for this character only."] = "Show detection stats for this character only."
L["Show detection stats summed across every character on this account."] = "Show detection stats summed across every character on this account."

-- History panel: stat-tile tooltips (STATS_TILE_TOOLTIPS title/body pairs)
L["Detected"] = "Detected"
L["Lifetime count of messages Sift caught, including messages from players you blocked yourself. Includes blocked, pass-thru, and restored entries."] = "Lifetime count of messages Sift caught, including messages from players you blocked yourself. Includes blocked, pass-thru, and restored entries."
L["Lifetime count of messages Sift blocked. Messages left in chat because a category or surface was Paused are not counted, unless you later used Block retroactively on them."] = "Lifetime count of messages Sift blocked. Messages left in chat because a category or surface was Paused are not counted, unless you later used Block retroactively on them."
L["Pass-thru"] = "Pass-thru"
L["Caught as spam but left in chat because the surface or category was set to Paused. Still logged to History for review."] = "Caught as spam but left in chat because the surface or category was set to Paused. Still logged to History for review."
L["Blocks you have undone in History. These count toward the false-positive rate."] = "Blocks you have undone in History. These count toward the false-positive rate."
L["False positives"] = "False positives"
L["Restored \195\183 Blocked. A rough false-positive rate. Lower is better."] = "Restored \195\183 Blocked. A rough false-positive rate. Lower is better."

-- History panel: category filter chips (CHIP_FULL_NAMES + the two hover bodies)
L["Gold selling (real-money trading)"] = "Gold selling (real-money trading)"
L["Boosting (paid leveling and other services)"] = "Boosting (paid leveling and other services)"
L["Carrying (paid raid, Mythic+, and dungeon runs)"] = "Carrying (paid raid, Mythic+, and dungeon runs)"
L["My Keywords (phrases you added yourself)"] = "My Keywords (phrases you added yourself)"
L["Currently included in the list. Click to hide entries in this category."] = "Currently included in the list. Click to hide entries in this category."
L["Currently hidden from the list. Click to show entries in this category."] = "Currently hidden from the list. Click to show entries in this category."

-- History panel: tab buttons, filter dropdowns, and their tooltips
L["History"] = "History"
L["View blocked, restored, and pass-thru detections."] = "View blocked, restored, and pass-thru detections."
L["Config"] = "Config"
L["Adjust blocking, categories, surfaces, allowlist, and history settings."] = "Adjust blocking, categories, surfaces, allowlist, and history settings."
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
L["|cff58a0ffFiltering by:|r %s"] = "|cff58a0ffFiltering by:|r %s"

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
L["Sift Config"] = "Sift Config"
L["Close"] = "Close"

-- Config panel: Interface Options launcher stub (RegisterInterfaceOptions)
L["Sift Configuration"] = "Sift Configuration"
L["Open Sift Config..."] = "Open Sift Config..."

-- Config panel: remove-row tooltips (format strings -- the row's own text,
-- a sender label or a keyword, is a %s argument, never part of the key)
L["Take %s off the allowlist. Use Undo above to revert."] = "Take %s off the allowlist. Use Undo above to revert."
L["Take %s off the Blocked list."] = "Take %s off the Blocked list."
L["Take \"%s\" out of this list."] = "Take \"%s\" out of this list."
L["Remove"] = "Remove"

-- Config panel: left-nav section names and their hover tooltips (SECTIONS / NAV_TOOLTIPS)
L["Detection"] = "Detection"
L["How readily Sift blocks spam, and how it handles spam waves."] = "How readily Sift blocks spam, and how it handles spam waves."
L["Categories"] = "Categories"
L["Toggle each spam category between Active (block), Paused (log only), and Off (ignore)."] = "Toggle each spam category between Active (block), Paused (log only), and Off (ignore)."
L["Surfaces"] = "Surfaces"
L["Choose how Sift handles each kind of chat: Chat, Whisper, and Bnet whisper. Also has the option to hide chat bubbles for blocked messages."] = "Choose how Sift handles each kind of chat: Chat, Whisper, and Bnet whisper. Also has the option to hide chat bubbles for blocked messages."
L["Allowlist"] = "Allowlist"
L["Players whose messages Sift won't block. Add them from History or import a saved list. If you also block one of them yourself, your block wins."] = "Players whose messages Sift won't block. Add them from History or import a saved list. If you also block one of them yourself, your block wins."
L["Players Sift has blocked before, plus anyone you blocked yourself."] = "Players Sift has blocked before, plus anyone you blocked yourself."
L["Your own words and phrases to block, on top of Sift's filter."] = "Your own words and phrases to block, on top of Sift's filter."
L["Never Block"] = "Never Block"
L["Your own words and phrases that let a message through, even past Sift's filter. They don't override players you blocked yourself."] = "Your own words and phrases that let a message through, even past Sift's filter. They don't override players you blocked yourself."
L["How much History Sift keeps, your lifetime totals, and the button to clear it."] = "How much History Sift keeps, your lifetime totals, and the button to clear it."
L["UI"] = "UI"
L["Show or hide the minimap button, reset the Config and History panels to their default size and position, or put every setting back to its default."] = "Show or hide the minimap button, reset the Config and History panels to their default size and position, or put every setting back to its default."

-- Config panel: Detection section sliders
L["Block threshold"] = "Block threshold"
L["How sure Sift must be before it blocks a message. A lower number blocks more messages, and a higher number blocks fewer."] = "How sure Sift must be before it blocks a message. A lower number blocks more messages, and a higher number blocks fewer."
L["Reset"] = "Reset"
L["Spam wave window (seconds)"] = "Spam wave window (seconds)"
L["Reset this setting to its default (%s)."] = "Reset this setting to its default (%s)."
L["How long Sift watches for the same spam showing up again and again. A longer window catches slower spam waves, and a shorter one only catches quick bursts. Leave at %d unless spam waves are getting through."] = "How long Sift watches for the same spam showing up again and again. A longer window catches slower spam waves, and a shorter one only catches quick bursts. Leave at %d unless spam waves are getting through."
L["Choose how readily Sift blocks spam."] = "Choose how readily Sift blocks spam."

-- Config panel: per-surface / per-category pause rows (AddAxisPauseRow's
-- displayLabel dedupes against the History-panel entries above; the Paused
-- body reuses the History-panel key above verbatim)
L["Active \194\183 detected spam on this surface is blocked from chat."] = "Active \194\183 detected spam on this surface is blocked from chat."
L["Active \194\183 messages in this category are blocked."] = "Active \194\183 messages in this category are blocked."
L["Off \194\183 Sift won't block anything on this surface."] = "Off \194\183 Sift won't block anything on this surface."
L["Off \194\183 Sift ignores this category."] = "Off \194\183 Sift ignores this category."

-- Config panel: Surfaces section
L["Filter bubbles"] = "Filter bubbles"
L["Also hides the chat bubble for blocked Say and Yell messages. To do this, Sift briefly turns off the game's chat bubbles, then turns them back on with the next chat message and when you log out."] = "Also hides the chat bubble for blocked Say and Yell messages. To do this, Sift briefly turns off the game's chat bubbles, then turns them back on with the next chat message and when you log out."
L["Three states per category: Active (block) / Paused (detect + log, don't hide) / Off (ignore)."] = "Three states per category: Active (block) / Paused (detect + log, don't hide) / Off (ignore)."
L["Three states per surface: Active (block) / Paused (detect + log, don't hide) / Off (do nothing)."] = "Three states per surface: Active (block) / Paused (detect + log, don't hide) / Off (do nothing)."

-- Config panel: Allowlist section
L["Type part of a name or realm, then click Apply to filter the list below. You can also search the word shown under each name: manual, history, or import."] = "Type part of a name or realm, then click Apply to filter the list below. You can also search the word shown under each name: manual, history, or import."
L["Type part of a name, then click Apply to filter the list below. You can also search the word shown under each name: manual, history, or import."] = "Type part of a name, then click Apply to filter the list below. You can also search the word shown under each name: manual, history, or import."
L["Apply"] = "Apply"
L["Apply the search box to the allowlist below and reset to page 1."] = "Apply the search box to the allowlist below and reset to page 1."
L["Export"] = "Export"
L["Open a window with your entire allowlist as text you can copy and save."] = "Open a window with your entire allowlist as text you can copy and save."
L["Import"] = "Import"
L["Paste in a previously exported allowlist to add those entries to your current one."] = "Paste in a previously exported allowlist to add those entries to your current one."
L["Add from History"] = "Add from History"
L["Enter as Name-Realm. The sender must already appear in your History. You can't allowlist arbitrary names, only ones Sift has actually seen."] = "Enter as Name-Realm. The sender must already appear in your History. You can't allowlist arbitrary names, only ones Sift has actually seen."
L["Enter the player's full name, first name and surname. The sender must already appear in your History. You can't allowlist arbitrary names, only ones Sift has actually seen."] = "Enter the player's full name, first name and surname. The sender must already appear in your History. You can't allowlist arbitrary names, only ones Sift has actually seen."
L["Add"] = "Add"
L["Add the Name-Realm in the box to the allowlist."] = "Add the Name-Realm in the box to the allowlist."
L["Add the player named in the box to the allowlist."] = "Add the player named in the box to the allowlist."
L["Undo"] = "Undo"
L["Restore the entry you just removed."] = "Restore the entry you just removed."
L["Prev"] = "Prev"
L["Show the previous page of allowlist entries."] = "Show the previous page of allowlist entries."
L["Next"] = "Next"
L["Show the next page of allowlist entries."] = "Show the next page of allowlist entries."
L["Enter a sender by their full name."] = "Enter a sender by their full name."
L["Sift can only manually allow players already present in History."] = "Sift can only manually allow players already present in History."
L["Enter a sender as Name-Realm."] = "Enter a sender as Name-Realm."
L["Allowlist API is unavailable."] = "Allowlist API is unavailable."
L[" Manual block removed."] = " Manual block removed."
L["Added %s."] = "Added %s."
L["%s is already allowlisted."] = "%s is already allowlisted."
L["Removed %s."] = "Removed %s."
L["Restored %s."] = "Restored %s."
L["Import text is empty."] = "Import text is empty."
L["Line %s is not key=value."] = "Line %s is not key=value."
L["Duplicate format line."] = "Duplicate format line."
L["Duplicate version line."] = "Duplicate version line."
L["Duplicate exportedAt line."] = "Duplicate exportedAt line."
L["Line %s must have 6 entry fields."] = "Line %s must have 6 entry fields."
L["Line %s has an invalid GUID."] = "Line %s has an invalid GUID."
L["Line %s repeats a GUID."] = "Line %s repeats a GUID."
L["Line %s has invalid name fields."] = "Line %s has invalid name fields."
L["Line %s has an invalid source."] = "Line %s has an invalid source."
L["Line %s has invalid addedAt."] = "Line %s has invalid addedAt."
L["Line %s has invalid lastSeenAt."] = "Line %s has invalid lastSeenAt."
L["Line %s has an unknown key."] = "Line %s has an unknown key."
L["Import format must be Sift-allowlist."] = "Import format must be Sift-allowlist."
L["Import version must be 1."] = "Import version must be 1."
L["exportedAt must be positive."] = "exportedAt must be positive."
L["Import contains no entries."] = "Import contains no entries."
L["Imported %s entries%s%s."] = "Imported %s entries%s%s."
L["; skipped %s"] = "; skipped %s"
L["; lifted %s manual blocks"] = "; lifted %s manual blocks"
L["Import includes entries that are already allowlisted. Overwrite matching entries?"] = "Import includes entries that are already allowlisted. Overwrite matching entries?"
L["Overwrite"] = "Overwrite"
L["%s - added %s - seen %s"] = "%s - added %s - seen %s"
L["Page %s of %s"] = "Page %s of %s"
L["Sift Allowlist Export"] = "Sift Allowlist Export"
L["Sift Allowlist Import"] = "Sift Allowlist Import"
L["Manage senders that Sift should trust."] = "Manage senders that Sift should trust."
L["No allowlist entries"] = "No allowlist entries"
L["Use Restore + Always allow in History, or import."] = "Use Restore + Always allow in History, or import."
L["Entries: %s"] = "Entries: %s"
L["manual"] = "manual"
L["history"] = "history"
L["import"] = "import"

-- Config panel: Blocked section
L["Type part of a name to filter the list below, then click Apply."] = "Type part of a name to filter the list below, then click Apply."
L["Apply the search box to the Blocked list and reset to page 1."] = "Apply the search box to the Blocked list and reset to page 1."
L["Clear All"] = "Clear All"
L["Remove every player from the Blocked list. Confirmation required."] = "Remove every player from the Blocked list. Confirmation required."
L["Show the previous page of the Blocked list."] = "Show the previous page of the Blocked list."
L["Show the next page of the Blocked list."] = "Show the next page of the Blocked list."
L["%s (blocked by you)"] = "%s (blocked by you)"
L["%s (blocked by Sift)"] = "%s (blocked by Sift)"
L["Removed blocked actor."] = "Removed blocked actor."
L["Blocked actors cleared."] = "Blocked actors cleared."
L["Clear all blocked actors?"] = "Clear all blocked actors?"
L["Clear"] = "Clear"
L["Blocked actors: %s"] = "Blocked actors: %s"
L["blocked by you - blocks %s - last %s"] = "blocked by you - blocks %s - last %s"
L["blocked by Sift - blocks %s - last %s"] = "blocked by Sift - blocks %s - last %s"
L["Review actors currently tracked as blocked."] = "Review actors currently tracked as blocked."
L["Add a manual block"] = "Add a manual block"
L["Right-click a player name in chat and choose Block (Sift)."] = "Right-click a player name in chat and choose Block (Sift)."
L["No blocked actors"] = "No blocked actors"
L["Nothing to manage."] = "Nothing to manage."

-- Config panel: My Keywords / Never Block sections (KEYWORD_SECTIONS)
L["Block phrase"] = "Block phrase"
L["Type a word or phrase to block. Sift hides messages that contain it."] = "Type a word or phrase to block. Sift hides messages that contain it."
L["Allow phrase"] = "Allow phrase"
L["Type a word or phrase that should always come through, unless you blocked the sender yourself."] = "Type a word or phrase that should always come through, unless you blocked the sender yourself."
L["Search"] = "Search"
L["Type to match by phrase. Click Apply to filter the list below."] = "Type to match by phrase. Click Apply to filter the list below."
L["Apply the search box to the list below and reset to page 1."] = "Apply the search box to the list below and reset to page 1."
L["Remove All"] = "Remove All"
L["Remove every phrase in this list. Asks for confirmation first."] = "Remove every phrase in this list. Asks for confirmation first."
L["Add the phrase in the box to this list."] = "Add the phrase in the box to this list."
L["Show the previous page."] = "Show the previous page."
L["Show the next page."] = "Show the next page."
L["Removed %s phrase(s)."] = "Removed %s phrase(s)."
L["Remove every phrase from your keyword block list (%d in total)? This cannot be undone."] = "Remove every phrase from your keyword block list (%d in total)? This cannot be undone."
L["Remove every phrase from your never-block list (%d in total)? This cannot be undone."] = "Remove every phrase from your never-block list (%d in total)? This cannot be undone."
L["Keyword rules are unavailable."] = "Keyword rules are unavailable."
L["Added \"%s\"."] = "Added \"%s\"."
L["That matches \"%s\", already in this list."] = "That matches \"%s\", already in this list."
L["This list is full (%d maximum). Remove something first."] = "This list is full (%d maximum). Remove something first."
L["Enter a word or phrase."] = "Enter a word or phrase."
L["That phrase is too short. Try a longer one."] = "That phrase is too short. Try a longer one."
L["Nothing to remove."] = "Nothing to remove."
L["added %s"] = "added %s"
L["Removed \"%s\"."] = "Removed \"%s\"."
L["Could not remove \"%s\"."] = "Could not remove \"%s\"."
L["Words and phrases you want hidden. Messages containing them are blocked even when Sift's own filter would let them through."] = "Words and phrases you want hidden. Messages containing them are blocked even when Sift's own filter would let them through."
L["A phrase also catches longer text that contains it, so \"tank lf\" also catches \"tank lfm dungeon\". Use distinctive phrases. Anything blocked this way stays in History."] = "A phrase also catches longer text that contains it, so \"tank lf\" also catches \"tank lfm dungeon\". Use distinctive phrases. Anything blocked this way stays in History."
L["No keywords yet"] = "No keywords yet"
L["Add a word or phrase above to start blocking it."] = "Add a word or phrase above to start blocking it."
L["Words and phrases that protect a message. Anything containing one is never blocked, unless you blocked the sender yourself."] = "Words and phrases that protect a message. Anything containing one is never blocked, unless you blocked the sender yourself."
L["|cffff6060Careful:|r these win over Sift's own filter, so a spammer who guesses one of your phrases can put it in a message and walk straight through. Use long, distinctive phrases, not common words. Only your Allowlist and the players you have blocked yourself outrank this."] = "|cffff6060Careful:|r these win over Sift's own filter, so a spammer who guesses one of your phrases can put it in a message and walk straight through. Use long, distinctive phrases, not common words. Only your Allowlist and the players you have blocked yourself outrank this."
L["No never-block phrases"] = "No never-block phrases"
L["Sift's filter decides on its own until you add one."] = "Sift's filter decides on its own until you add one."
L["Unavailable"] = "Unavailable"
L["Keyword rules failed to load."] = "Keyword rules failed to load."

-- Config panel: History section
L["Total detections"] = "Total detections"
L["Every message Sift has caught on this character, including messages from players you blocked yourself, ones left in chat because a category or surface was Paused, and ones you restored. Clearing History does not reset this."] = "Every message Sift has caught on this character, including messages from players you blocked yourself, ones left in chat because a category or surface was Paused, and ones you restored. Clearing History does not reset this."
L["Total blocks"] = "Total blocks"
L["Messages Sift blocked on this character, including messages from players you blocked yourself. Messages left in chat because a category or surface was Paused are not counted, unless you later used Block retroactively on them."] = "Messages Sift blocked on this character, including messages from players you blocked yourself. Messages left in chat because a category or surface was Paused are not counted, unless you later used Block retroactively on them."
L["Total restores"] = "Total restores"
L["Blocked messages you restored in History on this character."] = "Blocked messages you restored in History on this character."
L["Maximum history entries"] = "Maximum history entries"
L["The most History entries Sift keeps for each character. The oldest are removed first, and lifetime totals are not affected."] = "The most History entries Sift keeps for each character. The oldest are removed first, and lifetime totals are not affected."
L["Account total"] = "Account total"
L["The most History entries Sift keeps across all your characters combined. If lowering it would remove entries, Sift asks first and then trims the oldest right away. The limit is also checked each time you log in."] = "The most History entries Sift keeps across all your characters combined. If lowering it would remove entries, Sift asks first and then trims the oldest right away. The limit is also checked each time you log in."
L["Clear History"] = "Clear History"
L["Delete all retained History entries. Lifetime stats counters are preserved. Confirmation required."] = "Delete all retained History entries. Lifetime stats counters are preserved. Confirmation required."
L["History cleared."] = "History cleared."
L["History clear API is unavailable."] = "History clear API is unavailable."
L["History trimmed to %s entries per character."] = "History trimmed to %s entries per character."
L["History trim API is unavailable."] = "History trim API is unavailable."
L["History trimmed account-wide to %s total entries."] = "History trimmed account-wide to %s total entries."
L["Clear all Sift history?"] = "Clear all Sift history?"
L["Trim history on every character down to the new maximum?"] = "Trim history on every character down to the new maximum?"
L["Trim"] = "Trim"
L["Trim history across all characters down to the new account-wide maximum?"] = "Trim history across all characters down to the new account-wide maximum?"
L["Retained entries: %s"] = "Retained entries: %s"
L["Account-wide records: %s"] = "Account-wide records: %s"
L["Control retained block history."] = "Control retained block history."

-- Config panel: UI section
L["Show minimap button"] = "Show minimap button"
L["Toggle the Sift launcher icon on the minimap."] = "Toggle the Sift launcher icon on the minimap."
L["Reset History Panel"] = "Reset History Panel"
L["Move this panel back to the middle of the screen at its normal size. History and Config share one panel, so this resets both."] = "Move this panel back to the middle of the screen at its normal size. History and Config share one panel, so this resets both."
L["Reset Config Panel"] = "Reset Config Panel"
L["Move this panel back to the middle of the screen at its normal size. Config and History share one panel, so this does the same as Reset History Panel."] = "Move this panel back to the middle of the screen at its normal size. Config and History share one panel, so this does the same as Reset History Panel."
L["History panel position reset."] = "History panel position reset."
L["History panel reset API is unavailable."] = "History panel reset API is unavailable."
L["Config panel position reset."] = "Config panel position reset."
L["Panel size and position, the minimap button, and resetting all settings."] = "Panel size and position, the minimap button, and resetting all settings."

-- Config panel: UI section, Reset Settings
L["Reset Settings"] = "Reset Settings"
L["Puts every setting back to its default, and asks first. Your Allowlist, Blocked list, My Keywords, and Never Block are kept, but if you had raised Maximum history entries or Account total, History entries over the default limit are removed right away, oldest first."] = "Puts every setting back to its default, and asks first. Your Allowlist, Blocked list, My Keywords, and Never Block are kept, but if you had raised Maximum history entries or Account total, History entries over the default limit are removed right away, oldest first."
L["Settings reset to defaults."] = "Settings reset to defaults."
L["Settings API is unavailable."] = "Settings API is unavailable."
L["Reset Sift settings to defaults?"] = "Reset Sift settings to defaults?"

-- Config panel: resize handle
L["Resize panel"] = "Resize panel"
L["Drag to resize the Config panel."] = "Drag to resize the Config panel."
L["Minimum size: 600 \195\151 400."] = "Minimum size: 600 \195\151 400."

-- FirstRunChooser panel
L["Sift: choose what to hide"] = "Sift: choose what to hide"
L["Pick what Sift hides. You can change these any time with /sift config."] = "Pick what Sift hides. You can change these any time with /sift config."
L["Keep current settings"] = "Keep current settings"
L["%s (paused)"] = "%s (paused)"
L["Filter choices not saved. Sift will ask again next login; change them any time with /sift config."] = "Filter choices not saved. Sift will ask again next login; change them any time with /sift config."

-- Player menu: block confirmation on a guild or character-community roster row
L["Block %s? Sift will hide their messages in say, yell, whispers, emotes and channels. Guild, community, party, raid and instance chat is not hidden."] = "Block %s? Sift will hide their messages in say, yell, whispers, emotes and channels. Guild, community, party, raid and instance chat is not hidden."
L["Block"] = "Block"
L["Cancel"] = "Cancel"
L["this player"] = "this player"
L["Blocked %s. Undo in /sift config > Blocked."] = "Blocked %s. Undo in /sift config > Blocked."
L["%s is already blocked."] = "%s is already blocked."
L["Block (Sift) - unavailable for this message"] = "Block (Sift) - unavailable for this message"
L["Blocked (Sift)"] = "Blocked (Sift)"
L["Block (Sift)"] = "Block (Sift)"

-- DB.lua: keyword-phrase merge notice
L["%d of your %s phrases matched another phrase already in the list, so we combined the duplicates. What gets filtered has not changed."] = "%d of your %s phrases matched another phrase already in the list, so we combined the duplicates. What gets filtered has not changed."

-- Init.lua: /sift command output
L["history panel is unavailable."] = "history panel is unavailable."
L["config panel is unavailable."] = "config panel is unavailable."
L["allow requires a sender from History, by their full name."] = "allow requires a sender from History, by their full name."
L["allow requires a sender from History, formatted as Name-Realm."] = "allow requires a sender from History, formatted as Name-Realm."
L["sender is already allowlisted or cannot be allowlisted."] = "sender is already allowlisted or cannot be allowlisted."
L[" Your manual block on them was removed."] = " Your manual block on them was removed."
L["allowlisted %s."] = "allowlisted %s."
L["rebuild API unavailable."] = "rebuild API unavailable."
L["stats rebuilt from retained history: %s entries counted. Reload or reopen the History panel to refresh the stats display."] = "stats rebuilt from retained history: %s entries counted. Reload or reopen the History panel to refresh the stats display."
L["usage: %s"] = "usage: %s"
L["brought your BawrSpam data back, but a follow-up step failed. A /reload should finish it."] = "brought your BawrSpam data back, but a follow-up step failed. A /reload should finish it."
L["could not bring back your BawrSpam data this time. It will try again next login."] = "could not bring back your BawrSpam data this time. It will try again next login."

-- DB.lua: chat notices
L["enforcing new account-wide history cap: trimmed %d records (%d per-char excess, %d global). Open /sift config > History to adjust the caps."] = "enforcing new account-wide history cap: trimmed %d records (%d per-char excess, %d global). Open /sift config > History to adjust the caps."
L["could not initialize: Foundry.DB is missing."] = "could not initialize: Foundry.DB is missing."
L["brought back %d allowed players and %d blocked senders from BawrSpam"] = "brought back %d allowed players and %d blocked senders from BawrSpam"

-- DB.lua: keyword-phrase removal notice
L["Removed from your %s because they are now too short to use: %s"] = "Removed from your %s because they are now too short to use: %s"
