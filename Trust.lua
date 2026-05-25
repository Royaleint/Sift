local _, NS = ...
local Trust = {}

local allowlist = {}

local function ClearTable(tbl)
  if type(wipe) == "function" then
    wipe(tbl)
    return
  end

  for key in pairs(tbl) do
    tbl[key] = nil
  end
end

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

local function SafeCall(fn, ...)
  if type(fn) ~= "function" then
    return false, nil
  end

  local ok, result = pcall(fn, ...)
  if not ok then
    return false, nil
  end
  return true, result
end

local function Now()
  if type(GetServerTime) == "function" then
    return GetServerTime()
  end
  return time()
end

local function IsFriend(guid)
  if not C_FriendList or type(C_FriendList.IsFriend) ~= "function" then
    return false
  end

  local ok, result = SafeCall(C_FriendList.IsFriend, guid)
  return ok and result == true
end

local function IsBattleNetFriend(guid)
  if not C_BattleNet or type(C_BattleNet.GetGameAccountInfoByGUID) ~= "function" then
    return false
  end

  local ok, accountInfo = SafeCall(C_BattleNet.GetGameAccountInfoByGUID, guid)
  return ok and type(accountInfo) == "table" and accountInfo.gameAccountID ~= nil
end

local function TokenHasGUID(token, guid)
  local ok, unitGUID = SafeCall(UnitGUID, token)
  return ok and unitGUID == guid
end

local function IsGrouped(guid)
  if not IsUsableString(guid) then
    return false
  end

  if TokenHasGUID("player", guid) then
    return true
  end

  for index = 1, 4 do
    if TokenHasGUID("party" .. index, guid) then
      return true
    end
  end

  for index = 1, 40 do
    if TokenHasGUID("raid" .. index, guid) then
      return true
    end
  end

  return false
end

function Trust.Initialize()
  Trust.RefreshAllowlistFromDB()
end

function Trust.RefreshAllowlistFromDB()
  ClearTable(allowlist)

  local global = NS.DB and NS.DB.GetGlobal and NS.DB.GetGlobal()
  local stored = global and global.allowlist
  if type(stored) ~= "table" then
    return
  end

  for guid, entry in pairs(stored) do
    if type(guid) == "string" and type(entry) == "table" then
      allowlist[guid] = entry
    end
  end
end

function Trust.IsAllowlisted(guid)
  if not IsUsableString(guid) then
    return false
  end
  return allowlist[guid] ~= nil
end

function Trust.AddAllowlist(guid, name, realm, source)
  if not IsUsableString(guid) or Trust.IsAllowlisted(guid) then
    return false
  end

  if source ~= "manual" and source ~= "history" and source ~= "import" then
    source = "manual"
  end

  local entry = {
    name = IsUsableString(name) and name or nil,
    realm = IsUsableString(realm) and realm or nil,
    addedAt = Now(),
    lastSeenAt = Now(),
    source = source,
  }

  allowlist[guid] = entry

  local global = NS.DB and NS.DB.GetGlobal and NS.DB.GetGlobal()
  if global then
    global.allowlist = global.allowlist or {}
    global.allowlist[guid] = entry
  end

  return true
end

function Trust.RemoveAllowlist(guid)
  if not IsUsableString(guid) or not allowlist[guid] then
    return false
  end

  allowlist[guid] = nil

  local global = NS.DB and NS.DB.GetGlobal and NS.DB.GetGlobal()
  if global and global.allowlist then
    global.allowlist[guid] = nil
  end

  return true
end

function Trust.GetAllowlist()
  local copy = {}
  for guid, entry in pairs(allowlist) do
    local entryCopy = {}
    for key, value in pairs(entry) do
      entryCopy[key] = value
    end
    copy[guid] = entryCopy
  end
  return copy
end

-- Returns the trust source that would mark this sender trusted, or nil if not
-- trusted. Mirrors IsTrusted's exact short-circuit order so the two never drift.
-- Devmode diagnostics (BSP-047) read this to name which source fired.
function Trust.TrustReason(guid, _name, flag)
  if IsSecret(flag) then
    flag = nil
  end
  if flag == "GM" or flag == "DEV" then
    return "flag"
  end

  if not IsUsableString(guid) then
    return nil
  end

  if Trust.IsAllowlisted(guid) then
    return "allowlist"
  end

  if IsFriend(guid) then
    return "friend"
  end
  -- guild-trust removed (BSP-047): IsPlayerInGuildFromGUID returns "is in ANY
  -- guild", not "my guild" -- it trusted every guilded player. Do not re-add
  -- without a real same-guild (IsGuildMember(name)) check.
  if IsBattleNetFriend(guid) then
    return "bnet"
  end
  if IsGrouped(guid) then
    return "group"
  end

  return nil
end

function Trust.IsTrusted(guid, name, flag)
  return Trust.TrustReason(guid, name, flag) ~= nil
end

NS.Trust = Trust
return Trust
