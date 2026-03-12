# LuaJIT Unicode Fix for Windows

![Windows](https://img.shields.io/badge/OS-Windows-blue?logo=windows)
![Architecture](https://img.shields.io/badge/Arch-x86%20%7C%20x64-blue?logo=intel)
![LuaJIT](https://img.shields.io/badge/LuaJIT-2.1-darkblue?logo=lua)
![License](https://img.shields.io/badge/License-MIT-green)

A seamless IAT-based patcher that brings transparent UTF-8 support to standard [LuaJIT] I/O, OS,
and C module loading functions on Windows (x86 and x64).

[LuaJIT]: https://luajit.org/luajit.html


## ⚠️ The Problem

On Windows, standard Lua/LuaJIT builds ultimately call narrow CRT / Win32 APIs
that interpret `char*` strings using the system ANSI code page.

As a result, UTF-8 paths, command strings, environment variable names, and DLL paths
may fail or become corrupted when they contain characters outside the active legacy code page.


## 💡 The Solution

This module patches the Import Address Table (IAT) of the core LuaJIT runtime in memory
and transparently redirects selected narrow calls to their wide-character equivalents.

This method is particularly well-suited for environments where direct binary modification
is neither feasible nor desirable.

While effective in its designed scope, it's important to note that it may not be the optimal solution for all scenarios.
For a broader overview of alternative Unicode fixing strategies for LuaJIT, please refer to [UNICODE.md](UNICODE.md).

To get more info about some limitations, see also the Notes section at the end of this document.


## ✨ Features

- **Zero code changes required:** Require and run the module once at startup
  and keep using the standard `io`, `os`, and `require` APIs.
- **Smart fallback:** Automatically detects if the [Windows Active Code Page][use-utf8-code-page]
  is already set to UTF-8 (a feature in modern Windows 10/11) and skips patching to avoid unnecessary overhead.
- **CRT-aware:** Wide-character CRT exports are resolved from the same CRT module
  that owns LuaJIT’s original imported function, avoiding [cross-CRT] `FILE*` issues.
- **Works with API-set based imports:** The patcher follows the real loaded target used by the process,
  not just the DLL name found in the PE import table.
- **Supports both x86 and x64 LuaJIT on Windows.**

[use-utf8-code-page]: https://learn.microsoft.com/windows/apps/design/globalizing/use-utf8-code-page
[cross-CRT]: https://learn.microsoft.com/cpp/c-runtime-library/potential-errors-passing-crt-objects-across-dll-boundaries?view=msvc-170#example-pass-file-handle-across-dll-boundary


## 🔧 Intercepted Functions

- `io.open` via `fopen` -> `_wfopen`
- `io.popen` via `_popen` -> `_wpopen`
- `os.execute` via `system` -> `_wsystem`
- `os.remove` via `remove` -> `_wremove`
- `os.rename` via `rename` -> `_wrename`
- `os.getenv` via `getenv` -> `_wgetenv`
- `package.loadlib` and `require` for C modules via `LoadLibraryExA` -> `LoadLibraryExW`
- `package.path` / `package.cpath` via `GetModuleFileNameA` -> `GetModuleFileNameW`
  (for more info, see the Limitations section at the end of this document).


## 🧠 How It Works

1. The module locates the LuaJIT host module (`lua51.dll` or the main executable).
2. It patches selected entries in that module’s Import Address Table.
3. For CRT-backed functions, it resolves the real owning CRT module from the original imported function address.
   It assumes all CRT imports are from a single runtime (mixed CRTs are unsupported).
4. It then resolves the matching wide-character export from that same CRT and calls it with UTF-16 arguments.


## 🚀 Usage

Simply require the module and call the returned function as early as possible during process startup.
You can choose to patch all supported functions or only specific ones.

```lua
local unicode_fix = require("unicode_crt_fix")
-- unicode_fix.log = print -- to see log messages

-- Patch everything supported by this module
unicode_fix.apply("all")

-- Or patch only selected functions
-- unicode_fix.apply("fopen", "_popen", "system")

-- From this point on, standard Lua functions accept UTF-8 paths transparently.

-- 1. Working with files with Unicode names
local file = io.open("C:/Έγγραφα/δοκιμή.txt", "w")
if file then
    file:write("Γειά σου Κόσμε!")
    file:close()
end

-- 2. Renaming files
os.rename("C:/Έγγραφα/δοκιμή.txt", "C:/Έγγραφα/μετονομάστηκε.txt")

-- 3. Executing Unicode commands
os.execute('echo "Γειά σου Κόσμε!"')

-- 4. Loading DLLs with Unicode paths
-- require("βιβλιοθήκη")
```


## 🛡️ Safe Patching & Diagnostics

The bundled IAT patcher is designed to be **strict and safe by default**.
If it detects a conflict (e.g., a target function is already hooked by an antivirus or profiler)
or if your specific LuaJIT build is missing expected functions in its IAT, `apply("all")` will
intentionally abort the process (returning `nil`) to prevent undefined behavior.

You should not trust the patcher blindly, **always use `assert`** so your application fails fast
if the environment is unexpected:

```lua
assert(unicode_fix.apply("all"))
```

Any failure here is a deliberate safety mechanism indicating that your LuaJIT environment is non-standard
or has been modified by third-party software.

If the assertion fails in your custom environment, run the patcher in `"dry-run"` mode
with verbose logging enabled in order to investigate the discrepancy
(see the sample [diagnostic.lua](diagnostic.lua) script).

If — and only if — you understand why your environment differs and consciously decide it is safe to proceed,
you can take responsibility by explicitly opting into specific functions:

```lua
-- Explicitly listing functions bypasses the strict "all-or-nothing" safety check
assert(unicode_fix.apply("fopen", "_popen", "system"))
```

For advanced API details of the patcher itself (configuration flags to alter this strict behavior, callbacks, etc.),
please refer directly to the [bundled patcher source code](unicode_crt_fix/patcher.lua).


## ⚙️ The IAT Patcher

The default patcher bundled with this project operates by modifying the IAT of the core LuaJIT module.
While it was designed to be compatible with most LuaJIT-backed executables,
it might encounter limitations in highly complex applications and unusual build configurations.

For more robust coverage of edge cases, consider using a more advanced IAT patcher available at:
https://github.com/PublicAffairs/luajit-iat-patcher.

To utilize this external patcher instead of the project's default:

```lua
package.loaded["unicode_fix.patcher"] = require("iat-patcher")
local unicode_fix = require("luajit-unicode-crt-fix")
```


## ⚠️ Limitations & Caveats


### `package.path` / `package.cpath`
During the initialization of `package.path` and `package.cpath`, LuaJIT uses
`GetModuleFileNameA` for executable-directory expansion (see `luaconf.h`).

Although this module redirects `GetModuleFileNameA` to `GetModuleFileNameW`,
this only affects future initializations of `package.path` and `package.cpath`.
If the current `lua_State` has already opened the `package` library before patching,
you may need to repair `package.path` and `package.cpath` manually for that state.


### `os.tmpname`
`os.tmpname` is intentionally left untouched.

Some widely used legacy Windows CRT implementations are known to return names like `\s3e8`,
which effectively point to the root of the current drive rather than to a proper user-writable temporary directory.

In practice, that makes `os.tmpname` a poor fit for modern Windows applications,
so this project does not try to preserve or extend that behavior.


### Command-Line Arguments
The method used by this project cannot fix the processing of `luajit.exe` command-line arguments.

In particular, if a script with Unicode characters in its name is passed, it will not be executed.
It also does not attempt to modify the global `arg` table.

However, you can manually retrieve the correct arguments using the WinAPI functions `GetCommandLineW` and `CommandLineToArgvW` via `ffi`.


### External C Modules
External C modules keep using their own imports and their own CRT/Win32 calls
and will not automatically benefit from this patch.

That means third-party DLLs may still use legacy code-page-based file APIs internally,
even if standard LuaJIT functions are already UTF-8 aware.

You *can* technically patch external C modules separately by calling the underlying `iat-patcher` directly and
specifying the target DLL's name.
However, the required set of intercepted functions might differ significantly from what this project provides.

Providing patches for third-party modules is **out of scope** for this project.

**The Recommended Approach for C Modules:** For filesystem helpers in LuaJIT,
prefer UTF-8 aware implementations over patching arbitrary native modules whenever possible.
For example, instead of trying to intercept and patch multiple internal functions of the standard [luafilesystem] (lfs),
it is much safer and easier to use a ready-made UTF-8 friendly FFI-based reimplementation such as [sonoro1234/luafilesystem].


## 🌟 Recommended Extension for Comprehensive Unicode Support

This module fixes UTF-8 interaction with the OS and filesystem.
It does **not** change how Lua string functions interpret UTF-8 text internally.
Functions such as `string.len`, `string.sub`, and `string.match` still operate on bytes, not Unicode code points.

For character-aware UTF-8 string handling (getting the actual string length, proper slicing, matching, etc.),
consider pairing this module with [starwing/luautf8].

[luafilesystem]: https://github.com/lunarmodules/luafilesystem
[sonoro1234/luafilesystem]: https://github.com/sonoro1234/luafilesystem
[starwing/luautf8]: https://github.com/starwing/luautf8
