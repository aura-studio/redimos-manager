@echo off
rem ============================================================================
rem  redimos-manager :: one-click build
rem  Double-click this file to build all three parts and package them into
rem  dist\redimos-manager-<version>-windows-x64.zip
rem
rem  Pass-through options (open a terminal and run "build.cmd <opts>"):
rem    build.cmd -RebuildServers      also recompile redimos-v1/v2.exe
rem    build.cmd -SkipDll             reuse the existing redimos_core.dll (no Docker)
rem    build.cmd -Version 0.2.0       override the package version
rem ============================================================================
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build.ps1" %*
set _rc=%ERRORLEVEL%
echo.
if %_rc% NEQ 0 (
  echo Build exited with code %_rc%.
) else (
  echo Done. Package is in the dist\ folder.
)
echo.
pause
