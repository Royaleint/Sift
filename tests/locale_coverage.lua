-- luacheck: read globals arg
-- Static check that player-visible English text reaches the screen through L.
-- Run from the repository root: lua tests/locale_coverage.lua
--
-- Scans every .lua file in Sift.toc (except Locales/* and PatternData.lua).
-- A literal group (string literals joined only by "..") must be one of:
--   - the direct argument of an L[...] lookup,
--   - an executed key of Locales/enUS.lua,
--   - too short or too plain to be display text, or
--   - listed in tests/locale_coverage_exempt.lua with a valid category.
--
-- Failure ids:
--   (a) uncovered group      (b) bad or missing exempt category
--   (c) stale exempt entry   (d) L[...] literal that is not an enUS key
--   (input) a required input is missing, unreadable or empty
-- Prints "RESULT: OK" and exits 0 only when nothing failed.

local TOC_PATH = "Sift.toc"
local EXEMPT_PATH = "tests/locale_coverage_exempt.lua"
local ENUS_PATH = "Locales/enUS.lua"
local SKIP_FILES = { ["PatternData.lua"] = true }
local CATEGORIES = { id = true, data = true, dev = true, brand = true, game = true }

local failures = {}

local function fail(id, where, detail)
  failures[#failures + 1] = "FAIL (" .. id .. ") " .. where .. ": " .. detail
end

local function show(text)
  return (text:gsub("%c", function(c)
    if c == "\n" then return "\\n" end
    if c == "\t" then return "\\t" end
    return string.format("\\%d", c:byte())
  end))
end

local function normalize(path)
  return (path:gsub("\\", "/"))
end

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if not data then return nil end
  data = data:gsub("\r\n", "\n")
  data = data:gsub("\r", "\n")
  return data
end

local ESCAPES = {
  a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
}

local function countNewlines(s)
  local _, n = s:gsub("\n", "")
  return n
end

-- Lua 5.1 tokenizer reduced to what the check needs. Comments are dropped,
-- long strings become opaque "long" tokens, short strings are decoded.
local function tokenize(src)
  local toks, pos, line, len = {}, 1, 1, #src
  local function push(t, v, ln) toks[#toks + 1] = { t = t, v = v, line = ln or line } end
  while pos <= len do
    local c = src:sub(pos, pos)
    if c == "\n" then
      line = line + 1
      pos = pos + 1
    elseif c:match("%s") then
      pos = pos + 1
    elseif src:sub(pos, pos + 1) == "--" then
      local eq = src:match("^%-%-%[(=*)%[", pos)
      if eq then
        local close = "]" .. eq .. "]"
        local _, e = src:find(close, pos, true)
        e = e or len
        line = line + countNewlines(src:sub(pos, e))
        pos = e + 1
      else
        local e = src:find("\n", pos, true)
        pos = e or (len + 1)
      end
    elseif c == "[" and src:match("^%[=*%[", pos) then
      local eq = src:match("^%[(=*)%[", pos)
      local close = "]" .. eq .. "]"
      local _, e = src:find(close, pos, true)
      e = e or len
      push("long", "")
      line = line + countNewlines(src:sub(pos, e))
      pos = e + 1
    elseif c == '"' or c == "'" then
      local startLine = line
      local buf = {}
      pos = pos + 1
      while pos <= len do
        local ch = src:sub(pos, pos)
        if ch == c then
          pos = pos + 1
          break
        elseif ch == "\\" then
          local nx = src:sub(pos + 1, pos + 1)
          local dec = src:match("^%d%d?%d?", pos + 1)
          if dec then
            buf[#buf + 1] = string.char(tonumber(dec) % 256)
            pos = pos + 1 + #dec
          elseif ESCAPES[nx] then
            buf[#buf + 1] = ESCAPES[nx]
            pos = pos + 2
          elseif nx == "\n" then
            buf[#buf + 1] = "\n"
            line = line + 1
            pos = pos + 2
          else
            buf[#buf + 1] = nx
            pos = pos + 2
          end
        elseif ch == "\n" then
          break
        else
          buf[#buf + 1] = ch
          pos = pos + 1
        end
      end
      push("str", table.concat(buf), startLine)
    elseif c:match("[%a_]") then
      local word = src:match("^[%w_]+", pos)
      push("name", word)
      pos = pos + #word
    elseif c:match("%d") or (c == "." and src:match("^%.%d", pos)) then
      local num = src:match("^[%w%.]+", pos)
      push("num", num)
      pos = pos + #num
    elseif src:sub(pos, pos + 2) == "..." then
      push("op", "...")
      pos = pos + 3
    elseif src:sub(pos, pos + 1) == ".." then
      push("op", "..")
      pos = pos + 2
    else
      push("op", c)
      pos = pos + 1
    end
  end
  return toks
end

-- Literal groups: runs of string tokens joined only by "..".
local function groups(toks)
  local out, i = {}, 1
  while i <= #toks do
    local tk = toks[i]
    if tk.t == "str" then
      local first, last, parts = i, i, { tk.v }
      while toks[last + 1] and toks[last + 1].t == "op" and toks[last + 1].v == ".."
        and toks[last + 2] and toks[last + 2].t == "str" do
        parts[#parts + 1] = toks[last + 2].v
        last = last + 2
      end
      local prev, prev2, nxt = toks[first - 1], toks[first - 2], toks[last + 1]
      out[#out + 1] = {
        text = table.concat(parts),
        line = tk.line,
        inL = (prev and prev.t == "op" and prev.v == "["
          and prev2 and prev2.t == "name" and prev2.v == "L"
          and nxt and nxt.t == "op" and nxt.v == "]") and true or false,
      }
      i = last + 1
    else
      i = i + 1
    end
  end
  return out
end

local function displayLike(text)
  local s = text
  s = s:gsub("%%%%", "")
  s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
  s = s:gsub("|r", "")
  s = s:gsub("|T.-|t", "")
  s = s:gsub("%%[%-%+ #0]*%d*%.?%d*%a", "")
  local _, letters = s:gsub("%a", "")
  if letters < 2 then return false end
  local trimmed = s:match("^%s*(.-)%s*$")
  if not trimmed:find("%s") and not trimmed:match("^%u%l+$") then return false end
  return true
end

local function loadTocFiles()
  local toc = readFile(TOC_PATH)
  if not toc then
    fail("input", TOC_PATH, "unreadable")
    return nil
  end
  local files = {}
  for rawLine in (toc .. "\n"):gmatch("(.-)\n") do
    local entry = normalize(rawLine):match("^%s*(.-)%s*$")
    if entry ~= "" and entry:sub(1, 1) ~= "#" and entry:lower():match("%.lua$") then
      if entry:lower():sub(1, 8) ~= "locales/" and not SKIP_FILES[entry] then
        files[#files + 1] = entry
      end
    end
  end
  if #files == 0 then
    fail("input", TOC_PATH, "no scannable .lua entries")
    return nil
  end
  return files
end

local function loadEnglishKeys()
  local src = readFile(ENUS_PATH)
  if not src then
    fail("input", ENUS_PATH, "unreadable")
    return nil
  end
  local chunk, err = loadstring(src, "@" .. ENUS_PATH)
  if not chunk then
    fail("input", ENUS_PATH, "does not compile: " .. show(tostring(err)))
    return nil
  end
  local ns = {}
  setfenv(chunk, setmetatable({}, { __index = _G }))
  local ok, runErr = pcall(chunk, "Sift", ns)
  if not ok then
    fail("input", ENUS_PATH, "does not execute: " .. show(tostring(runErr)))
    return nil
  end
  local keys, count = {}, 0
  if type(ns.L) == "table" then
    for k in pairs(ns.L) do
      keys[k] = true
      count = count + 1
    end
  end
  if count == 0 then
    fail("input", ENUS_PATH, "executes to zero keys")
    return nil
  end
  return keys
end

local function loadExempt()
  local chunk = loadfile(EXEMPT_PATH)
  if not chunk then
    fail("input", EXEMPT_PATH, "missing or does not load")
    return nil
  end
  local ok, list = pcall(chunk)
  if not ok or type(list) ~= "table" then
    fail("input", EXEMPT_PATH, "does not return a table")
    return nil
  end
  return list
end

local function run()
  local files = loadTocFiles()
  local keys = loadEnglishKeys()
  local exempt = loadExempt()
  if not (files and keys and exempt) then return end

  local exemptIndex = {}
  for i, entry in ipairs(exempt) do
    local where = EXEMPT_PATH .. "#" .. i
    if type(entry) ~= "table" or type(entry.file) ~= "string" or type(entry.text) ~= "string" then
      fail("b", where, "entry needs string file and text")
    else
      if not CATEGORIES[entry.category] then
        fail("b", where, "bad or missing category for " .. show(entry.text))
      end
      local id = normalize(entry.file) .. "\0" .. entry.text
      exemptIndex[id] = { used = false, where = where, file = entry.file, text = entry.text }
    end
  end

  local scanned = 0
  for _, path in ipairs(files) do
    local src = readFile(path)
    if not src then
      fail("input", path, "unreadable")
    else
      scanned = scanned + 1
      for _, g in ipairs(groups(tokenize(src))) do
        if g.inL then
          if not keys[g.text] then
            fail("d", path .. ":" .. g.line, show(g.text))
          end
        elseif not keys[g.text] and displayLike(g.text) then
          local hit = exemptIndex[path .. "\0" .. g.text]
          if hit then
            hit.used = true
          else
            fail("a", path .. ":" .. g.line, show(g.text))
          end
        end
      end
    end
  end
  if scanned == 0 then
    fail("input", TOC_PATH, "no files could be read")
    return
  end

  for _, e in pairs(exemptIndex) do
    if not e.used then
      fail("c", e.where, "no match in " .. e.file .. " for " .. show(e.text))
    end
  end
end

local ok, err = pcall(run)
if not ok then
  fail("input", "locale_coverage.lua", show(tostring(err)))
end

if #failures > 0 then
  for _, line in ipairs(failures) do print(line) end
  os.exit(1)
end
print("RESULT: OK")
os.exit(0)
