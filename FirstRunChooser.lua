-- First-run filter chooser.
--
-- Invariant: no filter state changes unless the player presses Apply. The
-- seen set changes only on Apply or Keep current settings. Dismissal writes
-- nothing.
--
-- Shown only when LIVE is true or the attached add-on is enabled.
local addonName, NS = ...
local L = NS.L

local Chooser = {}

-- Module field, not a local, so a test can set it.
Chooser.LIVE = false

local BASE_HEIGHT = 142
local ROW_HEIGHT = 28
local PANEL_WIDTH = 420
-- Row 1's default position. It pins lower than this when the intro needs
-- more room than a one- or two-line English intro (Show(), below).
local ROW_TOP = -88

-- Derived from the vararg, not a literal folder name, so a DevBuild copy
-- (Sift_DevBuild) resolves its own logo rather than Sift's.
local LOGO = string.format("Interface\\AddOns\\%s\\Media\\SiftPortrait.tga", addonName)

-- Ordered so rows list in a stable sequence. A new entry also needs its label
-- in Locales/enUS.lua (it reaches L[] through row.label, not a literal), and
-- SameSettings/CopyState in ChatScanner.lua extended for any new settings key.
local REGISTRY = {
  {
    key = "RMT",
    label = "Gold selling",
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
    label = "Boosting",
    shippedState = "active",
    defaultFor = function(_compat) return true end,
    getState = function() return NS.PauseState.GetCategory("Boosting") end,
    setState = function(state)
      NS.PauseState.SetCategory("Boosting", state)
      return NS.PauseState.GetCategory("Boosting") == state
    end,
  },
  {
    key = "Carrying",
    label = "Carrying",
    shippedState = "active",
    defaultFor = function(_compat) return true end,
    getState = function() return NS.PauseState.GetCategory("Carrying") end,
    setState = function(state)
      NS.PauseState.SetCategory("Carrying", state)
      return NS.PauseState.GetCategory("Carrying") == state
    end,
  },
}

-- Exposed as the same table, not a copy, so other files and tests can use it.
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
  local ext = NS.extension
  if ext and ext.enabled then
    return true
  end
  return false
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

-- Lists every registered entry, seen or not. The initial tick applies only to
-- a row that is both unseen and still at its shipped state; any other row
-- shows its current state.
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

-- Re-reads getState() per row, since Apply can run long after Show(). A row is
-- marked seen only if it needed no write or its write succeeded, so a failed
-- write is offered again next login.
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
-- Panel. Built lazily on first Show(). Uses Blizzard's portrait frame when the
-- client has it, otherwise a standalone BackdropTemplate shell.
-- ---------------------------------------------------------------------------

local panel
local decided = false
local shownThisSession = false

-- Blizzard's PLAYER_ENTERING_WORLD handler calls CloseAllWindows(1) on every
-- login, which would hide the panel (it is in UISpecialFrames) behind the
-- loading screen. Tracked from file load so OnLogin knows whether it already
-- fired; this relies on Sift not being load-on-demand.
local pewFired = false
local pewWaiters = {}

local pewWatcher = CreateFrame("Frame")
pewWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
pewWatcher:SetScript("OnEvent", function(self)
  self:UnregisterEvent("PLAYER_ENTERING_WORLD")
  pewFired = true
  local waiters = pewWaiters
  pewWaiters = {}
  for _, waiter in ipairs(waiters) do
    waiter()
  end
end)

local function RunNextFrame(fn)
  if C_Timer and C_Timer.After then
    C_Timer.After(0, fn)
  end
end

-- Runs `fn` one frame after PLAYER_ENTERING_WORLD, so it never depends on the
-- order frames receive that event. Always waits the tick, even if the event
-- already fired.
local function AfterEnteringWorld(fn)
  if pewFired then
    RunNextFrame(fn)
    return
  end
  pewWaiters[#pewWaiters + 1] = function() RunNextFrame(fn) end
end

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

-- Row position is set in Show(), not here: pooled checkboxes are re-anchored
-- on every Show() because the intro height can change.
local function GetOrCreateCheckbox(index)
  panel.checkboxes = panel.checkboxes or {}
  local checkbox = panel.checkboxes[index]
  if checkbox then
    return checkbox
  end
  checkbox = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  checkbox:SetSize(24, 24)

  local rowLabel = checkbox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  rowLabel:SetPoint("LEFT", checkbox, "RIGHT", 4, 0)
  rowLabel:SetJustifyH("LEFT")
  -- Named rowLabel, not text/Text, so it never collides with a template region.
  checkbox.rowLabel = rowLabel

  panel.checkboxes[index] = checkbox
  return checkbox
end

-- Apply/Keep and dismiss-on-close wiring shared by both chrome paths.
local function FinishPanel(frame)
  local applyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  applyButton:SetSize(120, 24)
  applyButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)
  applyButton:SetText(L["Apply"])
  applyButton:SetScript("OnClick", OnApplyClick)

  local keepButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  keepButton:SetSize(180, 24)
  keepButton:SetPoint("LEFT", applyButton, "RIGHT", 8, 0)
  keepButton:SetText(L["Keep current settings"])
  keepButton:SetScript("OnClick", OnKeepClick)

  -- A parent-wide hide (Alt+Z, a cinematic) fires OnHide with IsShown() still
  -- true; only a real Hide() of this frame reads false. Apply/Keep set
  -- `decided` first, so only a real dismissal (Escape, the X) reaches the Print.
  frame:SetScript("OnHide", function(self)
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
end

-- Fallback when PortraitFrameTemplate is missing or has no CloseButton; keep it
-- even if unused.
local function BuildPlainShell()
  local shell = CreateFrame("Frame", "SiftFirstRunFrame", UIParent, "BackdropTemplate")
  shell:SetSize(PANEL_WIDTH, BASE_HEIGHT)
  shell:SetPoint("CENTER")
  shell:SetFrameStrata("DIALOG")
  shell:SetClampedToScreen(true)
  if shell.SetBackdrop then
    shell:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    shell:SetBackdropColor(0.02, 0.02, 0.025, 0.96)
    shell:SetBackdropBorderColor(0.35, 0.36, 0.42, 1)
  end

  local title = shell:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", shell, "TOP", 0, -16)
  title:SetText(L["Sift: choose what to hide"])

  -- Named logo, never portrait, so it can't collide with a template region.
  -- The asset's own alpha makes it round; this path has no mask.
  shell.logo = shell:CreateTexture(nil, "ARTWORK")
  shell.logo:SetSize(48, 48)
  shell.logo:SetPoint("TOPLEFT", shell, "TOPLEFT", 8, -8)
  shell.logo:SetTexture(LOGO)

  local closeButton = CreateFrame("Button", nil, shell, "UIPanelCloseButton")
  closeButton:SetPoint("TOPRIGHT", shell, "TOPRIGHT", 2, -2)
  closeButton:SetScript("OnClick", function() shell:Hide() end)
  shell.CloseButton = closeButton

  -- 8px lower than the template path's intro, clearing this path's own title.
  local intro = shell:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  intro:SetPoint("TOPLEFT", shell, "TOPLEFT", 70, -38)
  intro:SetWidth(334)
  intro:SetJustifyH("LEFT")
  intro:SetText(L["Pick what Sift hides. You can change these any time with /sift config."])
  shell.intro = intro
  shell.introTop = -38

  return shell
end

local function BuildFrame()
  if panel then
    return panel
  end

  -- A template without a CloseButton counts as no template: the fallback shell
  -- has a working X.
  local ok, frame = pcall(CreateFrame, "Frame", "SiftFirstRunFrame", UIParent, "PortraitFrameTemplate")
  if ok and frame and frame.CloseButton then
    panel = frame
    panel:SetSize(PANEL_WIDTH, BASE_HEIGHT)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)

    if panel.SetTitle then
      panel:SetTitle(L["Sift: choose what to hide"])
    end
    if panel.SetPortraitToAsset then
      panel:SetPortraitToAsset(LOGO)
    end
    -- Replaces the template's HideUIPanel click, which is gated on combat; this
    -- frame is not a UIPanel, and Hide() matches what Escape does.
    panel.CloseButton:SetScript("OnClick", function() panel:Hide() end)

    -- One anchor plus an explicit width, so the string wraps at a known width
    -- before the frame's first layout pass (Show() reads GetStringHeight()).
    local intro = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    intro:SetPoint("TOPLEFT", panel, "TOPLEFT", 70, -30)
    intro:SetWidth(334)
    intro:SetJustifyH("LEFT")
    intro:SetText(L["Pick what Sift hides. You can change these any time with /sift config."])
    panel.intro = intro
    panel.introTop = -30
  else
    panel = BuildPlainShell()
  end

  FinishPanel(panel)
  return panel
end

-- force = true (a preview) ignores the seen set for display,
-- but Apply/Keep still write the real seen set.
function Chooser.Show(force)
  local frame = BuildFrame()
  local seenForDisplay = force and {} or NS.DB.GetChooserSeen()
  local rows = Chooser.ComputeRows(REGISTRY, seenForDisplay, NS.Compat or {})

  -- Row 1 moves below the intro when the intro needs more room than ROW_TOP,
  -- measured from each chrome path's own introTop. GetStringHeight() can read
  -- low before the first layout pass; math.min only ever moves rows down, so
  -- that case still pins at ROW_TOP.
  local introTop = frame.introTop or -30
  local introHeight = frame.intro and frame.intro:GetStringHeight() or 0
  local rowTop = math.min(ROW_TOP, introTop - introHeight - 8)

  for index, row in ipairs(rows) do
    local checkbox = GetOrCreateCheckbox(index)
    checkbox:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, rowTop - ROW_HEIGHT * (index - 1))
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
  frame:SetHeight(BASE_HEIGHT + ROW_HEIGHT * #rows + (ROW_TOP - rowTop))
  frame:Show()
end

-- Every gate is re-checked here, not once in OnLogin: the add-on state, LIVE and the
-- seen set can all change before the deferred show lands.
local function AttemptShow()
  if shownThisSession or not Chooser.IsLive() then
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
      -- Re-check everything: any of these can change during combat.
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

-- Called by Init after InstallPlayerMenu(). The combat hold in AttemptShow is
-- a courtesy, not a taint guard.
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

  -- Waits rather than showing here; see AfterEnteringWorld above.
  AfterEnteringWorld(AttemptShow)
end

NS.FirstRunChooser = Chooser
return Chooser
