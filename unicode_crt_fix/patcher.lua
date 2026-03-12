--[[
  patcher.lua
  IAT patcher for Windows PE (x86 and x64).
  Named imports only; ordinal, delayed and bound imports are not supported.
  More advanced version is here: https://github.com/PublicAffairs/luajit-iat-patcher
]]

local ffi = require("ffi")
assert(ffi.os == "Windows", "This module is Windows-only")

-- ─── PE structures and WinAPI ────────────────────────────────────────────────

ffi.cdef[[
    typedef struct {
        uint16_t Hint;
        uint8_t  Name[1];
    } IMAGE_IMPORT_BY_NAME;

    typedef struct {
        uint32_t OriginalFirstThunk;
        uint32_t TimeDateStamp;
        uint32_t ForwarderChain;
        uint32_t Name;
        uint32_t FirstThunk;
    } IMAGE_IMPORT_DESCRIPTOR;

    void* __stdcall GetModuleHandleA(const char* module_name);
    void* __stdcall GetProcAddress(void* module_handle, const char* proc_name);
    unsigned int __stdcall GetLastError(void);
    int __stdcall VirtualProtect(void* address, size_t size, unsigned int new_protect, unsigned int* old_protect);
]]

-- ─── Pointer arithmetic helpers ──────────────────────────────────────────────

local function ptr2int(p)
  return tonumber(ffi.cast("uintptr_t", p))
end

local function int2ptr(addr, ctype)
  return ffi.cast(ctype, ffi.cast("uintptr_t", addr))
end

-- ─── Storage ─────────────────────────────────────────────────────────────────

local original = {}
-- Garbage Collector anchor! Prevents FFI callbacks from being collected.
local active_callbacks = {} -- luacheck: ignore 241

-- ─── PE parsing ──────────────────────────────────────────────────────────────

local function pe_import_rva(base)
  assert(int2ptr(base, "uint16_t*")[0] == 0x5A4D, "Invalid DOS signature (MZ expected)")

  local e_lfanew = int2ptr(base + 0x3C, "uint32_t*")[0]
  assert(int2ptr(base + e_lfanew, "uint32_t*")[0] == 0x4550, "Invalid PE signature")

  local opt_base = base + e_lfanew + 24
  local magic    = int2ptr(opt_base, "uint16_t*")[0]

  -- Import DataDirectory offset from OptionalHeader start:
  local imp_off = (magic == 0x20B) and 120 -- PE32+ (0x20B): 120 bytes
               or (magic == 0x10B) and 104 -- PE32  (0x10B): 104 bytes
  assert(imp_off, string.format("Unknown OptionalHeader magic: 0x%04X", magic))

  local import_rva = int2ptr(opt_base + imp_off, "uint32_t*")[0]
  assert(import_rva ~= 0, "Module has no import directory")
  return import_rva
end

-- ─── IAT scanning ────────────────────────────────────────────────────────────

local M -- fwd decl.
local function logf(msg, ...)
  if M.log then
    M.log(string.format(msg, ...))
  end
end

-- ILT/IAT are plain uintptr_t arrays; no struct needed.
local function scan_iat(base, targets, options)
  local results = {}
  for name in pairs(targets) do
    if original[name] then
      if options.break_on_already_patched then
        return nil, string.format("'%s' already patched", name)
      end
      logf("'%s' already patched, skipping", name)
      targets[name] = nil
    end
  end
  if not next(targets) then return results end

  local import_rva = pe_import_rva(base)
  local desc = int2ptr(base + import_rva, "IMAGE_IMPORT_DESCRIPTOR*")
  local i = 0
  while desc[i].Name ~= 0 do
    local ilt_rva = desc[i].OriginalFirstThunk
    if ilt_rva ~= 0 then
      local cur_dll = ffi.string(int2ptr(base + desc[i].Name, "uint8_t*"))
      local ilt     = int2ptr(base + ilt_rva,            "uintptr_t*")
      local iat     = int2ptr(base + desc[i].FirstThunk, "uintptr_t*")
      local j = 0
      while ilt[j] ~= 0 do
        -- skip ordinal imports (MSB set)
        if ffi.cast("intptr_t", ilt[j]) > 0 then
          local ibn       = int2ptr(base + tonumber(ilt[j]), "IMAGE_IMPORT_BY_NAME*")
          local func_name = ffi.string(ibn.Name)
          if targets[func_name] then
            logf("Found '%s' in '%s' at index %d", func_name, cur_dll, j)
            local entry = { ptr = iat + j, dll = cur_dll }
            -- Verify not already hooked (catches both our own and foreign hooks)
            local h = ffi.C.GetModuleHandleA(cur_dll)
            if h ~= nil then
              local expected = ffi.C.GetProcAddress(h, func_name)
              if expected ~= nil and tonumber(iat[j]) ~= ptr2int(expected) then
                entry.ptr  = nil
                logf("'%s' from '%s': already hooked", func_name, cur_dll)
                if options.patch_all_or_nothing then
                  return nil, string.format("'%s' from '%s': already hooked", func_name, cur_dll)
                end
              end
            end
            results[func_name] = entry
            targets[func_name] = nil
          end
        end
        j = j + 1
      end
    end
    if not next(targets) then break end
    i = i + 1
  end

  for name in pairs(targets) do
    logf("Warning: '%s' not found in IAT", name)
    if options.patch_all_or_nothing then
      return nil, "One or more target functions were not found in the IAT"
    end
  end
  return results
end

-- ─── IAT entry patching ──────────────────────────────────────────────────────

local function patch_iat(entries, hooks)
  local cell_size    = ffi.sizeof("uintptr_t")
  local dummy = ffi.new("uint32_t[1]")
  local PAGE_READWRITE = 0x04
  for func_name, entry in pairs(entries) do
    if entry.ptr and hooks[func_name] then
      local ptr      = entry.ptr -- uintptr_t*
      local ptr_type = ffi.typeof("$ *", ffi.typeof(ffi.C[func_name]))
      local cb       = ffi.cast(ptr_type, hooks[func_name])
      local old_prot = ffi.new("uint32_t[1]")
      -- Each IAT slot may reside in a different allocation region; patch one cell at a time.
      local vpOk = ffi.C.VirtualProtect(ptr, cell_size, PAGE_READWRITE, old_prot) ~= 0
      if vpOk then
        original[func_name] = ffi.cast(ptr_type, ptr[0]) -- exposed in public API
        active_callbacks[ptr2int(ptr)] = cb              -- prevent GC
        ptr[0] = ffi.cast("uintptr_t", cb)
        vpOk = ffi.C.VirtualProtect(ptr, cell_size, old_prot[0], dummy) ~= 0
      end
      if not vpOk then
        local code = ffi.C.GetLastError()
        local restore = original[func_name] and "restore " or ""
        error(string.format("VirtualProtect %sfailed for '%s': %d", restore, func_name, code))
      end
    end
  end
  return true
end

-- ─── Public API ──────────────────────────────────────────────────────────────

M = {
  PATCHES  = {},
  original = original,
  base_dll = nil,
  break_on_already_patched = true,
  patch_all_or_nothing = true,
  --log      = print,
}

local function patch(base_ptr, hooks, options)
  local targets = {}
  for name in pairs(hooks) do targets[name] = true end
  local entries, errmsg = scan_iat(ptr2int(base_ptr), targets, options)
  if not entries then
    return nil,errmsg
  end
  if options.dry_run then
    return true
  end
  return patch_iat(entries, hooks)
end

function M.apply(...)
  assert(select("#", ...) > 0, "pass function names or 'all'")
  local patches, options
  if ... == "all" then
    patches = M.PATCHES
  elseif ... == "dry-run" then
    patches = M.PATCHES
    options = { dry_run=true }
  else
    patches = {}
    for _, name in ipairs({...}) do
      local fn = M.PATCHES[name]
      if not fn then
        error(string.format("Undefined function: '%s'", name))
      end
      patches[name] = fn
    end
  end
  return patch(assert(M.base_dll), patches, options or {
    break_on_already_patched = M.break_on_already_patched,
    patch_all_or_nothing = M.break_on_already_patched,
  })
end

return M
