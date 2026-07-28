local _, NS = ...
local PlayerMenu = {}

-- BSP-037: Blizzard tags every unit context menu "MENU_UNIT_"..which, where
-- which is the UnitPopup menu name (UnitPopupShared.lua, retail 12.0.7).
-- FRIEND / FRIEND_OFFLINE are what a chat-name link opens; the rest are the
-- unit frame, nameplate, target and roster menus. SELF is deliberately absent,
-- and so are the BN_ menus: a Battle.net account is not a character GUID, so an
-- entry there would key to nothing. The COMMUNITIES_* menus are a deliberate
-- follow-up (SFT-083-adjacent), not an oversight.
local MENU_WHICH = {
  "FRIEND",
  "FRIEND_OFFLINE",
  "CHAT_ROSTER",
  "GUILD",
  "GUILD_OFFLINE",
  "PLAYER",
  "PARTY",
  "RAID_PLAYER",
  "TARGET",
  "FOCUS",
  "ENEMY_PLAYER",
}

local BLOCK_LABEL = "Block (Sift)"
local BLOCKED_LABEL = "Blocked (Sift)"
local UNAVAILABLE_LABEL = "Block (Sift) - unavailable for this message"

local registered = false

local function IsSecret(value)
  if type(issecretvalue) ~= "function" then
    return false
  end

  local ok, result = pcall(issecretvalue, value)
  return ok and result == true
end

local function IsUsableString(value)
  if IsSecret(value) then
    return false
  end
  return type(value) == "string" and value ~= ""
end

local function Print(message)
  message = "|cff33ff99Sift|r " .. tostring(message)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(message)
  else
    print(message)
  end
end

local function DevLog(message)
  if NS.DB and NS.DB.DevLog then
    NS.DB.DevLog(message)
  end
end

-- Chat-name menus are the interesting case: Blizzard builds their contextData
-- without a GUID, but it carries the chat lineID, and ChatScanner has already
-- seen that line arrive with its sender GUID. Joining on lineID keys the block
-- to the real sender rather than to a display name someone else could wear.
local function ResolveGUID(contextData)
  if IsUsableString(contextData.guid) then
    return contextData.guid
  end

  local unit = contextData.unit
  if IsUsableString(unit) and type(UnitGUID) == "function" then
    local ok, unitGUID = pcall(UnitGUID, unit)
    if ok and IsUsableString(unitGUID) then
      return unitGUID
    end
  end

  if contextData.lineID ~= nil and NS.ChatScanner and NS.ChatScanner.GetSenderGUIDByLineID then
    local cached = NS.ChatScanner.GetSenderGUIDByLineID(contextData.lineID)
    if IsUsableString(cached) then
      return cached
    end
  end

  return nil
end

local function IsSelf(guid)
  if type(UnitGUID) ~= "function" then
    return false
  end
  local ok, selfGUID = pcall(UnitGUID, "player")
  return ok and guid == selfGUID
end

local function ResolveTarget(contextData)
  local guid = ResolveGUID(contextData)
  -- Player-* is the only GUID namespace blockedActors is keyed in. Battle.net
  -- accounts, pets and creatures all reach these menus and must not be stored.
  if not guid or not string.find(guid, "^Player%-") then
    return nil
  end

  local name = IsUsableString(contextData.name) and contextData.name or nil
  local realm = IsUsableString(contextData.server) and contextData.server or nil

  -- Blizzard normally fills name/server for us, from UnitNameUnmodified on unit
  -- menus. Fall back to the unit itself so a blocked actor can never render as
  -- a bare GUID in Config > Blocked.
  if not name and IsUsableString(contextData.unit) and type(UnitName) == "function" then
    local ok, unitName, unitRealm = pcall(UnitName, contextData.unit)
    if ok and IsUsableString(unitName) then
      name = unitName
      realm = realm or (IsUsableString(unitRealm) and unitRealm or nil)
    end
  end

  return guid, name, realm
end

local function SenderLabel(name, realm)
  if name and realm then
    return name .. "-" .. realm
  end
  return name or "this player"
end

local function AddDisabledButton(rootDescription, label)
  local entry = rootDescription:CreateButton(label, function() end)
  if entry and entry.SetEnabled then
    entry:SetEnabled(false)
  end
  return entry
end

local function OnBlockClicked(guid, name, realm)
  if not NS.DB or not NS.DB.BlockActorManually then
    return
  end

  if NS.DB.BlockActorManually(guid, name, realm) then
    Print("Blocked " .. SenderLabel(name, realm) .. ". Undo in /sift config > Blocked.")
  else
    Print(SenderLabel(name, realm) .. " is already blocked.")
  end
end

local function AddBlockEntry(_owner, rootDescription, contextData)
  if type(contextData) ~= "table" or rootDescription == nil then
    return
  end

  local guid, name, realm = ResolveTarget(contextData)

  -- Your own menu, including the menu on your own chat lines. Nothing to offer,
  -- and an "unavailable" note here would just be noise.
  if guid and IsSelf(guid) then
    return
  end

  if not guid then
    -- A chat-name menu always names a real player, so failing to key one means
    -- the message arrived on chat Sift does not read (guild, party, raid), or
    -- that line has already been pushed out of the ring by newer messages.
    -- Say the entry is unavailable rather than letting it silently vanish.
    if contextData.lineID ~= nil then
      AddDisabledButton(rootDescription, UNAVAILABLE_LABEL)
    end
    return
  end

  -- Already blocked: show the state instead of hiding the entry, so the menu
  -- answers "did that work?". Removing a block stays in Config > Blocked.
  if NS.DB and NS.DB.IsManuallyBlocked and NS.DB.IsManuallyBlocked(guid) then
    AddDisabledButton(rootDescription, BLOCKED_LABEL)
    return
  end

  rootDescription:CreateButton(BLOCK_LABEL, function()
    OnBlockClicked(guid, name, realm)
  end)
end

function PlayerMenu.Initialize()
  if registered then
    return false
  end

  -- Feature-detected rather than gated on retail: Blizzard_Menu also ships
  -- Classic/Cata/Vanilla builds that define ModifyMenu but tag their unit menus
  -- differently, and there our callback simply never fires.
  if type(Menu) ~= "table" or type(Menu.ModifyMenu) ~= "function" then
    DevLog("PlayerMenu: Menu.ModifyMenu unavailable; right-click block is off.")
    return false
  end

  local count = 0
  for _, which in ipairs(MENU_WHICH) do
    -- Tag registration is the surface most likely to churn across patches, so a
    -- failure stays a devMode diagnostic (design spec: patch-churn is silent).
    if pcall(Menu.ModifyMenu, "MENU_UNIT_" .. which, AddBlockEntry) then
      count = count + 1
    else
      DevLog("PlayerMenu: could not register MENU_UNIT_" .. which)
    end
  end

  registered = count > 0
  return registered
end

NS.PlayerMenu = PlayerMenu
return PlayerMenu
