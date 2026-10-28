#!/usr/bin/env bash
# Package Poltergeist into a macOS .app bundle with a generated icon.
#
#   scripts/package-app.sh [debug|release]   (default: release)
#
# The icon is composed from icon/master.svg: the line art is centered on a
# dark rounded-rect ("squircle") tile following Apple's icon grid, rendered
# crisply at every required size with rsvg-convert, then assembled via iconutil.
# libghostty is statically linked, so the built binary is self-contained.

set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

config="${1:-release}"
if [[ "$config" != debug && "$config" != release ]]; then
    echo "error: config must be 'debug' or 'release' (got '$config')" >&2
    exit 1
fi

master="$repo/icon/master.svg"
dist="$repo/dist"
composed="$dist/AppIcon.svg"
iconset="$dist/Poltergeist.iconset"
icns="$dist/Poltergeist.icns"
app="$dist/Poltergeist.app"
# Bundle version; CI sets POLTERGEIST_VERSION from the release tag.
app_version="${POLTERGEIST_VERSION:-0.2.0}"

for tool in rsvg-convert iconutil swift; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: required tool '$tool' not found in PATH" >&2
        exit 1
    fi
done
if [[ ! -f "$master" ]]; then
    echo "error: icon source not found at $master" >&2
    exit 1
fi

rm -rf "$dist"
mkdir -p "$iconset"

# --- compose: dark squircle tile + soft shadow + scaled line art ----------
# Pull the inner nodes out of master.svg (drop its <svg> open + </svg> close),
# then drop them into a group scaled to ~62% and centered. fill="none" on the
# group preserves the envelope's stroke-only look; paths that set fill="black"
# explicitly still fill.
inner="$(sed '1d;$d' "$master")"

printf '%s\n' \
'<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">' \
'  <defs>' \
'    <linearGradient id="tileGrad" x1="0" y1="0" x2="0" y2="1">' \
'      <stop offset="0" stop-color="#2A2A2E"/>' \
'      <stop offset="1" stop-color="#161618"/>' \
'    </linearGradient>' \
'    <filter id="tileShadow" x="-20%" y="-20%" width="140%" height="140%">' \
'      <feDropShadow dx="0" dy="12" stdDeviation="18" flood-color="black" flood-opacity="0.35"/>' \
'    </filter>' \
'    <filter id="artWhite" x="-5%" y="-5%" width="110%" height="110%" color-interpolation-filters="sRGB">' \
'      <feColorMatrix type="matrix" values="0 0 0 0 1  0 0 0 0 1  0 0 0 0 1  0 0 0 1 0"/>' \
'    </filter>' \
'  </defs>' \
'  <rect x="100" y="100" width="824" height="824" rx="185" ry="185" fill="url(#tileGrad)" filter="url(#tileShadow)"/>' \
'  <g fill="none" filter="url(#artWhite)" transform="translate(512,512) scale(0.62) translate(-512.5,-512)">' \
"$inner" \
'  </g>' \
'</svg>' >"$composed"

# --- render every iconset size straight from the SVG (sharp at all sizes) --
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
        128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
        512:icon_512x512 1024:icon_512x512@2x; do
    size="${spec%%:*}"
    name="${spec##*:}"
    if ! rsvg-convert -w "$size" -h "$size" "$composed" -o "$iconset/$name.png"; then
        echo "error: rsvg-convert failed for $name" >&2
        exit 1
    fi
done

if ! iconutil -c icns "$iconset" -o "$icns"; then
    echo "error: iconutil failed" >&2
    exit 1
fi

# --- build the executable --------------------------------------------------
if ! swift build -c "$config" --package-path "$repo"; then
    echo "error: swift build failed" >&2
    exit 1
fi
bin="$repo/.build/$config/Poltergeist"
if [[ ! -f "$bin" ]]; then
    echo "error: build did not produce $bin" >&2
    exit 1
fi

# --- assemble the .app bundle ---------------------------------------------
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin" "$contents/MacOS/Poltergeist"
cp "$icns" "$contents/Resources/Poltergeist.icns"
printf 'APPL????' >"$contents/PkgInfo"

printf '%s\n' \
'<?xml version="1.0" encoding="UTF-8"?>' \
'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
'<plist version="1.0">' \
'<dict>' \
'  <key>CFBundleName</key><string>Poltergeist</string>' \
'  <key>CFBundleDisplayName</key><string>Poltergeist</string>' \
'  <key>CFBundleExecutable</key><string>Poltergeist</string>' \
'  <key>CFBundleIdentifier</key><string>com.tbremer.Poltergeist</string>' \
'  <key>CFBundleIconFile</key><string>Poltergeist</string>' \
'  <key>CFBundlePackageType</key><string>APPL</string>' \
"  <key>CFBundleShortVersionString</key><string>$app_version</string>" \
"  <key>CFBundleVersion</key><string>$app_version</string>" \
'  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>' \
'  <key>LSMinimumSystemVersion</key><string>14.0</string>' \
'  <key>NSHighResolutionCapable</key><true/>' \
'  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>' \
'</dict>' \
'</plist>' >"$contents/Info.plist"

# Nudge Finder/LaunchServices to pick up the freshly-built icon.
touch "$app"

echo "built $app ($config)"
