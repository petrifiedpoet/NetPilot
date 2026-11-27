#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
command -v cargo >/dev/null || { echo '请先安装 Rust (https://rustup.rs)，然后重新运行。'; exit 1; }
xcrun --find swiftc >/dev/null
version=v1.19.34
case "$(uname -m)" in
    arm64) platform=darwin-arm64; hash=1a7a20eca63fbbaec90137717465bfde488d0db2a3a79b8fadebf9b2545b6e4c ;;
    x86_64) platform=darwin-amd64-compatible; hash=703bceaa494732fa456f47e6ac2f06bf0bc5593d4c927d5f61e10f1a31039c37 ;;
    *) echo "未知 Mac 架构"; exit 1 ;;
esac
cargo build --locked --release
app="$PWD/dist/NetPilot.app"
bin="$app/Contents/MacOS"
mkdir -p "$bin" "$app/Contents/Resources" dist/cache
archive="dist/cache/mihomo-$platform-$version.gz"
verify() { test -f "$archive" && test "$(shasum -a 256 "$archive" | cut -d' ' -f1)" = "$hash"; }
if ! verify; then
    curl -fL --retry 2 "https://github.com/MetaCubeX/mihomo/releases/download/$version/mihomo-$platform-$version.gz" -o "$archive"
    verify || { echo "Mihomo 下载校验失败"; exit 1; }
fi
gzip -dc "$archive" > "$bin/mihomo"
chmod +x "$bin/mihomo"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" macos/*.swift -o "$bin/NetPilot"
cp macos/Info.plist "$app/Contents/Info.plist"
cp scripts/MIHOMO-LICENSE "$app/Contents/Resources/"
cp target/release/netpilot-core "$bin/"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
echo "$app"
