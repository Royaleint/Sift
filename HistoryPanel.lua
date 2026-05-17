local _, NS = ...
local HistoryPanel = {}

-- BSP-008: i18n hook. Identity function today; future Locale ticket
-- swaps to NS.L or a string table without touching call sites.
local function L(s) return s end

local DEFAULT_PANEL_WIDTH  = 820
local DEFAULT_PANEL_HEIGHT = 540
local MIN_PANEL_WIDTH      = 720
local MIN_PANEL_HEIGHT     = 500

local LIST_ROW_HEIGHT  = 26
local SCROLLBAR_GUTTER = 22

local MIN_LIST_PANE_WIDTH   = 240
local MIN_DETAIL_PANE_WIDTH = 360
local DEFAULT_LIST_PANE_WIDTH = 380
local SPLITTER_WIDTH = 4

local CATEGORY_COLORS = {
  RMT        = "c44",
  Boosting   = "d80",
  Casino     = "a4c",
  Phishing   = "58a",
  Commercial = "5a7",
  Anti       = "888",
}

local CATEGORIES         = { "RMT", "Boosting", "Casino", "Phishing", "Commercial", "Anti" }

-- Surface uses canonical lowercase keys ("chat", "lfg-search", "lfg-applicant")
-- to match what ChatScanner writes into entry.surface. SURFACE_LABELS maps the
-- key to its display name so the dropdown UI stays user-friendly.
local SURFACE_VALUES = { "All", "chat", "whisper", "bn-whisper", "lfg-search", "lfg-applicant" }
local SURFACE_LABELS = {
  All               = "All",
  chat              = "Chat",
  whisper           = "Whisper",
  ["bn-whisper"]    = "Bnet whisper",
  ["lfg-search"]    = "LFG search",
  ["lfg-applicant"] = "LFG applicant",
}

-- Friendly labels for the WoW chat event names persisted as entry.channel.
-- entry.channelName (when present, captured from the live event payload) is
-- preferred over this map — these labels are the fallback when channelName
-- is nil (e.g. SAY/YELL/WHISPER events where there's no channel name) or
-- for old entries written before ChatScanner started capturing channelName.
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

local function FormatChannel(entry)
  if entry.channelName and entry.channelName ~= "" then
    return entry.channelName
  end
  if entry.channel and CHAT_EVENT_LABELS[entry.channel] then
    return CHAT_EVENT_LABELS[entry.channel]
  end
  return entry.channel or "\226\128\148"
end

local TIME_WINDOW_VALUES = { "All", "Last hour", "Today", "Last 7 days" }
local OUTCOME_VALUES     = { "Blocked", "Restored", "Pass-thru", "All" }
local SORT_VALUES        = { "newest", "score", "sender" }
local SORT_LABELS = {
  newest = "Newest",
  score  = "Score",
  sender = "Sender",
}

local DOUBLE_CLICK_WINDOW    = 0.4
local MAX_ORIGINAL_CHARS     = 800

-- BSP-008 Commit 5: stats area tile metadata (used by BuildStatsArea +
-- RefreshStatsArea below; declared at file scope so RenderActions / other
-- helpers don't need to forward-reference them).
local STATS_TILE_KEYS = { "detected", "blocked", "passThru", "restored", "falsePositives" }
local STATS_TILE_LABELS = {
  detected       = "DETECTED",
  blocked        = "BLOCKED",
  passThru       = "PASS-THRU",
  restored       = "RESTORED",
  falsePositives = "FALSE POSITIVES",
}
local STATS_TILE_COLORS = {
  detected       = { 1.00, 1.00, 1.00 },
  blocked        = { 1.00, 0.47, 0.33 },
  passThru       = { 0.67, 0.48, 0.23 },
  restored       = { 0.35, 0.82, 0.50 },
  falsePositives = { 0.53, 0.67, 0.80 },
}

local fallbackMenuFrame

local function RegisterStaticPopups()
  if StaticPopupDialogs and not StaticPopupDialogs["BAWRSPAM_COPY_SENDER"] then
    StaticPopupDialogs["BAWRSPAM_COPY_SENDER"] = {
      text = "Sender name (Ctrl+C to copy):",
      button1 = CLOSE or "Close",
      hasEditBox = true,
      editBoxWidth = 250,
      OnShow = function(self, data)
        self.editBox:SetText(tostring(data or ""))
        self.editBox:HighlightText()
        self.editBox:SetFocus()
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
local sizeDirty
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

local function DefaultFilterState()
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

local function GetCharStore()
	local db = NS.DB and NS.DB.db
	if not db or not db.char then return nil end
	if not db.char.historyPanel then
    db.char.historyPanel = {}
  end
	return db.char.historyPanel
end

local function GetSettings()
	return NS.DB and NS.DB.GetSettings and NS.DB.GetSettings() or {}
end

local function GetStoredListPaneWidth()
  local store = GetCharStore() or {}
  local w = tonumber(store.listPaneWidth) or DEFAULT_LIST_PANE_WIDTH
  if w < MIN_LIST_PANE_WIDTH then w = MIN_LIST_PANE_WIDTH end
  return w
end

local function SaveListPaneWidth(width)
  local store = GetCharStore()
  if not store then return end
  store.listPaneWidth = width
end

local function SavePosition()
  if not frame then return end
  local store = GetCharStore()
  if not store then return end
  store.x = frame:GetLeft()
  store.y = frame:GetTop()
end

local function SaveSize()
  if not frame then return end
  local store = GetCharStore()
  if not store then return end
  store.width  = frame:GetWidth()
  store.height = frame:GetHeight()
  sizeDirty = false
end

local function ApplyStoredGeometry()
  local store = GetCharStore() or {}

  local width  = store.width  or DEFAULT_PANEL_WIDTH
  local height = store.height or DEFAULT_PANEL_HEIGHT
  if width  < MIN_PANEL_WIDTH  then width  = MIN_PANEL_WIDTH  end
  if height < MIN_PANEL_HEIGHT then height = MIN_PANEL_HEIGHT end
  frame:SetSize(width, height)

  frame:ClearAllPoints()
  if store.x and store.y then
    -- BSP-008: clamp off-screen geometry that pre-BSP-008 builds left behind.
    -- PortraitFrameTemplate's NineSlice extends ~13px beyond the client area,
    -- so existing TOPLEFT positions that were near-edge may now spill off-screen.
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

local function ClearStoredGeometry()
	local store = GetCharStore()
	if not store then return end
	store.x = nil
	store.y = nil
	store.width = nil
	store.height = nil
end

local function CreateBackdropFrame(parent)
  local f = CreateFrame("Frame", "BawrSpamHistoryFrame", parent, "PortraitFrameTemplate")
  f.layoutType = "ButtonFrameTemplateNoPortrait"
  if f.SetBorder then
    f:SetBorder("ButtonFrameTemplateNoPortrait")
  end
  if f.SetPortraitShown then
    f:SetPortraitShown(false)
  end
  if f.SetTitle then
    f:SetTitle(L("BawrSpam — History"))
  elseif f.TitleContainer and f.TitleContainer.TitleText then
    f.TitleContainer.TitleText:SetText(L("BawrSpam — History"))
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

local function OpenConfigPanel()
  HistoryPanel.ShowConfig("Detection")
end

local function CreateResizeHandle(parent)
  local handle = CreateFrame("Button", nil, parent)
  handle:SetSize(16, 16)
  handle:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -4, 4)
  handle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  handle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  handle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  handle:SetScript("OnMouseDown", function() parent:StartSizing("BOTTOMRIGHT") end)
  handle:SetScript("OnMouseUp",   function()
    parent:StopMovingOrSizing()
    sizeDirty = true
  end)
  return handle
end

local function CreatePanes(parent)
  local listWidth = GetStoredListPaneWidth()

  local list = CreateFrame("Frame", nil, parent)
  list:SetPoint("TOPLEFT",    parent, "TOPLEFT",    6, -64)
  list:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 6,   40)
  list:SetWidth(listWidth)

  local detail = CreateFrame("Frame", nil, parent)
  detail:SetPoint("TOPLEFT",     parent, "TOPLEFT",     6 + listWidth + SPLITTER_WIDTH + 4, -64)
  detail:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 40)

  return list, detail
end

local function GetEntries()
  if NS.History and NS.History.GetAll then
    return NS.History.GetAll()
  end
  local db = NS.DB and NS.DB.db
  return (db and db.char and db.char.history) or {}
end

local function GetHistoryStats()
  if NS.History and NS.History.GetStats then
    return NS.History.GetStats()
  end

  local entries = GetEntries()
  return {
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

local function UpdateHistoryStatsText()
  -- BSP-008: stats text moves to detail pane (Commit 5); placeholder while chrome transitions.
  return
end

local function CurrentEntries()
  return currentEntriesSnapshot or GetEntries()
end

local function TimeWindowCutoff(label)
  if label == "Last hour"   then return GetServerTime() - 3600  end
  if label == "Today"       then return GetServerTime() - 86400 end
  if label == "Last 7 days" then return GetServerTime() - 7 * 86400 end
  return nil
end

local function EntryDominantCategory(entry)
  if type(entry.breakdown) ~= "table" then return nil end
  local bestCat, bestVal
  for c, v in pairs(entry.breakdown) do
    if c ~= "MixedScript" and (not bestVal or v > bestVal) then
      bestCat, bestVal = c, v
    end
  end
  return bestCat
end

local function MatchesFilters(entry)
  if filterState.surface and filterState.surface ~= "All"
     and entry.surface ~= filterState.surface then
    return false
  end

  -- filterState.outcome \in { "All", "Blocked", "Restored", "Pass-thru" }
  -- Lower-cased compare matches against entry.outcome which is one of
  -- { "blocked", "restored", "pass-thru" } (set by ChatScanner / History.RetroactiveBlock).
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

local function SortByMode(list, mode)
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

local function ApplyFilterAndSort(entries)
  if not filterState or not sortMode then
    return entries
  end

  local out = {}
  for _, e in ipairs(entries) do
    if MatchesFilters(e) then
      out[#out + 1] = e
    end
  end
  SortByMode(out, sortMode)
  return out
end

local function DominantCategory(breakdown)
  if type(breakdown) ~= "table" then return nil end
  local bestCat, bestVal
  for cat, val in pairs(breakdown) do
    if cat ~= "MixedScript" and (not bestVal or val > bestVal) then
      bestCat, bestVal = cat, val
    end
  end
  return bestCat
end

local function RelativeTime(ts)
  if type(ts) ~= "number" then return "?" end
  local delta = GetServerTime() - ts
  if delta < 0          then return "0s"  end
  if delta < 60         then return tostring(delta) .. "s" end
  if delta < 3600       then return tostring(math.floor(delta / 60))   .. "m" end
  if delta < 86400      then return tostring(math.floor(delta / 3600)) .. "h" end
  if delta < 90 * 86400 then return tostring(math.floor(delta / 86400)) .. "d" end
  return date("%Y-%m-%d", ts)
end

local function HexNibble(s, i)
  return tonumber(s:sub(i, i), 16) / 15
end

local function RenderRow(row, entry)
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
    senderLabel = senderLabel .. " |cffaa7a3a(pass-thru)|r"
  elseif outcome == "restored" then
    senderLabel = "|cff5ad080\226\156\147|r " .. senderLabel
  end
  row.senderText:SetText(senderLabel)

  row.badgeText:SetText(cat or "?")
  row.scoreText:SetText(tostring(entry.score or 0))
end

local function FindEntryById(id)
  if id == nil then return nil end
  for _, e in ipairs(CurrentEntries()) do
    if e.id == id then return e end
  end
  return nil
end

local function FormatSender(entry)
  local label = entry.name or "?"
  if entry.realm and entry.realm ~= "" then
    label = label .. "-" .. entry.realm
  end
  return label
end

local function ShowEmptyState(show)
  if not detailPane or not detailPane.sections then return end
  if detailPane.empty then
    detailPane.empty:SetShown(show)
    if show and detailPane.empty.stats then
      local stats = GetHistoryStats()
      local retained = stats and stats.retained and stats.retained.detections or 0
      local detected = stats and stats.lifetime and stats.lifetime.detections or retained
      if retained > 0 then
        detailPane.empty.stats:SetText(tostring(retained) .. " entries filtered out.")
      elseif detected > 0 then
        detailPane.empty.stats:SetText(tostring(detected) .. " lifetime detections; retained history is empty.")
      else
        detailPane.empty.stats:SetText("0 detections recorded.")
      end
    end
  end
  for _, section in pairs(detailPane.sections) do
    section:SetShown(not show)
  end
end

local RefreshDetail

local function RenderSenderHistory(entry)
  if not detailPane or not detailPane.footer or not detailPane.footer.senderHistory then
    return
  end
  local entries = CurrentEntries()
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

  detailPane.footer.senderHistory:SetText(string.format(
    "Total blocks: %d   \194\183   First seen: %s   \194\183   Last seen: %s",
    count,
    firstSeen and RelativeTime(firstSeen) or "\226\128\148",
    lastSeen  and RelativeTime(lastSeen)  or "\226\128\148"))
end

local RefreshList, SelectEntry, UpdateSenderFilterChip

local function PerformRestore(entry)
  if not entry or entry.outcome == "restored" then return end
  if NS.History and NS.History.MarkRestored then
    NS.History.MarkRestored(entry.id)
  end
  -- Keep the just-restored entry visible: when the default Outcome filter is
  -- "Blocked", a Restore would immediately filter the row out. Promote the
  -- filter to "All" so the user can see their action stuck and can re-toggle
  -- to "Restored" if they want a focused view.
  if filterState and filterState.outcome == "Blocked" then
    filterState.outcome = "All"
    -- Modern WowStyle1DropdownTemplate reflects state via its getValue
    -- closure; call GenerateMenu to refresh the visible label after we mutate
    -- filterState.outcome externally. AceGUI's SetValue is no longer used.
    if frame and frame.filterStrip and frame.filterStrip.outcomeDD
       and frame.filterStrip.outcomeDD.GenerateMenu then
      frame.filterStrip.outcomeDD:GenerateMenu()
    end
  end
  if RefreshList then RefreshList() end
end

local function PerformAlwaysAllow(entry)
  if not entry or not entry.guid or entry.guid == "" then return end
  if NS.Trust and NS.Trust.AddAllowlist then
    NS.Trust.AddAllowlist(entry.guid, entry.name, entry.realm, "history")
  end
  if RefreshList then RefreshList() end
end

local function PerformBlockRetroactively(entry)
  if not entry or entry.outcome ~= "pass-thru" then return end
  if NS.History and NS.History.RetroactiveBlock then
    NS.History.RetroactiveBlock(entry.id)
  end
  -- Fire ReportFlow if a report kind exists for this surface. ReportFlow only
  -- registers reports for blocked entries today, so retroactive block needs to
  -- enqueue the report payload itself; the helpers below no-op if the report
  -- record is unavailable.
  local surface = entry.surface
  if NS.ReportFlow then
    if (surface == "chat" or surface == "whisper" or surface == "bn-whisper")
       and NS.ReportFlow.ReportChatNow then
      NS.ReportFlow.ReportChatNow(entry.id)
    elseif (surface == "lfg-search" or surface == "lfg-applicant")
       and NS.ReportFlow.ReportLFGAdvertisementNow then
      NS.ReportFlow.ReportLFGAdvertisementNow(entry.id)
    end
  end
  if RefreshList then RefreshList() end
end

local function SetSenderFilter(entry)
  if not entry or not filterState then return end
  filterState.senderFilter = {
    guid  = entry.guid,
    name  = entry.name,
    realm = entry.realm,
  }
  if UpdateSenderFilterChip then UpdateSenderFilterChip() end
  if RefreshList then RefreshList() end
end

local function ClearSenderFilter()
  if not filterState then return end
  filterState.senderFilter = nil
  if UpdateSenderFilterChip then UpdateSenderFilterChip() end
  if RefreshList then RefreshList() end
end

local function FallbackMenuFrame()
  if not fallbackMenuFrame then
    fallbackMenuFrame = CreateFrame("Frame", "BawrSpamContextMenu", UIParent, "UIDropDownMenuTemplate")
  end
  return fallbackMenuFrame
end

local function ContextEntryRestorable(entry)
  return entry.outcome ~= "restored"
end

local function ContextEntryCanAllowlist(entry)
  if entry.surface ~= "chat" then return false end
  if not entry.guid or entry.guid == "" then return false end
  if NS.Trust and NS.Trust.IsAllowlisted and NS.Trust.IsAllowlisted(entry.guid) then
    return false
  end
  return true
end

local function GetReportKind(entry)
  if not entry or not entry.id or not NS.ReportFlow then return nil end
  if not NS.ReportFlow.HasReport or not NS.ReportFlow.HasReport(entry.id) then return nil end
  if NS.ReportFlow.GetReportKind then
    return NS.ReportFlow.GetReportKind(entry.id)
  end
  return nil
end

local function GetReportLabel(kind)
  if kind == "lfg-ad" then return "Report Listing" end
  if kind == "chat" then return "Report Spam" end
  return nil
end

local function PerformReport(entry)
  local kind = GetReportKind(entry)
  if not kind or not NS.ReportFlow then return end

  if kind == "lfg-ad" and NS.ReportFlow.ReportLFGAdvertisementNow then
    NS.ReportFlow.ReportLFGAdvertisementNow(entry.id)
  elseif kind == "chat" and NS.ReportFlow.ReportChatNow then
    NS.ReportFlow.ReportChatNow(entry.id)
  end

  if RefreshDetail then RefreshDetail() end
end

local function ShowCopySenderPopup(entry)
  if StaticPopup_Show then
    StaticPopup_Show("BAWRSPAM_COPY_SENDER", nil, nil, FormatSender(entry))
  end
end

local function BuildContextMenuItems(entry)
  local items = { { text = "BawrSpam", isTitle = true, notCheckable = true } }

  if ContextEntryRestorable(entry) then
    items[#items + 1] = { text = "Restore", notCheckable = true,
      func = function() PerformRestore(entry) end }
    if ContextEntryCanAllowlist(entry) then
      items[#items + 1] = { text = "Restore + Always allow", notCheckable = true,
        func = function()
          PerformRestore(entry)
          PerformAlwaysAllow(entry)
        end }
    end
  end

  items[#items + 1] = { text = "Filter by this sender", notCheckable = true,
    func = function() SetSenderFilter(entry) end }
  if filterState and filterState.senderFilter then
    items[#items + 1] = { text = "Clear sender filter", notCheckable = true,
      func = ClearSenderFilter }
  end

  local reportKind = GetReportKind(entry)
  local reportLabel = GetReportLabel(reportKind)
  if reportLabel then
    items[#items + 1] = { text = reportLabel, notCheckable = true,
      func = function() PerformReport(entry) end }
  end

  items[#items + 1] = { text = "Copy sender name", notCheckable = true,
    func = function() ShowCopySenderPopup(entry) end }

  return items
end

local function OpenRowContextMenu(anchor, entry)
  if not entry or not anchor then return end

  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(anchor, function(_, root)
      root:CreateTitle("BawrSpam")
      if ContextEntryRestorable(entry) then
        root:CreateButton("Restore", function() PerformRestore(entry) end)
        if ContextEntryCanAllowlist(entry) then
          root:CreateButton("Restore + Always allow", function()
            PerformRestore(entry)
            PerformAlwaysAllow(entry)
          end)
        end
      end
      root:CreateButton("Filter by this sender", function() SetSenderFilter(entry) end)
      if filterState and filterState.senderFilter then
        root:CreateButton("Clear sender filter", ClearSenderFilter)
      end
      local reportKind = GetReportKind(entry)
      local reportLabel = GetReportLabel(reportKind)
      if reportLabel then
        root:CreateButton(reportLabel, function() PerformReport(entry) end)
      end
      root:CreateButton("Copy sender name", function() ShowCopySenderPopup(entry) end)
    end)
    return
  end

  if EasyMenu then
    local f = FallbackMenuFrame()
    if f then
      EasyMenu(BuildContextMenuItems(entry), f, "cursor", 0, 0, "MENU")
    end
  end
end

local function RenderActions(entry)
  local actions = detailPane and detailPane.actions
  if not actions or not actions.btn1 or not actions.btn2 then return end

  actions.btn1:Hide()
  actions.btn2:Hide()
  actions.btn1:Enable()
  actions.btn2:Enable()
  actions.btn1:SetScript("OnClick", nil)
  actions.btn2:SetScript("OnClick", nil)

  if not entry then return end

  local outcome = entry.outcome or "blocked"

  if outcome == "restored" then
    actions.btn1:SetText(L("\226\156\147 Restored"))
    actions.btn1:Disable()
    actions.btn1:Show()
    if NS.Trust and NS.Trust.IsAllowlisted and entry.guid and entry.guid ~= ""
       and NS.Trust.IsAllowlisted(entry.guid) then
      actions.btn2:SetText(L("Allowlisted"))
      actions.btn2:Disable()
      actions.btn2:Show()
    end
    return
  end

  if outcome == "pass-thru" then
    if entry.surface == "lfg-applicant" then
      -- No safe in-game applicant-report path: C_LFGList exposes only
      -- ReportGroupAsAdvertisement(searchResultID) for listings, and
      -- C_ReportSystem.SendReport is documented "Not allowed to be called
      -- by addons." BSP-008 investigation closed without a callable API;
      -- hide the action row for pass-thru applicant entries until a future
      -- BSP- ticket re-investigates.
      return
    end
    actions.btn1:SetText(L("Block retroactively"))
    actions.btn1:SetScript("OnClick", function()
      PerformBlockRetroactively(entry)
    end)
    actions.btn1:Show()
    local allowable = (entry.surface == "chat" or entry.surface == "whisper" or entry.surface == "bn-whisper")
      and entry.guid and entry.guid ~= ""
    if allowable and not (NS.Trust and NS.Trust.IsAllowlisted and NS.Trust.IsAllowlisted(entry.guid)) then
      actions.btn2:SetText(L("Always allow"))
      actions.btn2:SetScript("OnClick", function() PerformAlwaysAllow(entry) end)
      actions.btn2:Show()
    end
    return
  end

  -- outcome == "blocked": existing behavior with broadened allowlist eligibility
  -- (chat + whisper + bn-whisper now qualify, up from chat-only).
  local reportKind = GetReportKind(entry)
  local reportLabel = GetReportLabel(reportKind)

  if reportLabel then
    actions.btn1:SetText(L("Restore"))
    actions.btn1:SetScript("OnClick", function() PerformRestore(entry) end)
    actions.btn1:Show()
    actions.btn2:SetText(L(reportLabel))
    actions.btn2:SetScript("OnClick", function() PerformReport(entry) end)
    actions.btn2:Show()
    return
  end

  local allowable = (entry.surface == "chat" or entry.surface == "whisper" or entry.surface == "bn-whisper")
    and entry.guid and entry.guid ~= ""
  if allowable then
    local already = NS.Trust and NS.Trust.IsAllowlisted and NS.Trust.IsAllowlisted(entry.guid)
    if already then
      actions.btn1:SetText(L("Restore"))
      actions.btn1:SetScript("OnClick", function() PerformRestore(entry) end)
      actions.btn1:Show()
    else
      actions.btn1:SetText(L("Restore + Always allow"))
      actions.btn1:SetScript("OnClick", function()
        PerformRestore(entry)
        PerformAlwaysAllow(entry)
      end)
      actions.btn1:Show()
      actions.btn2:SetText(L("Restore only"))
      actions.btn2:SetScript("OnClick", function() PerformRestore(entry) end)
      actions.btn2:Show()
    end
  else
    actions.btn1:SetText(L("Restore"))
    actions.btn1:SetScript("OnClick", function() PerformRestore(entry) end)
    actions.btn1:Show()
  end
end

local function RefreshStatsArea()
  if not detailPane or not detailPane.stats then return end
  local stats = NS.History and NS.History.GetStats and NS.History.GetStats() or { lifetime = {}, retained = {} }
  local lifetime = stats.lifetime or {}

  local detected = tonumber(lifetime.detections) or 0
  local blocked  = tonumber(lifetime.blocked) or 0
  local passThru = tonumber(lifetime.passThru) or 0
  local restored = tonumber(lifetime.restored) or 0
  local fpRate
  if blocked > 0 then
    fpRate = string.format("%.1f%%", (restored / blocked) * 100)
  else
    fpRate = "\226\128\148"  -- em dash
  end

  local values = {
    detected       = tostring(detected),
    blocked        = tostring(blocked),
    passThru       = tostring(passThru),
    restored       = tostring(restored),
    falsePositives = fpRate,
  }
  for key, tile in pairs(detailPane.stats.tiles) do
    tile.valueText:SetText(values[key] or "\226\128\148")
    local color = STATS_TILE_COLORS[key]
    if color then
      tile.valueText:SetTextColor(color[1], color[2], color[3])
    end
  end

  -- By-surface inline line.
  local bySurface = lifetime.bySurface or {}
  local surfaceParts = {}
  local surfaceOrder = { "chat", "whisper", "bn-whisper", "lfg-search", "lfg-applicant" }
  for _, s in ipairs(surfaceOrder) do
    local label = SURFACE_LABELS[s] or s
    surfaceParts[#surfaceParts + 1] = string.format("%s |cffffffff%d|r", L(label), tonumber(bySurface[s]) or 0)
  end
  detailPane.stats.bySurfaceText:SetText(table.concat(surfaceParts, "   "))

  -- By-category inline line; paused/off categories render muted.
  local byCategory = lifetime.byCategory or {}
  local categoryParts = {}
  for _, cat in ipairs(CATEGORIES) do
    local count = tonumber(byCategory[cat]) or 0
    local hex = CATEGORY_COLORS[cat] or "888"
    local hexFull = hex .. hex  -- 3-char hex doubled to 6 for color codes
    local state = NS.PauseState and NS.PauseState.GetCategory and NS.PauseState.GetCategory(cat) or "active"
    local part
    if state == "paused" or state == "off" then
      part = string.format("|cff%s%s|r |cff888888%d|r", hexFull, L(cat), count)
    else
      part = string.format("|cff%s%s|r |cffffffff%d|r", hexFull, L(cat), count)
    end
    categoryParts[#categoryParts + 1] = part
  end
  detailPane.stats.byCategoryText:SetText(table.concat(categoryParts, "   "))

  local throttled = tonumber(lifetime.throttled) or 0
  local bubbles   = tonumber(lifetime.bubblesSuppressed) or 0
  detailPane.stats.pipelineText:SetText(string.format(
    "%s |cffffffff%d|r   %s |cffffffff%d|r",
    L("Throttled"), throttled, L("Bubbles suppressed"), bubbles))
end

local function RenderBodyFlex(entry)
  if not detailPane or not detailPane.body then return end
  local body = detailPane.body
  local original = entry and entry.original or ""
  if #original > MAX_ORIGINAL_CHARS then
    original = original:sub(1, MAX_ORIGINAL_CHARS) .. " \226\128\166(truncated)"
  end
  body.text:SetText(original)

  -- Auto-size: measure FontString natural height and set frame height to match.
  local naturalHeight = body.text:GetStringHeight() or 0
  local desired = math.max(naturalHeight + 16, 80)  -- 16 = top+bottom padding; 80 = min
  body:SetHeight(desired)
end

local function RenderBreakdownChips(breakdown)
  if not detailPane or not detailPane.footer or not detailPane.footer.breakdownRow then return end
  local row = detailPane.footer.breakdownRow
  row.chips = row.chips or {}

  for _, chip in ipairs(row.chips) do chip:Hide() end

  if type(breakdown) ~= "table" then return end

  local sorted = {}
  for cat, val in pairs(breakdown) do
    if cat ~= "MixedScript" and (tonumber(val) or 0) > 0 then
      sorted[#sorted + 1] = { cat = cat, val = val }
    end
  end
  table.sort(sorted, function(a, b) return (a.val or 0) > (b.val or 0) end)

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
      row.chips[index] = chip
    end
    local hex = CATEGORY_COLORS[item.cat] or "888"
    if chip.SetBackdropColor then
      chip:SetBackdropColor(HexNibble(hex, 1), HexNibble(hex, 2), HexNibble(hex, 3), 1)
    end
    chip.label:SetText(string.format("|cff000000%s +%d|r", item.cat, item.val))
    chip:SetSize(80, 14)
    chip:ClearAllPoints()
    chip:SetPoint("LEFT", row, "LEFT", xOffset, 0)
    chip:Show()
    xOffset = xOffset + 84
  end
end

RefreshDetail = function()
  if not detailPane or not detailPane.sections then return end

  local entries = CurrentEntries()
  if #entries == 0 then
    ShowEmptyState(true)
    RefreshStatsArea()
    return
  end
  ShowEmptyState(false)

  local entry = FindEntryById(selectedEntryId)
  if not entry then
    local sorted = ApplyFilterAndSort(entries)
    entry = sorted[1]
    if entry then selectedEntryId = entry.id end
  end
  if not entry then RefreshStatsArea() return end

  -- Header
  local channel      = FormatChannel(entry)
  local linkSuffix   = entry.containsItemLinks and ("   " .. L("contains item link")) or ""
  local surfaceLabel = (entry.surface and SURFACE_LABELS[entry.surface]) or entry.surface or "?"
  detailPane.header.senderText:SetText(FormatSender(entry))

  local outcome = entry.outcome or "blocked"
  local statusText
  local pauseReason = ""
  if outcome == "restored" then
    statusText = "|cff5ad080" .. L("RESTORED") .. "|r"
  elseif outcome == "pass-thru" then
    statusText = "|cffaa7a3a" .. L("PASSED THROUGH") .. "|r"
    local surfaceKey = entry.surface or "chat"
    local surfaceState = NS.PauseState and NS.PauseState.GetSurface and NS.PauseState.GetSurface(surfaceKey) or "active"
    if surfaceState == "paused" then
      pauseReason = "   " .. L(surfaceLabel) .. " " .. L("surface paused")
    end
  else
    statusText = "|cffff5577" .. L("BLOCKED") .. "|r"
  end
  statusText = statusText .. string.format("   %d / %d",
    tonumber(entry.score) or 0, tonumber(entry.threshold) or 0)
  detailPane.header.statusText:SetText(statusText)
  detailPane.header.metaText:SetText(string.format("%s   %s%s%s",
    L(surfaceLabel), channel, linkSuffix, pauseReason))

  RenderBodyFlex(entry)
  RenderBreakdownChips(entry.breakdown)
  RenderSenderHistory(entry)
  RenderActions(entry)
  RefreshStatsArea()
end

RefreshList = function()
  if not listPane or not listPane.scroll then return end

  local allEntries = GetEntries() or {}
  currentEntriesSnapshot = allEntries
  UpdateHistoryStatsText()
  local filtered = ApplyFilterAndSort(allEntries)
  local provider = listPane.scroll:GetDataProvider()
  provider:Flush()
  provider:InsertTable(filtered)
  RefreshDetail()
  currentEntriesSnapshot = nil
end

SelectEntry = function(id)
  selectedEntryId = id
  if RefreshDetail then RefreshDetail() end
  -- Update the existing-selection visual on rendered rows without rebuilding
  -- the data provider (which would reset scroll). The ScrollBox's
  -- ForEachFrame iterates current visible rows.
  if listPane and listPane.scroll and listPane.scroll.ForEachFrame then
    listPane.scroll:ForEachFrame(function(rowFrame, entryData)
      if rowFrame.selection then
        rowFrame.selection:SetShown(selectedEntryId == entryData.id)
      end
    end)
  end
end

local function InitListRow(button)
  if button.bsInit then return end
  button.bsInit = true

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
  button.senderText:SetPoint("RIGHT", button,          "RIGHT", -94, 0)
  button.senderText:SetJustifyH("LEFT")

  button.badgeText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  button.badgeText:SetPoint("RIGHT", button, "RIGHT", -34, 0)
  button.badgeText:SetWidth(54)
  button.badgeText:SetJustifyH("CENTER")

  button.scoreText = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  button.scoreText:SetPoint("RIGHT", button, "RIGHT", -4, 0)
  button.scoreText:SetWidth(30)
  button.scoreText:SetJustifyH("RIGHT")

  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
end

local function CreateListPane()
  local FILTER_STRIP_HEIGHT = 54
  -- listPane.filterStrip is created by CreateHeaderFilters; anchor below it.
  -- Column-header strip below the filter strip. Right anchor subtracts
  -- SCROLLBAR_GUTTER so headers align with row column positions.
  local header = CreateFrame("Frame", nil, listPane)
  header:SetHeight(18)
  header:SetPoint("TOPLEFT",  listPane, "TOPLEFT",  0, -FILTER_STRIP_HEIGHT)
  header:SetPoint("TOPRIGHT", listPane, "TOPRIGHT", -SCROLLBAR_GUTTER, -FILTER_STRIP_HEIGHT)
  listPane.columnHeader = header

  header.timeLabel = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header.timeLabel:SetPoint("LEFT", header, "LEFT", 10, 0)
  header.timeLabel:SetWidth(36)
  header.timeLabel:SetJustifyH("CENTER")
  header.timeLabel:SetText("Time")

  header.senderLabel = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header.senderLabel:SetPoint("LEFT",  header.timeLabel, "RIGHT",  4, 0)
  header.senderLabel:SetPoint("RIGHT", header,           "RIGHT", -94, 0)
  header.senderLabel:SetJustifyH("CENTER")
  header.senderLabel:SetText("Sender")

  header.badgeLabel = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header.badgeLabel:SetPoint("RIGHT", header, "RIGHT", -34, 0)
  header.badgeLabel:SetWidth(54)
  header.badgeLabel:SetJustifyH("CENTER")
  header.badgeLabel:SetText("Category")

  header.scoreLabel = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header.scoreLabel:SetPoint("RIGHT", header, "RIGHT", -4, 0)
  header.scoreLabel:SetWidth(30)
  header.scoreLabel:SetJustifyH("CENTER")
  header.scoreLabel:SetText("Score")

  local scrollBox = CreateFrame("Frame", nil, listPane, "WowScrollBoxList")
  scrollBox:SetPoint("TOPLEFT",     listPane, "TOPLEFT",     0, -(FILTER_STRIP_HEIGHT + 18))
  scrollBox:SetPoint("BOTTOMRIGHT", listPane, "BOTTOMRIGHT", -SCROLLBAR_GUTTER, 18)

  local scrollBar = CreateFrame("EventFrame", nil, listPane, "MinimalScrollBar")
  scrollBar:SetPoint("TOPLEFT",    scrollBox, "TOPRIGHT",    0,  0)
  scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 0,  0)
  scrollBar:SetHideIfUnscrollable(false)

  local view = CreateScrollBoxListLinearView()
  view:SetElementExtent(LIST_ROW_HEIGHT)
  view:SetElementInitializer("Button", function(button, entry)
    InitListRow(button)
    RenderRow(button, entry)
    button.selection:SetShown(selectedEntryId == entry.id)
    button:SetScript("OnClick", function(self, mouseButton)
      if mouseButton == "RightButton" then
        self._lastClick = nil
        OpenRowContextMenu(self, entry)
        return
      end
      local now = GetTime()
      if self._lastClick and (now - self._lastClick) < DOUBLE_CLICK_WINDOW then
        self._lastClick = nil
        PerformRestore(entry)
        if ContextEntryCanAllowlist(entry) then
          PerformAlwaysAllow(entry)
        end
      else
        self._lastClick = now
        SelectEntry(entry.id)
      end
    end)
  end)
  view:SetElementResetter(function(button)
    button:SetScript("OnClick", nil)
    button.selection:Hide()
    button._lastClick = nil
  end)

  ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
  view:SetDataProvider(CreateDataProvider())

  listPane.scroll = scrollBox

  local legend = CreateFrame("Frame", nil, listPane)
  legend:SetHeight(18)
  legend:SetPoint("BOTTOMLEFT",  listPane, "BOTTOMLEFT",  0, 0)
  legend:SetPoint("BOTTOMRIGHT", listPane, "BOTTOMRIGHT", 0, 0)

  local lx = 4
  for _, cat in ipairs(CATEGORIES) do
    local hex = CATEGORY_COLORS[cat] or "888"
    local swatch = legend:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(10, 10)
    swatch:SetPoint("LEFT", legend, "LEFT", lx, 0)
    swatch:SetColorTexture(HexNibble(hex, 1), HexNibble(hex, 2), HexNibble(hex, 3), 1)

    local label = legend:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    label:SetPoint("LEFT", swatch, "RIGHT", 3, 0)
    label:SetText(cat)

    lx = lx + 12 + label:GetStringWidth() + 8
  end

  listPane.legend = legend
end

local function PlaceStatsTiles(stats)
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

local function BuildStatsArea(parent)
  parent.titleLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  parent.titleLabel:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -6)
  parent.titleLabel:SetText(L("DETECTION STATS"))

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
    tile.labelText = tile:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    tile.labelText:SetPoint("BOTTOM", tile, "BOTTOM", 0, 4)
    tile.labelText:SetText(L(STATS_TILE_LABELS[key]))
    parent.tiles[key] = tile
  end
  parent.tilesRow:SetScript("OnSizeChanged", function() PlaceStatsTiles(parent) end)
  PlaceStatsTiles(parent)

  parent.bySurfaceLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  parent.bySurfaceLabel:SetPoint("TOPLEFT", parent.tilesRow, "BOTTOMLEFT", 0, -8)
  parent.bySurfaceLabel:SetText(L("BY SURFACE"))

  parent.bySurfaceText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  parent.bySurfaceText:SetPoint("TOPLEFT",  parent.bySurfaceLabel, "BOTTOMLEFT", 0, -2)
  parent.bySurfaceText:SetPoint("TOPRIGHT", parent, "RIGHT", -10, 0)
  parent.bySurfaceText:SetJustifyH("LEFT")
  parent.bySurfaceText:SetWordWrap(true)

  parent.byCategoryLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  parent.byCategoryLabel:SetPoint("TOPLEFT", parent.bySurfaceText, "BOTTOMLEFT", 0, -8)
  parent.byCategoryLabel:SetText(L("BY CATEGORY"))

  parent.byCategoryText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  parent.byCategoryText:SetPoint("TOPLEFT",  parent.byCategoryLabel, "BOTTOMLEFT", 0, -2)
  parent.byCategoryText:SetPoint("TOPRIGHT", parent, "RIGHT", -10, 0)
  parent.byCategoryText:SetJustifyH("LEFT")
  parent.byCategoryText:SetWordWrap(true)

  parent.pipelineLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  parent.pipelineLabel:SetPoint("TOPLEFT", parent.byCategoryText, "BOTTOMLEFT", 0, -8)
  parent.pipelineLabel:SetText(L("PIPELINE"))

  parent.pipelineText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  parent.pipelineText:SetPoint("TOPLEFT", parent.pipelineLabel, "BOTTOMLEFT", 0, -2)
  parent.pipelineText:SetPoint("RIGHT",   parent, "RIGHT", -10, 0)
  parent.pipelineText:SetJustifyH("LEFT")
end

local function BuildEmptyState(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("CENTER", f, "CENTER", 0, 40)
  f.title:SetText("No blocks yet.")

  f.subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.subtitle:SetPoint("CENTER", f, "CENTER", 0, 16)
  f.subtitle:SetText("BawrSpam is watching.")

  f.stats = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.stats:SetPoint("CENTER", f, "CENTER", 0, -12)
  f.stats:SetText("0 blocks recorded.")

  return f
end

local function CreateDetailPane()
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

  hdr.senderText = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  hdr.senderText:SetPoint("TOPLEFT", hdr, "TOPLEFT", 10, -6)

  hdr.statusText = hdr:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hdr.statusText:SetPoint("TOPRIGHT", hdr, "TOPRIGHT", -10, -6)

  hdr.metaText = hdr:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
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

  footer.senderHistory = footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
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

  detailPane.footer = footer
  detailPane.actions = { btn1 = footer.btn1, btn2 = footer.btn2 }
  detailPane.sections.footer = footer

  -- Stats area (flex-grow to fill below footer)
  local stats = CreateFrame("Frame", nil, detailPane)
  stats:SetPoint("TOPLEFT",     footer, "BOTTOMLEFT",  0, -6)
  stats:SetPoint("TOPRIGHT",    footer, "BOTTOMRIGHT", 0, -6)
  stats:SetPoint("BOTTOMLEFT",  detailPane, "BOTTOMLEFT",  0, 0)
  stats:SetPoint("BOTTOMRIGHT", detailPane, "BOTTOMRIGHT", 0, 0)
  BuildStatsArea(stats)
  detailPane.stats = stats
  detailPane.sections.stats = stats

  -- Empty state placeholder (replaces header/body/footer when nothing selected)
  detailPane.empty = BuildEmptyState(detailPane)
  detailPane.empty:Hide()
end

local function UpdateChipVisual(chip, cat)
  if not filterState then return end
  local active = filterState.categories[cat] ~= false
  if active then
    chip:UnlockHighlight()
    chip:SetAlpha(1.0)
  else
    chip:SetAlpha(0.45)
  end
end

local CHIP_WIDTHS = {
  RMT        = 50,
  Boosting   = 72,
  Casino     = 60,
  Phishing   = 72,
  Commercial = 86,
  Anti       = 50,
}

local function BuildCategoryChips(strip)
  local chips = {}
  local x = 0
  for _, cat in ipairs(CATEGORIES) do
    local chip = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    local w = CHIP_WIDTHS[cat] or 60
    chip:SetSize(w, 22)
    chip:SetPoint("TOPLEFT", strip, "TOPLEFT", x, 0)
    chip:SetText(cat)
    chip:SetScript("OnClick", function()
      filterState.categories[cat] = (filterState.categories[cat] == false)
      UpdateChipVisual(chip, cat)
      if RefreshList then RefreshList() end
    end)
    UpdateChipVisual(chip, cat)
    chips[cat] = chip
    x = x + w + 4
  end
  strip.chips = chips
  return x
end

local function CreateModernDropdown(parent, labelText, values, labels, getValue, setValue)
  local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  dd:SetSize(110, 22)
  if dd.SetDefaultText then
    dd:SetDefaultText(L(labelText))
  end
  dd:SetupMenu(function(_, root)
    root:CreateTitle(L(labelText))
    for _, v in ipairs(values) do
      local displayLabel = (labels and labels[v]) or v
      root:CreateRadio(L(displayLabel),
        function() return getValue() == v end,
        function() setValue(v); dd:GenerateMenu() end)
    end
  end)
  return dd
end

local function CreateSenderFilterChip()
  local chip = CreateFrame("Frame", nil, frame)
  chip:SetPoint("TOPLEFT",  frame, "TOPLEFT",   8, -100)
  chip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -100)
  chip:SetHeight(18)
  chip:Hide()

  chip.label = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  chip.label:SetPoint("LEFT", chip, "LEFT", 4, 0)
  chip.label:SetText("")

  chip.clear = CreateFrame("Button", nil, chip, "UIPanelCloseButton")
  chip.clear:SetSize(18, 18)
  chip.clear:SetPoint("LEFT", chip.label, "RIGHT", 2, 0)
  chip.clear:SetScript("OnClick", ClearSenderFilter)

  frame.senderChip = chip
end

UpdateSenderFilterChip = function()
  -- BSP-008 Commit 4: chip show/hide only — listPane anchors are owned by
  -- CreatePanes + CreateSplitter (width is user-resizable and persisted), so
  -- this no longer re-anchors listPane the way it did before the restructure.
  -- Chip placement vs. the in-listPane filter strip will be reworked in a
  -- later commit; for now the chip remains visible/hideable as before.
  if not frame or not frame.senderChip or not listPane then return end
  local chip = frame.senderChip
  if filterState and filterState.senderFilter then
    chip.label:SetText("|cff58a0ffFiltering by:|r " .. FormatSender(filterState.senderFilter))
    chip:Show()
  else
    chip:Hide()
  end
end

local function SetTabHighlight()
  for mode, button in pairs(tabButtons) do
    if mode == activeMode then
      button:LockHighlight()
    else
      button:UnlockHighlight()
    end
  end
end

local function ShowHistoryContent()
  activeMode = "History"
  if configHost then configHost:Hide() end
  if listPane then listPane:Show() end
  if detailPane then detailPane:Show() end
  if frame and frame.filterStrip then frame.filterStrip:Show() end
  UpdateSenderFilterChip()
  SetTabHighlight()
end

local function ShowConfigContent(section)
  activeMode = "Config"
  activeConfigSection = section or activeConfigSection or "Detection"
  if frame and frame.filterStrip then frame.filterStrip:Hide() end
  if frame and frame.senderChip then frame.senderChip:Hide() end
  if listPane then listPane:Hide() end
  if detailPane then detailPane:Hide() end
  if configHost then
    configHost:Show()
    if NS.ConfigPanel and NS.ConfigPanel.Attach then
      NS.ConfigPanel.Attach(configHost, activeConfigSection)
    end
  end
  SetTabHighlight()
end

local function CreateTabStrip(parent)
  local strip = CreateFrame("Frame", nil, parent)
  strip:SetHeight(30)
  strip:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 8, 6)
  strip:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 6)

  local history = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
  history:SetSize(92, 24)
  history:SetPoint("LEFT", strip, "LEFT", 0, 0)
  history:SetText("History")
  history:SetScript("OnClick", function()
    HistoryPanel.Show()
  end)
  tabButtons.History = history

  local config = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
  config:SetSize(92, 24)
  config:SetPoint("LEFT", history, "RIGHT", 6, 0)
  config:SetText("Config")
  config:SetScript("OnClick", function()
    HistoryPanel.ShowConfig(activeConfigSection)
  end)
  tabButtons.Config = config
  parent.tabStrip = strip
end

local function CreateHeaderFilters()
  local strip = CreateFrame("Frame", nil, listPane)
  strip:SetHeight(54)
  strip:SetPoint("TOPLEFT",  listPane, "TOPLEFT",  0, 0)
  strip:SetPoint("TOPRIGHT", listPane, "TOPRIGHT", 0, 0)
  listPane.filterStrip = strip
  frame.filterStrip = strip -- preserved for legacy callers that reference frame.filterStrip

  -- Row 1: category chips
  local chipsRow = CreateFrame("Frame", nil, strip)
  chipsRow:SetHeight(24)
  chipsRow:SetPoint("TOPLEFT",  strip, "TOPLEFT",  4, -2)
  chipsRow:SetPoint("TOPRIGHT", strip, "TOPRIGHT", -4, -2)
  BuildCategoryChips(chipsRow)

  -- Row 2: dropdowns + Refresh
  local ddRow = CreateFrame("Frame", nil, strip)
  ddRow:SetHeight(24)
  ddRow:SetPoint("TOPLEFT",  chipsRow, "BOTTOMLEFT",  0, -4)
  ddRow:SetPoint("TOPRIGHT", chipsRow, "BOTTOMRIGHT", 0, -4)

  strip.surfaceDD = CreateModernDropdown(ddRow, "Surface", SURFACE_VALUES, SURFACE_LABELS,
    function() return filterState.surface end,
    function(v) filterState.surface = v; if RefreshList then RefreshList() end end)
  strip.surfaceDD:SetPoint("LEFT", ddRow, "LEFT", 0, 0)

  strip.timeDD = CreateModernDropdown(ddRow, "Time", TIME_WINDOW_VALUES, nil,
    function() return filterState.timeWindow end,
    function(v) filterState.timeWindow = v; if RefreshList then RefreshList() end end)
  strip.timeDD:SetPoint("LEFT", strip.surfaceDD, "RIGHT", 4, 0)

  strip.outcomeDD = CreateModernDropdown(ddRow, "Outcome", OUTCOME_VALUES, nil,
    function() return filterState.outcome end,
    function(v) filterState.outcome = v; if RefreshList then RefreshList() end end)
  strip.outcomeDD:SetPoint("LEFT", strip.timeDD, "RIGHT", 4, 0)

  strip.sortDD = CreateModernDropdown(ddRow, "Sort", SORT_VALUES, SORT_LABELS,
    function() return sortMode end,
    function(v) sortMode = v; if RefreshList then RefreshList() end end)
  strip.sortDD:SetPoint("LEFT", strip.outcomeDD, "RIGHT", 4, 0)

  local refresh = CreateFrame("Button", nil, ddRow, "UIPanelButtonTemplate")
  refresh:SetSize(60, 22)
  refresh:SetPoint("RIGHT", ddRow, "RIGHT", 0, 0)
  refresh:SetText(L("Refresh"))
  refresh:SetScript("OnClick", function()
    if RefreshList then RefreshList() end
  end)
  strip.refresh = refresh
end

local function ClampPanes(parent)
  if not listPane or not detailPane or not parent then return end
  local parentWidth = parent:GetWidth()
  if not parentWidth or parentWidth <= 0 then return end
  local maxList = parentWidth - SPLITTER_WIDTH - MIN_DETAIL_PANE_WIDTH - 16
  -- 16 = left margin 6 + post-splitter gap 4 + right margin 6
  local currentList = listPane:GetWidth()
  local clamped = currentList
  if clamped < MIN_LIST_PANE_WIDTH then clamped = MIN_LIST_PANE_WIDTH end
  if clamped > maxList then clamped = maxList end
  if clamped < MIN_LIST_PANE_WIDTH then clamped = MIN_LIST_PANE_WIDTH end
  if clamped ~= currentList then
    listPane:SetWidth(clamped)
  end
  detailPane:ClearAllPoints()
  detailPane:SetPoint("TOPLEFT",     parent, "TOPLEFT",     6 + clamped + SPLITTER_WIDTH + 4, -64)
  detailPane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 40)
end

local function CreateSplitter(parent)
  local splitter = CreateFrame("Button", nil, parent)
  splitter:SetWidth(SPLITTER_WIDTH)
  splitter:SetPoint("TOPLEFT",    listPane, "TOPRIGHT", 0, 0)
  splitter:SetPoint("BOTTOMLEFT", listPane, "BOTTOMRIGHT", 0, 0)

  splitter.tex = splitter:CreateTexture(nil, "ARTWORK")
  splitter.tex:SetAllPoints(splitter)
  splitter.tex:SetColorTexture(0.23, 0.23, 0.27, 1)

  splitter.hoverTex = splitter:CreateTexture(nil, "HIGHLIGHT")
  splitter.hoverTex:SetAllPoints(splitter)
  splitter.hoverTex:SetColorTexture(0.45, 0.45, 0.55, 1)

  splitter:EnableMouse(true)
  splitter:RegisterForDrag("LeftButton")
  splitter.dragging = false

  splitter:SetScript("OnMouseDown", function(self) self.dragging = true end)
  splitter:SetScript("OnMouseUp",   function(self)
    self.dragging = false
    SaveListPaneWidth(listPane:GetWidth())
  end)

  splitter:SetScript("OnUpdate", function(self)
    if not self.dragging then return end
    local scale = parent:GetEffectiveScale()
    local cx = select(1, GetCursorPosition()) / scale
    local parentLeft = parent:GetLeft()
    if not parentLeft then return end
    local localX = cx - parentLeft - 6  -- 6 matches CreatePanes TOPLEFT offset
    if localX < MIN_LIST_PANE_WIDTH then localX = MIN_LIST_PANE_WIDTH end
    local maxList = parent:GetWidth() - SPLITTER_WIDTH - MIN_DETAIL_PANE_WIDTH - 16
    -- 16 = left margin 6 + post-splitter gap 4 + right margin 6
    if localX > maxList then localX = maxList end
    listPane:SetWidth(localX)
    detailPane:ClearAllPoints()
    detailPane:SetPoint("TOPLEFT",     parent, "TOPLEFT",     6 + localX + SPLITTER_WIDTH + 4, -64)
    detailPane:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 40)
  end)

  parent.splitter = splitter
  return splitter
end

local pauseRow, pausePills

local PAUSE_PILL_KEYS = { "chat", "whisper", "bn-whisper", "lfg-search", "lfg-applicant" }
local PAUSE_PILL_LABELS = {
  chat              = "Chat",
  whisper           = "Whisp",
  ["bn-whisper"]    = "Bnet",
  ["lfg-search"]    = "LFG-s",
  ["lfg-applicant"] = "LFG-a",
}
local PAUSE_STATE_COLOR = {
  active = { 0.35, 0.82, 0.50 },  -- green
  paused = { 0.83, 0.69, 0.28 },  -- yellow
  off    = { 1.00, 0.33, 0.46 },  -- red
}
local PAUSE_STATE_GLYPH = { active = "●", paused = "⏸", off = "⊘" }

local function CreatePauseRow(parent)
  pauseRow = CreateFrame("Frame", nil, parent)
  pauseRow:SetHeight(20)
  if parent.TitleContainer then
    pauseRow:SetPoint("TOPRIGHT", parent.TitleContainer, "BOTTOMRIGHT", -28, -2)
  else
    pauseRow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -32, -32)
  end

  pausePills = {}
  local previousPill
  for i = #PAUSE_PILL_KEYS, 1, -1 do
    local surfaceKey = PAUSE_PILL_KEYS[i]
    local pill = CreateFrame("Button", nil, pauseRow)
    pill:SetSize(60, 18)
    if previousPill then
      pill:SetPoint("RIGHT", previousPill, "LEFT", -4, 0)
    else
      pill:SetPoint("RIGHT", pauseRow, "RIGHT", 0, 0)
    end
    pill:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    pill.surfaceKey = surfaceKey

    pill.bg = pill:CreateTexture(nil, "BACKGROUND")
    pill.bg:SetAllPoints(pill)
    pill.bg:SetColorTexture(0.13, 0.13, 0.16, 0.95)

    pill.glyph = pill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pill.glyph:SetPoint("LEFT", pill, "LEFT", 4, 0)

    pill.label = pill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pill.label:SetPoint("LEFT", pill.glyph, "RIGHT", 2, 0)
    pill.label:SetText(L(PAUSE_PILL_LABELS[surfaceKey]))

    -- BSP-008 Commit 6: left-click cycles forward, right-click cycles backward.
    pill:SetScript("OnClick", function(self, mouseButton)
      if not NS.PauseState then return end
      local direction = (mouseButton == "RightButton") and "backward" or "forward"
      NS.PauseState.CycleSurface(self.surfaceKey, direction)
    end)

    pausePills[surfaceKey] = pill
    previousPill = pill
  end

  return pauseRow
end

-- Public API for the listener (wired in Commit 6).
function HistoryPanel.RefreshPauseRow()
  if not pausePills or not NS.PauseState then return end
  for surfaceKey, pill in pairs(pausePills) do
    local state = NS.PauseState.GetSurface(surfaceKey)
    local color = PAUSE_STATE_COLOR[state]
    local glyph = PAUSE_STATE_GLYPH[state] or "●"
    pill.glyph:SetText(glyph)
    if color then
      pill.glyph:SetTextColor(color[1], color[2], color[3])
    end
  end
end

local function BuildFrame()
  if frame then return end

  frame = CreateBackdropFrame(UIParent)
  frame:SetMovable(true)
  frame:SetResizable(true)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(MIN_PANEL_WIDTH, MIN_PANEL_HEIGHT)
  end

  -- Title-bar drag — TitleContainer is the modern drag region.
  if frame.TitleContainer then
    frame.TitleContainer:EnableMouse(true)
    frame.TitleContainer:RegisterForDrag("LeftButton")
    frame.TitleContainer:SetScript("OnDragStart", function() frame:StartMoving() end)
    frame.TitleContainer:SetScript("OnDragStop", function()
      frame:StopMovingOrSizing()
      SavePosition()
    end)
  end

  CreateResizeHandle(frame)
  CreatePauseRow(frame)
  if HistoryPanel.RefreshPauseRow then HistoryPanel.RefreshPauseRow() end
  listPane, detailPane = CreatePanes(frame)
  CreateSplitter(frame)
  CreateListPane()
  CreateDetailPane()
  CreateHeaderFilters()
  CreateSenderFilterChip()
  configHost = CreateFrame("Frame", nil, frame)
  configHost:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -40)
  configHost:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 40)
  configHost:Hide()
  CreateTabStrip(frame)
  UpdateSenderFilterChip()

  frame:SetScript("OnSizeChanged", function()
    sizeDirty = true
    ClampPanes(frame)
    if listPane and listPane.scroll then listPane.scroll:FullUpdate() end
  end)
  frame:SetScript("OnHide", function()
    if sizeDirty then SaveSize() end
  end)

  ApplyStoredGeometry()
  tinsert(UISpecialFrames, "BawrSpamHistoryFrame")
end

local function RegisterMinimap()
	local LDB     = LibStub and LibStub("LibDataBroker-1.1", true)
	local LDBIcon = LibStub and LibStub("LibDBIcon-1.0",      true)
	if not LDB or not LDBIcon then return end

  minimapLDB = LDB:NewDataObject("BawrSpam", {
    type  = "launcher",
    text  = "BawrSpam",
    icon  = "Interface\\Icons\\INV_Misc_Note_03",
    OnClick = function(self, button)
      if button == "RightButton" then
        if not MenuUtil or not MenuUtil.CreateContextMenu then
          OpenConfigPanel()
          return
        end
        MenuUtil.CreateContextMenu(self, function(_, root)
          root:CreateTitle(L("BawrSpam"))
          local submenu = root:CreateButton(L("Pause surface"))
          local surfaceKeys = NS.PauseState and NS.PauseState.GetSurfaceKeys() or {}
          for _, surfaceKey in ipairs(surfaceKeys) do
            local labelText = SURFACE_LABELS[surfaceKey] or surfaceKey
            local glyphFn = function()
              local s = NS.PauseState and NS.PauseState.GetSurface(surfaceKey) or "active"
              if s == "active" then return "|cff5ad080\226\151\143|r" end
              if s == "paused" then return "|cffd4b048\226\143\184|r" end
              return "|cffff5577\226\138\152|r"
            end
            submenu:CreateButton(L(labelText) .. "  " .. glyphFn(), function()
              if NS.PauseState then NS.PauseState.CycleSurface(surfaceKey, "forward") end
            end)
          end
          root:CreateDivider()
          root:CreateButton(L("Open config"), function() OpenConfigPanel() end)
        end)
      else
        HistoryPanel.Toggle()
      end
    end,
    OnTooltipShow = function(tooltip)
      tooltip:AddLine("BawrSpam")
      tooltip:AddLine("Left-click to toggle history.", 1, 1, 1)
      tooltip:AddLine("Right-click to open config.", 1, 1, 1)
    end,
  })

	local settings = GetSettings()
	minimapOptions = minimapOptions or {}
	minimapOptions.hide = settings.showMinimapButton == false
	pcall(LDBIcon.Register, LDBIcon, "BawrSpam", minimapLDB, minimapOptions)
end

function HistoryPanel.Initialize()
  filterState = DefaultFilterState()
  sortMode = "newest"
  RegisterStaticPopups()
  RegisterMinimap()

  -- BSP-008 Commit 6: react to PauseState changes (header pills, ConfigPanel,
  -- minimap submenu). RefreshPauseRow re-paints the header chrome; a
  -- category-axis change additionally re-renders the BY CATEGORY detail row.
  if NS.PauseState and NS.PauseState.RegisterListener then
    NS.PauseState.RegisterListener(function(axis, key, state)
      if HistoryPanel.RefreshPauseRow then HistoryPanel.RefreshPauseRow() end
      if axis == "category" and RefreshDetail then RefreshDetail() end
    end)
  end
end

function HistoryPanel.Toggle()
  BuildFrame()
  if frame:IsShown() and activeMode == "History" then
    frame:Hide()
  else
    HistoryPanel.Show()
  end
end

function HistoryPanel.Show()
  BuildFrame()
  ShowHistoryContent()
  RefreshList()
  frame:Show()
end

function HistoryPanel.ShowConfig(section)
  BuildFrame()
  ShowConfigContent(section)
  frame:Show()
end

function HistoryPanel.Hide()
  if frame then frame:Hide() end
end

function HistoryPanel.IsShown()
	return frame ~= nil and frame:IsShown()
end

function HistoryPanel.ResetPosition()
	ClearStoredGeometry()
	if frame then
		frame:SetSize(DEFAULT_PANEL_WIDTH, DEFAULT_PANEL_HEIGHT)
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
		SaveSize()
	end
end

function HistoryPanel.RefreshMinimap()
	local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
	if not LDBIcon then return end
	if not minimapLDB then
		RegisterMinimap()
	end
	if minimapOptions then
		pcall(LDBIcon.Refresh, LDBIcon, "BawrSpam", minimapOptions)
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
		RegisterMinimap()
	end
	if value then
		pcall(LDBIcon.Show, LDBIcon, "BawrSpam")
	else
		pcall(LDBIcon.Hide, LDBIcon, "BawrSpam")
	end
	HistoryPanel.RefreshMinimap()
end

NS.HistoryPanel = HistoryPanel
return HistoryPanel
