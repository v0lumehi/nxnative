#!/bin/sh
# Agents' iPhone loop, step 1: build a signed development app from an Xcode project that build_ipa_from_nsp.py --prepare-xcode made (or a copy of one whose Sources / Gen
# links point at another worktree), stage it on the game's drive with clone copies of the game files and shader libraries (the app is never copied whole), and install it
# on a wired device. The game's files stay on the drive: Xcode's own resource copy is off (DM_COPY_GAME_RESOURCES=NO) and the stage adds them by APFS clone.
#   dev_install.sh [--no-install]
# Settings come from the environment or from the file $DM_AUTO_CONF (shell assignments; see auto_run.sh):
#   DM_XCODE_PROJECT  the folder holding DmIOS.xcodeproj and Gen/ (required)
#   DM_AUTO_WORK      work folder on the game's drive (derived data, stage, logs; required)
#   DM_IOS_DEVICE     device UDID; DM_IOS_BUNDLE bundle ID; DM_IOS_TEAM development team (all required)
#   DM_EXTRA_MSL      optional "name=folder ..." shader library folders added beside the main one (msl/<name>, for DM_MSL_VS_DIR / DM_MSL_FS_DIR experiments)
#   DM_STAGE_NAME     the installed app folder's name (default DmIOS.app; keep the name other tools on the same device look for, such as BotW.app)
#   DM_MIN_FREE_GB    free space the internal disk needs before an install (default 20: the device installer stages the whole app there)
set -e
[ -n "$DM_AUTO_CONF" ] && [ -f "$DM_AUTO_CONF" ] && . "$DM_AUTO_CONF"
die() { echo "[RED] $*" >&2; exit 1; }
X="${DM_XCODE_PROJECT:?set DM_XCODE_PROJECT}"; W="${DM_AUTO_WORK:?set DM_AUTO_WORK}"
DEV="${DM_IOS_DEVICE:?set DM_IOS_DEVICE}"; BID="${DM_IOS_BUNDLE:?set DM_IOS_BUNDLE}"; TEAM="${DM_IOS_TEAM:?set DM_IOS_TEAM}"
INSTALL=1; [ "$1" = --no-install ] && INSTALL=0
free_gb() { df -g "$1" | awk 'NR==2{print $4}'; }
mkdir -p "$W"; DD="$W/dd"; ST="$W/stage"
[ "$(free_gb "$W")" -ge 3 ] || die "less than 3 GB free on $W"
SCHEME=$(xcodebuild -list -project "$X/DmIOS.xcodeproj" 2>/dev/null | awk '/Schemes:/{f=1;next} f&&NF{print; exit}' | sed 's/^ *//')
OUT=$(sed -n 's/^DM_XCODE_OUTPUT_ROOT = //p' "$X/Gen/dm.xcconfig")
echo "$(date +%T) build: scheme $SCHEME, products in $OUT"
xcodebuild -quiet -project "$X/DmIOS.xcodeproj" -scheme "$SCHEME" -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER="$BID" DM_COPY_GAME_RESOURCES=NO build > "$W/xcodebuild.log" 2>&1 \
  || { tail -30 "$W/xcodebuild.log"; die "xcodebuild failed (log: $W/xcodebuild.log)"; }
APP="$OUT/Build/Products/Release-iphoneos/DmIOS.app"; [ -d "$APP" ] || die "no app at $APP"
. "$X/Gen/resources.env"
# A capture-enabled build (build_ipa.sh DM_METAL_CAPTURE=1) runs every Metal call through the capture layer: in Breath of the Wild on an iPhone 17 Pro Max it took 41 % of the
# render thread (-[CaptureMTLBuffer contents], GTMemWatch_registerBuffer) and wrapped every encoder of the encode thread, so its CPU timings are not the product's
/usr/libexec/PlistBuddy -c 'Print :MetalCaptureEnabled' "$APP/Info.plist" >/dev/null 2>&1 && echo "note: MetalCaptureEnabled is set: Metal runs through its capture layer, CPU timings include it (DM_ALLOW_CAPTURE=1 to install anyway)" && [ "${DM_ALLOW_CAPTURE:-0}" != 1 ] && die "a capture-enabled build is not for measurements"
codesign -d --entitlements - --xml "$APP" > "$W/app.xcent"
ID=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)/\1/p' | head -1); [ -n "$ID" ] || die "the app is not signed with a development identity"
S="$ST/${DM_STAGE_NAME:-$(basename "$APP")}"
rm -rf "$ST" && mkdir -p "$ST" && cp -cR "$APP" "$S" && mkdir -p "$S/msl" && cp -cR "$DM_RESOURCE_SHADERS" "$S/msl/$DM_RESOURCE_MSLDIR"
[ -n "$DM_RESOURCE_AOC" ] && cp -cR "$DM_RESOURCE_AOC" "$S/aoc"
for e in $DM_EXTRA_MSL; do cp -cR "${e#*=}" "$S/msl/${e%%=*}"; done
cp -cR "$DM_RESOURCE_ROMFS" "$S/romfs"
rm -rf "$S/_CodeSignature"
codesign --force --sign "$ID" --entitlements "$W/app.xcent" --generate-entitlement-der "$S" >/dev/null
codesign --verify --deep "$S"
echo "$(date +%T) staged and signed: $S (free: internal $(free_gb /) GB, $W $(free_gb "$W") GB)"
[ $INSTALL = 1 ] || exit 0
# someone may be playing (a user's run is not under any lock file): never replace the app under a running game
# (this bundle's install path: other test apps on the device have a DmIOS executable too)
APPURL=$(xcrun devicectl device info apps --device "$DEV" --bundle-id "$BID" --json-output "$W/.apps.json" >/dev/null 2>&1 && python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["apps"][0]["url"])' "$W/.apps.json" 2>/dev/null)
if [ -n "$APPURL" ]; then xcrun devicectl device info processes --device "$DEV" --json-output "$W/.ps.json" >/dev/null 2>&1
    python3 -c 'import json,sys; sys.exit(0 if any(p.get("executable","").startswith(sys.argv[2]) for p in json.load(open(sys.argv[1]))["result"]["runningProcesses"]) else 1)' "$W/.ps.json" "$APPURL" && die "the app is running on the device; not installing"; fi
[ "$(free_gb /)" -ge "${DM_MIN_FREE_GB:-20}" ] || die "only $(free_gb /) GB free on the internal disk; the installer stages the whole app there (DM_MIN_FREE_GB=${DM_MIN_FREE_GB:-20})"
xcrun devicectl device install app --device "$DEV" "$S" > "$W/install.log" 2>&1 || { tail -20 "$W/install.log"; die "install failed (log: $W/install.log)"; }
echo "$(date +%T) installed on $DEV (free: internal $(free_gb /) GB)"
