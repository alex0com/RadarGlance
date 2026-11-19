#!/bin/sh
# Archives a Release build of QuickRadarGlance and uploads it to App Store Connect for TestFlight.
#
#   tools/archive-testflight.sh                 # archive, sign, and upload
#   tools/archive-testflight.sh --export-only   # archive and export an .ipa, no upload
#
# Needs:
# - Config/Local.xcconfig with DEVELOPMENT_TEAM and BUNDLE_ID_PREFIX (see Config/Signing.xcconfig).
# - An App Store Connect app record for <BUNDLE_ID_PREFIX>.quickradarglance (uploads only).
# - Either an Apple ID signed in to Xcode (Settings → Accounts) or an App Store Connect API key:
#     ASC_KEY_PATH=~/keys/AuthKey_ABC123.p8 ASC_KEY_ID=ABC123 ASC_ISSUER_ID=<issuer-uuid> tools/archive-testflight.sh
#
# The build number is the UTC time (e.g. 20261117.1830) so every upload is higher than the last;
# override with BUILD_NUMBER=... The version shown to testers is MARKETING_VERSION in project.yml.
set -eu
cd "$(dirname "$0")/.."

team=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' Config/Local.xcconfig 2>/dev/null | tail -n 1)
if [ -z "$team" ]; then
    echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig first (see Config/Signing.xcconfig)." >&2
    exit 1
fi

destination=upload
[ "${1:-}" = "--export-only" ] && destination=export
build=${BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M)}
out=build/testflight
rm -rf "$out"
mkdir -p "$out"

set --
if [ -n "${ASC_KEY_PATH:-}" ]; then
    set -- -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
fi

cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>$destination</string>
    <key>teamID</key>
    <string>$team</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
EOF

xcodegen generate
echo "Archiving build ${build}…"
xcodebuild archive -project QuickRadarGlance.xcodeproj -scheme QuickRadarGlance -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$out/QuickRadarGlance.xcarchive" \
    -allowProvisioningUpdates "$@" CURRENT_PROJECT_VERSION="$build" -quiet
echo "Exporting (${destination})…"
xcodebuild -exportArchive -archivePath "$out/QuickRadarGlance.xcarchive" \
    -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out/export" \
    -allowProvisioningUpdates "$@"

if [ "$destination" = upload ]; then
    echo "Uploaded build $build. It appears in App Store Connect → TestFlight after processing (5–30 min)."
else
    echo "Exported to $out/export (build $build); not uploaded."
fi
