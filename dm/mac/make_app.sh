#!/bin/sh
# Packs a game as a Mac app with a launcher window (dm/mac/Launcher.swift): <NSP folder>/mac/<game name>.app, after scripts/build_ipa_from_nsp.py has prepared the game (extracted
# files kept, rewritten modules and shaders in <NSP folder>/<title ID>_build). The app holds the host built for the game's profile and the launcher; the game files stay in the
# build folder and are found by absolute path (game.json), so moving the NSP folder needs the app packed again. Starting it shows the settings (resolution, frame rate,
# sharpening, console mode, language, full screen, HUD) and Play starts the game in this app, so macOS turns Game Mode on in full screen.
# usage: dm/mac/make_app.sh <title ID> <NSP folder> [overlay folder [overlay label]]
#   the launcher lets the player choose a folder whose files replace the game's by path (DM_ROMFS_OVERLAY, e.g. assets from the PC version they own); an overlay folder given
#   here is the preset choice and the label the note under it
set -eu
G=${1:?title ID}; NSP=$(cd "${2:?NSP folder}" && pwd); OVL=${3:-}; OVL_LABEL=${4:-}
DM=$(cd "$(dirname "$0")/.." && pwd); B="$NSP/${G}_build"
gp() { python3 "$DM/games/game.py" "$G" "$1" 2>/dev/null || echo "${2:-}"; }
NAME=$(gp name); PKG=$(gp package); [ -n "$NAME" ] && [ -n "$PKG" ] || { echo "no profile $G"; exit 1; }
ROMFS="$B/extract/$PKG/RomFS"; MODS="$B/patched_$PKG"
[ -d "$ROMFS" ] && [ -d "$MODS" ] || { echo "$B: run scripts/build_ipa_from_nsp.py on the NSP folder first (extracted files and rewritten modules are missing)"; exit 1; }
if [ -d "$B/shader/vk" ]; then MSL="$B/shader"; else MSL="$B/shader/cache"; fi   # a Vulkan game's library, or the NVN shader cache
[ -f "$B/font/nintendo_ext.ttf" ] || { mkdir -p "$B/font"; python3 "$DM/tools/make_ext_font.py" "$B/font/nintendo_ext.ttf" >/dev/null; }
APP="$NSP/mac/$(printf %s "$NAME" | sed 's/: / - /g; s/[:\/]/-/g').app"; C="$APP/Contents"   # a colon in the name is a slash in Finder
rm -rf "$APP"; mkdir -p "$C/MacOS" "$C/Resources"
L=$(mktemp); make -C "$DM/host" GAME="$G" dmhost >"$L" 2>&1 || { grep -E "error" "$L"; echo "building the host failed (log $L)"; exit 1; }; rm -f "$L"; cp "$DM/host/dmhost" "$C/MacOS/dmhost"
swiftc -O -parse-as-library -target arm64-apple-macos14 "$DM/mac/Launcher.swift" -o "$C/MacOS/Launcher"
SHMAP=""; [ -f "$DM/games/$G/shader_map.tsv" ] && cp "$DM/games/$G/shader_map.tsv" "$C/Resources/" && SHMAP="$C/Resources/shader_map.tsv"
LANGS=$(python3 "$DM/tools/nacp.py" --languages "$B/extract/$PKG/control.nacp" 2>/dev/null || true)
python3 - "$C/Resources/game.json" <<EOF
import json, sys
sys.path.insert(0, """$DM/games"""); import settings
fx = settings.fixups_keys(__import__('pathlib').Path("""$MODS""") / 'main.fixups.tsv')   # what main's rewriter stubs offer (patch_nso.py FS_KEYS)
json.dump({"name": """$NAME""", "root": """$B""", "modules": """$MODS""", "romfs": """$ROMFS""", "msl": """$MSL""", "font": """$B/font""",
           "aoc": """$B/aoc""" if __import__('os').path.isdir("""$B/aoc""") else None, "shmap": """$SHMAP""" or None,
           "fpsTarget": int("""$(gp fps_target 0)""" or 0), "fpsMax": 240 if 'VAR_STEP' in fx else int("""$(gp fps_max 60)""" or 60),
           "outputSize": 'OUTPUT_W' in fx and 'RENDER_POOL' not in fx, "renderPool": 'RENDER_POOL' in fx, "docked": """$(gp op_mode docked)""" != "handheld",
           "languages": """$LANGS""".split(), "overlay": """$OVL""" or None, "overlayLabel": """$OVL_LABEL""" or None}, open(sys.argv[1], "w"), indent=1)
EOF
ICON="$B/extract/$PKG/icon.jpg"; ICONKEY=""
if [ -f "$ICON" ]; then
    T=$(mktemp -d); mkdir "$T/AppIcon.iconset"
    for s in 16 32 128 256 512; do sips -s format png -z $s $s "$ICON" --out "$T/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null; sips -s format png -z $((s*2)) $((s*2)) "$ICON" --out "$T/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null; done
    iconutil -c icns "$T/AppIcon.iconset" -o "$C/Resources/AppIcon.icns" && ICONKEY="<key>CFBundleIconFile</key><string>AppIcon</string>"; rm -rf "$T"
fi
cat > "$C/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>Launcher</string>
	<key>CFBundleIdentifier</key><string>org.nxnative.mac.$(echo "$G" | tr 'A-Z' 'a-z')</string>
	<key>CFBundleName</key><string>$NAME</string>
	<key>CFBundleDisplayName</key><string>$NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$(gp version 1.0 | head -1)</string>
	$ICONKEY
	<key>LSApplicationCategoryType</key><string>$(gp app_category public.app-category.games)</string>
	<key>LSSupportsGameMode</key><true/>
	<key>GCSupportsGameMode</key><true/>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --deep --sign - "$APP" 2>/dev/null
echo "$APP"
