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
local addonName, NS = ...
local L = NS.L

local Chooser = {}

-- Module field, not a local, so a test (or BSP-040's flip) can set it.
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

-- Ordered so the panel lists rows in a stable sequence. A future entry here
-- (e.g. BSP-040) also needs: its label added to Locales/enUS.lua AND to
-- INDIRECTLY_REACHED_STRINGS in run_locale_tests.lua (the label reaches L[]
-- through row.label, not a literal call site); and SameSettings/CopyState
-- extended for any new settings key it introduces (ChatScanner.lua).
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
-- Panel. Built lazily on first Show(). Tries Blizzard's portrait frame first
-- (the probe in BuildFrame, below), like ConfigPanel's own chrome probe; a
-- client without the template falls back to BuildPlainShell, a standalone
-- BackdropTemplate shell with its own close button and logo texture.
-- ---------------------------------------------------------------------------

local panel
local decided = false
local shownThisSession = false

-- Blizzard's own PLAYER_ENTERING_WORLD handler calls CloseAllWindows(1)
-- unconditionally on every login, which Hide()s the panel (it is in
-- UISpecialFrames) before the player ever sees it, behind the loading
-- screen. Tracked from file load, unconditionally, rather than only when
-- OnLogin needs it: this file loads before PLAYER_ENTERING_WORLD can fire,
-- since Sift is not load-on-demand (Sift.toc), so listening starts early
-- enough to tell OnLogin whether it already fired instead of guessing from
-- event order.
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

-- Runs `fn` one frame after PLAYER_ENTERING_WORLD (and the CloseAllWindows(1)
-- it carries on every client): deferring one tick avoids depending on the
-- order frames receive the same event. If PLAYER_ENTERING_WORLD already
-- fired, `fn` still waits for that one tick rather than running inline.
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

-- The row position is set in Show(), not here: a pooled checkbox is
-- re-anchored on every Show() so an English show and a pseudolocale show
-- (a taller intro) each place rows from their own row origin.
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
  -- Named rowLabel, not text/Text -- UICheckButtonTemplate's own regions are
  -- outside our control across clients, and this pooled field is read back
  -- and rewritten on every Show(), so it must never collide with one.
  checkbox.rowLabel = rowLabel

  panel.checkboxes[index] = checkbox
  return checkbox
end

-- Apply/Keep and the dismiss-on-close handling are identical on both chrome
-- paths, so BuildFrame's two branches share this instead of each wiring it
-- separately.
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

  -- A parent-wide hide (Alt+Z, a cinematic) fires OnHide on every visible
  -- descendant while each descendant's OWN shown flag stays true -- only an
  -- actual Hide() of this frame leaves self:IsShown() false by the time this
  -- runs. Apply/Keep set `decided` before calling Hide(), and the X (below)
  -- calls Hide() without setting it, so a real dismissal (Escape, the X) is
  -- the only path that reaches the Print below.
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

-- A self-contained backdrop shell with its own close button and round logo
-- texture, for a client without a usable PortraitFrameTemplate. No current
-- client reaches this path; it exists for an unknown future one.
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

  -- Named logo, never portrait, so it can't be confused with a template
  -- region if a future client half-supports the template. The asset's own
  -- round alpha makes it round with no mask, since this path has none.
  shell.logo = shell:CreateTexture(nil, "ARTWORK")
  shell.logo:SetSize(48, 48)
  shell.logo:SetPoint("TOPLEFT", shell, "TOPLEFT", 8, -8)
  shell.logo:SetTexture(LOGO)

  local closeButton = CreateFrame("Button", nil, shell, "UIPanelCloseButton")
  closeButton:SetPoint("TOPRIGHT", shell, "TOPRIGHT", 2, -2)
  closeButton:SetScript("OnClick", function() shell:Hide() end)
  shell.CloseButton = closeButton

  -- 8px lower than the template path's intro: this path's own title sits at
  -- TOP -16 instead of the template's title bar, and without the offset the
  -- two overlap by a few pixels.
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

  -- Requires a CloseButton, not just a frame: a client whose template lacks
  -- one is treated the same as a client with no template at all, since the
  -- fallback shell (with its own X) is a better dialog than a portrait frame
  -- a player can't dismiss with the X they can see.
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
    -- Overrides the template's own HideUIPanel click: that call is gated on
    -- combat and taint state we don't need, and a frame that isn't a UIPanel
    -- gets no benefit from it. panel:Hide() takes the same path Escape
    -- already does, in or out of combat.
    panel.CloseButton:SetScript("OnClick", function() panel:Hide() end)

    -- Beside the portrait, not under a title FontString of our own. A single
    -- anchor plus an explicit width, so the string wraps at a known width
    -- instead of depending on a second TOPRIGHT anchor and the frame's own
    -- layout pass, which may not have run yet when Show() reads
    -- GetStringHeight() (see Show(), below).
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

-- force = true (the /bdev chooser preview) ignores the seen set for display
-- so every row shows its shipped default, but Apply/Keep still write through
-- the real seen set below -- the dev command previews the FIRST-RUN look, not
-- a no-op.
function Chooser.Show(force)
  local frame = BuildFrame()
  local seenForDisplay = force and {} or NS.DB.GetChooserSeen()
  local rows = Chooser.ComputeRows(REGISTRY, seenForDisplay, NS.Compat or {})

  -- Row 1 pins under the intro instead of staying at ROW_TOP whenever the
  -- intro needs more room than that: a longer translation pushes the rows
  -- (and the frame height below) down by the same amount, so the intro can
  -- never overlap row 1. Measured from each build path's own intro position
  -- (introTop), not a shared constant -- the fallback's intro sits 8px lower
  -- than the template path's. Before the frame's first layout pass,
  -- GetStringHeight() may read back 0 or an unwrapped single-line height
  -- rather than the true wrapped height; math.min only ever pushes rowTop
  -- lower than ROW_TOP, never higher, so a short or unmeasured intro still
  -- pins at ROW_TOP.
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

-- The actual show is deferred past PLAYER_ENTERING_WORLD (see
-- AfterEnteringWorld above), so every gate is re-checked here rather than
-- once in OnLogin -- dev mode, LIVE, and the seen set can all move in the
-- gap between login and the deferred show landing.
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

-- Runs after InstallPlayerMenu(), once Init's `initialized` flag is true
-- (Init.lua gates the call the same way it gates InstallScanner/
-- InstallPlayerMenu themselves). Not secure -- the combat hold in AttemptShow
-- is a courtesy, not a taint guard.
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

  -- See AfterEnteringWorld and pewWatcher above for why this waits rather
  -- than showing here directly.
  AfterEnteringWorld(AttemptShow)
end

NS.FirstRunChooser = Chooser
return Chooser
