#!/bin/bash
set -euo pipefail

echo "🔨 Building ghostty-vt.wasm..."

if ! command -v zig &> /dev/null; then
    echo "❌ Error: Zig not found"
    echo ""
    echo "Install Zig 0.17.0+ (required by Ghostty 1.4):"
    echo "  macOS:   brew install zig"
    echo "  Linux:   https://ziglang.org/download/"
    echo ""
    exit 1
fi

echo "✓ Found Zig $(zig version)"

if [ ! -d "ghostty/.git" ] && [ ! -f "ghostty/.git" ]; then
    echo "📦 Initializing Ghostty submodule..."
    git submodule update --init --recursive
fi

# Absolute paths: the EXIT trap runs after the script has left ghostty/.
root="$(pwd)"
patch="$root/patches/ghostty-1.4-webshell.patch"
abi="$root/ghostty/src/webshell_abi.zig"

cd ghostty
cleanup() {
    rm -f "$abi"
    git -C "$root/ghostty" apply -R "$patch" 2>/dev/null || true
}

echo "🔧 Applying WebShell ABI patch..."
git apply --check "$patch" || {
    echo "❌ Patch doesn't apply cleanly"
    echo "Ghostty may have changed. Check patches/ghostty-1.4-webshell.patch"
    exit 1
}
git apply "$patch"
trap cleanup EXIT
cp ../wasm/webshell_abi.zig "$abi"

# One generic (non-SIMD) module is shared by the browser, the WebShell server
# checkpoint engine and the wasm2c native clients.
echo "⚙️  Building WASM..."
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Dcpu=generic -Doptimize=ReleaseSmall

cp zig-out/bin/ghostty-vt.wasm ../ghostty-vt.wasm
cd ..

SIZE=$(du -h ghostty-vt.wasm | cut -f1)
echo "✅ Built ghostty-vt.wasm ($SIZE)"
