--[[ Copyright (c) 2010 Peter "Corsix" Cawley

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE. --]]

local function ParseComments(tokens, i, object)
  -- Collect the comments prior to the given token
  local comment_parts = {}
  local was_short = false
  while i > 1 do
    i = i - 1
    local tok = tokens[i]
    if tok[2] ~= "comment" then
      if tok[2] ~= "whitespace" then
        break
      end
    -- Ignore Unix Shebang and License comments
    elseif tok[1]:sub(1, 1) ~= "#" and not tok[1]:find[[THE SOFTWARE IS PROVIDED "AS IS"]] then
      local part = tok[1]:sub(3, -1)
      local mkr = part:match"^%[(=*)%["
      if mkr then
        part = part:sub(3 + #mkr, -3 - #mkr)
      end
      part = part:trim()
      if (not mkr) and was_short and comment_parts[1]:sub(1, 1) ~= "!" then
        -- Merge multiple short comments into a single comment part
        comment_parts[1] = part .. "\n" .. comment_parts[1]
      else
        table.insert(comment_parts, 1, part)
      end
      was_short = not mkr
    end
  end
  -- Parse each command
  for _, part in ipairs(comment_parts) do
    for command in (" "..part):gmatch"([^!]+)" do
      local operation = command:match"(%S*)"
      local operand = command:sub(1 + #operation, -1):trim()
      if operation == "" then
        if operand ~= "" then
          if object:getShortDesc() then
            object:setLongDesc(operand)
          else
            object:setShortDesc(operand)
          end
        end
      else
        error("Unknown documentation command: " .. operation)
      end
    end
  end
end

local function IdentifyClasses(tokens, globals)
  for tokens, j, i in tokens_gfind(tokens,
    "class", {"string", ".*"}
  )do
    local name = loadstring("return " .. tokens[i][1])()
    local class = LuaClass():setName(name):setParent(globals)
    ParseComments(tokens, j, class)
    local ib1, b1 = tokens_next(tokens, i)
    if b1 and b1[1] == "(" then
      local is, s = tokens_next(tokens, ib1)
      if s and s[2] == "identifier" then
        class:setSuperClass(s[1])
      end
    end
  end
end

local function ResolveSuperclassNames(globals)
  for _, var in globals:pairs() do
    if class.is(var, LuaClass) and type(var:getSuperClass()) == "string" then
      var:setSuperClass(globals:get(var:getSuperClass()))
    end
  end
end

local function GetFunctionName(tokens, i)
  local name_parts, is_method, is_local = {}, false, false
  for j = i - 1, 1, -1 do
    local token = tokens[j]
    if token[2] ~= "whitespace" and token[2] ~= "comment" then
      is_local = (token[2] == "keyword" and token[1] == "local")
      break
    end
  end
  while true do
    i = tokens_next(tokens, i)
    local token = tokens[i]
    if token[2] == "(" then
      break
    end
    if token[2] == ":" then
      is_method = true
    elseif token[2] == "identifier" then
      name_parts[#name_parts + 1] = token[1]
    end
  end
  return name_parts, is_method
end

local function ScanToEndToken(tokens, i)
  local level = 1
  while i <= #tokens do
    local tok = tokens[i]
    if tok[2] == "keyword" then
      local k = tok[1]
      if k == "end" then
        level = level - 1
        if level == 0 then
          break
        end
      elseif k == "do" or k == "if" or k == "function" then
        level = level + 1
      end
    end
    i = i + 1
  end
  return i
end

local function IdentifyMethods(tokens, globals)
  local i = 1
  while i <= #tokens do
    if tokens[i][1] == "function" and tokens[i][2] == "keyword" then
      local name_parts, is_method, is_local = GetFunctionName(tokens, i)
      local method, class
      if not is_local and (#name_parts == 2 or #name_parts == 1) then
        if #name_parts == 1 then
          method = LuaFunction():setParent(globals)
        else
          class = globals:get(name_parts[1])
          if not class then
            class = LuaTable():setName(name_parts[1]):setParent(globals)
          end
          method = LuaFunction():setParent(class)
          local existing = class:get(name_parts[#name_parts])
          if existing and existing:getParent() == class then
            class:removeMember(existing)
          end
        end
        method:setName(name_parts[#name_parts]):setIsMethod(is_method)
      end
      local endi = ScanToEndToken(tokens, i + 1)
      while i < endi do
        if is_method and tokens[i][1] == "self" and tokens[i][2] == "identifier" then
          i = tokens_next(tokens, i)
          if tokens[i][2] == "." or tokens[i][2] == ":" then
            i = tokens_next(tokens, i)
            if tokens[i][2] == "identifier" then
              local field = class:get(tokens[i][1])
              if not field or (field.type ~= "function" and field:getParent() ~= class) then
                LuaVariable():setName(tokens[i][1]):setParent(class)
              end
            end
          end
        end
        i = i + 1
      end
    end
    i = i + 1
  end
end

local function FixClassTree(class)
  local super = class:getSuperClass()
  if super then
    local to_remove = {}
    for key, val in class:pairs() do
      if val:getParent() == class and val.type == nil then
        local existing = super:get(key)
        if existing and existing.type == "function" then
          to_remove[val] = true
        end
      end
    end
    for val in pairs(to_remove) do
      class:removeMember(val)
    end
  end
  for _, class in class:subclassPairs() do
    FixClassTree(class)
  end
end

function MakeLuaCodeModel(lua_file_names)
  tokens_gfind_mode "Lua"
  local lua_file_tokens = {}
  for _, filename in ipairs(lua_file_names) do
    local f = assert(io.open(filename))
    lua_file_tokens[filename] = TokeniseLua(f:read "*a")
    f:close()
  end
  local globals = LuaTable()
  for filename, tokens in pairs(lua_file_tokens) do
    IdentifyClasses(tokens, globals)
  end
  ResolveSuperclassNames(globals)
  for filename, tokens in pairs(lua_file_tokens) do
    IdentifyMethods(tokens, globals)
  end
  for _, var in globals:pairs() do
    if class.is(var, LuaClass) and not var:getSuperClass() then
      FixClassTree(var)
    end
  end
  return globals
end