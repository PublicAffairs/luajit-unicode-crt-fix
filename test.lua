--package.loaded["unicode_crt_fix.patcher"] = require("iat_patcher")
local unicode_fix = require"unicode_crt_fix"
unicode_fix.log = print

local DIR  = "_iat_test"
local NAME = "Ελλ_中文_한국_عربي_кирил"
local BASE = DIR .. "\\" .. NAME

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function create_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

local function exit(code)
  --cleanup
  os.execute('rmdir /s /q "' .. DIR .. '" 2>nul')
  os.remove("test_setup.cmd")
  os.exit(code)
end

local function passert (ok,...)
  if ok then return ok,... end
  io.write(...)
  error(exit(1))
end

-- ─── Setup fixtures (ASCII args — works without patch) ───────────────────────

create_file("test_setup.cmd", string.gsub([[
@echo off
chcp 65001 1>nul
if %errorlevel% neq 0 exit /b 1

set DIR=$dir
set NAME=$name

:: Clean up previous run and verify removal
rmdir /s /q "%DIR%" 2>nul
if exist "%DIR%" exit /b 1
mkdir "%DIR%"
echo.> "%DIR%\%NAME%.txt"
echo.> "%DIR%\%NAME%.lua"
echo.> "%DIR%\rename_src_%NAME%.txt"
echo.> "%DIR%\%NAME%_to_remove.txt"
:: (ignore error if file not found)

copy "%~dp1lua51.dll" "%DIR%\%NAME%_lib.dll" >nul 2>&1 || echo [!] '%~dp1lua51.dll' not found!
set "IAT_TEST_VAR=%NAME%"
echo.> "%DIR%\setup_done.txt"
]], "$dir", DIR):gsub("$name",NAME))
local cmdline = string.format('test_setup.cmd "%s"', arg and arg[-1] or "") -- full-qualified path to luajit.exe
local ret = passert(os.execute(cmdline))
passert(ret == 0, "test_setup.cmd failed (check chcp 65001 support and permissions)")
-- Verify fixtures were actually created
passert(file_exists(DIR .. "\\setup_done.txt"), "Setup did not complete successfully")

local PASS, FAIL, SKIP = 0, 0, 0
local function test(name, fn)
  io.write("[?] " .. name)
  io.flush()
  local ok, err = pcall(fn)
  if ok then
    io.write("\r[x] " .. name .. "\n")
    PASS = PASS + 1
  else
    io.write("\r[ ] " .. name .. ": " .. tostring(err) .. "\n")
    if err and err:match"precondition:" then
      SKIP = SKIP + 1
    else
      FAIL = FAIL + 1
    end
  end
end

-- ─── Apply patches ────────────────────────────────────────────────────────────

passert(unicode_fix.apply"all")--todo
--passert(unicode_fix.apply"dry-run")--todo
--passert(unicode_fix.apply"fopen")

local read_ok = false
test("io.open read Unicode", function() -- Anchor Test
  local f = assert(io.open(BASE .. ".txt", "r"))
  f:close()
  read_ok = true
end)

if not read_ok then
  io.write("[!] The rest of the tests has not been performed")
  return exit(1)
end

test("io.open write Unicode", function()
  local path = BASE .. "_write.txt"
  local f = assert(io.open(path, "w"))
  f:close()
  assert(file_exists(path), "written file not readable back")
end)

test("loadfile Unicode", function()
  local path = BASE .. ".lua"
  assert(file_exists(path), "precondition: file must exist")
  assert(loadfile(path))
end)

test("dofile Unicode", function()
  local path = BASE .. ".lua"
  assert(file_exists(path), "precondition: file must exist")
  dofile(path)
end)

test("io.popen Unicode command arg", function()
  local path = BASE .. ".txt"
  assert(file_exists(path), "precondition: file must exist")
  local cmd = 'type ' .. '"' .. path .. '" 2>&1'
  local f = assert(io.popen(cmd, "r"))
  local out = f:read("*l")
  f:close()
  assert(out == "", out)
end)

test("os.execute Unicode command arg", function()
  local marker = BASE .. "_exec_marker.txt"
  assert(not file_exists(marker), "precondition: marker file must NOT exist")
  local code = assert(os.execute('cmd /c echo.> "' .. marker .. '"'))
  assert(code == 0, "os.execute returned " .. tostring(code))
  assert(file_exists(marker), "marker not created — os.execute Unicode arg failed")
end)

test("os.remove Unicode", function()
  local path = BASE .. "_to_remove.txt"
  assert(file_exists(path), "precondition: file must exist")
  assert(os.remove(path))
  assert(not file_exists(path), "file still exists after remove")
end)

test("os.rename Unicode -> Unicode", function()
  local src = DIR .. "\\rename_src_" .. NAME .. ".txt"
  assert(file_exists(src), "precondition: source must exist")
  local dst = BASE .. "_renamed.txt"
  assert(os.rename(src, dst))
  assert(file_exists(dst),     "renamed file not found")
  assert(not file_exists(src), "source still exists after rename")
end)

test("os.getenv Unicode value", function()
  local val = os.getenv("IAT_TEST_VAR")
  assert(val, "precondition: IAT_TEST_VAR must be pre-set")
  assert(val == NAME, "got: " .. tostring(val))
end)

test("package.loadlib with Unicode paths", function()
  local path = BASE .. "_lib.dll"
  assert(file_exists(path), "precondition: file must exist")
  assert(package.loadlib(path, "luaopen_os"))
end)

-- ─── Summary ─────────────────────────────────────────────────────────────────

io.write(string.format("\n%d passed, %d failed, %d skipped\n", PASS, FAIL, SKIP))
exit(FAIL)
