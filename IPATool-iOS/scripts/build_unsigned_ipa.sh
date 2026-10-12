#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo 'This script requires macOS with Xcode and the iOS SDK.' >&2
  exit 1
fi
python3 "$project_root/scripts/assemble_runtime.py"
xcodebuild -resolvePackageDependencies -project "$project_root/IPATool.xcodeproj" -scheme IPATool
xcodebuild -project "$project_root/IPATool.xcodeproj" -scheme IPATool -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$project_root/build/DerivedData" CODE_SIGNING_ALLOWED=NO build
package_root="$project_root/build/Export"
mkdir -p "$package_root/Payload"
if [ -d "$package_root/Payload/IPATool.app" ]; then
  rm -r "$package_root/Payload/IPATool.app"
fi
cp -R "$project_root/build/DerivedData/Build/Products/Release-iphoneos/IPATool.app" "$package_root/Payload/"
ditto -c -k --keepParent "$package_root/Payload" "$project_root/build/IPATool-unsigned.ipa"
echo "Created $project_root/build/IPATool-unsigned.ipa (requires your signing tool before installation)."
