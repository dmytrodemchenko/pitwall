#!/bin/bash
# Developer ID signed, notarized release: build/release/Pitwall-<version>.zip with the app and hooks/.
# Needs, once:
#   - the "Developer ID Application" certificate in your keychain, and TEAM_ID set to your team id;
#   - a notarytool profile: xcrun notarytool store-credentials pitwall --apple-id <you> --team-id <TEAM_ID>
#     (or set NOTARY_PROFILE to another profile name).
# Version = the latest git tag (v1.2 -> 1.2); build number = the commit count.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?set TEAM_ID to your Apple Developer team id}"
profile="${NOTARY_PROFILE:-pitwall}"
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first: a release is built from a tag." >&2; exit 1; }
tag=$(git describe --tags --abbrev=0 2>/dev/null) || { echo "Tag the release first, e.g. git tag v1.2" >&2; exit 1; }
version=${tag#v} build=$(git rev-list --count HEAD)
out=build/release name="Pitwall-$version"
rm -rf "$out" && mkdir -p "$out"

echo "== Archive $version ($build)"
xcodebuild -quiet -project Pitwall.xcodeproj -scheme Pitwall -configuration Release \
  -archivePath "$out/Pitwall.xcarchive" archive \
  DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build"

echo "== Export"
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -quiet -exportArchive -archivePath "$out/Pitwall.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist"
app="$out/export/Pitwall.app"
codesign --verify --strict --deep --verbose=2 "$app"

echo "== Notarize"
ditto -c -k --keepParent "$app" "$out/notarize.zip"
xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl -a -vv "$app"

echo "== Package"
mkdir -p "$out/$name/hooks"
cp -R "$app" "$out/$name/"
cp hooks/monitor-hook.sh hooks/permission-hook.sh hooks/install.sh hooks/uninstall.sh "$out/$name/hooks/"
cp README.md CHANGELOG.md "$out/$name/"
ditto -c -k --keepParent "$out/$name" "$out/$name.zip"
echo "Built $out/$name.zip"
