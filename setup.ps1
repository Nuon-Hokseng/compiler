$ErrorActionPreference = "Continue"
$APP_DIR  = "C:\IGAutomation"
$BACKEND  = "$APP_DIR\backend"
$FRONTEND = "$APP_DIR\frontend"
$LOG      = "$APP_DIR\setup-log.txt"

function Write-Log($msg, $color = "White") {
    $ts   = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LOG -Value $line -ErrorAction SilentlyContinue
}

function Write-Step($msg) {
    Write-Log ""
    Write-Log ">> $msg" "Cyan"
}

"" | Out-File -FilePath $LOG -Encoding utf8 -Force

Write-Log "================================================" "Magenta"
Write-Log "  IG Automation - Setup" "Magenta"
Write-Log "================================================"
Write-Log "APP_DIR  = $APP_DIR"
Write-Log "Log file = $LOG"

# ── VERIFY INSTALL ────────────────────────────────────
if (-not (Test-Path $APP_DIR)) {
    Write-Log "[ERROR] $APP_DIR not found. Please reinstall." "Red"
    exit 1
}
if (-not (Test-Path "$BACKEND\backend.exe")) {
    Write-Log "[ERROR] backend.exe missing. Please reinstall." "Red"
    exit 1
}
if (-not (Test-Path "$FRONTEND\.next")) {
    Write-Log "[ERROR] Frontend .next folder missing. Please reinstall." "Red"
    exit 1
}
Write-Log "[OK] Install verified." "Green"

# ── STEP 1: NODE.JS ───────────────────────────────────
Write-Step "[Step 1/3] Checking Node.js..."
$hasNode = $null
try { $hasNode = & node --version 2>&1 } catch {}

if (-not $hasNode -or $hasNode -notmatch "v\d") {
    Write-Log "   Node.js not found. Downloading..." "Yellow"
    $nodeInstaller = "$env:TEMP\node-lts-x64.msi"
    $nodeUrl       = "https://nodejs.org/dist/v20.19.0/node-v20.19.0-x64.msi"

    & curl.exe -L --silent --show-error --output $nodeInstaller $nodeUrl
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $nodeInstaller) -or (Get-Item $nodeInstaller).Length -lt 1000000) {
        Write-Log "[ERROR] Failed to download Node.js." "Red"
        Write-Log "   Install manually from https://nodejs.org then re-run setup." "Red"
        exit 1
    }

    $proc = Start-Process "msiexec.exe" -ArgumentList "/i `"$nodeInstaller`" /quiet /norestart" -Wait -PassThru
    Remove-Item $nodeInstaller -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
        Write-Log "[ERROR] Node.js install failed (exit $($proc.ExitCode))" "Red"
        exit 1
    }
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")
}
Write-Log "[OK] Node: $(& node --version 2>&1)" "Green"

# ── STEP 2: FRONTEND npm install (no build needed) ────
Write-Step "[Step 2/3] Installing frontend runtime packages..."
Set-Location $FRONTEND

# Inject env vars for npm start
$utf8NoBOM = [System.Text.UTF8Encoding]::new($false)
$loadEnvContent = @'
const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const SECRET_KEY = '9cbfcce635d1160bf8fd4143a322ef1c1edebc84749ae1d34bcb167347754406';
const ENC_PATH   = path.join(__dirname, '.env.enc');
function loadEnv() {
    if (!fs.existsSync(ENC_PATH)) { console.error('[load-env] .env.enc not found'); process.exit(1); }
    const enc    = Buffer.from(fs.readFileSync(ENC_PATH).toString().trim(), 'base64');
    const keyBuf = crypto.createHash('sha256').update(SECRET_KEY).digest();
    const plain  = Buffer.alloc(enc.length);
    for (let i = 0; i < enc.length; i++) plain[i] = enc[i] ^ keyBuf[i % keyBuf.length];
    let loaded = 0;
    for (const line of plain.toString('utf8').split('\n')) {
        const t = line.trim();
        if (!t || t.startsWith('#') || !t.includes('=')) continue;
        const [k, ...rest] = t.split('=');
        const key = k.trim();
        const val = rest.join('=').trim().replace(/^["']|["']$/g, '');
        if (key && !(key in process.env)) { process.env[key] = val; loaded++; }
    }
    console.log('[load-env] ' + loaded + ' vars loaded');
}
loadEnv();
module.exports = {};
'@
[System.IO.File]::WriteAllText("$FRONTEND\load-env.js", $loadEnvContent, $utf8NoBOM)

$nextCfg = "$FRONTEND\next.config.js"
if (Test-Path $nextCfg) {
    $content = Get-Content $nextCfg -Raw
    if ($content -notmatch "load-env") {
        [System.IO.File]::WriteAllText($nextCfg, "require('./load-env');`n" + $content, $utf8NoBOM)
        Write-Log "   Patched next.config.js"
    }
}

Write-Log "   Running npm install (production only)..."
& npm install --omit=dev --silent
Write-Log "[OK] Frontend packages installed." "Green"

# ── STEP 3: PLAYWRIGHT CHROMIUM ───────────────────────
Write-Step "[Step 3/3] Installing Playwright Chromium..."
$env:PLAYWRIGHT_BROWSERS_PATH = "$BACKEND\.playwright-browsers"

# Install playwright npm package just for the CLI
Set-Location $FRONTEND
& npm install playwright@1.44.0 --silent 2>$null
if (Test-Path "$FRONTEND\node_modules\.bin\playwright.cmd") {
    & "$FRONTEND\node_modules\.bin\playwright.cmd" install chromium
} else {
    & npx playwright install chromium
}
Write-Log "[OK] Playwright Chromium installed." "Green"

# ── CREATE LAUNCHER ───────────────────────────────────
Write-Step "Creating launcher and Desktop shortcut..."

$startBat = @"
@echo off
title IG Automation
set APP_DIR=C:\IGAutomation
set BACKEND=%APP_DIR%\backend
set FRONTEND=%APP_DIR%\frontend
set PLAYWRIGHT_BROWSERS_PATH=%BACKEND%\.playwright-browsers
set PATH=%PATH%;%APPDATA%\npm;%PROGRAMFILES%\nodejs

echo Stopping any existing instances...
for /f "tokens=5" %%a in ('netstat -aon ^| findstr ":3000 " ^| findstr "LISTENING"') do taskkill /F /PID %%a 2>nul
for /f "tokens=5" %%a in ('netstat -aon ^| findstr ":8000 " ^| findstr "LISTENING"') do taskkill /F /PID %%a 2>nul
timeout /t 1 /nobreak >nul

echo Starting backend...
start "IG Backend" cmd /k "cd /d ""%BACKEND%"" && backend.exe"

echo Starting frontend...
start "IG Frontend" cmd /k "cd /d ""%FRONTEND%"" && npm start"

echo Waiting for backend on port 8000...
:wait_backend
timeout /t 2 /nobreak >nul
netstat -an | findstr ":8000 " | findstr "LISTENING" >nul 2>&1
if errorlevel 1 goto wait_backend
echo [OK] Backend ready.

echo Waiting for frontend on port 3000...
:wait_frontend
timeout /t 2 /nobreak >nul
netstat -an | findstr ":3000 " | findstr "LISTENING" >nul 2>&1
if errorlevel 1 goto wait_frontend
echo [OK] Frontend ready.

start "" "http://localhost:3000"

echo.
echo ================================================
echo   IG Automation is running!
echo   Backend  : http://localhost:8000
echo   Frontend : http://localhost:3000
echo   Close the Backend and Frontend windows to stop.
echo ================================================
echo.
exit
"@
[System.IO.File]::WriteAllText("$APP_DIR\start.bat", $startBat, [System.Text.ASCIIEncoding]::new())
Write-Log "   start.bat written."

# ── SHORTCUT ──────────────────────────────────────────
$loggedInUser = $null
try { $loggedInUser = (Get-WmiObject -Class Win32_ComputerSystem).UserName -replace '.*\\','' } catch {}

$desktopPaths = @()
if ($loggedInUser) { $desktopPaths += "C:\Users\$loggedInUser\Desktop" }
$desktopPaths += @("$env:USERPROFILE\Desktop", "$env:PUBLIC\Desktop", "C:\Users\Public\Desktop")

foreach ($dp in ($desktopPaths | Select-Object -Unique)) {
    $existing = "$dp\IG Automation.lnk"
    if (Test-Path $existing) { Remove-Item $existing -Force -ErrorAction SilentlyContinue }
}

$iconRefreshCode = @"
using System;
using System.Runtime.InteropServices;
public class IconRefresh {
    [DllImport("Shell32.dll")]
    public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
}
"@
Add-Type -TypeDefinition $iconRefreshCode -ErrorAction SilentlyContinue

$shortcutCreated = $false
foreach ($dp in ($desktopPaths | Select-Object -Unique)) {
    if ((Test-Path $dp) -and (-not $shortcutCreated)) {
        try {
            $shell    = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut("$dp\IG Automation.lnk")
            $shortcut.TargetPath       = "$APP_DIR\start.bat"
            $shortcut.WorkingDirectory = $APP_DIR
            $shortcut.WindowStyle      = 1
            $shortcut.Description      = "IG Automation"
            $shortcut.IconLocation     = "$APP_DIR\AppIcon.ico,0"
            $shortcut.Save()
            [IconRefresh]::SHChangeNotify(0x8000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
            Write-Log "[OK] Shortcut created: $dp\IG Automation.lnk" "Green"
            $shortcutCreated = $true
        } catch {
            Write-Log "   Failed at $dp`: $_" "Yellow"
        }
    }
}

Write-Log ""
Write-Log "================================================" "Magenta"
Write-Log "  ALL DONE!" "Magenta"
Write-Log "  Double-click 'IG Automation' on your Desktop" "Magenta"
Write-Log "================================================"
Write-Log "Log: $LOG"
Write-Log "This window will stay open. Close it manually when ready."
