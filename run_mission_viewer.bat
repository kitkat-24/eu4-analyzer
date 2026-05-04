@echo off
:: ==========================================================
:: EU4 MISSION VIEWER LAUNCHER
:: ==========================================================
:: Instructions for users:
:: To change which files are being looked at, edit the paths
:: between the quotes below.
:: ==========================================================

:: 1. The path to your mission script (e.g., missions\mamluk_missions.txt)
set MISSION_FILE="C:\Path\To\Your\Mod\missions\my_mission_file.txt"

:: 2. The path to your localization YAML (e.g., localisation\english.yml)
:: If you don't want to use one, leave this blank.
set LOC_FILE="C:\Path\To\Your\Mod\localisation\english.yml"

:: 3. Optional Settings
:: Set DEPTH to 1 or 2 if you want to see branching missions in the same slot.
set DEPTH=0


:: ==========================================================
:: INTERNAL COMMAND (Do not edit below this line)
:: ==========================================================

echo Starting Mission Viewer...
echo Mission: %MISSION_FILE%
echo Loc:     %LOC_FILE%

mission_viewer.exe %MISSION_FILE% --locFile:%LOC_FILE% --depth:%DEPTH% --browser

echo.
echo Process complete. The browser should open automatically.
pause