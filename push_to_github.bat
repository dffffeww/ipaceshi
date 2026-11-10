@echo off
setlocal
cd /d "%~dp0"

echo ==============================================
echo  PeakPal iOS - Push to GitHub (auto-build .ipa)
echo ==============================================
echo.
echo Step 1: Create an EMPTY private repo on github.com first:
echo         github.com -^> "+" -^> New repository -^> Private -^> do NOT add README
echo.
echo Step 2: Paste the repo URL below, press Enter.
echo         (First time: a browser window opens for GitHub login)
echo.

set /p REPO=Repo URL (e.g. https://github.com/yourname/peakpal-ios.git):
if "%REPO%"=="" (
  echo No URL entered.
  pause
  exit /b 1
)

where git >nul 2>nul
if errorlevel 1 (
  echo Git not found on this PC.
  pause
  exit /b 1
)

git init
git config user.name "peakpal"
git config user.email "peakpal@app.local"
git add .
git commit -m "PeakPal iOS - auto build"
git branch -M main
git remote remove origin >nul 2>nul
git remote add origin "%REPO%"
echo.
echo Pushing... please wait.
git push -u origin main
echo.
echo ==============================================
echo Pushed! Now:
echo   1. Open your repo page on github.com
echo   2. Click the "Actions" tab, wait 10-15 min
echo   3. Click the finished run, download artifact
echo      "PeakPal-iOS-unsigned-ipa"  -^> that IS the .ipa
echo   4. Install on iPhone with AiSiHelper / Sideloadly
echo ==============================================
pause
