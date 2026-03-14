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

# VERIFY INSTALL
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

# STEP 1: NODE.JS
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

# STEP 2: FRONTEND npm install
Write-Step "[Step 2/3] Installing frontend runtime packages..."
Set-Location $FRONTEND

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

Write-Log "   Running npm install..."
& npm install --omit=dev --silent
Write-Log "[OK] Frontend packages installed." "Green"

# STEP 3: PLAYWRIGHT CHROMIUM
Write-Step "[Step 3/3] Installing Playwright Chromium..."
$env:PLAYWRIGHT_BROWSERS_PATH = "$BACKEND\.playwright-browsers"

Write-Log "   Installing Playwright..."
& npm install playwright --silent 2>$null

$playwrightCmd = $null
if (Test-Path "$FRONTEND\node_modules\.bin\playwright.cmd") {
    $playwrightCmd = "$FRONTEND\node_modules\.bin\playwright.cmd"
}

Write-Log "   Downloading Chromium browser..."
$chromiumOk = $false
try {
    if ($playwrightCmd) {
        & $playwrightCmd install chromium
    } else {
        & npx playwright install chromium
    }
    if ($LASTEXITCODE -eq 0) {
        $chromiumOk = $true
        Write-Log "[OK] Playwright Chromium installed." "Green"
    } else {
        Write-Log "[WARN] Chromium download failed - will retry on first launch." "Yellow"
    }
} catch {
    Write-Log "[WARN] Playwright install skipped: $($_.Exception.Message)" "Yellow"
}

# CREATE LAUNCHER
Write-Step "Creating launcher and Desktop shortcut..."

$launchVbs = @"
Dim sh, result
Set sh = CreateObject("WScript.Shell")

Dim APP_DIR, BACKEND, FRONTEND
APP_DIR  = "C:\IGAutomation"
BACKEND  = APP_DIR & "\backend"
FRONTEND = APP_DIR & "\frontend"

' Kill any existing instances silently
sh.Run "cmd /c for /f ""tokens=5"" %a in ('netstat -aon ^| findstr "":3000 "" ^| findstr ""LISTENING""') do taskkill /F /PID %a 2>nul", 0, True
sh.Run "cmd /c for /f ""tokens=5"" %a in ('netstat -aon ^| findstr "":8000 "" ^| findstr ""LISTENING""') do taskkill /F /PID %a 2>nul", 0, True
WScript.Sleep 1000

' Start backend silently (0 = hidden window)
sh.Run "cmd /c cd /d """ & BACKEND & """ && set PLAYWRIGHT_BROWSERS_PATH=" & BACKEND & "\.playwright-browsers && backend.exe", 0, False

' Start frontend silently
sh.Run "cmd /c cd /d """ & FRONTEND & """ && npm start", 0, False

' Wait for backend port 8000
Dim attempts
attempts = 0
Do
    WScript.Sleep 2000
    result = sh.Run("cmd /c netstat -an | findstr "":8000 "" | findstr ""LISTENING"" >nul 2>&1", 0, True)
    attempts = attempts + 1
    If attempts > 30 Then Exit Do
Loop While result <> 0

' Wait for frontend port 3000
attempts = 0
Do
    WScript.Sleep 2000
    result = sh.Run("cmd /c netstat -an | findstr "":3000 "" | findstr ""LISTENING"" >nul 2>&1", 0, True)
    attempts = attempts + 1
    If attempts > 30 Then Exit Do
Loop While result <> 0

' Open browser
sh.Run "http://localhost:3000"
"@
[System.IO.File]::WriteAllText("$APP_DIR\start.vbs", $launchVbs, [System.Text.UTF8Encoding]::new($false))
Write-Log "   start.vbs written."
[System.IO.File]::WriteAllText("$APP_DIR\start.bat", $startBat, [System.Text.ASCIIEncoding]::new())
Write-Log "   start.bat written."

# SHORTCUT
$loggedInUser = $null
try { $loggedInUser = (Get-WmiObject -Class Win32_ComputerSystem).UserName -replace '.*\\','' } catch {}

$desktopPaths = @()
if ($loggedInUser) { $desktopPaths += "C:\Users\$loggedInUser\Desktop" }
$desktopPaths += @("$env:USERPROFILE\Desktop", "$env:PUBLIC\Desktop", "C:\Users\Public\Desktop")

foreach ($dp in ($desktopPaths | Select-Object -Unique)) {
    $existing = "$dp\IG Automation.lnk"
    if (Test-Path $existing) {
        Remove-Item $existing -Force -ErrorAction SilentlyContinue
    }
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
            $shortcut.TargetPath       = "C:\Windows\System32\wscript.exe"
            $shortcut.Arguments        = "`"$APP_DIR\start.vbs`""
            $shortcut.WorkingDirectory = $APP_DIR
            $shortcut.WindowStyle      = 1
            $shortcut.Description      = "IG Automation"
            $shortcut.IconLocation     = "$APP_DIR\AppIcon.ico,0"
            $shortcut.Save()
            [IconRefresh]::SHChangeNotify(0x8000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
            Write-Log "[OK] Shortcut created: $dp\IG Automation.lnk" "Green"
            $shortcutCreated = $true
        } catch {
            Write-Log "   Failed at $dp`: $($_.Exception.Message)" "Yellow"
        }
    }
}

Write-Log ""
Write-Log "================================================" "Magenta"
Write-Log "  ALL DONE!" "Magenta"
Write-Log "  Double-click 'IG Automation' on your Desktop" "Magenta"
Write-Log "================================================"
Write-Log "Log: $LOG"
