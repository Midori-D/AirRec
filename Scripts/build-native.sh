#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN=d32c8189c51c2789496b0768039419c3705498c3
SRC="$ROOT/build/idevice-rawax-source"
DEST="$ROOT/Frameworks/IDevice.xcframework"
mkdir -p "$ROOT/build" "$ROOT/Frameworks"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --depth 1 --branch v0.1.68 https://github.com/jkcoxson/idevice.git "$SRC"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$PIN" ]] || { echo "Unexpected idevice revision" >&2; exit 1; }
cp "$ROOT/Native/airrecord_ax.rs" "$SRC/idevice/src/services/dvt/calltap_ax.rs"
cp "$ROOT/Native/ffi_airrecord_ax.rs" "$SRC/ffi/src/dvt/calltap_ax.rs"
cp "$ROOT/Archive/Legacy-CallTap-iCTRL/RawAX/calltap_keepalive.rs" "$SRC/idevice/src/services/dvt/calltap_keepalive.rs"
cp "$ROOT/Archive/Legacy-CallTap-iCTRL/RawAX/ffi_calltap_keepalive.rs" "$SRC/ffi/src/dvt/calltap_keepalive.rs"
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name, module, line in (
    ('idevice/src/services/dvt/mod.rs', 'calltap_ax', '\n#[cfg(feature = "rsd")]\npub mod calltap_ax;\n'),
    ('ffi/src/dvt/mod.rs', 'calltap_ax', '\n#[cfg(all(feature = "core_device_proxy", feature = "rsd"))]\npub mod calltap_ax;\n'),
    ('idevice/src/services/dvt/mod.rs', 'calltap_keepalive', '\n#[cfg(all(feature = "rsd", feature = "debug_proxy"))]\npub mod calltap_keepalive;\n'),
    ('ffi/src/dvt/mod.rs', 'calltap_keepalive', '\n#[cfg(all(feature = "core_device_proxy", feature = "rsd", feature = "debug_proxy"))]\npub mod calltap_keepalive;\n'),
):
    target = root / name
    text = target.read_text()
    if f'pub mod {module};' not in text:
        target.write_text(text + line)
PY
mkdir -p "$SRC/idevice/src/services/dvt/calltap_ax_fixtures"
cp "$ROOT/Native/Fixtures/"*.bplist "$SRC/idevice/src/services/dvt/calltap_ax_fixtures/"
export CARGO_TARGET_DIR="$ROOT/build/cargo-rawax"
# Run current AX tests and archived Helper teardown regressions before building.
# The legacy C ABI/module names stay stable; public source paths use AirRecord.
cargo test --locked --manifest-path "$SRC/Cargo.toml" -p idevice --features full,aws-lc calltap_ax::tests --lib
cargo test --locked --manifest-path "$SRC/Cargo.toml" -p idevice --features full,aws-lc calltap_keepalive::tests --lib
rustup target add aarch64-apple-ios
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$SDK" IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  cargo build --locked --manifest-path "$SRC/ffi/Cargo.toml" -p idevice-ffi \
  --release --target aarch64-apple-ios --features obfuscate
HEADERS="$ROOT/build/airrecord-headers"
mkdir -p "$HEADERS"
cp "$SRC/ffi/idevice.h" "$HEADERS/idevice.h"
printf 'module IDevice {\n  header "idevice.h"\n  export *\n}\n' > "$HEADERS/module.modulemap"
[[ "$DEST" == "$ROOT/Frameworks/IDevice.xcframework" ]] || exit 1
rm -rf -- "$DEST"
xcodebuild -create-xcframework \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/libidevice_ffi.a" \
  -headers "$HEADERS" -output "$DEST"
printf '%s\n' "v0.1.68-airrecord-ax" > "$DEST/.version"
