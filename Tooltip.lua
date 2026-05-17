local _, NS = ...
local Tooltip = {}

local registered = false

local function CountBlockedByGUID(guid)
  if type(guid) ~= "string" or guid == "" then return 0, nil end
  local char = NS.DB and NS.DB.GetChar and NS.DB.GetChar()
  if not char or type(char.history) ~= "table" then return 0, nil end

  local count = 0
  local lastTs
  for i = 1, #char.history do
    local entry = char.history[i]
    if entry and entry.guid == guid and entry.outcome == "blocked" then
      count = count + 1
      if entry.ts and (not lastTs or entry.ts > lastTs) then
        lastTs = entry.ts
      end
    end
  end
  return count, lastTs
end

local function RelativeAge(ts)
  if type(ts) ~= "number" or not GetServerTime then return nil end
  local delta = GetServerTime() - ts
  if delta < 0     then return "just now" end
  if delta < 60    then return tostring(delta) .. "s ago" end
  if delta < 3600  then return tostring(math.floor(delta / 60))   .. "m ago" end
  if delta < 86400 then return tostring(math.floor(delta / 3600)) .. "h ago" end
  return tostring(math.floor(delta / 86400)) .. "d ago"
end

local function OnUnitTooltip(tooltip, data)
  if not tooltip or not data or type(data.guid) ~= "string" then return end

  local count, lastTs = CountBlockedByGUID(data.guid)
  if count <= 0 then return end

  local plural = (count == 1) and "message" or "messages"
  local line = string.format("BawrSpam: blocked %d spam %s", count, plural)
  local ageSuffix = RelativeAge(lastTs)
  if ageSuffix then
    line = line .. " (last " .. ageSuffix .. ")"
  end
  tooltip:AddLine("|cffff5577" .. line .. "|r")
end

function Tooltip.Initialize()
  if registered then return end
  if not TooltipDataProcessor or type(TooltipDataProcessor.AddTooltipPostCall) ~= "function" then
    return
  end
  if not Enum or not Enum.TooltipDataType or not Enum.TooltipDataType.Unit then
    return
  end
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
  registered = true
end

NS.Tooltip = Tooltip
return Tooltip
