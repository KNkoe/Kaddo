#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 Sources/Kaddo/Resources/Verification/runtime/setup.py --check
if pgrep -f "^$PWD/dist/Kaddo.app/Contents/MacOS/Kaddo$" >/dev/null; then
  echo "Quit Kaddo before rebuilding so its running code signature stays valid." >&2
  exit 1
fi
swift build -c release
APP="$PWD/dist/Kaddo.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Kaddo "$APP/Contents/MacOS/Kaddo"
mkdir -p "$APP/Contents/Resources" "$PWD/.build/Kaddo.iconset"
swift scripts/icon.swift "$PWD/.build/Kaddo-icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$PWD/.build/Kaddo-icon.png" --out "$PWD/.build/Kaddo.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$PWD/.build/Kaddo-icon.png" --out "$PWD/.build/Kaddo.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$PWD/.build/Kaddo.iconset" -o "$APP/Contents/Resources/Kaddo.icns"
# Bundle.module must also resolve in the signed app for absent-resource fallbacks.
cp -R .build/release/Kaddo_Kaddo.bundle "$APP/Contents/Resources/"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# Stable development signatures keep macOS privacy grants across rebuilds.
# Use an explicit override, or the sole installed Apple Development identity.
signing_identity="${KADDO_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
  signing_identity="$(/usr/bin/security find-identity -v -p codesigning | awk '/Apple Development:/ { ids[++n]=$2 } END { if (n == 1) print ids[1] }')"
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
  echo "No unique development identity; ad-hoc builds may need privacy grants refreshed." >&2
fi
codesign --force --sign "$signing_identity" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
