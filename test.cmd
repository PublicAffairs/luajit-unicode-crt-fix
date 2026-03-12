@echo off
chcp 65001 1>nul
set "IAT_TEST_VAR=Ελλ_中文_한국_عربي_кирил"
for %%I in (luajit.exe) do %%~$PATH:I test.lua
::clean up
rmdir /s /q _iat_test 2>nul
