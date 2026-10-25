#!/bin/sh
# Build the clock probe app: build_clockprobe.sh <work folder on a drive with space>; prints the app's path. Install and run it with devicectl:
#   xcrun devicectl device install app --device <udid> <app>
#   xcrun devicectl device process launch --device <udid> --terminate-existing com.zijadaljic.clockprobe -order AB -secs 300
#   xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.zijadaljic.clockprobe --source Documents/clock.txt --destination clock.txt
set -e
W="$1"; [ -n "$W" ] || { echo "usage: $0 <work folder>"; exit 1; }
H="$(cd "$(dirname "$0")" && pwd)"; mkdir -p "$W"
cp "$H/clockprobe.m" "$H/overlap.m" "$H/clockprobe.yml" "$W/"
(cd "$W" && xcodegen --spec clockprobe.yml --quiet)
xcodebuild -quiet -project "$W/ClockProbe.xcodeproj" -scheme ClockProbe -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$W/dd" -allowProvisioningUpdates build
echo "$W/dd/Build/Products/Release-iphoneos/ClockProbe.app"
