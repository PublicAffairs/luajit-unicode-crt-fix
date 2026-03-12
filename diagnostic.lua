-- Run this script if `assert(unicode_fix.apply("all"))` fails in your application.

local unicode_fix = require("unicode_crt_fix")

print("--- Starting IAT Patcher Diagnostics ---")
unicode_fix.log = function(msg) print("[LOG] " .. msg) end

local ok, err = unicode_fix.apply("dry-run")

print("--- Diagnostics Complete ---\n")

if ok then
    print("[x] SUCCESS: All hooks can be safely applied.")
    print("You can safely use `assert(unicode_fix.apply('all'))` in your project.")
else
    print("[!] FAILURE: " .. err)
    print("\n--- How to resolve this ---")
    print("Read the [LOG] messages above to find which specific function caused the conflict.")
    print("It might be missing from your LuaJIT build or already hooked by another DLL (e.g., an antivirus).")
    print("If you are sure the rest of the patches are safe, explicitly list only the valid functions")
    print("in your startup script, effectively bypassing the problematic ones.")
    print("\n   Example:")
    print("assert(unicode_fix.apply('fopen', 'system', 'remove', 'rename', 'getenv'))")
end
