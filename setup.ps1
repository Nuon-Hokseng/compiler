# Force execution policy for this session regardless of machine policy
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
$ErrorActionPreference = "Continue"

$APP_DIR  = "C:\IGAutomation"
$BACKEND  = "$APP_DIR\backend"
$FRONTEND = "$APP_DIR\frontend"
$LOG      = "$APP_DIR\setup-log.txt"

function Write-Log($msg, $color = "White") {
    $ts   = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line -ForegroundColor $color
    try { Add-Content -Path $LOG -Value $line -ErrorAction SilentlyContinue } catch {}
}

function Write-Step($msg) {
    Write-Log ""
    Write-Log ">> $msg" "Cyan"
}

function Refresh-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
}

# Create log file — handle case where dir is read-only
try {
    "" | Out-File -FilePath $LOG -Encoding utf8 -Force
} catch {
    $LOG = "$env:TEMP\ig-automation-setup.log"
    "" | Out-File -FilePath $LOG -Encoding utf8 -Force
}

Write-Log "================================================" "Magenta"
Write-Log "  IG Automation - Setup" "Magenta"
Write-Log "================================================"
Write-Log "APP_DIR  = $APP_DIR"
Write-Log "Log file = $LOG"
Write-Log "User     = $env:USERNAME"
Write-Log "OS       = $([System.Environment]::OSVersion.VersionString)"

# Ensure execution policy is set machine-wide for future runs
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force -ErrorAction SilentlyContinue
    Write-Log "[OK] Execution policy set." "Green"
} catch {
    # Non-critical - installer already set this during install
}

# VERIFY INSTALL
if (-not (Test-Path $APP_DIR)) {
    Write-Log "[ERROR] $APP_DIR not found. Please reinstall." "Red"
    Read-Host "Press Enter to exit"; exit 1
}
if (-not (Test-Path "$BACKEND\backend.exe")) {
    Write-Log "[ERROR] backend.exe missing. Please reinstall." "Red"
    Read-Host "Press Enter to exit"; exit 1
}
if (-not (Test-Path "$FRONTEND\.next")) {
    Write-Log "[ERROR] Frontend .next folder missing. Please reinstall." "Red"
    Read-Host "Press Enter to exit"; exit 1
}
Write-Log "[OK] Install verified." "Green"

# STEP 1: NODE.JS
Write-Step "[Step 1/3] Checking Node.js..."

# Refresh PATH first in case Node was just installed
Refresh-Path

$hasNode = $null
try { $hasNode = & node --version 2>&1 } catch {}

# Also check common install paths directly
if (-not $hasNode -or $hasNode -notmatch "v\d") {
    foreach ($nodePath in @(
        "$env:PROGRAMFILES\nodejs\node.exe",
        "$env:ProgramFiles(x86)\nodejs\node.exe",
        "$env:APPDATA\npm\node.exe",
        "$env:LOCALAPPDATA\Programs\nodejs\node.exe"
    )) {
        if (Test-Path $nodePath) {
            $env:PATH = "$env:PATH;$(Split-Path $nodePath)"
            try { $hasNode = & node --version 2>&1 } catch {}
            if ($hasNode -match "v\d") { break }
        }
    }
}

if (-not $hasNode -or $hasNode -notmatch "v\d") {
    Write-Log "   Node.js not found. Downloading (this may take a few minutes)..." "Yellow"
    $nodeInstaller = "$env:TEMP\node-lts-x64.msi"
    $nodeUrl       = "https://nodejs.org/dist/v20.19.0/node-v20.19.0-x64.msi"

    # Try curl.exe first (built into Windows 10/11)
    $downloaded = $false
    try {
        & curl.exe -L --silent --show-error --output $nodeInstaller $nodeUrl
        if ($LASTEXITCODE -eq 0 -and (Test-Path $nodeInstaller) -and (Get-Item $nodeInstaller).Length -gt 1000000) {
            $downloaded = $true
        }
    } catch {}

    # Fallback to WebClient if curl fails
    if (-not $downloaded) {
        try {
            Write-Log "   Trying WebClient download..." "Yellow"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            (New-Object Net.WebClient).DownloadFile($nodeUrl, $nodeInstaller)
            if ((Test-Path $nodeInstaller) -and (Get-Item $nodeInstaller).Length -gt 1000000) {
                $downloaded = $true
            }
        } catch { Write-Log "   WebClient failed: $($_.Exception.Message)" "Yellow" }
    }

    if (-not $downloaded) {
        Write-Log "[ERROR] Could not download Node.js." "Red"
        Write-Log "   Please install Node.js manually from https://nodejs.org" "Red"
        Write-Log "   Then re-run: $APP_DIR\run-setup.bat" "Red"
        Read-Host "Press Enter to exit"; exit 1
    }

    Write-Log "   Installing Node.js silently..." "Yellow"
    $proc = Start-Process "msiexec.exe" -ArgumentList "/i `"$nodeInstaller`" /quiet /norestart ADDLOCAL=ALL" -Wait -PassThru
    Remove-Item $nodeInstaller -ErrorAction SilentlyContinue

    if ($proc.ExitCode -notin @(0, 1641, 3010)) {
        Write-Log "[ERROR] Node.js install failed (exit $($proc.ExitCode))" "Red"
        Read-Host "Press Enter to exit"; exit 1
    }

    Refresh-Path
    # Give installer a moment to settle
    Start-Sleep -Seconds 3

    # Re-check after install
    foreach ($nodePath in @(
        "$env:PROGRAMFILES\nodejs\node.exe",
        "$env:ProgramFiles(x86)\nodejs\node.exe"
    )) {
        if (Test-Path $nodePath) {
            $env:PATH = "$env:PATH;$(Split-Path $nodePath)"
        }
    }
    try { $hasNode = & node --version 2>&1 } catch {}
}

if (-not $hasNode -or $hasNode -notmatch "v\d") {
    Write-Log "[ERROR] Node.js not found after install." "Red"
    Write-Log "   Please restart your computer and run $APP_DIR\run-setup.bat again." "Red"
    Read-Host "Press Enter to exit"; exit 1
}
Write-Log "[OK] Node: $hasNode" "Green"


# Ensure npm is also on PATH explicitly
$npmPaths = @(
    (Join-Path $env:PROGRAMFILES "nodejs"),
    (Join-Path $env:APPDATA "npm"),
    (Join-Path $env:LOCALAPPDATA "Programs\nodejs")
)
foreach ($p in $npmPaths) {
    if ($p -and (Test-Path (Join-Path $p "npm.cmd"))) {
        if ($env:PATH -notlike "*$p*") { $env:PATH = "$env:PATH;$p" }
    }
}
try { Write-Log "[OK] npm: $(& npm --version 2>&1)" "Green" } catch {}

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
    $cfgContent = Get-Content $nextCfg -Raw
    if ($cfgContent -notmatch "load-env") {
        [System.IO.File]::WriteAllText($nextCfg, "require('./load-env');`n" + $cfgContent, $utf8NoBOM)
        Write-Log "   Patched next.config.js"
    }
}

Write-Log "   Running npm install..."
& npm install --silent 2>&1 | Out-Null
Write-Log "[OK] Frontend packages installed." "Green"

# STEP 3: PLAYWRIGHT CHROMIUM
Write-Step "[Step 3/3] Installing Playwright Chromium..."
$env:PLAYWRIGHT_BROWSERS_PATH = "$BACKEND\.playwright-browsers"

Write-Log "   Installing Playwright..."
& npm install playwright --save 2>&1 | Out-Null

Write-Log "   Downloading Chromium browser..."
try {
    $playwrightCmd = "$FRONTEND\node_modules\.bin\playwright.cmd"
    if (Test-Path $playwrightCmd) {
        & $playwrightCmd install chromium
        if ($LASTEXITCODE -eq 0) {
            Write-Log "[OK] Playwright Chromium installed." "Green"
        } else {
            Write-Log "[WARN] Chromium will download automatically on first launch." "Yellow"
        }
    } else {
        Write-Log "[WARN] Playwright CLI not found - browser will download on first launch." "Yellow"
    }
} catch {
    Write-Log "[WARN] Playwright skipped - browser will download on first launch." "Yellow"
}

# CREATE SILENT LAUNCHER (VBScript - no terminal windows)
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

' Start backend silently
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
