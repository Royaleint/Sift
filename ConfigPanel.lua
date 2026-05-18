local _, NS = ...
local ConfigPanel = {}

-- BSP-008: i18n hook. Identity today; future Locale ticket retrofits L.
local function L(s) return s end

local DEFAULT_WIDTH = 700
local DEFAULT_HEIGHT = 500
local MIN_WIDTH = 600
local MIN_HEIGHT = 400
local NAV_WIDTH = 128
local CONTENT_PAD = 14
local ROW_HEIGHT = 32
local PAGE_ROWS = 8

local SECTIONS = {
  "Detection",
  "Categories",
  "Surfaces",
  "Allowlist",
  "Blocked",
  "History",
  "UI",
  "Dev",
}

local CATEGORY_KEYS = { "RMT", "Boosting", "Casino", "Phishing", "Commercial", "Anti" }

local SURFACE_KEYS = { "chat", "whisper", "bn-whisper", "lfg-search", "lfg-applicant" }
local SURFACE_LABELS = {
  chat              = "Chat",
  whisper           = "Whisper",
  ["bn-whisper"]    = "Bnet whisper",
  ["lfg-search"]    = "LFG search",
  ["lfg-applicant"] = "LFG applicant",
}

local DEFAULT_SETTINGS = {
  threshold = 4,
  enabledCategories = {
    RMT = true,
    Boosting = true,
    Casino = true,
    Phishing = true,
    Commercial = true,
    Anti = true,
  },
  mixedScriptEnabled = true,
  mixedScriptWeight = 1,
  antiSignalCap = -5,
  filterBubbles = false,
  lfgScanEnabled = true,
  historyMaxEntries = 300,
  showMinimapButton = true,
  devMode = false,
}

local frame
local content
local navButtons = {}
local activeSection = "Detection"
local sizeDirty
local embeddedMode
local initialized
local interfaceRegistered
local popupsRegistered
local aceWidgets = {}
local nativeChildren = {}
local sectionStatus = {}
local removedAllowlistEntry
local pendingImport
local pendingHistoryMax
local dialogFrame

local listState = {
  allowlistSearch = "",
  allowlistPage = 1,
  allowlistAddText = "",
  blockedSearch = "",
  blockedPage = 1,
}

local function Print(message)
  message = "|cff33ff99BawrSpam|r " .. tostring(message)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(message)
  else
    print(message)
  end
end

local function DevLog(message)
  if NS.DB and NS.DB.IsDevMode and NS.DB.IsDevMode() then
    Print(message)
  end
end

local function Now()
  if type(GetServerTime) == "function" then
    return GetServerTime()
  end
  return time()
end

local function EnsureAceGUI()
  if not LibStub then
    return nil
  end
  return LibStub("AceGUI-3.0", true)
end

local function GetSettings()
  if NS.DB and NS.DB.GetSettings then
    return NS.DB.GetSettings()
  end
  return nil
end

local function GetGlobal()
  if NS.DB and NS.DB.GetGlobal then
    return NS.DB.GetGlobal()
  end
  return nil
end

local function GetChar()
  if NS.DB and NS.DB.GetChar then
    return NS.DB.GetChar()
  end
  local db = NS.DB and NS.DB.db
  return db and db.char
end

local function GetHistoryStats()
  if NS.History and NS.History.GetStats then
    return NS.History.GetStats()
  end

  local entries = NS.History and NS.History.GetAll and NS.History.GetAll() or {}
  return {
    lifetime = {
      detections = #entries,
      blocked = #entries,
      restored = 0,
    },
    retained = {
      detections = #entries,
      blocked = #entries,
      restored = 0,
    },
  }
end

local function CopyTable(tbl)
  local out = {}
  if type(tbl) == "table" then
    for key, value in pairs(tbl) do
      out[key] = value
    end
  end
  return out
end

local function SettingValue(key)
  local settings = GetSettings()
  if settings and settings[key] ~= nil then
    return settings[key]
  end
  return DEFAULT_SETTINGS[key]
end

local function SetSetting(key, value)
  if NS.DB and NS.DB.SetSetting then
    return NS.DB.SetSetting(key, value) ~= nil
  end

  local settings = GetSettings()
  if settings then
    settings[key] = value
    return true
  end
  return false
end

local function SetFilterBubblesEnabled(value)
  value = value == true
  SetSetting("filterBubbles", value)
  if not value and NS.BubbleSuppressor and NS.BubbleSuppressor.MaybeRestore then
    NS.BubbleSuppressor.MaybeRestore()
  end
end

local function SetLFGScanEnabled(value)
  value = value == true
  SetSetting("lfgScanEnabled", value)
  if NS.LFGScanner and NS.LFGScanner.SetEnabled then
    NS.LFGScanner.SetEnabled(value)
  end
end

local function ResetSettings()
  if NS.DB and NS.DB.ResetSettings then
    NS.DB.ResetSettings()
    return true
  end

  local settings = GetSettings()
  if not settings then
    return false
  end

  for key in pairs(settings) do
    settings[key] = nil
  end
  for key, value in pairs(DEFAULT_SETTINGS) do
    if type(value) == "table" then
      settings[key] = CopyTable(value)
    else
      settings[key] = value
    end
  end
  return true
end

local function ClampNumber(value, minValue, maxValue, fallback)
  value = tonumber(value) or fallback
  if value < minValue then value = minValue end
  if value > maxValue then value = maxValue end
  return value
end

local function ClearTable(tbl)
  if type(wipe) == "function" then
    wipe(tbl)
    return
  end
  for key in pairs(tbl) do
    tbl[key] = nil
  end
end

local function GetCharStore()
  local char = GetChar()
  if not char then
    return nil
  end
  char.configPanel = char.configPanel or {}
  return char.configPanel
end

local function SavePosition()
  if not frame then
    return
  end
  local store = GetCharStore()
  if not store then
    return
  end
  store.x = frame:GetLeft()
  store.y = frame:GetTop()
end

local function SaveSize()
  if not frame then
    return
  end
  local store = GetCharStore()
  if not store then
    return
  end
  store.width = frame:GetWidth()
  store.height = frame:GetHeight()
  sizeDirty = false
end

local function ApplyStoredGeometry()
  local store = GetCharStore() or {}
  local width = ClampNumber(store.width, MIN_WIDTH, 2000, DEFAULT_WIDTH)
  local height = ClampNumber(store.height, MIN_HEIGHT, 1600, DEFAULT_HEIGHT)

  frame:SetSize(width, height)
  frame:ClearAllPoints()
  if store.x and store.y then
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", store.x, store.y)
  else
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

local function TrackNative(child)
  nativeChildren[#nativeChildren + 1] = child
  return child
end

local function ReleaseContent()
  local AceGUI = EnsureAceGUI()
  if AceGUI then
    for _, widget in ipairs(aceWidgets) do
      AceGUI:Release(widget)
    end
  end
  aceWidgets = {}

  for _, child in ipairs(nativeChildren) do
    if child.Hide then child:Hide() end
    if child.ClearAllPoints then child:ClearAllPoints() end
  end
  nativeChildren = {}
end

local function AddText(text, template, x, y, width)
  local fs = TrackNative(content:CreateFontString(nil, "OVERLAY", template or "GameFontNormal"))
  fs:SetPoint("TOPLEFT", content, "TOPLEFT", x or CONTENT_PAD, y)
  if width then
    fs:SetWidth(width)
  else
    fs:SetPoint("RIGHT", content, "RIGHT", -CONTENT_PAD, 0)
  end
  fs:SetJustifyH("LEFT")
  fs:SetText(text or "")
  fs:Show()
  return fs
end

local function AddSectionTitle(title, subtitle)
  AddText(title, "GameFontNormalLarge", CONTENT_PAD, -12)
  if subtitle and subtitle ~= "" then
    local body = AddText(subtitle, "GameFontHighlightSmall", CONTENT_PAD, -36)
    body:SetWordWrap(true)
    return -70
  end
  return -48
end

local function AddStatus(y, message, good)
  if not message or message == "" then
    return y
  end

  local text = good and "|cff5ad080" or "|cffffd100"
  AddText(text .. message .. "|r", "GameFontHighlightSmall", CONTENT_PAD, y)
  return y - 22
end

local function AddNativeButton(label, x, y, width, onClick)
  local button = TrackNative(CreateFrame("Button", nil, content, "UIPanelButtonTemplate"))
  button:SetSize(width or 120, 24)
  button:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
  button:SetText(label)
  button:SetScript("OnClick", onClick)
  button:Show()
  return button
end

local function AddEditBox(x, y, width, initialText)
  local editBox = TrackNative(CreateFrame("EditBox", nil, content, "InputBoxTemplate"))
  editBox:SetSize(width or 180, 24)
  editBox:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
  editBox:SetAutoFocus(false)
  editBox:SetText(initialText or "")
  editBox:Show()
  return editBox
end

local function AddDisabledRow(label, value, y)
  local row = TrackNative(CreateFrame("Frame", nil, content, "BackdropTemplate"))
  row:SetHeight(30)
  row:SetPoint("TOPLEFT", content, "TOPLEFT", CONTENT_PAD, y)
  row:SetPoint("RIGHT", content, "RIGHT", -CONTENT_PAD, 0)
  if row.SetBackdrop then
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    row:SetBackdropColor(0.12, 0.12, 0.14, 0.55)
  end
  row:Show()

  local left = TrackNative(row:CreateFontString(nil, "OVERLAY", "GameFontDisable"))
  left:SetPoint("LEFT", row, "LEFT", 8, 0)
  left:SetJustifyH("LEFT")
  left:SetText(label)
  left:Show()

  local right = TrackNative(row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"))
  right:SetPoint("RIGHT", row, "RIGHT", -8, 0)
  right:SetJustifyH("RIGHT")
  right:SetText(value)
  right:Show()

  return y - 36
end

local function AddAceWidget(widgetType, x, y, width)
  local AceGUI = EnsureAceGUI()
  if not AceGUI then
    return nil
  end

  local widget = AceGUI:Create(widgetType)
  if not widget or not widget.frame then
    return nil
  end

  aceWidgets[#aceWidgets + 1] = widget
  widget.frame:SetParent(content)
  widget.frame:ClearAllPoints()
  widget.frame:SetPoint("TOPLEFT", content, "TOPLEFT", x or CONTENT_PAD, y)
  widget:SetWidth(width or 280)
  widget.frame:Show()
  return widget
end

local function AddSlider(label, key, minValue, maxValue, step, y)
  local slider = AddAceWidget("Slider", CONTENT_PAD, y, 330)
  if not slider then
    return AddDisabledRow(label, "AceGUI unavailable", y)
  end

  slider:SetLabel(label)
  slider:SetSliderValues(minValue, maxValue, step)
  slider:SetValue(tonumber(SettingValue(key)) or tonumber(DEFAULT_SETTINGS[key]) or minValue)
  slider:SetCallback("OnValueChanged", function(_, _, value)
    value = ClampNumber(value, minValue, maxValue, DEFAULT_SETTINGS[key] or minValue)
    if step >= 1 then
      value = math.floor(value + 0.5)
    end
    SetSetting(key, value)
  end)
  return y - 48
end

local function AddCheckbox(label, key, y, onChanged)
  local checkbox = AddAceWidget("CheckBox", CONTENT_PAD, y, 360)
  if not checkbox then
    return AddDisabledRow(label, "AceGUI unavailable", y)
  end

  checkbox:SetLabel(label)
  checkbox:SetValue(SettingValue(key) == true)
  checkbox:SetCallback("OnValueChanged", function(_, _, value)
    value = value == true
    if onChanged then
      onChanged(value)
    else
      SetSetting(key, value)
    end
  end)
  return y - 32
end

local function SectionExists(section)
  for _, name in ipairs(SECTIONS) do
    if name == section then
      return true
    end
  end
  return false
end

local function SetNavHighlight()
  for name, button in pairs(navButtons) do
    if name == activeSection then
      button:LockHighlight()
    else
      button:UnlockHighlight()
    end
  end
end

local function RelativeTime(ts)
  ts = tonumber(ts)
  if not ts then
    return "-"
  end
  local delta = Now() - ts
  if delta < 0 then return "0s" end
  if delta < 60 then return tostring(delta) .. "s" end
  if delta < 3600 then return tostring(math.floor(delta / 60)) .. "m" end
  if delta < 86400 then return tostring(math.floor(delta / 3600)) .. "h" end
  if delta < 90 * 86400 then return tostring(math.floor(delta / 86400)) .. "d" end
  return date("%Y-%m-%d", ts)
end

local function SenderLabel(entry)
  if type(entry) ~= "table" then
    return "?"
  end
  local name = entry.name or "?"
  if entry.realm and entry.realm ~= "" then
    return name .. "-" .. entry.realm
  end
  return name
end

local function Lower(value)
  return string.lower(tostring(value or ""))
end

local function MatchesSearch(entry, guid, search)
  search = Lower(search)
  if search == "" then
    return true
  end
  return string.find(Lower(guid), search, 1, true)
    or string.find(Lower(SenderLabel(entry)), search, 1, true)
    or string.find(Lower(entry and entry.source), search, 1, true)
end

local function SortedAllowlist()
  local allowlist = NS.Trust and NS.Trust.GetAllowlist and NS.Trust.GetAllowlist() or {}
  local out = {}
  for guid, entry in pairs(allowlist) do
    if type(guid) == "string" and type(entry) == "table"
       and MatchesSearch(entry, guid, listState.allowlistSearch) then
      out[#out + 1] = { guid = guid, entry = entry }
    end
  end
  table.sort(out, function(a, b)
    return Lower(SenderLabel(a.entry)) < Lower(SenderLabel(b.entry))
  end)
  return out
end

local function GetBlockedActors()
  local global = GetGlobal()
  if not global then
    return {}
  end
  global.blockedActors = global.blockedActors or {}
  return global.blockedActors
end

local function BlockedEntryLabel(key, entry)
  if type(entry) == "table" then
    local name = entry.name or entry.sender or entry.player
    local realm = entry.realm
    if name and realm and realm ~= "" then
      return tostring(name) .. "-" .. tostring(realm)
    end
    if name then
      return tostring(name)
    end
  end
  return tostring(key)
end

local function BlockedEntryCount(entry)
  if type(entry) == "table" then
    return tonumber(entry.count or entry.blockCount or entry.blocks or entry.total) or 1
  end
  return 1
end

local function BlockedEntryLastSeen(entry)
  if type(entry) == "table" then
    return entry.lastBlockedAt or entry.lastSeenAt or entry.updatedAt or entry.ts
  end
  return nil
end

local function SortedBlockedActors()
  local blocked = GetBlockedActors()
  local search = Lower(listState.blockedSearch)
  local out = {}
  for key, entry in pairs(blocked) do
    local label = BlockedEntryLabel(key, entry)
    if search == "" or string.find(Lower(key), search, 1, true)
       or string.find(Lower(label), search, 1, true) then
      out[#out + 1] = { key = key, entry = entry, label = label }
    end
  end
  table.sort(out, function(a, b)
    local ats = tonumber(BlockedEntryLastSeen(a.entry)) or 0
    local bts = tonumber(BlockedEntryLastSeen(b.entry)) or 0
    if ats ~= bts then
      return ats > bts
    end
    return Lower(a.label) < Lower(b.label)
  end)
  return out
end

local function MaxPage(total)
  local maxPage = math.ceil(total / PAGE_ROWS)
  if maxPage < 1 then
    maxPage = 1
  end
  return maxPage
end

local function FindHistorySender(text)
  text = tostring(text or "")
  local name, realm = string.match(text, "^%s*([^%-]+)%-(.-)%s*$")
  if not name or name == "" or not realm or realm == "" then
    return nil, "Enter a sender as Name-Realm."
  end

  local entries = NS.History and NS.History.GetAll and NS.History.GetAll() or {}
  local wantedName = Lower(name)
  local wantedRealm = Lower(realm)
  for _, entry in ipairs(entries) do
    if entry.guid and entry.guid ~= ""
       and Lower(entry.name) == wantedName
       and Lower(entry.realm) == wantedRealm then
      return entry
    end
  end

  return nil, "BawrSpam can only manually allow players already present in History."
end

local function AddAllowlistFromText(text)
  local entry, err = FindHistorySender(text)
  if not entry then
    sectionStatus.Allowlist = err
    return false
  end
  if not NS.Trust or not NS.Trust.AddAllowlist then
    sectionStatus.Allowlist = "Allowlist API is unavailable."
    return false
  end
  if NS.Trust.AddAllowlist(entry.guid, entry.name, entry.realm, "manual") then
    sectionStatus.Allowlist = "Added " .. SenderLabel(entry) .. "."
    listState.allowlistAddText = ""
    removedAllowlistEntry = nil
    return true
  end
  sectionStatus.Allowlist = SenderLabel(entry) .. " is already allowlisted."
  return false
end

local function RemoveAllowlist(guid, entry)
  if not NS.Trust or not NS.Trust.RemoveAllowlist then
    sectionStatus.Allowlist = "Allowlist API is unavailable."
    return
  end
  if NS.Trust.RemoveAllowlist(guid) then
    removedAllowlistEntry = { guid = guid, entry = CopyTable(entry) }
    sectionStatus.Allowlist = "Removed " .. SenderLabel(entry) .. "."
    ConfigPanel.ShowSection("Allowlist")
  end
end

local function UndoAllowlistRemove()
  local removed = removedAllowlistEntry
  if not removed or not NS.Trust or not NS.Trust.AddAllowlist then
    return
  end
  local entry = removed.entry or {}
  NS.Trust.AddAllowlist(removed.guid, entry.name, entry.realm, entry.source or "manual")
  removedAllowlistEntry = nil
  sectionStatus.Allowlist = "Restored " .. SenderLabel(entry) .. "."
  ConfigPanel.ShowSection("Allowlist")
end

local function RemoveBlocked(key)
  local blocked = GetBlockedActors()
  blocked[key] = nil
  sectionStatus.Blocked = "Removed blocked actor."
  ConfigPanel.ShowSection("Blocked")
end

local function RefreshHistoryPanelMinimap()
  if NS.HistoryPanel and NS.HistoryPanel.RefreshMinimap then
    NS.HistoryPanel.RefreshMinimap()
  end
end

local function SetHistoryPanelMinimapShown(shown)
  if NS.HistoryPanel and NS.HistoryPanel.SetMinimapShown then
    NS.HistoryPanel.SetMinimapShown(shown)
  end
  RefreshHistoryPanelMinimap()
end

local function EscapeField(value)
  value = tostring(value or "")
  value = string.gsub(value, "\\", "\\\\")
  value = string.gsub(value, "|", "\\p")
  value = string.gsub(value, "\r", "\\r")
  value = string.gsub(value, "\n", "\\n")
  return value
end

local function UnescapeField(value)
  local out = {}
  local i = 1
  while i <= #value do
    local ch = string.sub(value, i, i)
    if ch == "\\" then
      local nextCh = string.sub(value, i + 1, i + 1)
      if nextCh == "\\" then
        out[#out + 1] = "\\"
      elseif nextCh == "p" then
        out[#out + 1] = "|"
      elseif nextCh == "n" then
        out[#out + 1] = "\n"
      elseif nextCh == "r" then
        out[#out + 1] = "\r"
      else
        return nil
      end
      i = i + 2
    else
      out[#out + 1] = ch
      i = i + 1
    end
  end
  return table.concat(out)
end

local function SplitPipeFields(value)
  local fields = {}
  local field = {}
  local i = 1
  while i <= #value do
    local ch = string.sub(value, i, i)
    if ch == "\\" then
      local nextCh = string.sub(value, i + 1, i + 1)
      if nextCh == "\\" or nextCh == "p" or nextCh == "n" or nextCh == "r" then
        field[#field + 1] = ch .. nextCh
        i = i + 2
      else
        return nil
      end
    elseif ch == "|" then
      fields[#fields + 1] = table.concat(field)
      field = {}
      i = i + 1
    else
      field[#field + 1] = ch
      i = i + 1
    end
  end
  fields[#fields + 1] = table.concat(field)

  for index, raw in ipairs(fields) do
    local parsed = UnescapeField(raw)
    if parsed == nil then
      return nil
    end
    fields[index] = parsed
  end
  return fields
end

local function ValidGuid(guid)
  return type(guid) == "string"
    and guid ~= ""
    and string.find(guid, "-", 1, true) ~= nil
    and string.find(guid, "^[%w%-]+$") ~= nil
end

local function ValidName(value)
  return value == "" or (type(value) == "string" and not string.find(value, "[%c|]"))
end

local function ValidSource(value)
  return value == "" or value == "manual" or value == "history" or value == "import"
end

local function ParseImportText(text)
  local formatName
  local version
  local exportedAt
  local entries = {}
  local seenGuids = {}

  if type(text) ~= "string" or text == "" then
    return nil, "Import text is empty."
  end

  local lineNumber = 0
  for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
    lineNumber = lineNumber + 1
    line = string.gsub(line, "\r$", "")
    if line ~= "" then
      local key, value = string.match(line, "^([A-Za-z]+)=(.*)$")
      if not key then
        return nil, "Line " .. lineNumber .. " is not key=value."
      end

      if key == "format" then
        if formatName then return nil, "Duplicate format line." end
        formatName = value
      elseif key == "version" then
        if version then return nil, "Duplicate version line." end
        version = tonumber(value)
      elseif key == "exportedAt" then
        if exportedAt then return nil, "Duplicate exportedAt line." end
        exportedAt = tonumber(value)
      elseif key == "entry" then
        local fields = SplitPipeFields(value)
        if fields and #fields == 5 then
          fields[6] = ""
        end
        if not fields or #fields ~= 6 then
          return nil, "Line " .. lineNumber .. " must have 6 entry fields."
        end

        local guid = fields[1]
        local name = fields[2]
        local realm = fields[3]
        local source = fields[4]
        local addedAt = fields[5]
        local lastSeenAt = fields[6]

        if not ValidGuid(guid) then
          return nil, "Line " .. lineNumber .. " has an invalid GUID."
        end
        if seenGuids[guid] then
          return nil, "Line " .. lineNumber .. " repeats a GUID."
        end
        if not ValidName(name) or not ValidName(realm) then
          return nil, "Line " .. lineNumber .. " has invalid name fields."
        end
        if not ValidSource(source) then
          return nil, "Line " .. lineNumber .. " has an invalid source."
        end
        if addedAt ~= "" and not tonumber(addedAt) then
          return nil, "Line " .. lineNumber .. " has invalid addedAt."
        end
        if lastSeenAt ~= "" and not tonumber(lastSeenAt) then
          return nil, "Line " .. lineNumber .. " has invalid lastSeenAt."
        end

        seenGuids[guid] = true
        entries[#entries + 1] = {
          guid = guid,
          name = name ~= "" and name or nil,
          realm = realm ~= "" and realm or nil,
          source = source ~= "" and source or "import",
        }
      else
        return nil, "Line " .. lineNumber .. " has an unknown key."
      end
    end
  end

  if formatName ~= "BawrSpam-allowlist" then
    return nil, "Import format must be BawrSpam-allowlist."
  end
  if version ~= 1 then
    return nil, "Import version must be 1."
  end
  if exportedAt ~= nil and exportedAt < 0 then
    return nil, "exportedAt must be positive."
  end
  if #entries == 0 then
    return nil, "Import contains no entries."
  end

  return entries, nil
end

local function ExportAllowlistText()
  local allowlist = NS.Trust and NS.Trust.GetAllowlist and NS.Trust.GetAllowlist() or {}
  local rows = {
    "format=BawrSpam-allowlist",
    "version=1",
    "exportedAt=" .. tostring(Now()),
  }

  local guids = {}
  for guid in pairs(allowlist) do
    guids[#guids + 1] = guid
  end
  table.sort(guids)

  for _, guid in ipairs(guids) do
    local entry = allowlist[guid] or {}
    rows[#rows + 1] = table.concat({
      "entry=" .. EscapeField(guid),
      EscapeField(entry.name),
      EscapeField(entry.realm),
      EscapeField(entry.source or "manual"),
      EscapeField(entry.addedAt),
      EscapeField(entry.lastSeenAt),
    }, "|")
  end

  return table.concat(rows, "\n")
end

local function ApplyImport(entries, overwrite)
  if not NS.Trust or not NS.Trust.AddAllowlist then
    sectionStatus.Allowlist = "Allowlist API is unavailable."
    return
  end

  local current = NS.Trust.GetAllowlist and NS.Trust.GetAllowlist() or {}
  local added = 0
  local skipped = 0
  for _, entry in ipairs(entries) do
    if current[entry.guid] and overwrite and NS.Trust.RemoveAllowlist then
      NS.Trust.RemoveAllowlist(entry.guid)
      current[entry.guid] = nil
    end

    if not current[entry.guid] then
      if NS.Trust.AddAllowlist(entry.guid, entry.name, entry.realm, entry.source or "import") then
        added = added + 1
      end
    else
      skipped = skipped + 1
    end
  end

  pendingImport = nil
  removedAllowlistEntry = nil
  sectionStatus.Allowlist = "Imported " .. tostring(added) .. " entries"
    .. (skipped > 0 and ("; skipped " .. tostring(skipped) .. ".") or ".")
  if activeSection == "Allowlist" and frame and frame:IsShown() then
    ConfigPanel.ShowSection("Allowlist")
  end
end

local function ImportNeedsOverwrite(entries)
  local current = NS.Trust and NS.Trust.GetAllowlist and NS.Trust.GetAllowlist() or {}
  for _, entry in ipairs(entries) do
    if current[entry.guid] then
      return true
    end
  end
  return false
end

local function CloseDialog()
  if dialogFrame then
    dialogFrame:Hide()
  end
end

local function EnsureDialog()
  if dialogFrame then
    return dialogFrame
  end

  dialogFrame = CreateFrame("Frame", "BawrSpamConfigDialog", UIParent, "BackdropTemplate")
  dialogFrame:SetSize(520, 390)
  dialogFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  dialogFrame:SetFrameStrata("DIALOG")
  dialogFrame:SetClampedToScreen(true)
  dialogFrame:EnableMouse(true)
  if dialogFrame.SetBackdrop then
    dialogFrame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    dialogFrame:SetBackdropColor(0.02, 0.02, 0.025, 0.96)
    dialogFrame:SetBackdropBorderColor(0.35, 0.36, 0.42, 1)
  end

  dialogFrame.title = dialogFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  dialogFrame.title:SetPoint("TOPLEFT", dialogFrame, "TOPLEFT", 16, -14)
  dialogFrame.title:SetPoint("RIGHT", dialogFrame, "RIGHT", -42, 0)
  dialogFrame.title:SetJustifyH("LEFT")

  dialogFrame.close = CreateFrame("Button", nil, dialogFrame, "UIPanelCloseButton")
  dialogFrame.close:SetPoint("TOPRIGHT", dialogFrame, "TOPRIGHT", 0, 0)
  dialogFrame.close:SetScript("OnClick", CloseDialog)
  dialogFrame.close:Hide()

  dialogFrame.status = dialogFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dialogFrame.status:SetPoint("BOTTOMLEFT", dialogFrame, "BOTTOMLEFT", 18, 50)
  dialogFrame.status:SetPoint("RIGHT", dialogFrame, "RIGHT", -18, 0)
  dialogFrame.status:SetJustifyH("LEFT")

  dialogFrame.primary = CreateFrame("Button", nil, dialogFrame, "UIPanelButtonTemplate")
  dialogFrame.primary:SetSize(110, 24)
  dialogFrame.primary:SetPoint("BOTTOMRIGHT", dialogFrame, "BOTTOMRIGHT", -128, 16)

  dialogFrame.cancel = CreateFrame("Button", nil, dialogFrame, "UIPanelButtonTemplate")
  dialogFrame.cancel:SetSize(100, 24)
  dialogFrame.cancel:SetPoint("BOTTOMRIGHT", dialogFrame, "BOTTOMRIGHT", -18, 16)
  dialogFrame.cancel:SetText("Close")
  dialogFrame.cancel:SetScript("OnClick", CloseDialog)

  dialogFrame:Hide()
  return dialogFrame
end

local function ShowTextDialog(title, text, primaryLabel, primaryHandler)
  local AceGUI = EnsureAceGUI()
  if not AceGUI then
    Print("AceGUI-3.0 is missing; dialog unavailable.")
    return
  end

  local dialog = EnsureDialog()
  if dialog.editWidget then
    AceGUI:Release(dialog.editWidget)
    dialog.editWidget = nil
  end

  dialog.textValue = text or ""
  dialog.title:SetText(title)
  dialog.status:SetText("")
  dialog.primary:SetText(primaryLabel or "Close")
  dialog.primary:ClearAllPoints()
  if primaryHandler then
    dialog.primary:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -128, 16)
    dialog.cancel:Show()
  else
    dialog.primary:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -18, 16)
    dialog.cancel:Hide()
  end
  dialog.primary:SetScript("OnClick", function()
    if primaryHandler then
      primaryHandler(dialog.textValue or "")
    else
      CloseDialog()
    end
  end)
  dialog.close:Hide()

  local edit = AceGUI:Create("MultiLineEditBox")
  dialog.editWidget = edit
  edit:SetLabel("")
  edit:SetNumLines(16)
  edit:SetText(text or "")
  edit:SetFullWidth(true)
  edit:DisableButton(true)
  edit:SetCallback("OnTextChanged", function(_, _, value)
    dialog.textValue = value or ""
  end)
  edit.frame:SetParent(dialog)
  edit.frame:ClearAllPoints()
  edit.frame:SetPoint("TOPLEFT", dialog, "TOPLEFT", 16, -44)
  edit.frame:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -16, 78)
  edit.frame:Show()

  dialog:Show()
  if edit.editBox and edit.editBox.SetFocus then
    edit.editBox:SetFocus()
    edit.editBox:HighlightText()
  end
end

local function RegisterStaticPopups()
  if popupsRegistered or not StaticPopupDialogs then
    return
  end
  popupsRegistered = true

  StaticPopupDialogs["BAWRSPAM_CLEAR_HISTORY"] = {
    text = "Clear all BawrSpam history?",
    button1 = "Clear",
    button2 = "Cancel",
    OnAccept = function()
      if NS.History and NS.History.Clear then
        NS.History.Clear()
        sectionStatus.History = "History cleared."
      else
        sectionStatus.History = "History clear API is unavailable."
      end
      if activeSection == "History" and frame and frame:IsShown() then
        ConfigPanel.ShowSection("History")
      end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
  }

  StaticPopupDialogs["BAWRSPAM_CLEAR_BLOCKED"] = {
    text = "Clear all blocked actors?",
    button1 = "Clear",
    button2 = "Cancel",
    OnAccept = function()
      ClearTable(GetBlockedActors())
      sectionStatus.Blocked = "Blocked actors cleared."
      if activeSection == "Blocked" and frame and frame:IsShown() then
        ConfigPanel.ShowSection("Blocked")
      end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
  }

  StaticPopupDialogs["BAWRSPAM_RESET_SETTINGS"] = {
    text = "Reset BawrSpam settings to defaults?",
    button1 = "Reset",
    button2 = "Cancel",
    OnAccept = function()
      if ResetSettings() then
        sectionStatus.Dev = "Settings reset to defaults."
        SetHistoryPanelMinimapShown(SettingValue("showMinimapButton") ~= false)
      else
        sectionStatus.Dev = "Settings API is unavailable."
      end
      if activeSection == "Dev" and frame and frame:IsShown() then
        ConfigPanel.ShowSection("Dev")
      end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
  }

  StaticPopupDialogs["BAWRSPAM_IMPORT_OVERWRITE"] = {
    text = "Import includes entries that are already allowlisted. Overwrite matching entries?",
    button1 = "Overwrite",
    button2 = "Cancel",
    OnAccept = function()
      if pendingImport then
        ApplyImport(pendingImport, true)
      end
    end,
    OnCancel = function()
      pendingImport = nil
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
  }

  StaticPopupDialogs["BAWRSPAM_TRIM_HISTORY"] = {
    text = "Trim current history down to the new maximum?",
    button1 = "Trim",
    button2 = "Cancel",
    OnAccept = function()
      local max = pendingHistoryMax
      pendingHistoryMax = nil
      if max then
        SetSetting("historyMaxEntries", max)
        if NS.History and NS.History.TrimToMax then
          NS.History.TrimToMax(max)
          sectionStatus.History = "History trimmed to " .. tostring(max) .. " entries."
        else
          sectionStatus.History = "History trim API is unavailable."
        end
      end
      if activeSection == "History" and frame and frame:IsShown() then
        ConfigPanel.ShowSection("History")
      end
    end,
    OnCancel = function()
      pendingHistoryMax = nil
      if activeSection == "History" and frame and frame:IsShown() then
        ConfigPanel.ShowSection("History")
      end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
  }
end

local function RegisterInterfaceOptions()
  if interfaceRegistered or type(CreateFrame) ~= "function" then
    return
  end
  interfaceRegistered = true

  local panel = CreateFrame("Frame", "BawrSpamConfigOptionsPanel")
  panel.name = "BawrSpam"

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
  title:SetText("BawrSpam Configuration")

  local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  button:SetSize(190, 24)
  button:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -18)
  button:SetText("Open BawrSpam Config...")
  button:SetScript("OnClick", function()
    local settingsPanel = _G["SettingsPanel"]
    if settingsPanel and settingsPanel.Close then
      pcall(settingsPanel.Close, settingsPanel)
    end
    local cancel = _G["InterfaceOptionsFrameCancel"]
    if cancel and cancel.Click then
      pcall(cancel.Click, cancel)
    end
    ConfigPanel.Open()
  end)

  local settings = _G["Settings"]
  if settings and settings.RegisterCanvasLayoutCategory and settings.RegisterAddOnCategory then
    local ok, category = pcall(settings.RegisterCanvasLayoutCategory, panel, "BawrSpam")
    if ok and category then
      pcall(settings.RegisterAddOnCategory, category)
      return
    end
  end

  local legacy = _G["InterfaceOptions_AddCategory"]
  if type(legacy) == "function" then
    local ok = pcall(legacy, panel)
    if ok then
      return
    end
  end

  DevLog("Interface options registration unavailable.")
end

-- BSP-008 Commit 6: shared 3-state pause-pill row for Categories and Surfaces.
-- Blizzard atlas icons (self-colored, always render reliably).
-- LevelUp-Dot-Green                  -> green dot
-- CreditsScreen-Assets-Buttons-Pause -> media pause icon
-- communities-icon-redx              -> red X
local PAUSE_ROW_ATLAS = {
  active = "LevelUp-Dot-Green",
  paused = "CreditsScreen-Assets-Buttons-Pause",
  off    = "communities-icon-redx",
}

local function AddAxisPauseRow(axis, key, displayLabel, y)
  local row = TrackNative(CreateFrame("Frame", nil, content, "BackdropTemplate"))
  row:SetHeight(28)
  row:SetPoint("TOPLEFT", content, "TOPLEFT", CONTENT_PAD, y)
  row:SetPoint("RIGHT",   content, "RIGHT",   -CONTENT_PAD, 0)
  if row.SetBackdrop then
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    row:SetBackdropColor(0.10, 0.11, 0.13, 0.6)
  end
  row:Show()

  local label = TrackNative(row:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
  label:SetPoint("LEFT", row, "LEFT", 8, 0)
  label:SetText(L(displayLabel))
  label:Show()

  local pill = TrackNative(CreateFrame("Button", nil, row))
  pill:SetSize(80, 20)
  pill:SetPoint("RIGHT", row, "RIGHT", -8, 0)
  pill:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  pill.bg = pill:CreateTexture(nil, "BACKGROUND")
  pill.bg:SetAllPoints(pill)
  pill.bg:SetColorTexture(0.13, 0.13, 0.16, 1)
  pill.glyph = pill:CreateTexture(nil, "ARTWORK")
  pill.glyph:SetSize(14, 14)
  pill.glyph:SetPoint("LEFT", pill, "LEFT", 6, 0)
  pill.text = pill:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  pill.text:SetPoint("LEFT", pill.glyph, "RIGHT", 4, 0)

  local function Refresh()
    local state
    if axis == "surface" then
      state = NS.PauseState and NS.PauseState.GetSurface(key) or "active"
    else
      state = NS.PauseState and NS.PauseState.GetCategory(key) or "active"
    end
    local atlas = PAUSE_ROW_ATLAS[state] or PAUSE_ROW_ATLAS.active
    if atlas and pill.glyph and pill.glyph.SetAtlas then
      pill.glyph:SetAtlas(atlas, false)
    end
    pill.text:SetText(L(state))
  end

  pill:SetScript("OnClick", function(self, mouseButton)
    if not NS.PauseState then return end
    local direction = (mouseButton == "RightButton") and "backward" or "forward"
    if axis == "surface" then
      NS.PauseState.CycleSurface(key, direction)
    else
      NS.PauseState.CycleCategory(key, direction)
    end
    Refresh()
  end)

  Refresh()
  return y - 34
end

local RenderDetection
local RenderCategories
local RenderSurfaces
local RenderAllowlist
local RenderBlocked
local RenderHistory
local RenderUI
local RenderDev

RenderDetection = function()
  local y = AddSectionTitle("Detection", "Tune the score threshold and mixed-script signal weight.")
  y = AddStatus(y, sectionStatus.Detection)
  y = AddSlider("Block threshold", "threshold", 1, 10, 1, y)
  y = AddSlider("Anti-signal cap", "antiSignalCap", -10, -1, 1, y)
  y = AddSlider("Mixed-script weight", "mixedScriptWeight", 0, 3, 1, y)
  AddCheckbox("Use mixed-script detection", "mixedScriptEnabled", y)
end

RenderCategories = function()
  local y = AddSectionTitle("Categories", "Three states per category: Active (block) / Paused (detect + log, don't hide) / Off (ignore).")
  y = AddStatus(y, sectionStatus.Categories)
  for _, category in ipairs(CATEGORY_KEYS) do
    y = AddAxisPauseRow("category", category, category, y)
  end
end

RenderSurfaces = function()
  local y = AddSectionTitle("Surfaces", "Three states per surface: Active (block) / Paused (detect + log, don't hide) / Off (don't scan).")
  y = AddStatus(y, sectionStatus.Surfaces)
  for _, surface in ipairs(SURFACE_KEYS) do
    local label = SURFACE_LABELS[surface] or surface
    y = AddAxisPauseRow("surface", surface, label, y)
  end
  -- Preserved settings (live toggles, not part of the pause taxonomy).
  y = AddCheckbox("Filter bubbles", "filterBubbles", y, SetFilterBubblesEnabled)
  AddCheckbox("LFG scanning", "lfgScanEnabled", y, SetLFGScanEnabled)
end

RenderAllowlist = function()
  local y = AddSectionTitle("Allowlist", "Manage senders that BawrSpam should trust.")
  y = AddStatus(y, sectionStatus.Allowlist)

  AddText("Search", "GameFontNormalSmall", CONTENT_PAD, y + 2, 48)
  local search = AddEditBox(CONTENT_PAD + 54, y + 5, 160, listState.allowlistSearch)
  AddNativeButton("Apply", CONTENT_PAD + 222, y + 6, 70, function()
    listState.allowlistSearch = search:GetText() or ""
    listState.allowlistPage = 1
    ConfigPanel.ShowSection("Allowlist")
  end)
  y = y - 34

  AddNativeButton("Export", CONTENT_PAD, y + 6, 72, ConfigPanel.OpenExportDialog)
  AddNativeButton("Import", CONTENT_PAD + 82, y + 6, 72, ConfigPanel.OpenImportDialog)
  y = y - 34

  AddText("Add from History", "GameFontNormalSmall", CONTENT_PAD, y + 2, 104)
  local addBox = AddEditBox(CONTENT_PAD + 112, y + 5, 180, listState.allowlistAddText)
  AddNativeButton("Add", CONTENT_PAD + 300, y + 6, 72, function()
    listState.allowlistAddText = addBox:GetText() or ""
    AddAllowlistFromText(listState.allowlistAddText)
    ConfigPanel.ShowSection("Allowlist")
  end)
  y = y - 34

  if removedAllowlistEntry then
    AddText("Removed " .. SenderLabel(removedAllowlistEntry.entry) .. ".", "GameFontHighlightSmall", CONTENT_PAD, y)
    AddNativeButton("Undo", CONTENT_PAD + 210, y + 4, 70, UndoAllowlistRemove)
    y = y - 30
  end

  local entries = SortedAllowlist()
  local maxPage = MaxPage(#entries)
  if listState.allowlistPage > maxPage then listState.allowlistPage = maxPage end
  local startIndex = (listState.allowlistPage - 1) * PAGE_ROWS + 1
  local endIndex = math.min(startIndex + PAGE_ROWS - 1, #entries)

  AddText("Entries: " .. tostring(#entries), "GameFontNormalSmall", CONTENT_PAD, y)
  y = y - 20

  if #entries == 0 then
    AddDisabledRow("No allowlist entries", "Use History restore + allow, or import.", y)
    return
  end

  for index = startIndex, endIndex do
    local rowData = entries[index]
    local row = TrackNative(CreateFrame("Frame", nil, content, "BackdropTemplate"))
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", CONTENT_PAD, y)
    row:SetPoint("RIGHT", content, "RIGHT", -CONTENT_PAD, 0)
    if row.SetBackdrop then
      row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
      row:SetBackdropColor(0.10, 0.11, 0.13, 0.6)
    end
    row:Show()

    local label = TrackNative(row:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
    label:SetPoint("LEFT", row, "LEFT", 8, 6)
    label:SetText(SenderLabel(rowData.entry))
    label:Show()

    local meta = TrackNative(row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"))
    meta:SetPoint("LEFT", row, "LEFT", 8, -8)
    meta:SetText((rowData.entry.source or "manual") .. " - added " .. RelativeTime(rowData.entry.addedAt)
      .. " - seen " .. RelativeTime(rowData.entry.lastSeenAt))
    meta:Show()

    local remove = TrackNative(CreateFrame("Button", nil, row, "UIPanelButtonTemplate"))
    remove:SetSize(72, 22)
    remove:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    remove:SetText("Remove")
    remove:SetScript("OnClick", function()
      RemoveAllowlist(rowData.guid, rowData.entry)
    end)
    remove:Show()

    y = y - (ROW_HEIGHT + 4)
  end

  AddText("Page " .. tostring(listState.allowlistPage) .. " of " .. tostring(maxPage),
    "GameFontDisableSmall", CONTENT_PAD, y)
  AddNativeButton("Prev", CONTENT_PAD + 170, y + 4, 60, function()
    if listState.allowlistPage > 1 then
      listState.allowlistPage = listState.allowlistPage - 1
      ConfigPanel.ShowSection("Allowlist")
    end
  end)
  AddNativeButton("Next", CONTENT_PAD + 236, y + 4, 60, function()
    if listState.allowlistPage < maxPage then
      listState.allowlistPage = listState.allowlistPage + 1
      ConfigPanel.ShowSection("Allowlist")
    end
  end)
end

RenderBlocked = function()
  local y = AddSectionTitle("Blocked", "Review actors currently tracked as blocked.")
  y = AddStatus(y, sectionStatus.Blocked)

  AddText("Search", "GameFontNormalSmall", CONTENT_PAD, y + 2, 48)
  local search = AddEditBox(CONTENT_PAD + 54, y + 5, 160, listState.blockedSearch)
  AddNativeButton("Apply", CONTENT_PAD + 222, y + 6, 70, function()
    listState.blockedSearch = search:GetText() or ""
    listState.blockedPage = 1
    ConfigPanel.ShowSection("Blocked")
  end)
  AddNativeButton("Clear All", CONTENT_PAD + 300, y + 6, 90, ConfigPanel.ConfirmClearBlocked)
  y = y - 34

  y = AddDisabledRow("Manual blocked add", "Deferred until scanner consumption exists", y)

  local entries = SortedBlockedActors()
  local maxPage = MaxPage(#entries)
  if listState.blockedPage > maxPage then listState.blockedPage = maxPage end
  local startIndex = (listState.blockedPage - 1) * PAGE_ROWS + 1
  local endIndex = math.min(startIndex + PAGE_ROWS - 1, #entries)

  AddText("Blocked actors: " .. tostring(#entries), "GameFontNormalSmall", CONTENT_PAD, y)
  y = y - 20

  if #entries == 0 then
    AddDisabledRow("No blocked actors", "Nothing to manage.", y)
    return
  end

  for index = startIndex, endIndex do
    local rowData = entries[index]
    local row = TrackNative(CreateFrame("Frame", nil, content, "BackdropTemplate"))
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", CONTENT_PAD, y)
    row:SetPoint("RIGHT", content, "RIGHT", -CONTENT_PAD, 0)
    if row.SetBackdrop then
      row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
      row:SetBackdropColor(0.10, 0.11, 0.13, 0.6)
    end
    row:Show()

    local label = TrackNative(row:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
    label:SetPoint("LEFT", row, "LEFT", 8, 6)
    label:SetText(rowData.label)
    label:Show()

    local meta = TrackNative(row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"))
    meta:SetPoint("LEFT", row, "LEFT", 8, -8)
    meta:SetText("blocks " .. tostring(BlockedEntryCount(rowData.entry))
      .. " - last " .. RelativeTime(BlockedEntryLastSeen(rowData.entry)))
    meta:Show()

    local remove = TrackNative(CreateFrame("Button", nil, row, "UIPanelButtonTemplate"))
    remove:SetSize(72, 22)
    remove:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    remove:SetText("Remove")
    remove:SetScript("OnClick", function()
      RemoveBlocked(rowData.key)
    end)
    remove:Show()

    y = y - (ROW_HEIGHT + 4)
  end

  AddText("Page " .. tostring(listState.blockedPage) .. " of " .. tostring(maxPage),
    "GameFontDisableSmall", CONTENT_PAD, y)
  AddNativeButton("Prev", CONTENT_PAD + 170, y + 4, 60, function()
    if listState.blockedPage > 1 then
      listState.blockedPage = listState.blockedPage - 1
      ConfigPanel.ShowSection("Blocked")
    end
  end)
  AddNativeButton("Next", CONTENT_PAD + 236, y + 4, 60, function()
    if listState.blockedPage < maxPage then
      listState.blockedPage = listState.blockedPage + 1
      ConfigPanel.ShowSection("Blocked")
    end
  end)
end

RenderHistory = function()
  local entries = NS.History and NS.History.GetAll and NS.History.GetAll() or {}
  local stats = GetHistoryStats()
  local lifetime = stats and stats.lifetime or {}
  local retained = stats and stats.retained or {}
  local y = AddSectionTitle("History", "Control retained block history.")
  y = AddStatus(y, sectionStatus.History)
  y = AddDisabledRow("Total detections", tostring(tonumber(lifetime.detections) or 0), y)
  y = AddDisabledRow("Total blocks", tostring(tonumber(lifetime.blocked) or 0), y)
  y = AddDisabledRow("Total restores", tostring(tonumber(lifetime.restored) or 0), y)
  AddText("Retained entries: " .. tostring(tonumber(retained.detections) or #entries),
    "GameFontNormalSmall", CONTENT_PAD, y)
  y = y - 28

  local slider = AddAceWidget("Slider", CONTENT_PAD, y, 360)
  if slider then
    slider:SetLabel("Maximum history entries")
    slider:SetSliderValues(100, 5000, 100)
    slider:SetValue(tonumber(SettingValue("historyMaxEntries")) or DEFAULT_SETTINGS.historyMaxEntries)
    slider:SetCallback("OnValueChanged", function(_, _, value)
      value = ClampNumber(value, 100, 5000, DEFAULT_SETTINGS.historyMaxEntries)
      value = math.floor((value + 50) / 100) * 100
      if value < #entries then
        pendingHistoryMax = value
        if StaticPopup_Show then
          StaticPopup_Show("BAWRSPAM_TRIM_HISTORY")
        end
      else
        SetSetting("historyMaxEntries", value)
      end
    end)
    y = y - 52
  else
    y = AddDisabledRow("Maximum history entries", "AceGUI unavailable", y)
  end

  AddNativeButton("Clear History", CONTENT_PAD, y, 120, ConfigPanel.ConfirmClearHistory)
end

RenderUI = function()
  local y = AddSectionTitle("UI", "Panel position and minimap controls.")
  y = AddStatus(y, sectionStatus.UI)
  y = AddCheckbox("Show minimap button", "showMinimapButton", y, function(value)
    SetSetting("showMinimapButton", value)
    SetHistoryPanelMinimapShown(value)
  end)

  AddNativeButton("Reset History Panel", CONTENT_PAD, y, 150, function()
    if NS.HistoryPanel and NS.HistoryPanel.ResetPosition then
      NS.HistoryPanel.ResetPosition()
      sectionStatus.UI = "History panel position reset."
    else
      sectionStatus.UI = "History panel reset API is unavailable."
    end
    ConfigPanel.ShowSection("UI")
  end)
  AddNativeButton("Reset Config Panel", CONTENT_PAD + 160, y, 150, function()
    ConfigPanel.ResetPosition()
    sectionStatus.UI = "Config panel position reset."
    ConfigPanel.ShowSection("UI")
  end)
end

RenderDev = function()
  local y = AddSectionTitle("Dev", "Developer-only diagnostics and reset controls.")
  y = AddStatus(y, sectionStatus.Dev)
  y = AddCheckbox("Enable dev mode", "devMode", y)
  AddNativeButton("Reset Settings", CONTENT_PAD, y, 120, function()
    if StaticPopup_Show then
      StaticPopup_Show("BAWRSPAM_RESET_SETTINGS")
    end
  end)
end

local RENDERERS = {
  Detection = RenderDetection,
  Categories = RenderCategories,
  Surfaces = RenderSurfaces,
  Allowlist = RenderAllowlist,
  Blocked = RenderBlocked,
  History = RenderHistory,
  UI = RenderUI,
  Dev = RenderDev,
}

local function CreateBackdropFrame(parent)
  local f = CreateFrame("Frame", "BawrSpamConfigFrame", parent, "BackdropTemplate")
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.02, 0.02, 0.025, 0.96)
    f:SetBackdropBorderColor(0.35, 0.36, 0.42, 1)
  end
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:Hide()
  return f
end

local function CreateHeaderBar(parent)
  local header = CreateFrame("Frame", nil, parent)
  header:SetHeight(28)
  header:SetPoint("TOPLEFT", parent, "TOPLEFT", 6, -6)
  header:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, -6)
  header:EnableMouse(true)
  header:RegisterForDrag("LeftButton")
  header:SetScript("OnDragStart", function()
    parent:StartMoving()
  end)
  header:SetScript("OnDragStop", function()
    parent:StopMovingOrSizing()
    SavePosition()
  end)

  local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("LEFT", header, "LEFT", 4, 0)
  title:SetText("BawrSpam - Config")

  local close = CreateFrame("Button", nil, parent, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 2, -2)
  close:SetScript("OnClick", function()
    parent:Hide()
  end)
end

local function CreateResizeHandle(parent)
  local handle = CreateFrame("Button", nil, parent)
  handle:SetSize(16, 16)
  handle:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -4, 4)
  handle:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  handle:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  handle:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  handle:SetScript("OnMouseDown", function()
    parent:StartSizing("BOTTOMRIGHT")
  end)
  handle:SetScript("OnMouseUp", function()
    parent:StopMovingOrSizing()
    sizeDirty = true
  end)
end

local function CreateNav(parent)
  local nav = CreateFrame("Frame", nil, parent)
  nav:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -40)
  nav:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 8, 12)
  nav:SetWidth(NAV_WIDTH)

  local previous
  for _, section in ipairs(SECTIONS) do
    local button = CreateFrame("Button", nil, nav, "UIPanelButtonTemplate")
    button:SetSize(NAV_WIDTH - 8, 24)
    if previous then
      button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -6)
    else
      button:SetPoint("TOPLEFT", nav, "TOPLEFT", 0, 0)
    end
    button:SetText(section)
    button:SetScript("OnClick", function()
      ConfigPanel.ShowSection(section)
    end)
    navButtons[section] = button
    previous = button
  end
end

local function BuildFrame(parent)
  local embedded = parent ~= nil
  if frame then
    if embedded and frame.SetParent then
      frame:SetParent(parent)
      frame:ClearAllPoints()
      frame:SetAllPoints(parent)
      embeddedMode = true
    end
    return
  end

  if embedded then
    frame = CreateFrame("Frame", "BawrSpamConfigFrame", parent)
    frame:SetAllPoints(parent)
    embeddedMode = true
  else
    frame = CreateBackdropFrame(UIParent)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
      frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT)
    end

    CreateHeaderBar(frame)
    CreateResizeHandle(frame)
  end
  CreateNav(frame)

  content = CreateFrame("Frame", nil, frame)
  if embedded then
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", NAV_WIDTH + 8, 0)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  else
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", NAV_WIDTH + 16, -40)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 12)
  end

  frame:SetScript("OnSizeChanged", function()
    sizeDirty = true
  end)
  frame:SetScript("OnHide", function()
    if sizeDirty then
      SaveSize()
    end
  end)

  if not embedded then
    ApplyStoredGeometry()
  end
  if not embedded and UISpecialFrames then
    tinsert(UISpecialFrames, "BawrSpamConfigFrame")
  end
end

function ConfigPanel.Initialize()
  if initialized then
    return
  end
  initialized = true
  RegisterStaticPopups()
  RegisterInterfaceOptions()
  if not EnsureAceGUI() then
    DevLog("AceGUI-3.0 is missing; ConfigPanel will show limited controls.")
  end
end

function ConfigPanel.Open(section)
  ConfigPanel.Initialize()
  if NS.HistoryPanel and NS.HistoryPanel.ShowConfig then
    NS.HistoryPanel.ShowConfig(section)
    return
  end
  BuildFrame()
  ConfigPanel.ShowSection(section or activeSection or "Detection")
  frame:Show()
end

function ConfigPanel.Close()
  if embeddedMode and NS.HistoryPanel and NS.HistoryPanel.Show then
    NS.HistoryPanel.Show()
    return
  end
  if frame then
    frame:Hide()
  end
end

function ConfigPanel.Toggle(section)
  ConfigPanel.Initialize()
  if NS.HistoryPanel and NS.HistoryPanel.ShowConfig then
    NS.HistoryPanel.ShowConfig(section)
    return
  end
  BuildFrame()
  if frame:IsShown() then
    frame:Hide()
  else
    ConfigPanel.Open(section)
  end
end

function ConfigPanel.ResetPosition()
  if embeddedMode then
    if NS.HistoryPanel and NS.HistoryPanel.ResetPosition then
      NS.HistoryPanel.ResetPosition()
    end
    return
  end
  local store = GetCharStore()
  if store then
    store.x = nil
    store.y = nil
    store.width = DEFAULT_WIDTH
    store.height = DEFAULT_HEIGHT
  end
  if frame then
    ApplyStoredGeometry()
    SavePosition()
    SaveSize()
  end
end

function ConfigPanel.Attach(parent, section)
  if not parent then
    return nil
  end

  ConfigPanel.Initialize()
  BuildFrame(parent)
  ConfigPanel.ShowSection(section or activeSection or "Detection")
  frame:Show()
  return frame
end

function ConfigPanel.ShowSection(section)
  if not SectionExists(section) then
    section = "Detection"
  end
  BuildFrame()
  activeSection = section
  ReleaseContent()
  SetNavHighlight()

  local renderer = RENDERERS[section]
  if renderer then
    renderer()
  end
end

function ConfigPanel.OpenExportDialog()
  ConfigPanel.Initialize()
  ShowTextDialog("BawrSpam Allowlist Export", ExportAllowlistText(), "Close", nil)
end

function ConfigPanel.OpenImportDialog()
  ConfigPanel.Initialize()
  ShowTextDialog("BawrSpam Allowlist Import", "", "Import", function(text)
    local entries, err = ParseImportText(text)
    if not entries then
      if dialogFrame and dialogFrame.status then
        dialogFrame.status:SetText("|cffff5577" .. tostring(err) .. "|r")
      end
      return
    end

    CloseDialog()
    pendingImport = entries
    if ImportNeedsOverwrite(entries) and StaticPopup_Show then
      StaticPopup_Show("BAWRSPAM_IMPORT_OVERWRITE")
    else
      ApplyImport(entries, false)
    end
  end)
end

function ConfigPanel.ConfirmClearHistory()
  ConfigPanel.Initialize()
  if StaticPopup_Show then
    StaticPopup_Show("BAWRSPAM_CLEAR_HISTORY")
  end
end

function ConfigPanel.ConfirmClearBlocked()
  ConfigPanel.Initialize()
  if StaticPopup_Show then
    StaticPopup_Show("BAWRSPAM_CLEAR_BLOCKED")
  end
end

NS.ConfigPanel = ConfigPanel
return ConfigPanel
