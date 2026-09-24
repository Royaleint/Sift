-- SFT-099: first-run filter chooser.
--
-- Invariant: no filter state changes unless the player presses Apply. The
-- seen set changes only on Apply or Keep current settings. Dismissal writes
-- nothing. With LIVE = false and dev mode off, no player ever sees this panel.
--
-- Ships dark: RMT and Boosting already default to active for every player, so
-- showing this today would only ask them to confirm two categories nobody
-- needs to see yet. The framework ships now anyway, gated by Chooser.LIVE, so
-- it never reaches a live player until BSP-040 adds rows that actually need a
-- choice and that ticket flips LIVE = true. Until then the only way to see
-- the panel is /bdev chooser (dev mode) or Chooser.LIVE set true by a test.
local _, NS = ...
local L = NS.L

local Chooser = {}

-- Module field, not a local, so a test (or BSP-040's flip) can set it.
Chooser.LIVE = false

local BASE_HEIGHT = 142
local ROW_HEIGHT = 28
local PANEL_WIDTH = 420

-- Ordered so the panel lists rows in a stable sequence. A future entry here
-- (e.g. BSP-040) also needs: its label added to Locales/enUS.lua AND to
-- INDIRECTLY_REACHED_STRINGS in run_locale_tests.lua (the label reaches L[]
-- through row.label, not a literal call site); and SameSettings/CopyState
-- extended for any new settings key it introduces (ChatScanner.lua).
local REGISTRY = {
  {
    key = "RMT",
    label = "Gold selling (real-money trading)",
    shippedState = "active",
    defaultFor = function(_compat) return true end,
    getState = function() return NS.PauseState.GetCategory("RMT") end,
    setState = function(state)
      NS.PauseState.SetCategory("RMT", state)
      return NS.PauseState.GetCategory("RMT") == state
    end,
  },
  {
    key = "Boosting",
    label = "Boosting (paid carry ads)",
    shippedState = "active",
    defaultFor = function(_compat) return true end,
    getState = function() return NS.PauseState.GetCategory("Boosting") end,
    setState = function(state)
      NS.PauseState.SetCategory("Boosting", state)
      return NS.PauseState.GetCategory("Boosting") == state
    end,
  },
}

-- Exposed (same table, not a copy) so a future ticket can append a row from
-- its own file, and so tests can drive the pure functions below against the
-- real registry without reaching into a module local.
Chooser.REGISTRY = REGISTRY

local function Print(message)
  message = "|cff33ff99Sift|r " .. tostring(message)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(message)
  else
    print(message)
  end
end

function Chooser.IsLive()
  if Chooser.LIVE then
    return true
  end
  return NS.DB ~= nil and NS.DB.IsDevMode ~= nil and NS.DB.IsDevMode() == true
end

-- ---------------------------------------------------------------------------
-- Pure functions. No CreateFrame, no Print, no DB writes -- everything below
-- this line is exercised directly by the offline tests with plain tables.
-- ---------------------------------------------------------------------------

function Chooser.HasUnseen(registry, seen)
  for _, entry in ipairs(registry) do
    if seen[entry.key] ~= true then
      return true
    end
  end
  return false
end

-- Lists EVERY registered entry, seen or not, so a player who already decided
-- on one row still sees it alongside any new one rather than a partial list.
-- The initial tick only applies to a row that is BOTH unseen and still at its
-- shipped state -- a row a player already decided on (seen, or moved off its
-- shipped state some other way) shows its actual current state instead.
function Chooser.ComputeRows(registry, seen, compat)
  local rows = {}
  for _, entry in ipairs(registry) do
    local state = entry.getState()
    local checked
    if seen[entry.key] ~= true and state == entry.shippedState then
      checked = entry.defaultFor(compat) and true or false
    else
      checked = state ~= "off"
    end
    rows[#rows + 1] = {
      entry = entry,
      label = entry.label,
      checked = checked,
      paused = state == "paused",
    }
  end
  return rows
end

-- Re-reads getState() fresh per row -- Apply can run long after Show(), and
-- the checked state the panel captured is only ever compared against the
-- state as it is right now. markSeen(key) is called only for a row that
-- needed no write, or whose write reported success, so a failed write is
-- offered again next login instead of being marked seen anyway.
function Chooser.ApplyChoices(rows, checked, markSeen)
  for _, row in ipairs(rows) do
    local entry = row.entry
    local state = entry.getState()
    local isChecked = checked[entry.key] and true or false
    local wroteOk = true
    if isChecked and state == "off" then
      wroteOk = entry.setState("active") and true or false
    elseif not isChecked and state ~= "off" then
      wroteOk = entry.setState("off") and true or false
    end
    if wroteOk then
      markSeen(entry.key)
    end
  end
end

function Chooser.KeepCurrent(rows, markSeen)
  for _, row in ipairs(rows) do
    markSeen(row.entry.key)
  end
end

-- ---------------------------------------------------------------------------
-- Panel. Built lazily on first Show(); a plain BackdropTemplate shell,
-- identical on every client (no chrome probe -- BSP-041's portrait dance is
-- for ConfigPanel's persistent window, not this one-time dialog).
-- ---------------------------------------------------------------------------

local panel
local decided = false
local shownThisSession = false

local function MarkSeen(key)
  NS.DB.MarkChooserSeen(key)
end

local function CollectChecked()
  local checked = {}
  for _, row in ipairs(panel.rows or {}) do
    local checkbox = row.checkbox
    checked[row.entry.key] = checkbox and checkbox:GetChecked() and true or false
  end
  return checked
end

local function OnApplyClick()
  Chooser.ApplyChoices(panel.rows or {}, CollectChecked(), MarkSeen)
  decided = true
  panel:Hide()
end

local function OnKeepClick()
  Chooser.KeepCurrent(panel.rows or {}, MarkSeen)
  decided = true
  panel:Hide()
end

local function GetOrCreateCheckbox(index)
  panel.checkboxes = panel.checkboxes or {}
  local checkbox = panel.checkboxes[index]
  if checkbox then
    return checkbox
  end
  checkbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  checkbox:SetSize(24, 24)
  checkbox:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -78 - (index - 1) * ROW_HEIGHT)

  local rowLabel = checkbox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  rowLabel:SetPoint("LEFT", checkbox, "RIGHT", 4, 0)
  rowLabel:SetJustifyH("LEFT")
  -- Named rowLabel, not text/Text -- UICheckButtonTemplate's own regions are
  -- outside our control across clients, and this pooled field is read back
  -- and rewritten on every Show(), so it must never collide with one.
  checkbox.rowLabel = rowLabel

  panel.checkboxes[index] = checkbox
  return checkbox
end

local function BuildFrame()
  if panel then
    return panel
  end

  panel = CreateFrame("Frame", "SiftFirstRunFrame", UIParent, "BackdropTemplate")
  panel:SetSize(PANEL_WIDTH, BASE_HEIGHT)
  panel:SetPoint("CENTER")
  panel:SetFrameStrata("DIALOG")
  panel:SetClampedToScreen(true)
  if panel.SetBackdrop then
    panel:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0.02, 0.02, 0.025, 0.96)
    panel:SetBackdropBorderColor(0.35, 0.36, 0.42, 1)
  end

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", panel, "TOP", 0, -16)
  title:SetText(L["Sift: choose what to hide"])

  local intro = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  intro:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -40)
  intro:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -40)
  intro:SetJustifyH("LEFT")
  intro:SetText(L["Pick what Sift hides. You can change these any time with /sift config."])

  local applyButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  applyButton:SetSize(120, 24)
  applyButton:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 16)
  applyButton:SetText(L["Apply"])
  applyButton:SetScript("OnClick", OnApplyClick)

  local keepButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  keepButton:SetSize(180, 24)
  keepButton:SetPoint("LEFT", applyButton, "RIGHT", 8, 0)
  keepButton:SetText(L["Keep current settings"])
  keepButton:SetScript("OnClick", OnKeepClick)

  -- A parent-wide hide (Alt+Z, a cinematic) fires OnHide on every visible
  -- descendant while each descendant's OWN shown flag stays true -- only an
  -- actual Hide() of this frame leaves self:IsShown() false by the time this
  -- runs. Apply/Keep set `decided` before calling Hide(), so a real dismissal
  -- is the only path that reaches the Print below.
  panel:SetScript("OnHide", function(self)
    if self:IsShown() then
      return
    end
    if decided then
      return
    end
    Print(L["Filter choices not saved. Sift will ask again next login; change them any time with /sift config."])
  end)

  if UISpecialFrames then
    tinsert(UISpecialFrames, "SiftFirstRunFrame")
  end

  return panel
end

-- force = true (the /bdev chooser preview) ignores the seen set for display
-- so every row shows its shipped default, but Apply/Keep still write through
-- the real seen set below -- the dev command previews the FIRST-RUN look, not
-- a no-op.
function Chooser.Show(force)
  local frame = BuildFrame()
  local seenForDisplay = force and {} or NS.DB.GetChooserSeen()
  local rows = Chooser.ComputeRows(REGISTRY, seenForDisplay, NS.Compat or {})

  for index, row in ipairs(rows) do
    local checkbox = GetOrCreateCheckbox(index)
    local displayLabel = row.paused
      and string.format(L["%s (paused)"], L[row.label])
      or L[row.label]
    checkbox.rowLabel:SetText(displayLabel)
    checkbox:SetChecked(row.checked)
    row.checkbox = checkbox
    checkbox:Show()
  end
  for index = #rows + 1, #(frame.checkboxes or {}) do
    frame.checkboxes[index]:Hide()
  end
  frame.rows = rows

  decided = false
  frame:SetHeight(BASE_HEIGHT + ROW_HEIGHT * #rows)
  frame:Show()
end

-- Runs after InstallPlayerMenu(), once Init's `initialized` flag is true
-- (Init.lua gates the call the same way it gates InstallScanner/
-- InstallPlayerMenu themselves). Not secure -- the combat hold below is a
-- courtesy, not a taint guard.
function Chooser.OnLogin()
  if not (NS.DB and NS.DB.GetChooserSeen and NS.DB.MarkChooserSeen) then
    return
  end
  if shownThisSession then
    return
  end
  if not Chooser.IsLive() then
    return
  end
  if not Chooser.HasUnseen(REGISTRY, NS.DB.GetChooserSeen()) then
    return
  end

  if type(InCombatLockdown) == "function" and InCombatLockdown() then
    local waiter = CreateFrame("Frame")
    waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
    waiter:SetScript("OnEvent", function(self)
      self:UnregisterEvent("PLAYER_REGEN_ENABLED")
      -- Re-check everything: any of these can have changed while the fight
      -- ran (a /reload isn't possible mid-combat, but dev mode, LIVE, and the
      -- seen set can all still move).
      if shownThisSession or not Chooser.IsLive() then
        return
      end
      if not Chooser.HasUnseen(REGISTRY, NS.DB.GetChooserSeen()) then
        return
      end
      shownThisSession = true
      Chooser.Show()
    end)
    return
  end

  shownThisSession = true
  Chooser.Show()
end

NS.FirstRunChooser = Chooser
return Chooser
