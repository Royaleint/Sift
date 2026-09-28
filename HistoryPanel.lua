-- HistoryPanel: the Sift History window (filterable list, detail pane, detection stats), its embedded Config tab, the surface pause pills, and the minimap launcher.
local _, NS = ...
local L = NS.L
local HistoryPanel = {}

-- Foundry-1.0 is loaded before this file (see Init.lua).
local F = _G.Foundry_1_0

local Data = {}
local Actions = {}
local Chrome = {}
local HistoryPanelMixin = {}
local HistoryListMixin = {}
local HistoryRowMixin = {}
local HistoryDetailMixin = {}
local HistoryStatsMixin = {}
local HistoryFilterChipsMixin = {}
local HistoryPauseRowMixin = {}

-- GameTooltip hover help with a static title/body/hint. State-aware widgets
-- wire their own OnEnter. EnableMouse is set because layout-only
-- BackdropTemplate frames default to mouse-disabled.
function Chrome.AttachTooltip(widget, title, body, hint)
  if not widget then return end
  local host = widget.frame or widget
  if not host.HookScript then return end
  if host.EnableMouse then host:EnableMouse(true) end
  host:HookScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if title then GameTooltip:AddLine(L[title]) end
    if body  then GameTooltip:AddLine(L[body],  1.00, 1.00, 1.00, true) end
    if hint  then GameTooltip:AddLine(L[hint],  0.70, 0.70, 0.70, true) end
    GameTooltip:Show()
  end)
  host:HookScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
  end)
end

-- Layout constants for this file.
--
-- The panel is fixed-size so the legend and stat tiles always fit; it leaves
-- that size only while the embedded Config tab shows. CONFIG_HOST_BOTTOM_MARGIN
-- must match configHost's BOTTOMRIGHT offset in BuildFrame. MIN_LIST_PANE_WIDTH
-- clamps a saved width below the minimum.
local LAYOUT = {
  PANEL_WIDTH  = 940,
  PANEL_HEIGHT = 560,

  CONFIG_HOST_BOTTOM_MARGIN  = 40,
  CONFIG_MIN_EMBEDDED_HEIGHT = 200,

  LIST_ROW_HEIGHT  = 26,
  SCROLLBAR_GUTTER = 22,
  LIST_MAX_ROWS    = 40,

  MIN_LIST_PANE_WIDTH     = 420,
  DEFAULT_LIST_PANE_WIDTH = 440,
  SPLITTER_WIDTH          = 4,

  DOUBLE_CLICK_WINDOW = 0.4,
  MAX_ORIGINAL_CHARS  = 800,

  CHIP_GAP       = 3,
  CHIP_MIN_WIDTH = 38,
  CHIP_HEIGHT    = 22,
  CHIPS_TOP      = 28,
  -- Vertical gaps: chip band to dropdown row, dropdown row to list/detail.
  CHIP_BAND_GAP  = 6,
  LIST_TOP_GAP   = 6,
  -- The sender filter chip sits 14px below the list's own top edge, slightly
  -- over the column header, so it reads as a banner over the list rather
  -- than a separate reserved row.
  SENDER_CHIP_LIST_OFFSET = 14,
}

local CATEGORY_COLORS = {
  RMT        = "c44",
  Boosting   = "e60",
  Carrying   = "c8b",
  Casino     = "a4c",
  Phishing   = "58a",
  Commercial = "5a7",
  Anti       = "888",
  -- The player's own phrases: teal, distinct from the colours above.
  Custom     = "2bc",
}
-- Internal category keys that differ from the words the player sees. Every
-- surface that prints a category key routes through this map.
local CATEGORY_BADGE_LABELS = {
  RMT    = "Gold selling",
  Custom = "My Keywords",
  -- Breakdown-chip-only signal keys (never a "dominant category" -- see
  -- IGNORED_BREAKDOWN_KEYS below); display labels for their chip text.
  BlockedActor = "Blocked sender",
  Flood        = "Spam wave",
  Throttle     = "Repeat",
  ManualBlock  = "Manual block",
}
-- Chip tooltip bodies for the user-filterable categories.
local CHIP_FULL_NAMES = {
  RMT        = "Gold selling (real-money trading)",
  Boosting   = "Boosting (paid leveling and other services)",
  Carrying   = "Carrying (paid raid, Mythic+, and dungeon runs)",
  Custom     = "My Keywords (phrases you added yourself)",
}
-- Keys that say why a message was caught, not what kind of spam it is; they
-- never win "dominant category" but still show as breakdown chips. Copies in
-- ChatScanner, History, HistoryPanel, ShadowLog, Signals, ConfigPanel: keep all
-- six in step.
local IGNORED_BREAKDOWN_KEYS = {
  MixedScript = true,
  BlockedActor = true,
  Flood = true,
  Throttle = true,
  -- A manual block is an identity decision, not a content category.
  ManualBlock = true,
}

-- Categories the user can filter by. PauseState is the single declaration.
local CATEGORIES = NS.PauseState.GetCategoryKeys()

-- Every category a stored row can still carry, including retired ones: stored
-- rows are never rewritten.
local DISPLAY_CATEGORIES = {}
local RETIRED_CATEGORY_SET = {}
do
  for _, cat in ipairs(CATEGORIES) do DISPLAY_CATEGORIES[#DISPLAY_CATEGORIES + 1] = cat end
  local retired = {}
  for cat in pairs(NS.PauseState.GetRetiredCategoryStates()) do
    retired[#retired + 1] = cat
    RETIRED_CATEGORY_SET[cat] = true
  end
  table.sort(retired)
  for _, cat in ipairs(retired) do DISPLAY_CATEGORIES[#DISPLAY_CATEGORIES + 1] = cat end
end

-- Lowercase surface keys, as ChatScanner writes them. An unmapped saved surface
-- key displays as its raw string rather than erroring.
local SURFACE_VALUES = { "All", "chat", "whisper", "bn-whisper" }
local SURFACE_LABELS = {
  All               = "All",
  chat              = "Chat",
  whisper           = "Whisper",
  ["bn-whisper"]    = "Bnet whisper",
}

-- Labels for entry.channel, used when the entry has no channelName.
local CHAT_EVENT_LABELS = {
  CHAT_MSG_SAY        = "Say",
  CHAT_MSG_YELL       = "Yell",
  CHAT_MSG_WHISPER    = "Whisper",
  CHAT_MSG_EMOTE      = "Emote",
  CHAT_MSG_TEXT_EMOTE = "Emote",
  CHAT_MSG_DND        = "DND auto-response",
  CHAT_MSG_AFK        = "AFK auto-response",
  CHAT_MSG_CHANNEL    = "Channel",
}

function Data.FormatChannel(entry)
  if entry.channelName and entry.channelName ~= "" then
    return entry.channelName
  end
  if entry.channel and CHAT_EVENT_LABELS[entry.channel] then
    return L[CHAT_EVENT_LABELS[entry.channel]]
  end
  return entry.channel or "-"
end

local TIME_WINDOW_VALUES = { "All", "Last hour", "Today", "Last 7 days" }
local OUTCOME_VALUES     = { "Blocked", "Restored", "Pass-thru", "All" }
local SORT_VALUES        = { "newest", "score", "sender" }
local SORT_LABELS = {
  newest = "Newest",
  score  = "Score",
  sender = "Sender",
}

-- Stats-area tiles: display order, labels, tooltips, and value colours.
local STATS_TILE_KEYS = { "detected", "blocked", "passThru", "restored", "falsePositives" }
local STATS_TILE_LABELS = {
  detected       = "DETECTED",
  blocked        = "BLOCKED",
  passThru       = "PASS-THRU",
  restored       = "RESTORED",
  falsePositives = "FALSE POSITIVES",
}
-- Tooltip bodies for the lifetime-stats tiles.
local STATS_TILE_TOOLTIPS = {
  detected = {
    title = "Detected",
    body  = "Lifetime count of messages Sift caught, including messages from players you " ..
            "blocked yourself. Includes blocked, pass-thru, and restored entries.",
  },
  blocked = {
    title = "Blocked",
    body  = "Lifetime count of messages Sift blocked. Messages left in chat because a " ..
            "category or surface was Paused are not counted, unless you later used Block " ..
            "retroactively on them.",
  },
  passThru = {
    title = "Pass-thru",
    body  = "Caught as spam but left in chat because the surface or category " ..
            "was set to Paused. Still logged to History for review.",
  },
  restored = {
    title = "Restored",
    body  = "Blocks you have undone in History. These count toward the false-positive rate.",
  },
  falsePositives = {
    title = "False positives",
    body  = "Restored \195\183 Blocked. A rough false-positive rate. " ..
            "Lower is better.",
  },
}
local STATS_TILE_COLORS = {
  detected       = { 1.00, 1.00, 1.00 },
  blocked        = { 1.00, 0.47, 0.33 },
  passThru       = { 0.67, 0.48, 0.23 },
  restored       = { 0.35, 0.82, 0.50 },
  falsePositives = { 0.53, 0.67, 0.80 },
}

function Chrome.ShowPopup(which, ...)
  local dialog = StaticPopupDialogs and StaticPopupDialogs[which]
  if not dialog or type(StaticPopup_Show) ~= "function" then return end
  if which == "SIFT_COPY_SENDER" then
    dialog.text = L["Sender name (Ctrl+C to copy):"]
    dialog.button1 = CLOSE or "Close"
  end
  return StaticPopup_Show(which, ...)
end

function Chrome.RegisterStaticPopups()
  if StaticPopupDialogs and not StaticPopupDialogs["SIFT_COPY_SENDER"] then
    StaticPopupDialogs["SIFT_COPY_SENDER"] = {
      hasEditBox = true,
      editBoxWidth = 250,
      OnShow = function(self, data)
        self.EditBox:SetText(tostring(data or ""))
        self.EditBox:HighlightText()
        self.EditBox:SetFocus()
      end,
      EditBoxOnEscapePressed = function(self)
        self:GetParent():Hide()
      end,
      EnterClicksFirstButton = true,
      hideOnEscape = true,
      timeout = 0,
      whileDead = true,
    }
  end
end

local frame
local listPane
local detailPane
local pauseRow
local pausePills
local minimapLDB
local minimapOptions
local filterState
local sortMode
local selectedEntryId
local currentEntriesSnapshot
local configHost
local tabButtons = {}
local activeMode = "History"
local activeConfigSection = "Detection"
-- "char" or "account". Session-only view state, deliberately not persisted.
local statsScope = "char"

function Data.DefaultFilterState()
  local cats = {}
  for _, cat in ipairs(CATEGORIES) do cats[cat] = true end
  return {
    categories   = cats,
    surface      = "All",
    timeWindow   = "All",
    outcome      = "Blocked",
    senderFilter = nil,
  }
end

function Data.GetCharStore()
	local db = NS.DB and NS.DB.db
	if not db or not db.char then return nil end
	if not db.char.historyPanel then
    db.char.historyPanel = {}
  end
	return db.char.historyPanel
end

function Data.GetSettings()
	return NS.DB and NS.DB.GetSettings and NS.DB.GetSettings() or {}
end

function Data.GetStoredListPaneWidth()
  local store = Data.GetCharStore() or {}
  local w = tonumber(store.listPaneWidth) or LAYOUT.DEFAULT_LIST_PANE_WIDTH
  if w < LAYOUT.MIN_LIST_PANE_WIDTH then w = LAYOUT.MIN_LIST_PANE_WIDTH end
  return w
end

function HistoryPanelMixin:SavePosition()
  if not frame then return end
  local store = Data.GetCharStore()
  if not store then return end
  store.x = frame:GetLeft()
  store.y = frame:GetTop()
end

-- Restores the saved position only; the size is always the fixed panel size.
function HistoryPanelMixin:ApplyStoredGeometry()
  local store = Data.GetCharStore() or {}

  frame:SetSize(LAYOUT.PANEL_WIDTH, LAYOUT.PANEL_HEIGHT)

  frame:ClearAllPoints()
  if store.x and store.y then
    -- Clamp an off-screen saved position; the template's NineSlice extends
    -- ~13px beyond the client area.
    local screenW = GetScreenWidth and GetScreenWidth() or 1920
    local screenH = GetScreenHeight and GetScreenHeight() or 1080
    if store.x < -200 or store.x > screenW - 100
       or store.y < 100 or store.y > screenH + 100 then
      frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    else
      frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", store.x, store.y)
    end
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

function Data.ClearStoredGeometry()
	local store = Data.GetCharStore()
	if not store then return end
	store.x = nil
	store.y = nil
	-- store.width / store.height are kept so the panel can return to resizable
	-- without a data migration.
end

-- Resizes `win` keeping its top-left corner fixed, anchored the same way as
-- ApplyStoredGeometry / SavePosition.
function HistoryPanel.ResizeKeepingTopLeft(win, width, height)
  local left, top = win:GetLeft(), win:GetTop()
  win:SetSize(width, height)
  if left and top then
    win:ClearAllPoints()
    win:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
  end
end

-- The embedded Config window's size: ConfigPanel's embed width, and a height
-- measured from its rendered content (nil falls back to the History height).
-- Both clamp to History's own size. Pure, for tests.
function HistoryPanel.ComputeConfigWindowSize(configEmbedWidth, configMinHeight, frameTop, contentBottom)
  local width = configEmbedWidth or LAYOUT.PANEL_WIDTH
  if width > LAYOUT.PANEL_WIDTH then width = LAYOUT.PANEL_WIDTH end

  local height = LAYOUT.PANEL_HEIGHT
  if frameTop and contentBottom then
    height = (frameTop - contentBottom) + LAYOUT.CONFIG_HOST_BOTTOM_MARGIN
  end
  local floor = configMinHeight or LAYOUT.CONFIG_MIN_EMBEDDED_HEIGHT
  if floor < LAYOUT.CONFIG_MIN_EMBEDDED_HEIGHT then floor = LAYOUT.CONFIG_MIN_EMBEDDED_HEIGHT end
  if height < floor then height = floor end
  if height > LAYOUT.PANEL_HEIGHT then height = LAYOUT.PANEL_HEIGHT end

  return width, height
end

function Chrome.HidePortraitChrome(f)
  if not f then return end
  local frameName = f.GetName and f:GetName() or nil
  local pieces = {
    f.PortraitContainer,
    f.Portrait,
    f.portrait,
    f.portraitFrame,
    frameName and _G[frameName .. "PortraitContainer"] or nil,
    frameName and _G[frameName .. "Portrait"] or nil,
    frameName and _G[frameName .. "PortraitFrame"] or nil,
  }
  for _, piece in ipairs(pieces) do
    if piece and piece.Hide then
      piece:Hide()
      if piece.SetAlpha then
        piece:SetAlpha(0)
      end
    end
  end
end

function Chrome.CreatePlainHistoryFrame(parent)
  local ok, f = pcall(CreateFrame, "Frame", "SiftHistoryFrame", parent, "BackdropTemplate")
  if not ok or not f then
    f = CreateFrame("Frame", "SiftHistoryFrame", parent)
  end
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.02, 0.02, 0.025, 0.96)
    f:SetBackdropBorderColor(0.35, 0.36, 0.42, 1)
  end

  local header = CreateFrame("Frame", nil, f)
  header:SetHeight(28)
  header:SetPoint("TOPLEFT",  f, "TOPLEFT",   6, -6)
  header:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -6)
  header:EnableMouse(true)
  header:RegisterForDrag("LeftButton")
  header:SetScript("OnDragStart", function() f:StartMoving() end)
  header:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    if frame then frame:SavePosition() end
  end)

  header.TitleText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  header.TitleText:SetPoint("CENTER", header, "CENTER", 0, 0)
  header.TitleText:SetText(L["Sift History"])
  f.TitleContainer = header

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, -2)
  close:SetScript("OnClick", function() f:Hide() end)
  f.CloseButton = close

  return f
end

function Chrome.CreateHistoryFrame(parent)
  if NS.Compat and (NS.Compat.isClassicFamily or NS.Compat.isMistsClassic) then
    return Chrome.CreatePlainHistoryFrame(parent)
  end
  local template = "PortraitFrameTemplate"
  local ok, f = pcall(CreateFrame, "Frame", "SiftHistoryFrame", parent, template)
  if ok and f then
    return f
  end
  -- Unprotected retry on purpose: a template failure raises its real error here.
  return CreateFrame("Frame", "SiftHistoryFrame", parent, "PortraitFrameTemplate")
end

function Chrome.CreateBackdropFrame(parent)
  local f = Chrome.CreateHistoryFrame(parent)
  f.layoutType = "ButtonFrameTemplateNoPortrait"
  if f.SetBorder then
    f:SetBorder("ButtonFrameTemplateNoPortrait")
  end
  if f.SetPortraitShown then
    f:SetPortraitShown(false)
  end
  Chrome.HidePortraitChrome(f)
  if f.SetTitle then
    f:SetTitle(L["Sift History"])
  elseif f.TitleContainer and f.TitleContainer.TitleText then
    f.TitleContainer.TitleText:SetText(L["Sift History"])
  end
  -- Center the title within TitleContainer (template default is LEFT-anchored).
  if f.TitleContainer and f.TitleContainer.TitleText then
    f.TitleContainer.TitleText:ClearAllPoints()
    f.TitleContainer.TitleText:SetPoint("CENTER", f.TitleContainer, "CENTER", 0, 0)
  end
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:Hide()
  return f
end

function Chrome.OpenConfigPanel()
  HistoryPanel.ShowConfig("Detection")
end

function HistoryPanelMixin.CreatePanes(parent)
  local listWidth = Data.GetStoredListPaneWidth()

  local list = CreateFrame("Frame", nil, parent)
  Mixin(list, HistoryListMixin)
  list:SetPoint("TOPLEFT",    parent, "TOPLEFT",    6, -86)
  list:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 6,   40)
  list:SetWidth(listWidth)

  local detail = CreateFrame("Frame", nil, parent)
  Mixin(detail, HistoryDetailMixin)
  detail:SetPoint("TOPLEFT",     parent, "TOPLEFT",     6 + listWidth + LAYOUT.SPLITTER_WIDTH + 4, -86)
  detail:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 40)

  return list, detail
end

-- Cached until History.GetRevision() moves; clicks, filters and sorts reuse
-- the same array and stats objects.
function Data.GetEntries()
  local revision = NS.History and NS.History.GetRevision and NS.History.GetRevision()
  if revision ~= nil and HistoryPanel._entriesRevision == revision then
    return HistoryPanel._entries
  end

  local entries
  if NS.History and NS.History.GetAll then
    entries = NS.History.GetAll()
  else
    local db = NS.DB and NS.DB.db
    entries = (db and db.char and db.char.history) or {}
  end
  if revision ~= nil then
    HistoryPanel._entries = entries
    HistoryPanel._entriesRevision = revision
  end
  return entries
end

-- scope is "char" or "account"; each is cached separately.
function Data.GetHistoryStats(scope)
  scope = scope or "char"
  local revision = NS.History and NS.History.GetRevision and NS.History.GetRevision()
  if revision ~= nil then
    if HistoryPanel._statsRevision ~= revision then
      HistoryPanel._stats = {}
      HistoryPanel._statsRevision = revision
    end
    local cached = HistoryPanel._stats[scope]
    if cached then return cached end
  end

  local result
  if scope == "account" and NS.History and NS.History.GetAccountStats then
    result = NS.History.GetAccountStats()
  elseif NS.History and NS.History.GetStats then
    result = NS.History.GetStats()
  else
    local entries = Data.GetEntries()
    result = {
      lifetime = {
        detections = #entries,
        blocked = #entries,
        restored = 0,
        bySurface = {},
      },
      retained = {
        detections = #entries,
        blocked = #entries,
        restored = 0,
        bySurface = {},
      },
    }
  end
  if revision ~= nil then
    HistoryPanel._stats[scope] = result
  end
  return result
end

function Data.UpdateHistoryStatsText()
  -- Deliberate no-op: the stats render in the detail pane.
  return
end

function Data.CurrentEntries()
  return currentEntriesSnapshot or Data.GetEntries()
end

local function TimeWindowCutoff(label)
  if label == "Last hour"   then return GetServerTime() - 3600  end
  if label == "Today"       then return GetServerTime() - 86400 end
  if label == "Last 7 days" then return GetServerTime() - 7 * 86400 end
  return nil
end

local function EntryDominantCategory(entry)
  -- A custom-rule block is always Custom, whatever the largest weight.
  if entry.customRule then return "Custom" end
  if type(entry.breakdown) ~= "table" then return nil end
  local bestCat, bestVal
  for c, v in pairs(entry.breakdown) do
    local numeric = tonumber(v) or 0
    if not IGNORED_BREAKDOWN_KEYS[c] and numeric > 0
       and (not bestVal or numeric > bestVal) then
      bestCat, bestVal = c, numeric
    end
  end
  return bestCat
end

local function MatchesFilters(entry)
  if filterState.surface and filterState.surface ~= "All"
     and entry.surface ~= filterState.surface then
    return false
  end

  -- filterState.outcome is "All", "Blocked", "Restored" or "Pass-thru";
  -- entry.outcome is the lower-case form.
  if filterState.outcome and filterState.outcome ~= "All" then
    local desired = string.lower(filterState.outcome)
    if (entry.outcome or "blocked") ~= desired then return false end
  end

  local cutoff = TimeWindowCutoff(filterState.timeWindow)
  if cutoff and (tonumber(entry.ts) or 0) < cutoff then
    return false
  end

  local cat = EntryDominantCategory(entry)
  if cat and filterState.categories and filterState.categories[cat] == false then
    return false
  end

  local sf = filterState.senderFilter
  if sf then
    if sf.guid then
      if entry.guid ~= sf.guid then return false end
    else
      if (entry.name or "") ~= (sf.name or "") then return false end
      if (entry.realm or "") ~= (sf.realm or "") then return false end
    end
  end

  return true
end

function Data.SortByMode(list, mode)
  if mode == "score" then
    table.sort(list, function(a, b) return (a.score or 0) > (b.score or 0) end)
    return
  end
  if mode == "sender" then
    local counts = {}
    for _, e in ipairs(list) do
      local key = e.guid or e.name or "?"
      counts[key] = (counts[key] or 0) + 1
    end
    table.sort(list, function(a, b)
      local ka = a.guid or a.name or "?"
      local kb = b.guid or b.name or "?"
      if counts[ka] ~= counts[kb] then return counts[ka] > counts[kb] end
      return (a.ts or 0) > (b.ts or 0)
    end)
    return
  end
  -- "newest" is default ordering from History.GetAll(); leave as-is.
end

function Data.ApplyFilterAndSort(entries)
  if not filterState or not sortMode then
    return entries
  end

  local out = {}
  for _, e in ipairs(entries) do
    if MatchesFilters(e) then
      out[#out + 1] = e
    end
  end
  Data.SortByMode(out, sortMode)
  return out
end

function HistoryListMixin:VisibleRowCount(scroll)
  local height = scroll and scroll.GetHeight and scroll:GetHeight() or 0
  local count = math.floor(height / LAYOUT.LIST_ROW_HEIGHT)
  if count < 1 then
    count = 1
  end
  if count > LAYOUT.LIST_MAX_ROWS then
    count = LAYOUT.LIST_MAX_ROWS
  end
  return count
end

function HistoryListMixin:ClassicScrollBar(scroll)
  if not scroll or not scroll.GetName then return nil end
  local name = scroll:GetName()
  return name and _G[name .. "ScrollBar"] or nil
end

-- Breakdown only; EntryDominantCategory (used by the filter) also maps a custom-rule block to Custom.
local function DominantCategory(breakdown)
  if type(breakdown) ~= "table" then return nil end
  local bestCat, bestVal
  for cat, val in pairs(breakdown) do
    local numeric = tonumber(val) or 0
    if not IGNORED_BREAKDOWN_KEYS[cat] and numeric > 0
       and (not bestVal or numeric > bestVal) then
      bestCat, bestVal = cat, numeric
    end
  end
  return bestCat
end

local function RelativeTime(ts)
  if type(ts) ~= "number" then return "?" end
  local delta = GetServerTime() - ts
  if delta < 0          then return L["%ds"]:format(0) end
  if delta < 60         then return L["%ds"]:format(delta) end
  if delta < 3600       then return L["%dm"]:format(math.floor(delta / 60)) end
  if delta < 86400      then return L["%dh"]:format(math.floor(delta / 3600)) end
  if delta < 90 * 86400 then return L["%dd"]:format(math.floor(delta / 86400)) end
  return date("%Y-%m-%d", ts)
end

local function HexNibble(s, i)
  return tonumber(s:sub(i, i), 16) / 15
end

-- Hover-tooltip text for the History row badges, breakdown chips, legend
-- swatches, and column and stats-line hosts below. The resolvers below
-- return these as raw L[] keys, resolved at hover time.
--
-- RETIRED and ADDED are separate so the row tooltip can reuse RETIRED without
-- the ADDED sentence the chip tooltip adds.
local TIPS = {
  TIME     = "How long ago Sift caught this message. Entries older than 90 days show the date instead.",
  SENDER   = "The player who sent the message. A check mark means you restored it, and (pass-thru) means it was left in chat.",
  CATEGORY = "The kind of spam Sift found. Spam wave means a flood of the same spam, and You means you blocked the sender yourself.",
  SCORE    = "How suspicious the message looked to Sift. Higher means more suspicious.",

  YOU_HOVER     = "You blocked this player yourself with Block (Sift) on their right-click menu.",
  SPAM_WAVE_ROW = "Sift caught this as part of a spam wave, sent by one player or many.",
  QMARK_TITLE   = "Kind of spam not saved",
  QMARK_BODY    = "Sift caught this but didn't save which kind of spam it was. Older versions of Sift sometimes left that out.",

  RETIRED = "A kind of spam Sift still catches, but it no longer has its own button to pause it or filter by it.",
  ADDED   = "Part of why Sift caught this message.",

  CHIP_BLOCKED      = "This player is on your Blocked list.",
  CHIP_MANUAL       = "You blocked this player yourself, so Sift caught this message no matter what it said.",
  CHIP_SPAM_WAVE    = "This message was part of a spam wave.",
  CHIP_REPEAT       = "This message repeated one Sift had already caught from the same sender.",
  SPAM_WAVE_SWATCH  = "Gray marks messages Sift caught as part of a spam wave, with no spam category of their own. Players you blocked yourself, and entries marked ?, also show in gray.",

  STAT_SURFACE  = "Lifetime detections split by where they came from: Chat, Whisper, and Bnet whisper. Shows this character or the whole account, depending on the Character or Account button.",
  STAT_CATEGORY = "Lifetime detections split by spam category, for this character or the whole account. A gray number means that category is currently Paused or Off.",
  STAT_PIPELINE = "Repeats counts messages that repeat spam Sift already caught from the same sender. Bubbles suppressed counts the times Sift hid a chat bubble for a blocked Say or Yell. Spam wave (recent) counts blocked messages still in your History that were caught only as part of a spam wave, so it drops as old entries are removed.",
}

-- Pure resolvers (exported for tests). Every display goes through L[] at
-- hover time, and %d formatting is applied after the lookup.
--
-- RowTipKeys is the single source of the badge and tooltip, so they cannot
-- disagree.
function HistoryPanel.RowTipKeys(entry)
  if entry.reason == "manual-block" then
    return "You", "You", TIPS.YOU_HOVER
  end

  local cat = DominantCategory(entry.breakdown)
  if cat then
    if RETIRED_CATEGORY_SET[cat] then
      -- Retired categories get a plain badge; TIPS.RETIRED appears only in the tooltip body.
      local label = CATEGORY_BADGE_LABELS[cat] or cat
      return label, label, TIPS.RETIRED
    end
    if CHIP_FULL_NAMES[cat] then
      -- Keep `or cat`: most categories have no CATEGORY_BADGE_LABELS entry, and a nil badgeKey renders "?".
      return CATEGORY_BADGE_LABELS[cat] or cat, CHIP_FULL_NAMES[cat], nil
    end
    -- Unknown category: the same raw-key fallback ChipTipKeys and LegendTipKeys use.
    local label = CATEGORY_BADGE_LABELS[cat] or cat
    return label, label, nil
  end

  if type(entry.breakdown) == "table" and (tonumber(entry.breakdown.Flood) or 0) > 0 then
    local label = CATEGORY_BADGE_LABELS.Flood or "Flood"
    return label, label, TIPS.SPAM_WAVE_ROW
  end

  -- No category and no Flood: badgeKey stays nil so RenderRow keeps setting
  -- the literal "?" (not run through L[]).
  return nil, TIPS.QMARK_TITLE, TIPS.QMARK_BODY
end

function HistoryPanel.ChipTipKeys(cat, val)
  local label = CATEGORY_BADGE_LABELS[cat] or cat
  if RETIRED_CATEGORY_SET[cat] then
    return label, TIPS.RETIRED, TIPS.ADDED, val
  end
  if CHIP_FULL_NAMES[cat] then
    return CHIP_FULL_NAMES[cat], TIPS.ADDED, nil, val
  end
  if cat == "BlockedActor" then
    return label, TIPS.CHIP_BLOCKED, nil, val
  end
  if cat == "ManualBlock" then
    return label, TIPS.CHIP_MANUAL, nil, nil
  end
  if cat == "Flood" then
    return label, TIPS.CHIP_SPAM_WAVE, nil, val
  end
  if cat == "Throttle" then
    return label, TIPS.CHIP_REPEAT, nil, nil
  end
  return label, nil, nil, nil
end

function HistoryPanel.LegendTipKeys(cat)
  if cat == "Flood" then
    return CATEGORY_BADGE_LABELS.Flood or "Flood", TIPS.SPAM_WAVE_SWATCH
  end
  -- No RETIRED_CATEGORY_SET branch: RefreshLegend never passes a retired
  -- category here; its loop skips every retired category unconditionally.
  if CHIP_FULL_NAMES[cat] then
    return CHIP_FULL_NAMES[cat], nil
  end
  -- An unknown category returns its badge label (or raw key) with no body,
  -- the same fallback RowTipKeys and ChipTipKeys use.
  return CATEGORY_BADGE_LABELS[cat] or cat, nil
end

-- Hover handlers, hooked once at frame creation; each render re-points them by
-- writing tipTitle/tipBody/tipBody2 (and tipValue) onto the frame. Rows anchor
-- ANCHOR_LEFT so the tooltip does not drift with the mouse.
function HistoryRowMixin.RowOnEnter(self)
  if not GameTooltip then return end
  if not self.tipTitle then
    -- Defensive: shown rows always carry a tipTitle (RowTipKeys always returns a title key); only hidden rows clear it.
    GameTooltip:Hide()
    return
  end
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine(L[self.tipTitle])
  if self.tipBody then GameTooltip:AddLine(L[self.tipBody], 1.00, 1.00, 1.00, true) end
  GameTooltip:Show()
end
function HistoryRowMixin.RowOnLeave()
  if GameTooltip then GameTooltip:Hide() end
end

-- Chip / legend: shared by breakdown chips (tipValue set) and legend item
-- hosts (tipValue nil). string.format ignores an unused argument, so
-- :format(tipValue) is safe uniformly whether or not that body key has a %d.
function Chrome.ChipOnEnter(self)
  if not GameTooltip or not self.tipTitle then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(L[self.tipTitle])
  if self.tipBody then GameTooltip:AddLine(L[self.tipBody]:format(self.tipValue), 1.00, 1.00, 1.00, true) end
  if self.tipBody2 then GameTooltip:AddLine(L[self.tipBody2]:format(self.tipValue), 1.00, 1.00, 1.00, true) end
  GameTooltip:Show()
end
function Chrome.ChipOnLeave()
  if GameTooltip then GameTooltip:Hide() end
end

function HistoryRowMixin.RenderRow(row, entry)
  local cat = DominantCategory(entry.breakdown)
  local hex = CATEGORY_COLORS[cat] or "888"
  row.stripe:SetColorTexture(HexNibble(hex, 1), HexNibble(hex, 2), HexNibble(hex, 3), 1)

  local outcome = entry.outcome or "blocked"
  if outcome == "pass-thru" then
    row:SetAlpha(0.65)
  else
    row:SetAlpha(1.0)
  end

  row.timeText:SetText(RelativeTime(entry.ts))

  local senderLabel = entry.name or "?"
  if entry.realm and entry.realm ~= "" then
    senderLabel = senderLabel .. "-" .. entry.realm
  end
  if outcome == "pass-thru" then
    senderLabel = senderLabel .. " |cffaa7a3a" .. L["(pass-thru)"] .. "|r"
  elseif outcome == "restored" then
    senderLabel = "|cff5ad080\226\156\147|r " .. senderLabel
  end
  row.senderText:SetText(senderLabel)

  local badgeKey, titleKey, bodyKey = HistoryPanel.RowTipKeys(entry)
  -- Translated once here: badgeKey is nil only for the "?" case, which is
  -- never run through L[].
  row.badgeText:SetText(badgeKey and L[badgeKey] or "?")
  -- A manual block has no score; blank it rather than show 0.
  if entry.reason == "manual-block" then
    row.scoreText:SetText("")
  else
    row.scoreText:SetText(tostring(entry.score or 0))
  end

  -- Re-point the tooltip fields, since this frame is recycled.
  row.tipTitle, row.tipBody, row.tipBody2 = titleKey, bodyKey, nil

  -- Re-run the hover if the cursor is already on this row, or the tooltip goes stale.
  if GameTooltip and GameTooltip:IsShown() and GameTooltip:GetOwner() == row
     and row:IsMouseOver() then
    row:RowOnEnter()
  end
end

function Data.FindEntryById(id, entries)
  if id == nil then return nil end
  for _, e in ipairs(entries or Data.CurrentEntries()) do
    if e.id == id then return e end
  end
  return nil
end

function Data.FormatSender(entry)
  local label = entry.name or "?"
  if entry.realm and entry.realm ~= "" then
    label = label .. "-" .. entry.realm
  end
  return label
end

function HistoryDetailMixin:ShowEmptyState(show)
  if not detailPane or not detailPane.sections then return end
  if detailPane.empty then
    detailPane.empty:SetShown(show)
    if show and detailPane.empty.stats then
      local stats = Data.GetHistoryStats()
      local retained = stats and stats.retained and stats.retained.detections or 0
      local detected = stats and stats.lifetime and stats.lifetime.detections or retained
      if retained > 0 then
        detailPane.empty.stats:SetText(L["%s entries filtered out."]:format(tostring(retained)))
      elseif detected > 0 then
        detailPane.empty.stats:SetText(L["%s lifetime detections; retained history is empty."]:format(tostring(detected)))
      else
        detailPane.empty.stats:SetText(L["0 detections recorded."])
      end
    end
  end
  for _, section in pairs(detailPane.sections) do
    section:SetShown(not show)
  end
end

function HistoryDetailMixin:RenderSenderHistory(entry, entries)
  if not detailPane or not detailPane.footer or not detailPane.footer.senderHistory then
    return
  end
  entries = entries or Data.CurrentEntries()
  local count, firstSeen, lastSeen = 0, nil, nil
  for _, e in ipairs(entries) do
    local match
    if entry.guid and e.guid == entry.guid then
      match = true
    elseif not entry.guid and entry.name and e.name == entry.name then
      match = true
    end
    if match then
      count = count + 1
      if not firstSeen or (e.ts and e.ts < firstSeen) then firstSeen = e.ts end
      if not lastSeen  or (e.ts and e.ts > lastSeen)  then lastSeen  = e.ts end
    end
  end

  detailPane.footer.senderHistory:SetText(L["In History: %d   ·   First seen: %s   ·   Last seen: %s"]:format(
    count,
    firstSeen and RelativeTime(firstSeen) or "-",
    lastSeen  and RelativeTime(lastSeen)  or "-"))
end

function Actions.PerformRestore(entry)
  if not entry or entry.outcome == "restored" then return end
  if NS.History and NS.History.MarkRestored then
    NS.History.MarkRestored(entry.id)
  end
  if NS.ReportFlow and NS.ReportFlow.Clear then
    NS.ReportFlow.Clear(entry.id)
  end
  -- Under the "Blocked" filter a restored row would vanish; switch to "All".
  if filterState and filterState.outcome == "Blocked" then
    filterState.outcome = "All"
    -- The dropdown reads state through getValue; GenerateMenu refreshes its label.
    if frame and frame.filterStrip and frame.filterStrip.outcomeDD
       and frame.filterStrip.outcomeDD.GenerateMenu then
      frame.filterStrip.outcomeDD:GenerateMenu()
    end
  end
  if listPane then listPane:RefreshList() end
end

function Actions.PerformAlwaysAllow(entry)
  if not entry or not entry.guid or entry.guid == "" then return end
  if NS.Trust and NS.Trust.AddAllowlist then
    local _, clearedManualBlock = NS.Trust.AddAllowlist(entry.guid, entry.name, entry.realm, "history")
    -- Lifting a manual block is otherwise invisible; say so.
    if clearedManualBlock then
      local message = L["%s removed your manual block on %s."]:format(
        "|cff33ff99Sift|r", tostring(entry.name or L["that player"]))
      if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(message)
      else
        print(message)
      end
    end
  end
  if listPane then listPane:RefreshList() end
end

function Actions.PerformBlockRetroactively(entry)
  if not entry or entry.outcome ~= "pass-thru" then return end
  if NS.History and NS.History.RetroactiveBlock then
    NS.History.RetroactiveBlock(entry.id)
  end
  -- ReportFlow only queues reports for entries blocked at scan time, so a
  -- retroactive block enqueues its own; the helpers no-op without a record.
  local surface = entry.surface
  if NS.ReportFlow then
    if (surface == "chat" or surface == "whisper" or surface == "bn-whisper")
       and NS.ReportFlow.ReportChatNow then
      NS.ReportFlow.ReportChatNow(entry.id)
    end
  end
  if listPane then listPane:RefreshList() end
end

function Actions.SetSenderFilter(entry)
  if not entry or not filterState then return end
  filterState.senderFilter = {
    guid  = entry.guid,
    name  = entry.name,
    realm = entry.realm,
  }
  if frame then frame:UpdateSenderFilterChip() end
  if listPane then listPane:RefreshList() end
end

function Actions.ClearSenderFilter()
  if not filterState then return end
  filterState.senderFilter = nil
  if frame then frame:UpdateSenderFilterChip() end
  if listPane then listPane:RefreshList() end
end

function Actions.ContextEntryRestorable(entry)
  return entry.outcome ~= "restored"
end

function Actions.ContextEntryCanAllowlist(entry)
  if entry.surface ~= "chat" then return false end
  if not entry.guid or entry.guid == "" then return false end
  if NS.Trust and NS.Trust.IsAllowlisted and NS.Trust.IsAllowlisted(entry.guid) then
    return false
  end
  return true
end

function Actions.GetReportKind(entry)
  if not entry or not entry.id or not NS.ReportFlow then return nil end
  if not NS.ReportFlow.HasReport or not NS.ReportFlow.HasReport(entry.id) then return nil end
  if NS.ReportFlow.GetReportKind then
    local kind = NS.ReportFlow.GetReportKind(entry.id)
    if kind == "chat" and NS.ReportFlow.CanReportChat and not NS.ReportFlow.CanReportChat() then
      return nil
    end
    return kind
  end
  return nil
end

function Actions.GetReportLabel(kind)
  if kind == "chat" then return "Report" end
  return nil
end

function Actions.PerformReport(entry)
  local kind = Actions.GetReportKind(entry)
  if not kind or not NS.ReportFlow then return end

  if kind == "chat" and NS.ReportFlow.ReportChatNow then
    NS.ReportFlow.ReportChatNow(entry.id)
  end

  if detailPane then detailPane:RefreshDetail() end
end

function Actions.ShowCopySenderPopup(entry)
  Chrome.ShowPopup("SIFT_COPY_SENDER", nil, nil, Data.FormatSender(entry))
end

local rowContextMenu  -- set in HistoryPanel.Initialize()
local pauseSurfaceMenu  -- set in HistoryPanel.Initialize()

function Actions.OpenRowContextMenu(anchor, entry)
  if not entry or not anchor then return end
  if rowContextMenu then
    rowContextMenu:CreateContextMenu(anchor, entry)
  end
end

function HistoryDetailMixin:RenderActions(entry)
  local actions = detailPane and detailPane.actions
  if not actions or not actions.btn1 or not actions.btn2 then return end

  actions.btn1:Hide()
  actions.btn2:Hide()
  actions.btn1:Enable()
  actions.btn2:Enable()
  actions.btn1:SetScript("OnClick", nil)
  actions.btn2:SetScript("OnClick", nil)
  -- Clear tip strings so a hidden or repurposed button never shows a stale tooltip.
  actions.btn1.tipTitle, actions.btn1.tipBody = nil, nil
  actions.btn2.tipTitle, actions.btn2.tipBody = nil, nil

  if not entry then return end

  local outcome = entry.outcome or "blocked"

  if outcome == "restored" then
    actions.btn1:SetText(L["✓ Restored"])
    actions.btn1:Disable()
    actions.btn1:Show()
    actions.btn1.tipTitle = "Restored"
    actions.btn1.tipBody  = "This block has already been undone. No further action needed."
    if NS.Trust and NS.Trust.IsAllowlisted and entry.guid and entry.guid ~= ""
       and NS.Trust.IsAllowlisted(entry.guid) then
      actions.btn2:SetText(L["Allowlisted"])
      actions.btn2:Disable()
      actions.btn2:Show()
      actions.btn2.tipTitle = "Allowlisted"
      actions.btn2.tipBody  = "This sender is on the allowlist. Future messages from them bypass scanning."
    end
    return
  end

  if outcome == "pass-thru" then
    actions.btn1:SetText(L["Block retroactively"])
    actions.btn1:SetScript("OnClick", function()
      Actions.PerformBlockRetroactively(entry)
    end)
    actions.btn1:Show()
    actions.btn1.tipTitle = "Block retroactively"
    actions.btn1.tipBody  = "Mark this message as blocked. It already appeared in chat and " ..
      "stays there, but Sift opens Blizzard's report window for it when it can."
    local allowable = (entry.surface == "chat" or entry.surface == "whisper" or entry.surface == "bn-whisper")
      and entry.guid and entry.guid ~= ""
    if allowable and not (NS.Trust and NS.Trust.IsAllowlisted and NS.Trust.IsAllowlisted(entry.guid)) then
      actions.btn2:SetText(L["Always allow"])
      actions.btn2:SetScript("OnClick", function() Actions.PerformAlwaysAllow(entry) end)
      actions.btn2:Show()
      actions.btn2.tipTitle = "Always allow"
      actions.btn2.tipBody  = "Add this sender to the allowlist. Future messages from them bypass scanning."
    end
    return
  end

  -- outcome == "blocked".
  local reportKind = Actions.GetReportKind(entry)
  local reportLabel = Actions.GetReportLabel(reportKind)

  if reportLabel then
    actions.btn1:SetText(L["Restore"])
    actions.btn1:SetScript("OnClick", function() Actions.PerformRestore(entry) end)
    actions.btn1:Show()
    actions.btn1.tipTitle = "Restore"
    actions.btn1.tipBody  = "Undo this block. The message won't reappear in chat, only here " ..
      "in History, and you can no longer report it."
    actions.btn2:SetText(L[reportLabel])
    actions.btn2:SetScript("OnClick", function() Actions.PerformReport(entry) end)
    actions.btn2:Show()
    actions.btn2.tipTitle = reportLabel
    actions.btn2.tipBody  = "Open Blizzard's report window for this message."
    return
  end

  local allowable = (entry.surface == "chat" or entry.surface == "whisper" or entry.surface == "bn-whisper")
    and entry.guid and entry.guid ~= ""
  if allowable then
    local already = NS.Trust and NS.Trust.IsAllowlisted and NS.Trust.IsAllowlisted(entry.guid)
    if already then
      actions.btn1:SetText(L["Restore"])
      actions.btn1:SetScript("OnClick", function() Actions.PerformRestore(entry) end)
      actions.btn1:Show()
      actions.btn1.tipTitle = "Restore"
      actions.btn1.tipBody  = "Undo this block. The message won't reappear in chat, and " ..
        "the sender is already on the allowlist."
    else
      actions.btn1:SetText(L["Restore + Always allow"])
      actions.btn1:SetScript("OnClick", function()
        Actions.PerformRestore(entry)
        Actions.PerformAlwaysAllow(entry)
      end)
      actions.btn1:Show()
      actions.btn1.tipTitle = "Restore + Always allow"
      actions.btn1.tipBody  = "Undo this block and add the sender to the allowlist, so Sift " ..
        "stops checking their messages. The message won't reappear in chat."
      actions.btn2:SetText(L["Restore only"])
      actions.btn2:SetScript("OnClick", function() Actions.PerformRestore(entry) end)
      actions.btn2:Show()
      actions.btn2.tipTitle = "Restore only"
      actions.btn2.tipBody  = "Undo this block without changing the allowlist. The message " ..
        "won't reappear in chat."
    end
  else
    actions.btn1:SetText(L["Restore"])
    actions.btn1:SetScript("OnClick", function() Actions.PerformRestore(entry) end)
    actions.btn1:Show()
    actions.btn1.tipTitle = "Restore"
    actions.btn1.tipBody  = "Undo this block. The message won't reappear in chat, and this " ..
      "surface can't be allowlisted."
  end
end

-- Shared by the per-category legend items and the Flood swatch.
function HistoryListMixin:ShowLegendItem(legend, index, lx, hex, label, tipTitle, tipBody)
  local item = legend.items[index]
  if not item then
    item = {
      -- A host covering the swatch and its label, so hovering either
      -- explains the colour, not just the swatch's own 10x10 texture.
      host   = CreateFrame("Frame", nil, legend),
      swatch = legend:CreateTexture(nil, "ARTWORK"),
      label  = legend:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"),
    }
    item.host:SetHeight(18)
    item.host:EnableMouse(true)
    item.host:HookScript("OnEnter", Chrome.ChipOnEnter)
    item.host:HookScript("OnLeave", Chrome.ChipOnLeave)
    item.swatch:SetSize(10, 10)
    item.label:SetPoint("LEFT", item.swatch, "RIGHT", 3, 0)
    legend.items[index] = item
  end
  item.swatch:SetColorTexture(HexNibble(hex, 1), HexNibble(hex, 2), HexNibble(hex, 3), 1)
  item.swatch:ClearAllPoints()
  item.swatch:SetPoint("LEFT", legend, "LEFT", lx, 0)
  item.label:SetText(label)
  item.swatch:Show()
  item.label:Show()

  local width = 12 + (item.label:GetStringWidth() or 0)
  item.host:SetWidth(width)
  item.host:ClearAllPoints()
  item.host:SetPoint("LEFT", legend, "LEFT", lx, 0)
  item.host.tipTitle, item.host.tipBody = tipTitle, tipBody
  item.host:Show()

  return lx + 12 + item.label:GetStringWidth() + 8
end

-- The legend shows only live categories, never retired ones (unlike the
-- by-category stats line). Items are reused, never destroyed. It always
-- describes this character: pass char-scope `stats` if already fetched,
-- otherwise they are fetched here.
function HistoryListMixin:RefreshLegend(stats)
  local legend = listPane and listPane.legend
  if not legend then return end
  stats = stats or Data.GetHistoryStats("char")
  -- floodBadgeCount, not floodCount: RenderRow badges Flood on any outcome, so
  -- the swatch must too. The OTHER line uses floodCount (blocked only).
  local floodBadgeCount = tonumber(stats and stats.retained and stats.retained.floodBadgeCount) or 0
  local lx = 4
  local index = 0
  for _, cat in ipairs(DISPLAY_CATEGORIES) do
    if not RETIRED_CATEGORY_SET[cat] then
      index = index + 1
      local tipTitle, tipBody = HistoryPanel.LegendTipKeys(cat)
      lx = listPane:ShowLegendItem(legend, index, lx, CATEGORY_COLORS[cat] or "888",
        L[CATEGORY_BADGE_LABELS[cat] or cat], tipTitle, tipBody)
    end
  end
  -- Flood is not a category or a filter chip, but its rows still get the grey
  -- stripe, so it gets a legend entry while such a row is retained.
  if floodBadgeCount > 0 then
    index = index + 1
    local tipTitle, tipBody = HistoryPanel.LegendTipKeys("Flood")
    listPane:ShowLegendItem(legend, index, lx, "888", L["Spam wave"], tipTitle, tipBody)
  end
  for i = index + 1, #legend.items do
    legend.items[i].host:Hide()
    legend.items[i].swatch:Hide()
    legend.items[i].label:Hide()
  end
end

function HistoryStatsMixin:RefreshStatsArea()
  if not detailPane or not detailPane.stats then return end
  local stats = Data.GetHistoryStats(statsScope)
  local lifetime = stats.lifetime or {}

  local detected = tonumber(lifetime.detections) or 0
  local blocked  = tonumber(lifetime.blocked) or 0
  local passThru = tonumber(lifetime.passThru) or 0
  local restored = tonumber(lifetime.restored) or 0
  local fpRate
  if blocked > 0 then
    fpRate = string.format("%.1f%%", (restored / blocked) * 100)
  else
    fpRate = "-"  -- no value yet
  end

  local values = {
    detected       = tostring(detected),
    blocked        = tostring(blocked),
    passThru       = tostring(passThru),
    restored       = tostring(restored),
    falsePositives = fpRate,
  }
  for key, tile in pairs(detailPane.stats.tiles) do
    tile.valueText:SetText(values[key] or "-")
    local color = STATS_TILE_COLORS[key]
    if color then
      tile.valueText:SetTextColor(color[1], color[2], color[3])
    end
  end

  -- By-surface inline line.
  local bySurface = lifetime.bySurface or {}
  -- Inline, relying on word-wrap; the stats ScrollFrame handles overflow.
  local surfaceParts = {}
  local surfaceOrder = { "chat", "whisper", "bn-whisper" }
  for _, s in ipairs(surfaceOrder) do
    local label = SURFACE_LABELS[s] or s
    surfaceParts[#surfaceParts + 1] = string.format("%s |cffffffff%d|r", L[label], tonumber(bySurface[s]) or 0)
  end
  detailPane.stats.bySurfaceText:SetText(table.concat(surfaceParts, "   "))

  -- By-category inline line; paused/off categories render muted.
  local byCategory = lifetime.byCategory or {}
  local categoryParts = {}
  for _, cat in ipairs(DISPLAY_CATEGORIES) do
    local count = tonumber(byCategory[cat]) or 0
    -- A retired category is listed only while its lifetime count is nonzero.
    if count > 0 or not RETIRED_CATEGORY_SET[cat] then
      local hex = CATEGORY_COLORS[cat] or "888"
      local hexFull = (hex:gsub(".", "%0%0"))  -- 3-char hex expanded per digit to 6 for color codes
      local state = NS.PauseState and NS.PauseState.GetCategory and NS.PauseState.GetCategory(cat) or "active"
      local part
      local catLabel = CATEGORY_BADGE_LABELS[cat] or cat
      if state == "paused" or state == "off" then
        part = string.format("|cff%s%s|r |cff888888%d|r", hexFull, L[catLabel], count)
      else
        part = string.format("|cff%s%s|r |cffffffff%d|r", hexFull, L[catLabel], count)
      end
      categoryParts[#categoryParts + 1] = part
    end
  end
  detailPane.stats.byCategoryText:SetText(table.concat(categoryParts, "   "))

  local throttled = tonumber(lifetime.throttled) or 0
  local bubbles   = tonumber(lifetime.bubblesSuppressed) or 0
  -- Derived from retained rows, not a lifetime counter, hence "(recent)". The
  -- count stays white: all-grey reads as paused/off on the line above.
  local retained = stats.retained or {}
  local flood = tonumber(retained.floodCount) or 0
  detailPane.stats.pipelineText:SetText(string.format(
    "%s |cffffffff%d|r   %s |cffffffff%d|r   |cff888888%s|r |cffffffff%d|r",
    L["Repeats"], throttled, L["Bubbles suppressed"], bubbles, L["Spam wave (recent)"], flood))

  -- Keep the legend in sync. Only char-scope stats can be handed over.
  if listPane then listPane:RefreshLegend(statsScope == "char" and stats or nil) end

  -- Size the scrollChild to its content so long wraps scroll instead of
  -- clipping. Deferred one frame for wrap heights to settle; GetTop/GetBottom
  -- can be nil before layout, which falls back to the 280px envelope.
  if C_Timer and C_Timer.After then
    C_Timer.After(0, function()
      if not detailPane or not detailPane.stats or not detailPane.stats.pipelineText then return end
      local s = detailPane.stats
      local statsTop = s:GetTop()
      local lastBottom = s.pipelineText:GetBottom()
      if statsTop and lastBottom then
        local h = (statsTop - lastBottom) + 12
        if h < 200 then h = 200 end
        s:SetHeight(h)
      end
    end)
  end
end

function HistoryDetailMixin:RenderBodyFlex(entry)
  if not detailPane or not detailPane.body then return end
  local body = detailPane.body
  local original = entry and entry.original or ""
  if #original > LAYOUT.MAX_ORIGINAL_CHARS then
    original = original:sub(1, LAYOUT.MAX_ORIGINAL_CHARS) .. " \226\128\166" .. L["(truncated)"]
  end
  body.text:SetText(original)

  -- Auto-size: measure FontString natural height and set frame height to match.
  local naturalHeight = body.text:GetStringHeight() or 0
  local desired = math.max(naturalHeight + 16, 80)  -- 16 = top+bottom padding; 80 = min
  body:SetHeight(desired)
end

function HistoryDetailMixin:RenderBreakdownChips(breakdown)
  if not detailPane or not detailPane.footer or not detailPane.footer.breakdownRow then return end
  local row = detailPane.footer.breakdownRow
  row.chips = row.chips or {}

  for _, chip in ipairs(row.chips) do chip:Hide() end

  if type(breakdown) ~= "table" then return end

  local sorted = {}
  for cat, val in pairs(breakdown) do
    -- Only MixedScript is hidden; the other IGNORED_BREAKDOWN_KEYS still show as chips.
    if cat ~= "MixedScript" and (tonumber(val) or 0) > 0 then
      sorted[#sorted + 1] = { cat = cat, val = val }
    end
  end
  table.sort(sorted, function(a, b) return (a.val or 0) > (b.val or 0) end)

  local showPoints = NS.DB and NS.DB.IsDevMode and NS.DB.IsDevMode()
  local xOffset = 0
  for index, item in ipairs(sorted) do
    local chip = row.chips[index]
    if not chip then
      chip = CreateFrame("Frame", nil, row, "BackdropTemplate")
      if chip.SetBackdrop then
        chip:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
      end
      chip.label = chip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      chip.label:SetPoint("CENTER", chip, "CENTER", 0, 0)
      -- The chip frame itself is the hover host.
      chip:EnableMouse(true)
      chip:HookScript("OnEnter", Chrome.ChipOnEnter)
      chip:HookScript("OnLeave", Chrome.ChipOnLeave)
      row.chips[index] = chip
    end
    local hex = CATEGORY_COLORS[item.cat] or "888"
    if chip.SetBackdropColor then
      chip:SetBackdropColor(HexNibble(hex, 1), HexNibble(hex, 2), HexNibble(hex, 3), 1)
    end
    local chipName = L[CATEGORY_BADGE_LABELS[item.cat] or item.cat]
    if showPoints then
      chip.label:SetText(string.format("|cff000000%s +%d|r", chipName, item.val))
    else
      chip.label:SetText(string.format("|cff000000%s|r", chipName))
    end
    chip.tipTitle, chip.tipBody, chip.tipBody2, chip.tipValue = HistoryPanel.ChipTipKeys(item.cat, item.val)
    -- Size to the label with an 80px floor (same idiom as PlaceCategoryChips):
    -- mapped names like "Gold selling" do not fit 80px.
    local chipWidth = math.max(80, math.floor((chip.label:GetStringWidth() or 0) + 10.5))
    chip:SetSize(chipWidth, 14)
    chip:ClearAllPoints()
    chip:SetPoint("LEFT", row, "LEFT", xOffset, 0)
    chip:Show()
    xOffset = xOffset + chipWidth + 4
  end
end

function HistoryDetailMixin:RefreshDetail()
  if not detailPane or not detailPane.sections then return end

  local entries = Data.CurrentEntries()
  if #entries == 0 then
    detailPane:ShowEmptyState(true)
    if detailPane.stats then detailPane.stats:RefreshStatsArea() end
    return
  end
  detailPane:ShowEmptyState(false)

  local entry = Data.FindEntryById(selectedEntryId, entries)
  if not entry then
    local sorted = Data.ApplyFilterAndSort(entries)
    entry = sorted[1]
    if entry then selectedEntryId = entry.id end
  end
  if not entry then if detailPane.stats then detailPane.stats:RefreshStatsArea() end return end

  -- Header
  local channel      = Data.FormatChannel(entry)
  local linkSuffix   = entry.containsItemLinks and ("   " .. L["contains item link"]) or ""
  local surfaceLabel = (entry.surface and SURFACE_LABELS[entry.surface]) or entry.surface or "?"
  detailPane.header.senderText:SetText(Data.FormatSender(entry))

  local outcome = entry.outcome or "blocked"
  local statusText
  local pauseReason = ""
  if outcome == "restored" then
    statusText = "|cff5ad080" .. L["RESTORED"] .. "|r"
  elseif outcome == "pass-thru" then
    statusText = "|cffaa7a3a" .. L["PASSED THROUGH"] .. "|r"
    local surfaceKey = entry.surface or "chat"
    local surfaceState = NS.PauseState and NS.PauseState.GetSurface and NS.PauseState.GetSurface(surfaceKey) or "active"
    if surfaceState == "paused" then
      pauseReason = "   " .. L[surfaceLabel] .. " " .. L["surface paused"]
    end
  else
    statusText = "|cffff5577" .. L["BLOCKED"] .. "|r"
  end
  if entry.reason == "manual-block" then
    statusText = statusText .. "   " .. L["blocked by you"]
  elseif NS.DB and NS.DB.IsDevMode and NS.DB.IsDevMode() then
    statusText = statusText .. string.format("   %d / %d",
      tonumber(entry.score) or 0, tonumber(entry.threshold) or 0)
  end
  detailPane.header.statusText:SetText(statusText)
  -- Names the user's rule from the record, so it survives the rule's deletion.
  -- On the meta line because the footer is a fixed three-row layout.
  local keywordNote = ""
  if type(entry.customRule) == "table" then
    local rule = entry.customRule.raw or entry.customRule.cleansed
    if rule then
      keywordNote = "   |cffffd100" .. L["caught by your keyword"] .. ": " .. rule .. "|r"
    end
  end

  detailPane.header.metaText:SetText(string.format("%s   %s%s%s%s",
    L[surfaceLabel], channel, linkSuffix, pauseReason, keywordNote))

  detailPane:RenderBodyFlex(entry)
  detailPane:RenderBreakdownChips(entry.breakdown)
  detailPane:RenderSenderHistory(entry, entries)
  detailPane:RenderActions(entry)
  if detailPane.stats then detailPane.stats:RefreshStatsArea() end
end

function HistoryListMixin:RefreshList()
  if not listPane or not listPane.listBackend then return end

  local allEntries = Data.GetEntries() or {}
  -- The revision this draw reflects, so a later classic click can tell
  -- whether the rows on screen are still current (see SelectEntry).
  HistoryPanel._listRevision = NS.History and NS.History.GetRevision and NS.History.GetRevision()
  currentEntriesSnapshot = allEntries
  Data.UpdateHistoryStatsText()
  local filtered = Data.ApplyFilterAndSort(allEntries)

  if listPane.listBackend == "classic" then
    local scroll = listPane.scroll
    local visibleRows = listPane:VisibleRowCount(scroll)
    local scrollable = #filtered > visibleRows
    if not scrollable and scroll.SetVerticalScroll then
      scroll:SetVerticalScroll(0)
    end
    -- Keep the FauxScrollFrame visible even when the list is shorter than the
    -- viewport; otherwise Blizzard's template hides the frame and its rows.
    -- Hide only the scrollbar chrome when there is nothing to scroll.
    FauxScrollFrame_Update(scroll, #filtered, visibleRows, LAYOUT.LIST_ROW_HEIGHT,
      nil, nil, nil, nil, nil, nil, true)
    local scrollBar = listPane:ClassicScrollBar(scroll)
    if scrollBar then
      scrollBar:SetShown(scrollable)
    end
    local offset = scrollable and FauxScrollFrame_GetOffset(scroll) or 0

    for i = 1, LAYOUT.LIST_MAX_ROWS do
      local row = scroll.rows[i]
      local entry = filtered[offset + i]
      if row and entry and i <= visibleRows then
        row.entry = entry
        row:RenderRow(entry)
        row.selection:SetShown(selectedEntryId == entry.id)
        row:Show()
      elseif row then
        row.entry = nil
        -- The only place a classic row is hidden, so clear its tooltip here.
        row.tipTitle, row.tipBody, row.tipBody2 = nil, nil, nil
        row:Hide()
      end
    end
  else
    local provider = listPane.list:GetNativeHandles().dataProvider
    provider:Flush()
    provider:InsertTable(filtered)
  end

  if detailPane then detailPane:RefreshDetail() end
  currentEntriesSnapshot = nil
end

function HistoryListMixin:SelectEntry(id)
  selectedEntryId = id
  -- Classic backend: repaint highlights only while the History revision is
  -- unchanged; if data moved since the draw, the rows are stale, so redraw.
  if listPane and listPane.listBackend == "classic" then
    local revision = NS.History and NS.History.GetRevision and NS.History.GetRevision()
    if revision ~= nil and revision ~= HistoryPanel._listRevision then
      if listPane then listPane:RefreshList() end
    else
      if detailPane then detailPane:RefreshDetail() end
    end
    -- Repaint highlights after either branch: RefreshDetail can move the
    -- selection after RefreshList painted.
    local scroll = listPane.scroll
    if scroll and scroll.rows then
      for _, row in ipairs(scroll.rows) do
        if row.entry then
          row.selection:SetShown(selectedEntryId == row.entry.id)
        end
      end
    end
    return
  end
  if detailPane then detailPane:RefreshDetail() end
  -- Modern backend: repaint rendered rows without rebuilding the data provider,
  -- which would reset scroll.
  if listPane and listPane.list then
    listPane.list:ForEachFrame(function(rowFrame, entryData)
      if rowFrame.selection then
        rowFrame.selection:SetShown(selectedEntryId == entryData.id)
      end
    end)
  end
end

function HistoryRowMixin.InitListRow(button)
  if button.bsInit then return end
  button.bsInit = true
  Mixin(button, HistoryRowMixin)

  button.stripe = button:CreateTexture(nil, "ARTWORK")
  button.stripe:SetPoint("TOPLEFT",    button, "TOPLEFT",    0, 0)
  button.stripe:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
  button.stripe:SetWidth(4)

  button.selection = button:CreateTexture(nil, "BACKGROUND")
  button.selection:SetAllPoints()
  button.selection:SetColorTexture(80 / 255, 140 / 255, 200 / 255, 0.18)
  button.selection:Hide()

  button.timeText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  button.timeText:SetPoint("LEFT", button, "LEFT", 10, 0)
  button.timeText:SetWidth(36)
  button.timeText:SetJustifyH("LEFT")

  button.senderText = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  button.senderText:SetPoint("LEFT",  button.timeText, "RIGHT",  4, 0)
  button.senderText:SetPoint("RIGHT", button,          "RIGHT", -130, 0)
  button.senderText:SetJustifyH("LEFT")

  button.badgeText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  button.badgeText:SetPoint("RIGHT", button, "RIGHT", -69, 0)
  button.badgeText:SetWidth(54)
  button.badgeText:SetJustifyH("CENTER")

  button.scoreText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  button.scoreText:SetPoint("RIGHT", button, "RIGHT", -16, 0)
  button.scoreText:SetWidth(40)
  button.scoreText:SetJustifyH("RIGHT")

  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  -- The row itself is the hover host, so click routing is unaffected.
  button:HookScript("OnEnter", HistoryRowMixin.RowOnEnter)
  button:HookScript("OnLeave", HistoryRowMixin.RowOnLeave)
end

function Chrome.UseModernHistoryList()
  return not NS.Compat or NS.Compat.hasModernHistoryList ~= false
end

function HistoryListMixin:CreateListHeader()
  -- Filter chips/dropdowns are anchored to the parent frame (see
  -- CreateHeaderFilters), not nested inside listPane. Column header sits at
  -- listPane's TOPLEFT; ScrollBox starts 18 px below it.
  local header = CreateFrame("Frame", nil, listPane)
  header:SetHeight(18)
  header:SetPoint("TOPLEFT",  listPane, "TOPLEFT",  0, 0)
  header:SetPoint("TOPRIGHT", listPane, "TOPRIGHT", -LAYOUT.SCROLLBAR_GUTTER, 0)
  listPane.columnHeader = header

  -- Fixed width for row alignment; word wrap off clips an overflowing
  -- translation instead of wrapping the header to multiple lines.
  header.timeLabel = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header.timeLabel:SetPoint("LEFT", header, "LEFT", 10, 0)
  header.timeLabel:SetWidth(36)
  header.timeLabel:SetJustifyH("LEFT")
  header.timeLabel:SetWordWrap(false)
  header.timeLabel:SetText(L["Time"])

  header.senderLabel = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header.senderLabel:SetPoint("LEFT",  header.timeLabel, "RIGHT",  4, 0)
  header.senderLabel:SetPoint("RIGHT", header,           "RIGHT", -130, 0)
  header.senderLabel:SetJustifyH("LEFT")
  header.senderLabel:SetWordWrap(false)
  header.senderLabel:SetText(L["Sender"])

  header.badgeLabel = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header.badgeLabel:SetPoint("RIGHT", header, "RIGHT", -69, 0)
  header.badgeLabel:SetWidth(54)
  header.badgeLabel:SetJustifyH("CENTER")
  header.badgeLabel:SetWordWrap(false)
  header.badgeLabel:SetText(L["Category"])

  header.scoreLabel = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header.scoreLabel:SetPoint("RIGHT", header, "RIGHT", -16, 0)
  header.scoreLabel:SetWidth(40)
  header.scoreLabel:SetJustifyH("RIGHT")
  header.scoreLabel:SetWordWrap(false)
  header.scoreLabel:SetText(L["Score"])

  -- A hover host per column, anchored to the header's full height.
  local function AddHeaderTip(label, title, body)
    local host = CreateFrame("Frame", nil, header)
    host:SetPoint("TOP", header, "TOP", 0, 0)
    host:SetPoint("BOTTOM", header, "BOTTOM", 0, 0)
    host:SetPoint("LEFT", label, "LEFT", 0, 0)
    host:SetPoint("RIGHT", label, "RIGHT", 0, 0)
    Chrome.AttachTooltip(host, title, body)
  end
  AddHeaderTip(header.timeLabel,   "Time",     TIPS.TIME)
  AddHeaderTip(header.senderLabel, "Sender",   TIPS.SENDER)
  AddHeaderTip(header.badgeLabel,  "Category", TIPS.CATEGORY)
  AddHeaderTip(header.scoreLabel,  "Score",    TIPS.SCORE)
end

function HistoryListMixin:CreateModernListPane()
  listPane:CreateListHeader()

  -- Built with Foundry.List; RefreshList and SelectEntry use its native
  -- scrollBox through GetNativeHandles().
  F:RequireModule("List", 1)

  local list = F.List:New({
    name        = "SiftHistoryList",
    parent      = listPane,
    elementType = "Button",
    extent      = LAYOUT.LIST_ROW_HEIGHT,
    spacing     = 0,
    initializer = function(button, entry)
      HistoryRowMixin.InitListRow(button)
      button:RenderRow(entry)
      button.selection:SetShown(selectedEntryId == entry.id)
      button:SetScript("OnClick", function(rowButton, mouseButton)
        if mouseButton == "RightButton" then
          rowButton._lastClick = nil
          Actions.OpenRowContextMenu(rowButton, entry)
          return
        end
        local now = GetTime()
        if rowButton._lastClick and (now - rowButton._lastClick) < LAYOUT.DOUBLE_CLICK_WINDOW then
          rowButton._lastClick = nil
          Actions.PerformRestore(entry)
          if Actions.ContextEntryCanAllowlist(entry) then
            Actions.PerformAlwaysAllow(entry)
          end
        else
          rowButton._lastClick = now
          listPane:SelectEntry(entry.id)
        end
      end)
    end,
    resetter = function(button)
      button:SetScript("OnClick", nil)
      button.selection:Hide()
      button._lastClick = nil
      -- Defensive only: RenderRow overwrites these on every reuse.
      button.tipTitle, button.tipBody, button.tipBody2 = nil, nil, nil
    end,
  })

  -- Replace F.List's default anchors: scrollBox inset 18px for the column header
  -- above and the legend strip below, scrollbar gutter on the right; scrollBar flush.
  local handles = list:GetNativeHandles()
  local scrollBox = handles.scrollBox
  local scrollBar = handles.scrollBar

  scrollBox:ClearAllPoints()
  scrollBox:SetPoint("TOPLEFT",     listPane, "TOPLEFT",     0, -18)
  scrollBox:SetPoint("BOTTOMRIGHT", listPane, "BOTTOMRIGHT", -LAYOUT.SCROLLBAR_GUTTER, 18)

  scrollBar:ClearAllPoints()
  scrollBar:SetPoint("TOPLEFT",    scrollBox, "TOPRIGHT",    0, 0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 0, 0)
  scrollBar:SetHideIfUnscrollable(false)

  -- Refreshes use Flush/InsertTable on the native provider, not SetData, which
  -- would reset the scroll to the top.
  listPane.list = list
  listPane.listBackend = "modern"
end

function HistoryListMixin:CreateClassicListPane()
  listPane:CreateListHeader()

  local function refreshList() listPane:RefreshList() end

  local scroll = CreateFrame("ScrollFrame", "SiftHistoryListScroll", listPane, "FauxScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT",     listPane, "TOPLEFT",     0, -18)
  scroll:SetPoint("BOTTOMRIGHT", listPane, "BOTTOMRIGHT", -LAYOUT.SCROLLBAR_GUTTER, 18)
  scroll:SetScript("OnVerticalScroll", function(scrollFrame, yOffset)
    FauxScrollFrame_OnVerticalScroll(scrollFrame, yOffset, LAYOUT.LIST_ROW_HEIGHT, refreshList)
  end)

  scroll.rows = {}
  for i = 1, LAYOUT.LIST_MAX_ROWS do
    local row = CreateFrame("Button", nil, scroll)
    row:SetHeight(LAYOUT.LIST_ROW_HEIGHT)
    row:SetPoint("LEFT",  scroll, "LEFT",  0, 0)
    row:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
    if i == 1 then
      row:SetPoint("TOP", scroll, "TOP", 0, 0)
    else
      row:SetPoint("TOP", scroll.rows[i - 1], "BOTTOM", 0, 0)
    end
    HistoryRowMixin.InitListRow(row)
    row:SetScript("OnClick", function(rowButton, mouseButton)
      local entry = rowButton.entry
      if not entry then
        return
      end
      if mouseButton == "RightButton" then
        rowButton._lastClick = nil
        Actions.OpenRowContextMenu(rowButton, entry)
        return
      end
      local now = GetTime()
      if rowButton._lastClick and (now - rowButton._lastClick) < LAYOUT.DOUBLE_CLICK_WINDOW then
        rowButton._lastClick = nil
        Actions.PerformRestore(entry)
        if Actions.ContextEntryCanAllowlist(entry) then
          Actions.PerformAlwaysAllow(entry)
        end
      else
        rowButton._lastClick = now
        listPane:SelectEntry(entry.id)
      end
    end)
    row:Hide()
    scroll.rows[i] = row
  end

  listPane.scroll = scroll
  listPane.listBackend = "classic"
end

function HistoryListMixin:CreateUnavailableListPane()
  local text = listPane:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("CENTER", listPane, "CENTER", 0, 0)
  text:SetText(L["History list is unavailable in this client."])
  listPane.listBackend = "unavailable"
end

function HistoryListMixin:CreateListPane()
  if Chrome.UseModernHistoryList() then
    listPane:CreateModernListPane()
  elseif NS.Compat and NS.Compat.hasClassicHistoryList then
    listPane:CreateClassicListPane()
  else
    listPane:CreateUnavailableListPane()
  end

  local legend = CreateFrame("Frame", nil, listPane)
  legend:SetHeight(18)
  legend:SetPoint("BOTTOMLEFT",  listPane, "BOTTOMLEFT",  0, 0)
  legend:SetPoint("BOTTOMRIGHT", listPane, "BOTTOMRIGHT", 0, 0)
  legend.items = {}
  listPane.legend = legend
  listPane:RefreshLegend()
end

function HistoryStatsMixin.PlaceStatsTiles(stats)
  if not stats.tiles or not stats.tilesRow then return end
  local rowWidth = stats.tilesRow:GetWidth()
  if not rowWidth or rowWidth <= 0 then return end
  local tileCount = #STATS_TILE_KEYS
  local gap = 4
  local tileWidth = math.floor((rowWidth - gap * (tileCount - 1)) / tileCount)
  if tileWidth < 56 then tileWidth = 56 end
  for index, key in ipairs(STATS_TILE_KEYS) do
    local tile = stats.tiles[key]
    tile:ClearAllPoints()
    tile:SetSize(tileWidth, 38)
    if index == 1 then
      tile:SetPoint("LEFT", stats.tilesRow, "LEFT", 0, 0)
    else
      local prevTile = stats.tiles[STATS_TILE_KEYS[index - 1]]
      tile:SetPoint("LEFT", prevTile, "RIGHT", gap, 0)
    end
  end
end

function HistoryStatsMixin.BuildStatsArea(parent)
  parent.titleLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  parent.titleLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -6)
  parent.titleLabel:SetText(L["DETECTION STATS"])

  -- This-character / account-wide scope toggle for the stat boxes.
  local function SetStatsScope(scope)
    statsScope = scope
    parent.scopeCharBtn:SetEnabled(scope ~= "char")
    parent.scopeAccountBtn:SetEnabled(scope ~= "account")
    parent:RefreshStatsArea()
  end

  parent.scopeCharBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  parent.scopeCharBtn:SetSize(70, 16)
  parent.scopeCharBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, -4)
  parent.scopeCharBtn:SetText(L["Character"])
  parent.scopeCharBtn:SetScript("OnClick", function() SetStatsScope("char") end)
  Chrome.AttachTooltip(parent.scopeCharBtn, "Character",
    "Show detection stats for this character only.")

  parent.scopeAccountBtn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  parent.scopeAccountBtn:SetSize(70, 16)
  parent.scopeAccountBtn:SetPoint("RIGHT", parent.scopeCharBtn, "LEFT", -4, 0)
  parent.scopeAccountBtn:SetText(L["Account"])
  parent.scopeAccountBtn:SetScript("OnClick", function() SetStatsScope("account") end)
  Chrome.AttachTooltip(parent.scopeAccountBtn, "Account",
    "Show detection stats summed across every character on this account.")

  -- Default view is per-character; the char button starts disabled to show
  -- it's the active scope.
  parent.scopeCharBtn:SetEnabled(false)

  parent.tilesRow = CreateFrame("Frame", nil, parent)
  parent.tilesRow:SetHeight(38)
  parent.tilesRow:SetPoint("TOPLEFT",  parent, "TOPLEFT",  6, -22)
  parent.tilesRow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, -22)

  parent.tiles = {}
  for _, key in ipairs(STATS_TILE_KEYS) do
    local tile = CreateFrame("Frame", nil, parent.tilesRow, "BackdropTemplate")
    if tile.SetBackdrop then
      tile:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
      tile:SetBackdropColor(0.13, 0.13, 0.16, 1)
    end
    tile.valueText = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tile.valueText:SetPoint("TOP", tile, "TOP", 0, -2)
    tile.labelText = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tile.labelText:SetPoint("BOTTOM", tile, "BOTTOM", 0, 4)
    tile.labelText:SetText(L[STATS_TILE_LABELS[key]])
    local meta = STATS_TILE_TOOLTIPS[key]
    if meta then Chrome.AttachTooltip(tile, meta.title, meta.body) end
    parent.tiles[key] = tile
  end
  parent.tilesRow:SetScript("OnSizeChanged", function() parent:PlaceStatsTiles() end)
  parent:PlaceStatsTiles()

  parent.bySurfaceLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  parent.bySurfaceLabel:SetPoint("TOPLEFT", parent.tilesRow, "BOTTOMLEFT", 0, -8)
  parent.bySurfaceLabel:SetText(L["BY SURFACE"])

  parent.bySurfaceText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  parent.bySurfaceText:SetPoint("TOPLEFT",  parent.bySurfaceLabel, "BOTTOMLEFT", 0, -2)
  parent.bySurfaceText:SetPoint("TOPRIGHT", parent, "RIGHT", -10, 0)
  parent.bySurfaceText:SetJustifyH("LEFT")
  parent.bySurfaceText:SetWordWrap(true)

  parent.byCategoryLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  parent.byCategoryLabel:SetPoint("TOPLEFT", parent.bySurfaceText, "BOTTOMLEFT", 0, -8)
  parent.byCategoryLabel:SetText(L["BY CATEGORY"])

  parent.byCategoryText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  parent.byCategoryText:SetPoint("TOPLEFT",  parent.byCategoryLabel, "BOTTOMLEFT", 0, -2)
  parent.byCategoryText:SetPoint("TOPRIGHT", parent, "RIGHT", -10, 0)
  parent.byCategoryText:SetJustifyH("LEFT")
  parent.byCategoryText:SetWordWrap(true)

  parent.pipelineLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  parent.pipelineLabel:SetPoint("TOPLEFT", parent.byCategoryText, "BOTTOMLEFT", 0, -8)
  parent.pipelineLabel:SetText(L["OTHER"])

  parent.pipelineText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  parent.pipelineText:SetPoint("TOPLEFT", parent.pipelineLabel, "BOTTOMLEFT", 0, -2)
  parent.pipelineText:SetPoint("RIGHT",   parent, "RIGHT", -10, 0)
  parent.pipelineText:SetJustifyH("LEFT")

  -- One static-text hover host per stats line, anchored TOPLEFT to the
  -- line's label and BOTTOMRIGHT to its text. Titles reuse the existing
  -- on-screen line labels; OTHER gets one host for the whole line.
  local function AddStatsLineTip(labelFS, textFS, title, body)
    local host = CreateFrame("Frame", nil, parent)
    host:SetPoint("TOPLEFT", labelFS, "TOPLEFT", 0, 0)
    host:SetPoint("BOTTOMRIGHT", textFS, "BOTTOMRIGHT", 0, 0)
    Chrome.AttachTooltip(host, title, body)
  end
  AddStatsLineTip(parent.bySurfaceLabel,  parent.bySurfaceText,  "BY SURFACE",  TIPS.STAT_SURFACE)
  AddStatsLineTip(parent.byCategoryLabel, parent.byCategoryText, "BY CATEGORY", TIPS.STAT_CATEGORY)
  AddStatsLineTip(parent.pipelineLabel,   parent.pipelineText,   "OTHER",       TIPS.STAT_PIPELINE)
end

function HistoryDetailMixin.BuildEmptyState(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("CENTER", f, "CENTER", 0, 40)
  f.title:SetText(L["No blocks yet."])

  f.subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.subtitle:SetPoint("CENTER", f, "CENTER", 0, 16)
  f.subtitle:SetText(L["Sift is watching."])

  f.stats = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.stats:SetPoint("CENTER", f, "CENTER", 0, -12)
  f.stats:SetText(L["0 blocks recorded."])

  return f
end

function HistoryDetailMixin:CreateDetailPane()
  detailPane.sections = {}

  -- Status header (~50px tall, anchored TOP)
  local hdr = CreateFrame("Frame", nil, detailPane, "BackdropTemplate")
  hdr:SetHeight(50)
  hdr:SetPoint("TOPLEFT",  detailPane, "TOPLEFT",  0, 0)
  hdr:SetPoint("TOPRIGHT", detailPane, "TOPRIGHT", 0, 0)
  if hdr.SetBackdrop then
    hdr:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    hdr:SetBackdropColor(0.16, 0.16, 0.20, 1)
  end

  hdr.statusText = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdr.statusText:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -10, -6)

  hdr.senderText = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  hdr.senderText:SetPoint("TOPLEFT",  hdr, "TOPLEFT", 10, -6)
  hdr.senderText:SetPoint("TOPRIGHT", hdr.statusText, "TOPLEFT", -10, 0)
  hdr.senderText:SetJustifyH("LEFT")
  hdr.senderText:SetWordWrap(false)

  hdr.metaText = hdr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hdr.metaText:SetPoint("BOTTOMLEFT",  hdr, "BOTTOMLEFT",  10, 6)
  hdr.metaText:SetPoint("BOTTOMRIGHT", hdr, "BOTTOMRIGHT", -10, 6)
  hdr.metaText:SetJustifyH("LEFT")

  detailPane.header = hdr
  detailPane.sections.header = hdr

  -- Message body (auto-size, min 80px)
  local body = CreateFrame("Frame", nil, detailPane)
  body:SetPoint("TOPLEFT",  hdr, "BOTTOMLEFT",  0, -4)
  body:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, -4)
  body:SetHeight(80)
  body.text = body:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
  body.text:SetPoint("TOPLEFT",     body, "TOPLEFT",      10, -8)
  body.text:SetPoint("TOPRIGHT",    body, "TOPRIGHT",    -10, -8)
  body.text:SetPoint("BOTTOMLEFT",  body, "BOTTOMLEFT",   10,  8)
  body.text:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -10,  8)
  body.text:SetJustifyH("LEFT")
  body.text:SetJustifyV("TOP")
  body.text:SetWordWrap(true)
  body.text:SetNonSpaceWrap(true)
  detailPane.body = body
  detailPane.sections.body = body

  -- Footer (breakdown chips + sender history + actions)
  local footer = CreateFrame("Frame", nil, detailPane, "BackdropTemplate")
  footer:SetHeight(64)
  footer:SetPoint("TOPLEFT",  body, "BOTTOMLEFT",  0, -4)
  footer:SetPoint("TOPRIGHT", body, "BOTTOMRIGHT", 0, -4)
  if footer.SetBackdrop then
    footer:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    footer:SetBackdropColor(0.13, 0.13, 0.16, 1)
  end

  footer.breakdownRow = CreateFrame("Frame", nil, footer)
  footer.breakdownRow:SetHeight(16)
  footer.breakdownRow:SetPoint("TOPLEFT",  footer, "TOPLEFT",   8, -6)
  footer.breakdownRow:SetPoint("TOPRIGHT", footer, "TOPRIGHT", -8, -6)
  footer.breakdownRow.chips = {}

  footer.senderHistory = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  footer.senderHistory:SetPoint("TOPLEFT",  footer.breakdownRow, "BOTTOMLEFT",  0, -4)
  footer.senderHistory:SetPoint("TOPRIGHT", footer.breakdownRow, "BOTTOMRIGHT", 0, -4)
  footer.senderHistory:SetJustifyH("LEFT")

  footer.btn1 = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
  footer.btn1:SetSize(160, 22)
  footer.btn1:SetPoint("BOTTOMRIGHT", footer, "BOTTOMRIGHT", -6, 6)
  footer.btn1:Hide()

  footer.btn2 = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
  footer.btn2:SetSize(120, 22)
  footer.btn2:SetPoint("RIGHT", footer.btn1, "LEFT", -4, 0)
  footer.btn2:Hide()

  -- Reads .tipTitle / .tipBody, which RenderActions refreshes.
  local function ActionOnEnter(actionButton)
    if not GameTooltip or not actionButton.tipTitle then return end
    GameTooltip:SetOwner(actionButton, "ANCHOR_TOPRIGHT")
    GameTooltip:AddLine(L[actionButton.tipTitle])
    if actionButton.tipBody then
      GameTooltip:AddLine(L[actionButton.tipBody], 1.00, 1.00, 1.00, true)
    end
    GameTooltip:Show()
  end
  local function ActionOnLeave()
    if GameTooltip then GameTooltip:Hide() end
  end
  footer.btn1:HookScript("OnEnter", ActionOnEnter)
  footer.btn1:HookScript("OnLeave", ActionOnLeave)
  footer.btn2:HookScript("OnEnter", ActionOnEnter)
  footer.btn2:HookScript("OnLeave", ActionOnLeave)

  detailPane.footer = footer
  detailPane.actions = { btn1 = footer.btn1, btn2 = footer.btn2 }
  detailPane.sections.footer = footer

  -- The stats area scrolls rather than clipping into the tab strip. The
  -- scrollChild's width tracks the viewport so the text re-wraps.
  local statsScroll = CreateFrame("ScrollFrame", nil, detailPane, "UIPanelScrollFrameTemplate")
  statsScroll:SetPoint("TOPLEFT",     footer, "BOTTOMLEFT",  0, -6)
  statsScroll:SetPoint("TOPRIGHT",    footer, "BOTTOMRIGHT", -22, -6)
  statsScroll:SetPoint("BOTTOMLEFT",  detailPane, "BOTTOMLEFT",  0, 0)
  statsScroll:SetPoint("BOTTOMRIGHT", detailPane, "BOTTOMRIGHT", -22, 0)

  local stats = CreateFrame("Frame", nil, statsScroll)
  -- Width set after BuildStatsArea via the scroll's OnSizeChanged; the
  -- initial value matches the typical panel width so first-frame layout
  -- does not collapse to zero. Height is a worst-case envelope (tiles row
  -- + 3 wrapped data rows + labels + margins); scrollbar engages above it.
  stats:SetSize(540, 280)
  Mixin(stats, HistoryStatsMixin)
  stats:BuildStatsArea()
  statsScroll:SetScrollChild(stats)

  statsScroll:SetScript("OnSizeChanged", function(scrollFrame, w)
    if w and w > 0 then stats:SetWidth(w) end
  end)

  detailPane.statsScroll = statsScroll
  detailPane.stats = stats
  -- Must be the ScrollFrame, not the scrollChild: hiding only the child leaves
  -- the scrollbar drawing over the empty state.
  detailPane.sections.stats = statsScroll

  -- Empty state placeholder (replaces header/body/footer when nothing selected)
  detailPane.empty = detailPane:BuildEmptyState()
  detailPane.empty:Hide()
end

function HistoryFilterChipsMixin:UpdateChipVisual(chip, cat)
  if not filterState then return end
  local active = filterState.categories[cat] ~= false
  if active then
    chip:UnlockHighlight()
    chip:SetAlpha(1.0)
  else
    chip:SetAlpha(0.45)
  end
end

-- Filter chips exist only for the categories a user can filter by. CHIP_LABELS
-- covers CATEGORIES, not the wider DISPLAY_CATEGORIES.
local CHIP_LABELS = {
  RMT        = "Gold selling",
  Boosting   = "Boosting",
  Carrying   = "Carrying",
  -- Named for the settings section, not the internal breakdown key.
  Custom     = "My Keywords",
}

function HistoryFilterChipsMixin.PlaceCategoryChips(strip)
  if not strip or not strip.chips then return end

  -- Chips size to their labels (CHIP_MIN_WIDTH floor) and wrap at the strip's width.
  -- A zero width means anchors haven't resolved yet: skip wrapping rather than
  -- push every chip onto its own row.
  local availableWidth = strip:GetWidth()
  local x, y, rows = 0, 0, 1
  for _, cat in ipairs(CATEGORIES) do
    local chip = strip.chips[cat]
    if chip then
      local label = chip.GetFontString and chip:GetFontString()
      local textWidth = label and label:GetStringWidth() or 0
      local w = math.floor(textWidth + 24 + 0.5)
      if w < LAYOUT.CHIP_MIN_WIDTH then w = LAYOUT.CHIP_MIN_WIDTH end
      if x > 0 and availableWidth > 0 and x + w > availableWidth then
        x = 0
        y = y - (LAYOUT.CHIP_HEIGHT + LAYOUT.CHIP_GAP)
        rows = rows + 1
      end
      chip:SetSize(w, LAYOUT.CHIP_HEIGHT)
      chip:ClearAllPoints()
      chip:SetPoint("TOPLEFT", strip, "TOPLEFT", x, y)
      x = x + w + LAYOUT.CHIP_GAP
    end
  end
  strip:SetHeight(rows * LAYOUT.CHIP_HEIGHT + (rows - 1) * LAYOUT.CHIP_GAP)
end

function HistoryFilterChipsMixin.BuildCategoryChips(strip)
  local chips = {}
  for _, cat in ipairs(CATEGORIES) do
    local chip = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    chip:SetSize(LAYOUT.CHIP_MIN_WIDTH, LAYOUT.CHIP_HEIGHT)
    chip:SetText(L[CHIP_LABELS[cat] or cat])
    chip:SetScript("OnClick", function()
      -- nil counts as included; only an explicit false hides (see UpdateChipVisual, MatchesFilters).
      filterState.categories[cat] = (filterState.categories[cat] == false)
      strip:UpdateChipVisual(chip, cat)
      if listPane then listPane:RefreshList() end
    end)
    -- Reads the current filter state on every hover.
    chip:HookScript("OnEnter", function(chipButton)
      if not GameTooltip then return end
      local fullName = CHIP_FULL_NAMES[cat] or cat
      local active = filterState and filterState.categories
        and filterState.categories[cat] ~= false
      local body = active
        and "Currently included in the list. Click to hide entries in this category."
        or  "Currently hidden from the list. Click to show entries in this category."
      GameTooltip:SetOwner(chipButton, "ANCHOR_BOTTOMRIGHT")
      GameTooltip:AddLine(L[fullName])
      GameTooltip:AddLine(L[body], 1.00, 1.00, 1.00, true)
      GameTooltip:Show()
    end)
    chip:HookScript("OnLeave", function()
      if GameTooltip then GameTooltip:Hide() end
    end)
    strip:UpdateChipVisual(chip, cat)
    chips[cat] = chip
  end
  strip.chips = chips
  strip:PlaceCategoryChips()
  -- A width change can also change the row count, which OnChipsReflowed (set
  -- by CreateHeaderFilters) repositions everything below the band for.
  strip:SetScript("OnSizeChanged", function()
    strip:PlaceCategoryChips()
    if strip.OnChipsReflowed then strip:OnChipsReflowed() end
  end)
end

function Chrome.CreateModernDropdown(parent, labelText, values, labels, getValue, setValue)
  local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  dd:SetSize(110, 22)
  if dd.SetDefaultText then
    dd:SetDefaultText(L[labelText])
  end
  if F then
    local ctrl = F.Menu:New({
      name    = "NS.FilterDropdown." .. labelText,
      builder = function(_, root)
        root:CreateTitle(L[labelText])
        for _, v in ipairs(values) do
          local displayLabel = (labels and labels[v]) or v
          root:CreateRadio(L[displayLabel],
            function() return getValue() == v end,
            function() setValue(v); dd:GenerateMenu() end)
        end
      end,
    })
    if ctrl then ctrl:SetupDropdown(dd) end
  end
  return dd
end

function HistoryPanelMixin:CreateSenderFilterChip()
  local chip = CreateFrame("Frame", nil, frame)
  chip:SetHeight(18)
  chip:Hide()

  chip.label = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  chip.label:SetPoint("LEFT", chip, "LEFT", 4, 0)
  chip.label:SetText("")

  chip.clear = CreateFrame("Button", nil, chip, "UIPanelCloseButton")
  chip.clear:SetSize(18, 18)
  chip.clear:SetPoint("LEFT", chip.label, "RIGHT", 2, 0)
  chip.clear:SetScript("OnClick", Actions.ClearSenderFilter)
  Chrome.AttachTooltip(chip.clear, "Clear sender filter",
    "Remove the active sender filter and show entries from all senders again.")

  frame.senderChip = chip
  -- Position it now that it exists; ReflowBelowChips already ran once
  -- (CreateHeaderFilters, before this chip existed) and skipped it.
  if frame.filterChipsBand and frame.filterChipsBand.OnChipsReflowed then
    frame.filterChipsBand:OnChipsReflowed()
  end
end

function HistoryPanelMixin:UpdateSenderFilterChip()
  -- Show/hide only; position is owned by ReflowBelowChips (CreateHeaderFilters).
  if not frame or not frame.senderChip or not listPane then return end
  local chip = frame.senderChip
  if filterState and filterState.senderFilter then
    chip.label:SetText(L["|cff58a0ffFiltering by:|r %s"]:format(Data.FormatSender(filterState.senderFilter)))
    chip:Show()
  else
    chip:Hide()
  end
end

function HistoryPanelMixin:SetTabHighlight()
  for mode, button in pairs(tabButtons) do
    if mode == activeMode then
      button:LockHighlight()
    else
      button:UnlockHighlight()
    end
  end
end

-- Sizes the embedded window to Config's content. Guarded on activeMode, not
-- ConfigPanel's IsShown(), which stays true while History is the visible tab.
-- Schedules one remeasure a frame later (skipRemeasure stops it chaining),
-- because text re-wraps after the width shrinks.
function HistoryPanelMixin:ResizeForConfig(skipRemeasure)
  if activeMode ~= "Config" or not frame then return end
  local contentBottom = NS.ConfigPanel and NS.ConfigPanel.GetEmbeddedContentBottom
    and NS.ConfigPanel.GetEmbeddedContentBottom()
  local configWidth = NS.ConfigPanel and NS.ConfigPanel.GetEmbeddedWidth
    and NS.ConfigPanel.GetEmbeddedWidth()
  local configFloor = NS.ConfigPanel and NS.ConfigPanel.GetMinimumHeight
    and NS.ConfigPanel.GetMinimumHeight()
  local width, height = HistoryPanel.ComputeConfigWindowSize(configWidth, configFloor, frame:GetTop(), contentBottom)
  HistoryPanel.ResizeKeepingTopLeft(frame, width, height)
  if not skipRemeasure and C_Timer and C_Timer.After then
    C_Timer.After(0, function() frame:ResizeForConfig(true) end)
  end
end

-- On the module table (like ShowConfigContent below) so tests can drive it.
function HistoryPanel.ShowHistoryContent()
  local wasConfig = (activeMode == "Config")
  activeMode = "History"
  if configHost then configHost:Hide() end
  if listPane then listPane:Show() end
  if detailPane then detailPane:Show() end
  -- Restore the list/detail splitter when leaving Config mode.
  if frame and frame.splitter then frame.splitter:Show() end
  if frame and frame.filterStrip then frame.filterStrip:Show() end
  if frame and frame.filterChipsBand then frame.filterChipsBand:Show() end
  -- Only undo a Config-mode resize; an ordinary open must not touch the anchor.
  if wasConfig and frame then
    HistoryPanel.ResizeKeepingTopLeft(frame, LAYOUT.PANEL_WIDTH, LAYOUT.PANEL_HEIGHT)
  end
  if frame then frame:UpdateSenderFilterChip() end
  if frame then frame:SetTabHighlight() end
end

function HistoryPanel.ShowConfigContent(section)
  activeMode = "Config"
  activeConfigSection = section or activeConfigSection or "Detection"
  if frame and frame.filterStrip then frame.filterStrip:Hide() end
  if frame and frame.filterChipsBand then frame.filterChipsBand:Hide() end
  if frame and frame.senderChip then frame.senderChip:Hide() end
  if listPane then listPane:Hide() end
  if detailPane then detailPane:Hide() end
  -- The splitter is not a child of listPane, so hide it explicitly.
  if frame and frame.splitter then frame.splitter:Hide() end
  if configHost then
    configHost:Show()
    if NS.ConfigPanel and NS.ConfigPanel.Attach then
      NS.ConfigPanel.Attach(configHost, activeConfigSection)
    end
  end
  if frame then frame:ResizeForConfig() end
  if frame then frame:SetTabHighlight() end
end

function HistoryPanelMixin.CreateTabStrip(parent)
  local strip = CreateFrame("Frame", nil, parent)
  strip:SetHeight(30)
  strip:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 8, 6)
  strip:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 6)

  local history = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
  history:SetSize(92, 24)
  history:SetPoint("LEFT", strip, "LEFT", 0, 0)
  history:SetText(L["History"])
  history:SetScript("OnClick", function()
    HistoryPanel.Show()
  end)
  Chrome.AttachTooltip(history, "History",
    "View blocked, restored, and pass-thru detections.")
  tabButtons.History = history

  local config = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
  config:SetSize(92, 24)
  config:SetPoint("LEFT", history, "RIGHT", 6, 0)
  config:SetText(L["Config"])
  config:SetScript("OnClick", function()
    HistoryPanel.ShowConfig(activeConfigSection)
  end)
  Chrome.AttachTooltip(config, "Config",
    "Adjust blocking, categories, surfaces, allowlist, and history settings.")
  tabButtons.Config = config
  parent.tabStrip = strip
end

function HistoryPanelMixin:CreateHeaderFilters()
  -- Chips band: upper-left, right-bound by the pause-pill row, not by listPane.
  local chipsBand = CreateFrame("Frame", nil, frame)
  Mixin(chipsBand, HistoryFilterChipsMixin)
  -- Height is set by PlaceCategoryChips (below), from however many rows the
  -- chips actually need; no fixed height here.
  chipsBand:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -LAYOUT.CHIPS_TOP)
  if pauseRow then
    chipsBand:SetPoint("TOPRIGHT", pauseRow, "LEFT", -8, 0)
  else
    chipsBand:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -360, -LAYOUT.CHIPS_TOP)
  end
  chipsBand:BuildCategoryChips()

  -- Dropdowns band: full panel width, below chips band. Hosts dropdowns +
  -- Refresh. Anchoring to frame (not listPane) means the dropdown row width
  -- is bounded by the panel, not by the splitter. Top offset is recomputed
  -- by ReflowBelowChips (below) from the chip band's actual height.
  local ddBand = CreateFrame("Frame", nil, frame)
  ddBand:SetHeight(24)
  ddBand:SetPoint("TOPLEFT",  frame, "TOPLEFT",  6, -56)
  ddBand:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -56)

  ddBand.surfaceDD = Chrome.CreateModernDropdown(ddBand, "Surface", SURFACE_VALUES, SURFACE_LABELS,
    function() return filterState.surface end,
    function(v) filterState.surface = v; if listPane then listPane:RefreshList() end end)
  ddBand.surfaceDD:SetPoint("LEFT", ddBand, "LEFT", 0, 0)
  Chrome.AttachTooltip(ddBand.surfaceDD, "Surface",
    "Restrict the list to detections from one chat surface. \"All\" clears the filter.")

  ddBand.timeDD = Chrome.CreateModernDropdown(ddBand, "Time", TIME_WINDOW_VALUES, nil,
    function() return filterState.timeWindow end,
    function(v) filterState.timeWindow = v; if listPane then listPane:RefreshList() end end)
  ddBand.timeDD:SetPoint("LEFT", ddBand.surfaceDD, "RIGHT", 4, 0)
  Chrome.AttachTooltip(ddBand.timeDD, "Time",
    "Restrict the list to detections inside a recent time window.")

  ddBand.outcomeDD = Chrome.CreateModernDropdown(ddBand, "Outcome", OUTCOME_VALUES, nil,
    function() return filterState.outcome end,
    function(v) filterState.outcome = v; if listPane then listPane:RefreshList() end end)
  ddBand.outcomeDD:SetPoint("LEFT", ddBand.timeDD, "RIGHT", 4, 0)
  Chrome.AttachTooltip(ddBand.outcomeDD, "Outcome",
    "Blocked means hidden from chat. Restored means you undid the block. Pass-thru means " ..
    "it looked like spam but was left in chat because its surface or category was Paused.")

  ddBand.sortDD = Chrome.CreateModernDropdown(ddBand, "Sort", SORT_VALUES, SORT_LABELS,
    function() return sortMode end,
    function(v) sortMode = v; if listPane then listPane:RefreshList() end end)
  ddBand.sortDD:SetPoint("LEFT", ddBand.outcomeDD, "RIGHT", 4, 0)
  Chrome.AttachTooltip(ddBand.sortDD, "Sort",
    "Newest first \194\183 by Score (highest first) \194\183 by Sender (groups repeat offenders).")

  local refresh = CreateFrame("Button", nil, ddBand, "UIPanelButtonTemplate")
  refresh:SetPoint("RIGHT", ddBand, "RIGHT", 0, 0)
  refresh:SetText(L["Refresh"])
  -- Sizes to its own label instead of a fixed width. Never call
  -- SetTextToFit here -- it grows the button with no upper bound.
  do
    local REFRESH_MIN_WIDTH, REFRESH_MAX_WIDTH, REFRESH_TEXT_PADDING = 60, 160, 24
    local refreshWidth = refresh:GetTextWidth() + REFRESH_TEXT_PADDING
    local needsClip = false
    if refreshWidth < REFRESH_MIN_WIDTH then
      refreshWidth = REFRESH_MIN_WIDTH
    elseif refreshWidth > REFRESH_MAX_WIDTH then
      refreshWidth = REFRESH_MAX_WIDTH
      needsClip = true
    end
    refresh:SetSize(refreshWidth, 22)
    local refreshFontString = refresh:GetFontString()
    if refreshFontString then
      refreshFontString:SetWordWrap(false)
      -- Only bound at the cap: below it the label already fits, and
      -- binding it to its own measured width risks a rounding clip.
      if needsClip then
        refreshFontString:SetWidth(refreshWidth - REFRESH_TEXT_PADDING)
      end
    end
  end
  refresh:SetScript("OnClick", function()
    if listPane then listPane:RefreshList() end
  end)
  Chrome.AttachTooltip(refresh, "Refresh",
    "Reload the list to show messages Sift caught since you opened this window, or after " ..
    "clearing History.")
  ddBand.refresh = refresh

  -- ShowHistoryContent / ShowConfigContent toggle filterStrip (the dropdowns
  -- row); the chips band is toggled alongside.
  listPane.filterStrip = ddBand
  frame.filterStrip = ddBand
  frame.filterChipsBand = chipsBand

  -- Repositions everything below the chip band from its actual height, so a
  -- wrapped second row pushes the dropdowns, the sender filter chip, and the
  -- list/detail area down instead of overlapping them. Re-setting a single
  -- named point (TOPLEFT, TOPRIGHT) replaces only that point; the bottom
  -- anchors CreatePanes already set on listPane/detailPane are untouched.
  local function ReflowBelowChips()
    local ddTop = -LAYOUT.CHIPS_TOP - chipsBand:GetHeight() - LAYOUT.CHIP_BAND_GAP
    ddBand:SetPoint("TOPLEFT",  frame, "TOPLEFT",  6, ddTop)
    ddBand:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, ddTop)

    local listTop = ddTop - ddBand:GetHeight() - LAYOUT.LIST_TOP_GAP
    listPane:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, listTop)
    detailPane:SetPoint("TOPLEFT", frame, "TOPLEFT",
      6 + listPane:GetWidth() + LAYOUT.SPLITTER_WIDTH + 4, listTop)

    if frame.senderChip then
      local chipTop = listTop - LAYOUT.SENDER_CHIP_LIST_OFFSET
      frame.senderChip:SetPoint("TOPLEFT",  frame, "TOPLEFT",   8, chipTop)
      frame.senderChip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, chipTop)
    end
  end
  chipsBand.OnChipsReflowed = ReflowBelowChips
  ReflowBelowChips()
end

-- A decorative vertical line between listPane and detailPane; it does not drag.

function HistoryPanelMixin.CreateSplitter(parent)
  local splitter = CreateFrame("Frame", nil, parent)
  splitter:SetWidth(LAYOUT.SPLITTER_WIDTH)
  splitter:SetPoint("TOPLEFT",    listPane, "TOPRIGHT", 0, 0)
  splitter:SetPoint("BOTTOMLEFT", listPane, "BOTTOMRIGHT", 0, 0)

  splitter.tex = splitter:CreateTexture(nil, "ARTWORK")
  splitter.tex:SetAllPoints(splitter)
  splitter.tex:SetColorTexture(0.23, 0.23, 0.27, 1)

  parent.splitter = splitter
  return splitter
end

local PAUSE_PILL_KEYS = { "chat", "whisper", "bn-whisper" }
local PAUSE_PILL_LABELS = {
  chat              = "Chat",
  whisper           = "Whisp",
  ["bn-whisper"]    = "Bnet",
}

-- Sizes each pill to its label. PILL_LABEL_PADDING is the glyph and margins
-- the label doesn't get. Keep PILL_MAX_WIDTH modest -- it narrows the
-- category chips to its left.
local PILL_MIN_WIDTH = 60
local PILL_MAX_WIDTH = 92
local PILL_LABEL_PADDING = 26

-- Retail uses atlas icons; Classic-family clients use color textures
-- because some Retail atlas names are absent and can leave stale glyphs behind.
-- LevelUp-Dot-Green                  -> green dot
-- CreditsScreen-Assets-Buttons-Pause -> media pause icon
-- communities-icon-redx              -> red X
local PAUSE_STATE_ATLAS = {
  active = "LevelUp-Dot-Green",
  paused = "CreditsScreen-Assets-Buttons-Pause",
  off    = "communities-icon-redx",
}

local PAUSE_STATE_COLOR = {
  active = { 0.15, 0.85, 0.25, 1 },
  paused = { 1.00, 0.82, 0.10, 1 },
  off    = { 0.95, 0.12, 0.12, 1 },
}

function HistoryPauseRowMixin:ApplyPauseGlyph(glyph, state)
  if not glyph then return end
  state = (state == "paused" or state == "off") and state or "active"

  if NS.Compat and NS.Compat.isClassicFamily and glyph.SetColorTexture then
    local color = PAUSE_STATE_COLOR[state] or PAUSE_STATE_COLOR.active
    if glyph.SetTexture then
      glyph:SetTexture(nil)
    end
    if glyph.SetTexCoord then
      glyph:SetTexCoord(0, 1, 0, 1)
    end
    glyph:SetColorTexture(color[1], color[2], color[3], color[4])
    return
  end

  local atlas = PAUSE_STATE_ATLAS[state] or PAUSE_STATE_ATLAS.active
  if atlas and glyph.SetAtlas then
    glyph:SetAtlas(atlas, false)
  elseif glyph.SetColorTexture then
    local color = PAUSE_STATE_COLOR[state] or PAUSE_STATE_COLOR.active
    glyph:SetColorTexture(color[1], color[2], color[3], color[4])
  end
end

function Chrome.PauseStateMenuSuffix(state)
  state = (state == "paused" or state == "off") and state or "active"
  if NS.Compat and NS.Compat.isClassicFamily then
    return "  [" .. L[state] .. "]"
  end
  local atlas = PAUSE_STATE_ATLAS[state] or PAUSE_STATE_ATLAS.active
  return "  |A:" .. atlas .. ":14:14|a"
end

function HistoryPanelMixin.CreatePauseRow(parent)
  pauseRow = CreateFrame("Frame", nil, parent)
  pauseRow:SetHeight(20)
  if parent.TitleContainer then
    pauseRow:SetPoint("TOPRIGHT", parent.TitleContainer, "BOTTOMRIGHT", -28, -2)
  else
    pauseRow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -32, -32)
  end

  -- Above the NineSlice border (base+500) and TitleContainer (base+510).
  pauseRow:SetFrameLevel((parent:GetFrameLevel() or 1) + 520)

  Mixin(pauseRow, HistoryPauseRowMixin)
  pausePills = {}
  local previousPill
  local totalWidth = 0
  for i = #PAUSE_PILL_KEYS, 1, -1 do
    local surfaceKey = PAUSE_PILL_KEYS[i]
    local pill = CreateFrame("Button", nil, pauseRow)
    pill:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    pill.surfaceKey = surfaceKey

    pill.bg = pill:CreateTexture(nil, "BACKGROUND")
    pill.bg:SetAllPoints(pill)
    pill.bg:SetColorTexture(0.13, 0.13, 0.16, 0.95)

    pill.glyph = pill:CreateTexture(nil, "ARTWORK")
    pill.glyph:SetSize(14, 14)
    pill.glyph:SetPoint("LEFT", pill, "LEFT", 4, 0)

    pill.label = pill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pill.label:SetPoint("LEFT", pill.glyph, "RIGHT", 2, 0)
    pill.label:SetJustifyH("LEFT")
    pill.label:SetWordWrap(false)
    pill.label:SetText(L[PAUSE_PILL_LABELS[surfaceKey]])

    local pillWidth = (pill.label:GetStringWidth() or 0) + PILL_LABEL_PADDING
    if pillWidth < PILL_MIN_WIDTH then
      pillWidth = PILL_MIN_WIDTH
    elseif pillWidth > PILL_MAX_WIDTH then
      pillWidth = PILL_MAX_WIDTH
      -- Only bound at the cap: below it the label already fits, and
      -- binding it to its own measured width risks a rounding clip.
      pill.label:SetWidth(pillWidth - PILL_LABEL_PADDING)
    end
    pill:SetSize(pillWidth, 18)
    if previousPill then
      pill:SetPoint("RIGHT", previousPill, "LEFT", -4, 0)
      totalWidth = totalWidth + 4
    else
      pill:SetPoint("RIGHT", pauseRow, "RIGHT", 0, 0)
    end
    totalWidth = totalWidth + pillWidth

    -- Left-click cycles forward, right-click backward.
    pill:SetScript("OnClick", function(pillButton, mouseButton)
      if not NS.PauseState then return end
      local direction = (mouseButton == "RightButton") and "backward" or "forward"
      NS.PauseState.CycleSurface(pillButton.surfaceKey, direction)
    end)

    -- Reads current PauseState on every hover so the tooltip never goes stale.
    pill:HookScript("OnEnter", function(pillButton)
      if not GameTooltip then return end
      local fullName = SURFACE_LABELS[pillButton.surfaceKey] or pillButton.surfaceKey
      local state = NS.PauseState and NS.PauseState.GetSurface(pillButton.surfaceKey) or "active"
      local stateBody
      if state == "active" then
        stateBody = "Active \194\183 detected spam is blocked from chat."
      elseif state == "paused" then
        stateBody = "Paused \194\183 detected spam is logged to History but stays in chat."
      else
        stateBody = "Off \194\183 this surface is not scanned."
      end
      GameTooltip:SetOwner(pillButton, "ANCHOR_RIGHT")
      GameTooltip:AddLine(L[fullName])
      GameTooltip:AddLine(L[stateBody], 1.00, 1.00, 1.00, true)
      GameTooltip:AddLine(L["Left-click cycles forward · Right-click cycles back."],
        0.70, 0.70, 0.70, true)
      GameTooltip:Show()
    end)
    pill:HookScript("OnLeave", function()
      if GameTooltip then GameTooltip:Hide() end
    end)

    pausePills[surfaceKey] = pill
    previousPill = pill
  end
  pauseRow:SetWidth(totalWidth)

  return pauseRow
end

-- Called by the PauseState listener.
function HistoryPanel.RefreshPauseRow()
  if not pausePills or not NS.PauseState then return end
  for surfaceKey, pill in pairs(pausePills) do
    local state = NS.PauseState.GetSurface(surfaceKey)
    pauseRow:ApplyPauseGlyph(pill.glyph, state)
  end
end

function Chrome.BuildFrame()
  if frame then return end

  frame = Chrome.CreateBackdropFrame(UIParent)
  Mixin(frame, HistoryPanelMixin)
  frame:SetMovable(true)
  -- Drop the cached entries and stats on any close, so no message text
  -- outlives the panel in this cache.
  frame:HookScript("OnHide", function()
    HistoryPanel._entries, HistoryPanel._entriesRevision = nil, nil
    HistoryPanel._stats, HistoryPanel._statsRevision = nil, nil
    HistoryPanel._listRevision = nil
  end)
  -- Fixed size; the panel moves by dragging the title bar.
  -- TitleContainer is the modern drag region.
  if frame.TitleContainer then
    frame.TitleContainer:EnableMouse(true)
    frame.TitleContainer:RegisterForDrag("LeftButton")
    frame.TitleContainer:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame.TitleContainer:SetScript("OnDragStop", function()
      frame:StopMovingOrSizing()
      if frame then frame:SavePosition() end
    end)
  end

  frame:CreatePauseRow()
  if HistoryPanel.RefreshPauseRow then HistoryPanel.RefreshPauseRow() end
  listPane, detailPane = frame:CreatePanes()
  frame:CreateSplitter()
  listPane:CreateListPane()
  detailPane:CreateDetailPane()
  frame:CreateHeaderFilters()
  frame:CreateSenderFilterChip()
  configHost = CreateFrame("Frame", nil, frame)
  configHost:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -40)
  configHost:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 40)
  configHost:Hide()
  frame:CreateTabStrip()
  if frame then frame:UpdateSenderFilterChip() end

  -- No size saving: the panel is fixed-size, and the Config-tab resize is
  -- never saved.
  frame:ApplyStoredGeometry()
  tinsert(UISpecialFrames, "SiftHistoryFrame")
end

function Chrome.RegisterMinimap()
	local LDB     = LibStub and LibStub("LibDataBroker-1.1", true)
	local LDBIcon = LibStub and LibStub("LibDBIcon-1.0",      true)
	if not LDB or not LDBIcon then return end

  minimapLDB = LDB:NewDataObject("Sift", {
    type  = "launcher",
    text  = "Sift",
    icon  = "Interface\\Icons\\ability_warrior_shieldreflection",
    OnClick = function(self, button)
      if button == "RightButton" then
        if pauseSurfaceMenu then
          pauseSurfaceMenu:CreateContextMenu(self)
        else
          Chrome.OpenConfigPanel()
        end
      else
        HistoryPanel.Toggle()
      end
    end,
    OnTooltipShow = function(tooltip)
      tooltip:AddLine("Sift")
      tooltip:AddLine(L["Left-click to toggle the History panel."], 1, 1, 1)
      tooltip:AddLine(L["Right-click for the Pause-surface menu and config."], 1, 1, 1)
    end,
  })

	local settings = Data.GetSettings()
	minimapOptions = minimapOptions or {}
	minimapOptions.hide = settings.showMinimapButton == false
	pcall(LDBIcon.Register, LDBIcon, "Sift", minimapLDB, minimapOptions)
end

function HistoryPanel.Initialize()
  filterState = Data.DefaultFilterState()
  sortMode = "newest"
  statsScope = "char"
  Chrome.RegisterStaticPopups()
  Chrome.RegisterMinimap()

  -- A Config nav click never calls ShowConfig, so ConfigPanel calls back here
  -- to re-run the resize.
  if NS.ConfigPanel and NS.ConfigPanel.SetEmbeddedSectionCallback then
    NS.ConfigPanel.SetEmbeddedSectionCallback(function(skip) if frame then frame:ResizeForConfig(skip) end end)
  end

  -- React to PauseState changes from any surface. A category change also
  -- re-renders the BY CATEGORY row.
  if NS.PauseState and NS.PauseState.RegisterListener then
    NS.PauseState.RegisterListener(function(axis, key, state)
      if HistoryPanel.RefreshPauseRow then HistoryPanel.RefreshPauseRow() end
      -- Skip when hidden, or this would refill the cache for no reader.
      if axis == "category" and detailPane and frame and frame:IsShown() then
        detailPane:RefreshDetail()
      end
    end)
  end

  if F then
    rowContextMenu = F.Menu:New({
      name    = "NS.RowContext",
      builder = function(anchor, rootDescription, entry)
        rootDescription:CreateTitle("Sift")
        if Actions.ContextEntryRestorable(entry) then
          rootDescription:CreateButton(L["Restore"], function() Actions.PerformRestore(entry) end)
          if Actions.ContextEntryCanAllowlist(entry) then
            rootDescription:CreateButton(L["Restore + Always allow"], function()
              Actions.PerformRestore(entry)
              Actions.PerformAlwaysAllow(entry)
            end)
          end
        end
        rootDescription:CreateButton(L["Filter by this sender"], function() Actions.SetSenderFilter(entry) end)
        if filterState and filterState.senderFilter then
          rootDescription:CreateButton(L["Clear sender filter"], Actions.ClearSenderFilter)
        end
        local reportKind = Actions.GetReportKind(entry)
        local reportLabel = Actions.GetReportLabel(reportKind)
        if reportLabel then
          rootDescription:CreateButton(L["Report"], function() Actions.PerformReport(entry) end)
        end
        rootDescription:CreateButton(L["Copy sender name"], function() Actions.ShowCopySenderPopup(entry) end)
      end,
    })

    pauseSurfaceMenu = F.Menu:New({
      name    = "NS.PauseSurface",
      builder = function(_, rootDescription)
        rootDescription:CreateTitle(L["Sift"])
        rootDescription:CreateTitle(L["Pause surface"])
        for _, surfaceKey in ipairs(PAUSE_PILL_KEYS) do
          local labelText = SURFACE_LABELS[surfaceKey] or surfaceKey
          local s = NS.PauseState and NS.PauseState.GetSurface(surfaceKey) or "active"
          rootDescription:CreateButton(L[labelText] .. Chrome.PauseStateMenuSuffix(s), function()
            if NS.PauseState then NS.PauseState.CycleSurface(surfaceKey, "forward") end
            return MenuResponse.Refresh
          end)
        end
        rootDescription:CreateDivider()
        rootDescription:CreateButton(L["Open config"], function() Chrome.OpenConfigPanel() end)
      end,
    })
  end
end

function HistoryPanel.Toggle()
  Chrome.BuildFrame()
  if frame:IsShown() and activeMode == "History" then
    frame:Hide()
  else
    HistoryPanel.Show()
  end
end

function HistoryPanel.Show()
  Chrome.BuildFrame()
  HistoryPanel.ShowHistoryContent()
  if listPane then listPane:RefreshList() end
  frame:Show()
end

function HistoryPanel.ShowConfig(section)
  Chrome.BuildFrame()
  HistoryPanel.ShowConfigContent(section)
  frame:Show()
end

function HistoryPanel.Hide()
  if frame then frame:Hide() end
end

function HistoryPanel.IsShown()
	return frame ~= nil and frame:IsShown()
end

function HistoryPanel.ResetPosition()
	-- Clears the saved position and recenters at the fixed History size, even
	-- if the Config tab is showing (activeMode is not checked).
	Data.ClearStoredGeometry()
	if frame then
		frame:SetSize(LAYOUT.PANEL_WIDTH, LAYOUT.PANEL_HEIGHT)
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
end

function HistoryPanel.RefreshMinimap()
	local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
	if not LDBIcon then return end
	if not minimapLDB then
		Chrome.RegisterMinimap()
	end
	if minimapOptions then
		pcall(LDBIcon.Refresh, LDBIcon, "Sift", minimapOptions)
	end
end

function HistoryPanel.SetMinimapShown(shown)
	local value = shown == true
	if NS.DB and NS.DB.SetSetting then
		NS.DB.SetSetting("showMinimapButton", value)
	end

	minimapOptions = minimapOptions or {}
	minimapOptions.hide = not value
	local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
	if not LDBIcon then return end
	if not minimapLDB then
		Chrome.RegisterMinimap()
	end
	if value then
		pcall(LDBIcon.Show, LDBIcon, "Sift")
	else
		pcall(LDBIcon.Hide, LDBIcon, "Sift")
	end
	HistoryPanel.RefreshMinimap()
end

NS.HistoryPanel = HistoryPanel
return HistoryPanel
