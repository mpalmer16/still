#!/bin/bash
set -euo pipefail

still_project="$(cd "$(dirname "$0")/.." && pwd)"
still_bundle="${STILL_BUNDLE_PATH:-$still_project/dist/Still.app}"
still_bundle_identifier="${STILL_BUNDLE_IDENTIFIER:-local.still.room}"
still_display_name="${STILL_BUNDLE_DISPLAY_NAME:-Still}"
still_executable_name="${STILL_BUNDLE_EXECUTABLE:-Still}"
still_native_port="${STILL_NATIVE_PORT:-4040}"
still_native_build="$still_project/_build/native_macos"
cd "$still_project"

if [[ ! "$still_bundle_identifier" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  printf 'STILL_BUNDLE_IDENTIFIER must be a dotted bundle identifier.\n' >&2
  exit 1
fi
if [[ ! "$still_executable_name" =~ ^[A-Za-z0-9_.-]+$ || "$still_executable_name" == . || "$still_executable_name" == .. ]]; then
  printf 'STILL_BUNDLE_EXECUTABLE must be a single executable filename.\n' >&2
  exit 1
fi
if [[ ! "$still_native_port" =~ ^[0-9]{4,5}$ ]] || (( 10#$still_native_port < 1024 || 10#$still_native_port > 65535 )); then
  printf 'STILL_NATIVE_PORT must be between 1024 and 65535.\n' >&2
  exit 1
fi

mkdir -p "$still_native_build/module-cache" "$still_bundle/Contents/MacOS" "$still_bundle/Contents/Resources"

export MIX_ENV=prod
export MIX_BUILD_PATH="$still_native_build"
if [[ "${1:-}" != "--shell-only" ]]; then
  mix deps.get --only prod
  mix compile --warnings-as-errors
  mix assets.setup
  mix assets.deploy
  mix release --overwrite --path "$still_bundle/Contents/Resources/backend"
  # The release has copied the digests. Keep generated gzip/digest siblings out
  # of the source checkout while retaining its original static assets.
  mix phx.digest.clean --all --no-compile
fi
if [[ ! -x "$still_bundle/Contents/Resources/backend/bin/still" ]]; then
  printf 'The backend has not been assembled. Run native/build.sh without --shell-only first.\n' >&2
  exit 1
fi

swiftc -swift-version 5 -warnings-as-errors -parse-as-library -O -module-cache-path "$still_native_build/module-cache" \
  -framework AppKit -framework WebKit -framework Security \
  native/Still.swift native/WritingLocation.swift native/BackupClose.swift native/CorrespondenceNavigation.swift -o "$still_bundle/Contents/MacOS/$still_executable_name"
swiftc -swift-version 5 -warnings-as-errors -O -module-cache-path "$still_native_build/module-cache" \
  native/BackendGuard.swift -o "$still_bundle/Contents/MacOS/StillBackend"
swiftc -swift-version 5 -warnings-as-errors -O -module-cache-path "$still_native_build/module-cache" \
  -framework AppKit native/CreateIcon.swift -o "$still_native_build/create-icon"
"$still_native_build/create-icon" "$still_native_build/Still.iconset"
iconutil -c icns "$still_native_build/Still.iconset" -o "$still_bundle/Contents/Resources/Still.icns"
python3 native/package_runtime.py "$still_bundle"

python3 - "$still_bundle" "$still_bundle_identifier" "$still_display_name" "$still_executable_name" "$still_native_port" <<'PY'
import plistlib,sys,platform
from pathlib import Path
bundle = Path(sys.argv[1])
identifier, display_name, executable, port = sys.argv[2:]
with (bundle/'Contents/Info.plist').open('wb') as f:
    plistlib.dump({
      'CFBundleName':display_name, 'CFBundleDisplayName':display_name,
      'CFBundleIdentifier':identifier, 'CFBundleExecutable':executable,
      'CFBundlePackageType':'APPL', 'CFBundleVersion':'1',
      'CFBundleShortVersionString':'0.1.0', 'LSMinimumSystemVersion':platform.mac_ver()[0],
      'CFBundleIconFile':'Still.icns',
      'NSHighResolutionCapable':True, 'NSPrincipalClass':'NSApplication',
      'NSAppTransportSecurity': {'NSAllowsLocalNetworking':True},
      'StillNativePort':str(int(port)),
    },f)
PY
codesign --force --deep --sign - "$still_bundle"
codesign --verify --deep --strict "$still_bundle"
printf 'Built %s\nWriting folder is remembered by Still; choose it from the File menu.\nOpen with: open "%s"\n' "$still_bundle" "$still_bundle"
