#!/bin/bash
# ================================================================
#  build_installer_win.sh — IG Automation Windows EXE Builder
#  Flow:
#    1. PyInstaller → backend/dist/backend.exe
#    2. Next.js build → frontend/.next (compiled only)
#    3. NSIS → IGAutomation-Setup.exe
# ================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/_win_build"
OUTPUT="$SCRIPT_DIR/IGAutomation-Setup.exe"

echo "================================================"
echo "  IG Automation — Building Windows EXE"
echo "================================================"
echo ""

# ── CHECKS ────────────────────────────────────────────
echo "Checking required files..."
for f in "frontend" "backend" "setup.ps1" "installer.nsi" "AppIcon.ico"; do
    [ ! -e "$SCRIPT_DIR/$f" ] && echo "[ERROR] $f not found in project root" && exit 1
done
for enc in "backend/.env.enc" "frontend/.env.enc"; do
    if [ ! -f "$SCRIPT_DIR/$enc" ]; then
        echo "[ERROR] $enc not found. Run: python create_env.py"
        exit 1
    fi
done
if ! command -v makensis &>/dev/null; then
    echo "[ERROR] makensis not found. Run: apt install nsis"
    exit 1
fi
echo "[OK] All checks passed."

# ── INSTALL BUILD TOOLS ───────────────────────────────
echo ""
echo "Installing build tools..."
pip install pyinstaller --quiet
npm install -g terser 2>/dev/null || true
echo "[OK] Build tools ready."

# ── STEP 1: COMPILE BACKEND WITH PYINSTALLER ──────────
echo ""
echo "================================================"
echo "  Step 1/3: Compiling backend with PyInstaller"
echo "================================================"

cd "$SCRIPT_DIR/backend"

# Install backend dependencies for PyInstaller to bundle
pip install -r requirements.txt --quiet 2>/dev/null || true

# Create PyInstaller spec — bundle everything including playwright
python3 << 'PYEOF'
import os

# Auto-discover all local Python packages (folders with __init__.py)
local_packages = []
local_datas = [(".env.enc", ".")]
for item in os.listdir("."):
    if os.path.isdir(item) and os.path.exists(os.path.join(item, "__init__.py")):
        if item not in ["dist", "build_tmp", "__pycache__", "venv"]:
            local_packages.append(item)
            local_datas.append((item, item))

print("Local packages found:", local_packages)

hidden = local_packages + [
    "uvicorn", "uvicorn.logging", "uvicorn.loops", "uvicorn.loops.auto",
    "uvicorn.protocols", "uvicorn.protocols.http", "uvicorn.protocols.http.auto",
    "uvicorn.protocols.websockets", "uvicorn.protocols.websockets.auto",
    "uvicorn.lifespan", "uvicorn.lifespan.on",
    "fastapi", "pydantic",
    "pydantic.deprecated.class_validators", "pydantic.deprecated.config", "pydantic.deprecated.tools",
    "starlette", "starlette.routing", "starlette.middleware",
    "anyio", "anyio.from_thread",
    "dotenv", "cryptography",
    "langchain", "langchain_core", "langchain_community",
    "langchain_openai", "langchain_anthropic", "langchain_ollama",
    "supabase", "playwright",
]

lines = [
    "# -*- mode: python ; coding: utf-8 -*-",
    "a = Analysis(",
    '    ["run.py"],',
    '    pathex=["."],',
    "    binaries=[],",
    "    datas=" + repr(local_datas) + ",",
    "    hiddenimports=" + repr(hidden) + ",",
    "    hookspath=[],",
    "    hooksconfig={},",
    "    runtime_hooks=[],",
    "    excludes=[],",
    "    noarchive=False,",
    ")",
    "pyz = PYZ(a.pure)",
    "exe = EXE(",
    "    pyz, a.scripts, a.binaries, a.datas, [],",
    '    name="backend",',
    "    debug=False,",
    "    bootloader_ignore_signals=False,",
    "    strip=False,",
    "    upx=True,",
    "    upx_exclude=[],",
    "    runtime_tmpdir=None,",
    "    console=True,",
    "    disable_windowed_traceback=False,",
    "    argv_emulation=False,",
    "    target_arch=None,",
    "    codesign_identity=None,",
    "    entitlements_file=None,",
    ")",
]

with open("backend.spec", "w") as f:
    f.write("\n".join(lines))
print("[OK] backend.spec written")
PYEOF

# Run PyInstaller — produces backend/dist/backend.exe
pyinstaller backend.spec --distpath dist --workpath build_tmp --noconfirm --clean
rm -rf build_tmp backend.spec __pycache__

if [ ! -f "dist/backend.exe" ]; then
    echo "[ERROR] PyInstaller failed — backend.exe not found"
    exit 1
fi
echo "[OK] backend.exe compiled: $(du -sh dist/backend.exe | cut -f1)"

cd "$SCRIPT_DIR"

# ── STEP 2: BUILD FRONTEND (COMPILED ONLY) ────────────
echo ""
echo "================================================"
echo "  Step 2/3: Building frontend (production only)"
echo "================================================"

cd "$SCRIPT_DIR/frontend"

# Remove prebuild/decrypt-env scripts before build
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
let changed = false;
for (const key of ['prebuild','preinstall','predeploy','predev','prestart']) {
    if (pkg.scripts && pkg.scripts[key]) {
        delete pkg.scripts[key];
        changed = true;
        console.log('Removed script:', key);
    }
}
// Remove any script referencing decrypt-env
for (const [key, val] of Object.entries(pkg.scripts || {})) {
    if (val.includes('decrypt-env')) {
        delete pkg.scripts[key];
        changed = true;
        console.log('Removed decrypt-env script:', key);
    }
}
if (changed) fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2));
"

# Write load-env.js for build time env injection
cat > load-env.js << 'JSEOF'
const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const SECRET_KEY = '9cbfcce635d1160bf8fd4143a322ef1c1edebc84749ae1d34bcb167347754406';
const ENC_PATH   = path.join(__dirname, '.env.enc');
function loadEnv() {
    if (!fs.existsSync(ENC_PATH)) { console.error('[load-env] .env.enc not found'); return; }
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
JSEOF

# Patch next.config.js to require load-env
if [ -f "next.config.js" ]; then
    if ! grep -q "load-env" next.config.js; then
        echo "require('./load-env');" | cat - next.config.js > /tmp/nc.js && mv /tmp/nc.js next.config.js
        echo "[OK] Patched next.config.js"
    fi
else
    echo "require('./load-env');" > next.config.js
    echo "/** @type {import('next').NextConfig} */" >> next.config.js
    echo "const nextConfig = {};" >> next.config.js
    echo "module.exports = nextConfig;" >> next.config.js
fi

npm install --silent
npm run build

if [ $? -ne 0 ]; then
    echo "[ERROR] Frontend build failed"
    exit 1
fi
echo "[OK] Frontend built."

# Keep ONLY what's needed to run — delete all source files
echo "Stripping source files from frontend..."
find . -maxdepth 1 -name "*.js"   ! -name "next.config.js" -delete
find . -maxdepth 1 -name "*.ts"   -delete
find . -maxdepth 1 -name "*.tsx"  -delete
find . -maxdepth 1 -name "*.mjs"  -delete
rm -rf src app pages components lib hooks utils styles
rm -f load-env.js
echo "[OK] Source files stripped. Only .next/ remains."

cd "$SCRIPT_DIR"

# ── STEP 3: PACKAGE WITH NSIS ─────────────────────────
echo ""
echo "================================================"
echo "  Step 3/3: Packaging installer with NSIS"
echo "================================================"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/payload/backend"
mkdir -p "$BUILD_DIR/payload/frontend"

# Backend: only the compiled exe + .env.enc
cp "$SCRIPT_DIR/backend/dist/backend.exe"  "$BUILD_DIR/payload/backend/backend.exe"
cp "$SCRIPT_DIR/backend/.env.enc"          "$BUILD_DIR/payload/backend/.env.enc"
echo "[OK] Backend payload: backend.exe + .env.enc only"

# Frontend: only .next build output + package.json + .env.enc
# Use xcopy/cp instead of rsync (not available on Windows runners)
mkdir -p "$BUILD_DIR/payload/frontend"
cp -r "$SCRIPT_DIR/frontend/.next"          "$BUILD_DIR/payload/frontend/.next"
cp    "$SCRIPT_DIR/frontend/package.json"   "$BUILD_DIR/payload/frontend/package.json"
cp    "$SCRIPT_DIR/frontend/.env.enc"       "$BUILD_DIR/payload/frontend/.env.enc"
# Copy next.config.js if it exists
if [ -f "$SCRIPT_DIR/frontend/next.config.js" ]; then
    cp "$SCRIPT_DIR/frontend/next.config.js" "$BUILD_DIR/payload/frontend/next.config.js"
fi
echo "[OK] Frontend payload: .next + package.json + .env.enc only"

cp "$SCRIPT_DIR/setup.ps1"     "$BUILD_DIR/setup.ps1"
cp "$SCRIPT_DIR/installer.nsi" "$BUILD_DIR/installer.nsi"
cp "$SCRIPT_DIR/AppIcon.ico"   "$BUILD_DIR/AppIcon.ico"

echo "Compiling installer EXE..."
cd "$BUILD_DIR"
makensis installer.nsi

mv "$BUILD_DIR/IGAutomation-Setup.exe" "$OUTPUT"
rm -rf "$BUILD_DIR"

echo ""
echo "================================================"
echo "  DONE! Output: $OUTPUT"
echo "  Backend: single backend.exe (no Python source)"
echo "  Frontend: .next build only (no source files)"
echo "================================================"
