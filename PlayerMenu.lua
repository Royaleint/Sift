local _, NS = ...
local L = NS.L
local PlayerMenu = {}

-- Blizzard tags every unit context menu "MENU_UNIT_"..which, where which is
-- the UnitPopup menu name (UnitPopupShared.lua). FRIEND / FRIEND_OFFLINE are
-- what a chat-name link opens; the rest are the unit frame, nameplate,
-- target and roster menus. SELF is deliberately absent,
-- and so are the BN_ menus: a Battle.net account is not a character GUID,
-- so an entry there would key to nothing. COMMUNITIES_GUILD_MEMBER and
-- COMMUNITIES_WOW_MEMBER cover the guild and character-community rosters;
-- COMMUNITIES_MEMBER (Battle.net clubs) is left out for the same reason as
-- the BN_ menus.
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

local ROSTER_WHICH = {
  "COMMUNITIES_GUILD_MEMBER",
  "COMMUNITIES_WOW_MEMBER",
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

-- A roster name can arrive as a Kstring, a client-rendered display token
-- rather than real text. It is never stored, used as a target key, or
-- remembered as a sender; the block itself is keyed by GUID.
local function IsDisplayToken(value)
  return string.find(value, "|K", 1, true) ~= nil
end

local function IsUsableName(value)
  return IsUsableString(value) and not IsDisplayToken(value)
end

local rememberedTargets = {}

local function TargetKey(name, realm)
  if not IsUsableString(name) then
    return nil
  end
  return string.lower(name) .. "\031" .. string.lower(realm or "")
end

local function RememberTarget(guid, name, realm)
  local key = TargetKey(name, realm)
  if key and IsUsableString(guid) then
    rememberedTargets[key] = { guid = guid, name = name, realm = realm }
  end
end

local function RememberedTarget(name, realm)
  local key = TargetKey(name, realm)
  return key and rememberedTargets[key] or nil
end

local function NormalizeTarget(name, realm)
  if name and not realm then
    local baseName, nameRealm = string.match(name, "^([^%-]+)%-(.+)$")
    if baseName and nameRealm then
      return baseName, nameRealm
    end
  end
  return name, realm
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
  local name = IsUsableName(contextData.name) and contextData.name or nil
  local realm = IsUsableName(contextData.server) and contextData.server or nil

  -- Blizzard normally fills name/server for us, from UnitNameUnmodified on unit
  -- menus. Fall back to the unit itself so a blocked actor can never render as
  -- a bare GUID in Config > Blocked.
  if not name and IsUsableString(contextData.unit) and type(UnitName) == "function" then
    local ok, unitName, unitRealm = pcall(UnitName, contextData.unit)
    if ok and IsUsableName(unitName) then
      name = unitName
      realm = realm or (IsUsableName(unitRealm) and unitRealm or nil)
    end
  end

  name, realm = NormalizeTarget(name, realm)

  -- A chat link can reopen the FRIEND menu with the display name but without
  -- the original lineID. Reuse only a same-session name/realm -> GUID mapping
  -- established from the first menu, and only while that GUID is still
  -- manually blocked; once the block is gone the entry has no job, and using
  -- it would hand a name-only menu a one-click Block.
  if not guid then
    local remembered = RememberedTarget(name, realm)
    if remembered and NS.DB and NS.DB.IsManuallyBlocked and NS.DB.IsManuallyBlocked(remembered.guid) then
      guid = remembered.guid
    end
  end

  -- A roster row can hand back a Kstring instead of a name. Resolve the real
  -- name from the GUID Blizzard already gave us, so the token is never
  -- stored or remembered.
  if not name and guid and string.find(guid, "^Player%-") and type(GetPlayerInfoByGUID) == "function" then
    local ok, _, _, _, _, _, infoName, infoRealm = pcall(GetPlayerInfoByGUID, guid)
    if ok and IsUsableName(infoName) then
      name = infoName
      realm = realm or (IsUsableName(infoRealm) and infoRealm or nil)
    end
  end

  -- Player-* is the only GUID namespace blockedActors is keyed in. Battle.net
  -- accounts, pets and creatures all reach these menus and must not be stored.
  if not guid or not string.find(guid, "^Player%-") then
    return nil
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
    RememberTarget(guid, name, realm)
    Print("Blocked " .. SenderLabel(name, realm) .. ". Undo in /sift config > Blocked.")
  else
    Print(SenderLabel(name, realm) .. " is already blocked.")
  end
end

local CONFIRM_DIALOG = "SIFT_CONFIRM_BLOCK_PLAYER"
local confirmRegistered = false

-- Registered once at login, following ConfigPanel's RegisterStaticPopups
-- pattern. Roster rows only: chat and unit menus stay one click.
local function RegisterConfirmDialog()
  if confirmRegistered then
    return true
  end
  if type(StaticPopupDialogs) ~= "table" or type(StaticPopup_Show) ~= "function" then
    return false
  end
  StaticPopupDialogs[CONFIRM_DIALOG] = {
    text = L["Block %s? Sift will hide their messages in say, yell, whispers, emotes and channels. Guild, community, party, raid and instance chat is not hidden."],
    button1 = L["Block"],
    button2 = CANCEL or L["Cancel"],
    OnAccept = function(_, data)
      if type(data) == "table" then
        OnBlockClicked(data.guid, data.name, data.realm)
      end
    end,
    timeout = 60,
    whileDead = true,
    hideOnEscape = true,
  }
  confirmRegistered = true
  return true
end

local function AddBlockEntry(_owner, rootDescription, contextData, confirm)
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
    if confirm then
      StaticPopup_Show(CONFIRM_DIALOG, SenderLabel(name, realm), nil, { guid = guid, name = name, realm = realm })
    else
      OnBlockClicked(guid, name, realm)
    end
  end)
end

-- Two named closures fix the confirm flag at registration, so an extra
-- argument from a future client can never flip it: chat and unit menus stay
-- one click, and roster rows always confirm.
local function AddOneClickEntry(owner, rootDescription, contextData)
  AddBlockEntry(owner, rootDescription, contextData, false)
end

local function AddRosterBlockEntry(owner, rootDescription, contextData)
  AddBlockEntry(owner, rootDescription, contextData, true)
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
  local function RegisterTags(tags, callback)
    for _, which in ipairs(tags) do
      -- Tag registration is the surface most likely to churn across patches, so a
      -- failure stays a devMode diagnostic (design spec: patch-churn is silent).
      if pcall(Menu.ModifyMenu, "MENU_UNIT_" .. which, callback) then
        count = count + 1
      else
        DevLog("PlayerMenu: could not register MENU_UNIT_" .. which)
      end
    end
  end

  RegisterTags(MENU_WHICH, AddOneClickEntry)

  -- A roster row gets no entry, never a one-click fallback, if the
  -- confirmation dialog cannot be registered.
  if RegisterConfirmDialog() then
    RegisterTags(ROSTER_WHICH, AddRosterBlockEntry)
  end

  registered = count > 0
  return registered
end

NS.PlayerMenu = PlayerMenu
return PlayerMenu
