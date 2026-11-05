@echo off
rem Craft Updater launcher: asks Windows for administrator rights, then starts the updater.
rem Messages are shown in English and German (Deutsch).
setlocal
cd /d "%~dp0" || (echo ERROR / FEHLER: folder not reachable / Ordner nicht erreichbar.& pause& exit /b 2)
if not exist "%~dp0Craft-Auto-Updater-v5.8-Portable.ps1" (
  echo ERROR / FEHLER: the main script is missing in this folder / Hauptskript fehlt in diesem Ordner.
  pause
  exit /b 2
)
set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" (
  echo ERROR / FEHLER: Windows PowerShell 5.1 not found / nicht gefunden.
  pause
  exit /b 2
)
if /I "%~1"=="--elevated" goto RunUpdater
rem CMD passes its own path through an environment variable so that spaces and
rem special characters can never turn into PowerShell code.
set "CRAFT_UPDATER_CMD=%~f0"
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $p=$env:CRAFT_UPDATER_CMD; $id=[Security.Principal.WindowsIdentity]::GetCurrent(); $w=New-Object Security.Principal.WindowsPrincipal($id); if ($w.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 10 }; try { $args='/d /s /c ' + [char]34 + [char]34 + $p + [char]34 + ' --elevated' + [char]34; Start-Process -FilePath $env:ComSpec -ArgumentList $args -Verb RunAs -WindowStyle Minimized -ErrorAction Stop; exit 0 } catch { Write-Host ('Administrator approval failed / Administratorfreigabe fehlgeschlagen: ' + $_.Exception.Message); exit 5 }"
set "RC=%errorlevel%"
if "%RC%"=="10" goto RunUpdater
if not "%RC%"=="0" pause
exit /b %RC%
:RunUpdater
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -Command "$id=[Security.Principal.WindowsIdentity]::GetCurrent(); $w=New-Object Security.Principal.WindowsPrincipal($id); if(-not $w.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'ERROR / FEHLER: no administrator rights / keine Administratorrechte.'; exit 5 }"
if errorlevel 1 (
  echo ERROR / FEHLER: administrator rights missing / Administratorrechte fehlen.
  pause
  exit /b 5
)
echo Administrator rights confirmed / Administratorrechte bestaetigt. Craft Updater starting / startet.
echo IMPORTANT / WICHTIG: nothing is installed without your approval / ohne deine Freigabe wird nichts installiert.
"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Craft-Auto-Updater-v5.8-Portable.ps1"
set "RC=%errorlevel%"
echo.
echo Updater finished / beendet. Exit code / Rueckgabecode: %RC%
rem (No pause: when you close the sloth window, this window closes as well.)
rem (No self-deletion: this file stays - friendly to virus scanners.)
exit /b %RC%
