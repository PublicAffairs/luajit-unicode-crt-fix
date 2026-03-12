--[[
  luajit_unicode.lua
  IAT patcher for Unicode support in LuaJIT (Windows, x86 and x64)
]]

local patcher = require("unicode_crt_fix.patcher")
local ffi = require("ffi")

-- ─── WinAPI ───────────────────────────────────────────────────────────────────

ffi.cdef[[
    int __stdcall MultiByteToWideChar(
        unsigned int CodePage,
        unsigned int dwFlags,
        const char * lpMultiByteStr,
        int cbMultiByte,
        wchar_t * lpWideCharStr,
        int cchWideChar
    );
    int __stdcall WideCharToMultiByte(
        unsigned int CodePage,
        unsigned int dwFlags,
        const wchar_t * lpWideCharStr,
        int cchWideChar,
        char * lpMultiByteStr,
        int cbMultiByte,
        const char * lpDefaultChar,
        int * lpUsedDefaultChar
    );
    int __stdcall GetModuleHandleExA(
        unsigned int dwFlags,
        const char* lpModuleName,
        void** phModule
    );
    unsigned int __stdcall GetLastError(void);
    void __stdcall SetLastError(unsigned int dwErrCode);
    uint32_t __stdcall GetACP();
    void*    luaL_newstate(void);

    typedef struct _FILE FILE;
    int*     _errno(void);
    FILE*    fopen(const char* filename, const char* mode);
    FILE*    _popen(const char* command, const char* mode);
    int      system(const char* command);
    int      remove(const char* filename);
    int      rename(const char* old_filename, const char* new_filename);
    char*    getenv(const char* name);
    void * __stdcall LoadLibraryExA(
        const char *lpLibFileName,
        void *hFile,
        unsigned int dwFlags
    );
    unsigned int __stdcall GetModuleFileNameA(
        void* hModule,
        char* lpFilename,
        unsigned int nSize
    );

    FILE*    _wfopen(const wchar_t *filename, const wchar_t *mode);
    FILE*    _wpopen(const wchar_t* command, const wchar_t* mode);
    int      _wsystem(const wchar_t* command);
    int      _wremove(const wchar_t* path);
    int      _wrename(const wchar_t* oldname, const wchar_t* newname);
    wchar_t* _wgetenv(const wchar_t* varname);
    void * __stdcall LoadLibraryExW(
        const wchar_t *lpLibFileName,
        void *hFile,
        unsigned int dwFlags
    );
    unsigned int __stdcall GetModuleFileNameW(
        void* hModule,
        wchar_t* lpFilename,
        unsigned int nSize
    );
]]
local EINVAL = 22
local CP_UTF8 = 65001

--https://learn.microsoft.com/windows/apps/design/globalizing/use-utf8-code-page
if ffi.C.GetACP() == CP_UTF8 then
  return { apply = function() return nil, "Nothing to do: UTF-8 locale detected" end }
end

-- ─── UTF-8 → WCHAR* ──────────────────────────────────────────────────────────

local function utf8_to_wide(s)
  if not s then return nil end
  local req_chars = ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, -1, nil, 0)
  if req_chars == 0 then return nil end

  local buf = ffi.new("wchar_t[?]", req_chars)
  local written = ffi.C.MultiByteToWideChar(CP_UTF8, 0, s, -1, buf, req_chars)
  if written == 0 then return nil end
  return buf
end

local function wide_to_utf8(ws)
  if not ws then return nil end
  local req_bytes = ffi.C.WideCharToMultiByte(CP_UTF8, 0, ws, -1, nil, 0, nil, nil)
  if req_bytes == 0 then return nil end

  local buf = ffi.new("char[?]", req_bytes)
  local written = ffi.C.WideCharToMultiByte(CP_UTF8, 0, ws, -1, buf, req_bytes, nil, nil)
  if written == 0 then return nil end
  return buf
end

-- ─── Dynamic Lua Module Resolution ────────────────────────────────────────────

--local GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 0x00000004
--local GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT = 0x00000002
local GET_MODULE_FLAGS = 0x6
local function get_module_from_address(p, func_name)
  local hmod = ffi.new("void*[1]")
  local success = ffi.C.GetModuleHandleExA(GET_MODULE_FLAGS, ffi.cast("const char*", p), hmod)
  if success == 0 or hmod[0] == nil then
    error(string.format("Failed to resolve module base address for function '%s'", func_name))
  end
  return hmod[0]
end

-- ─── Hook functions ───────────────────────────────────────────────────────────

local wmap = {_wfopen="fopen",_wpopen="_popen",_wsystem="system",_wremove="remove",_wrename="rename",_wgetenv="getenv",}
local CRT = setmetatable({},{
  __index=function(t,func_name)
    local orig_name = wmap[func_name]
    local orig_func = patcher.original[orig_name]
    local crt_hmod = assert(get_module_from_address(orig_func, orig_name))
    local cfunc = ffi.C.GetProcAddress(crt_hmod, func_name)
    if cfunc == nil then
      error(string.format("GetProcAddress failed with CRT function '%s'", func_name))
    end
    local ptr_type = ffi.typeof("$ *", ffi.typeof(ffi.C[func_name]))
    t[func_name] = ffi.cast(ptr_type, cfunc)
    return t[func_name]
  end
})

local hooks = {}
function hooks.fopen (filename, mode) -- io.open
  local wf = utf8_to_wide(filename)
  local wm = utf8_to_wide(mode)
  if not wf or not wm then
    ffi.errno(EINVAL)
    return nil
  end
  return CRT._wfopen(wf, wm) -- the function itself sets errno on error.
end

function hooks._popen (command, mode) -- io.popen
  local wc = utf8_to_wide(command)
  local wm = utf8_to_wide(mode)
  if not wc or not wm then
    ffi.errno(EINVAL)
    return nil
  end
  return CRT._wpopen(wc, wm)
end

function hooks.system (command) -- os.execute
  local wc = utf8_to_wide(command)
  if not wc then
    ffi.errno(EINVAL)
    return -1
  end
  return CRT._wsystem(wc)
end

function hooks.remove (path) -- os.remove
  local wp = utf8_to_wide(path)
  if not wp then
    ffi.errno(EINVAL)
    return -1
  end
  return CRT._wremove(wp)
end

function hooks.rename (oldname, newname) -- os.rename
  local wo = utf8_to_wide(oldname)
  local wn = utf8_to_wide(newname)
  if not wo or not wn then
    ffi.errno(EINVAL)
    return -1
  end
  return CRT._wrename(wo, wn)
end

-- Anchor for getenv to ensure the buffer survives the C call.
-- Safe because Lua copies the returned char* into a managed Lua string immediately.
local getenv_static_buf
function hooks.getenv (name) -- os.getenv
  local wn = utf8_to_wide(name)
  local wresult = wn and CRT._wgetenv(wn)
  local mbuf = wresult~=nil and wide_to_utf8(wresult)
  if not mbuf or mbuf == nil then return nil end
  getenv_static_buf = mbuf
  return getenv_static_buf
end

function hooks.LoadLibraryExA (path, file, flags) -- package.loadlib
  local wp = utf8_to_wide(path)
  if not wp then return nil end
  return ffi.C.LoadLibraryExW(wp, file, flags)
end

local ERROR_SUCCESS = 0
local ERROR_INSUFFICIENT_BUFFER = 122
function hooks.GetModuleFileNameA(hModule, lpFilename, nSize)
  local wbuf = ffi.new("wchar_t[?]", nSize + 1) --ensures null-termination
  ffi.C.SetLastError(ERROR_SUCCESS)
  local wlen = ffi.C.GetModuleFileNameW(hModule, wbuf, nSize)
  -- Let WinAPI handle invalid args (nSize == 0, bad hModule, etc.)
  if wlen == 0 then return 0 end

  local last_err = ffi.C.GetLastError()
  local utf8_buf = wide_to_utf8(wbuf)
  if not utf8_buf then return 0 end

  local utf8_str = ffi.string(utf8_buf)
  local copy_len = #utf8_str
                                             -- UTF-8 expansion can also exceed nSize
  if (last_err == ERROR_INSUFFICIENT_BUFFER) or (copy_len >= nSize) then
    if nSize > 1 then
      ffi.copy(lpFilename, utf8_str, nSize - 1)
    end
    lpFilename[nSize - 1] = 0
    ffi.C.SetLastError(ERROR_INSUFFICIENT_BUFFER)
    return nSize
  end

  ffi.copy(lpFilename, utf8_str, copy_len + 1)
  ffi.C.SetLastError(last_err)
  return copy_len
end

-- ─── Public API ───────────────────────────────────────────────────────────────

-- Using luaL_newstate pointer to locate the host module
patcher.base_dll = assert(get_module_from_address(ffi.C.luaL_newstate, "luaL_newstate"))
patcher.PATCHES = hooks
return patcher
