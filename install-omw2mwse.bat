@echo off
setlocal EnableExtensions
rem install-omw2mwse.bat
rem Clone or update dejunai/openmw-mwse into tools\omw2mwse, where tidy looks
rem for tools\omw2mwse\bin\omw2mwse. Copy this file into the
rem morrowind-conflict-tools root (the folder that contains vortex_tidy.py)
rem and run it there. This script does not travel with conflict-tools.
rem MIT, Copyright (c) 2026 dej (dejunai).

set "REPO_URL=https://github.com/dejunai/openmw-mwse.git"
set "DEST=tools\omw2mwse"
set "ERR=0"
set "PAUSE_AT_END=0"

echo %CMDCMDLINE% | find /I "%~nx0" >nul
if not errorlevel 1 set "PAUSE_AT_END=1"

cd /d "%~dp0"
if errorlevel 1 (
  echo ERROR: could not change to the folder this script is in.
  set "ERR=1"
  goto :finish
)

if not exist "vortex_tidy.py" goto :not_root
if not exist "mwdialog_check.py" goto :not_root
goto :have_root

:not_root
echo ERROR: this is not the morrowind-conflict-tools root.
echo Put this script in the folder that contains vortex_tidy.py and
echo mwdialog_check.py, then run it from there.
set "ERR=1"
goto :finish

:have_root
where git >nul 2>&1
if errorlevel 1 (
  echo ERROR: git was not found on PATH.
  echo Install Git for Windows, then open a new command prompt and try again.
  echo https://git-scm.com/download/win
  set "ERR=1"
  goto :finish
)

rem Do not hang waiting for GitHub credentials if a clone is not allowed.
set "GIT_TERMINAL_PROMPT=0"

if exist "%DEST%\.git" goto :update
if exist "%DEST%" (
  echo ERROR: %DEST% already exists and is not a git checkout.
  echo This script will not overwrite, reset, or clean that folder.
  echo Move or rename it, then run this script again.
  set "ERR=1"
  goto :finish
)

echo Cloning %REPO_URL% into %DEST% ...
git clone "%REPO_URL%" "%DEST%"
if errorlevel 1 (
  echo ERROR: git clone failed.
  echo If GitHub asked for a login, check that you can read
  echo https://github.com/dejunai/openmw-mwse
  set "ERR=1"
  goto :finish
)
goto :verify

:update
echo Updating the existing checkout in %DEST% ...
set "ORIGIN="
for /f "usebackq delims=" %%U in (`git -C "%DEST%" remote get-url origin 2^>nul`) do set "ORIGIN=%%U"
echo Origin: %ORIGIN%
echo %ORIGIN% | find /I "openmw-mwse" >nul
if errorlevel 1 (
  echo ERROR: %DEST% does not look like a checkout of dejunai/openmw-mwse.
  echo This script will not replace it. Origin was: %ORIGIN%
  set "ERR=1"
  goto :finish
)

git -C "%DEST%" pull --ff-only
if errorlevel 1 (
  echo ERROR: git pull --ff-only failed.
  echo The checkout was left as it is. This script does not force, reset, or clean.
  set "ERR=1"
  goto :finish
)

:verify
if not exist "%DEST%\bin\omw2mwse" (
  echo ERROR: the checkout is missing bin\omw2mwse, which is what tidy runs.
  set "ERR=1"
  goto :finish
)

echo.
echo tidy will find the converter at %DEST%\bin\omw2mwse
echo and run it with the same Python that runs vortex_tidy.py.
echo Python 3.9 or later is required.

set "PY="
where py >nul 2>&1
if not errorlevel 1 (
  py -3 -c "import sys" >nul 2>&1
  if not errorlevel 1 set "PY=py -3"
)
if not defined PY (
  where python >nul 2>&1
  if not errorlevel 1 set "PY=python"
)
if not defined PY (
  where python3 >nul 2>&1
  if not errorlevel 1 set "PY=python3"
)

if defined PY (
  echo Verifying with: %PY% "%DEST%\bin\omw2mwse" --version
  %PY% "%DEST%\bin\omw2mwse" --version
  if errorlevel 1 (
    echo ERROR: the converter did not run. Install Python 3.9+ and try again.
    set "ERR=1"
    goto :finish
  )
) else (
  echo NOTE: Python was not found on PATH, so the converter was not run here.
  echo tidy still needs Python 3.9+ to launch it.
)

echo.
echo Done. omw2mwse is in %DEST%.
goto :finish

:finish
if "%PAUSE_AT_END%"=="1" pause
exit /b %ERR%
