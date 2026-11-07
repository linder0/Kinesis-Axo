#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if pgrep -f "^$PWD/dist/Kinesis.app/Contents/MacOS/Kinesis$" >/dev/null; then
    printf 'quit kinesis before rebuilding.\n' >&2
    exit 1
fi

local_build=false
for argument in "$@"; do
    case "$argument" in
        --local) local_build=true ;;
        --dev) KINESIS_DEV=1 ;;
        --help|-h)
            printf 'usage: ./scripts/build.sh [--local] [--dev]\n'
            printf '  --local  build for this Mac and use ad-hoc signing by default\n'
            printf '  --dev    include developer tools\n'
            exit 0 ;;
        *) printf 'unknown argument: %s\n' "$argument" >&2; exit 1 ;;
    esac
done

build_args=(-c release -Xswiftc -warnings-as-errors)
if ! $local_build; then build_args+=(--arch arm64 --arch x86_64); fi
# --dev (or KINESIS_DEV=1) makes a dev build: the same app with experiments and
# developer tools compiled in, such as the practice lab. Releases leave them out.
if [ "${KINESIS_DEV:-}" = 1 ]; then build_args+=(-Xswiftc -DKINESIS_DEV); fi
binary_dir=$(swift build "${build_args[@]}" --show-bin-path)
# SwiftPM can retain removed resources in an existing bundle.
if [ -d "$binary_dir/Kinesis_Kinesis.bundle" ]; then
    rm -r "$binary_dir/Kinesis_Kinesis.bundle"
fi
swift build "${build_args[@]}"

mkdir -p dist .build/tools
stage_dir=$(mktemp -d "$PWD/dist/.package.XXXXXX")
app_path="$PWD/dist/Kinesis.app"
staged_app="$stage_dir/Kinesis.app"
cleanup() {
    if [ -d "$stage_dir/previous.app" ] && [ ! -e "$app_path" ]; then
        mv "$stage_dir/previous.app" "$app_path"
    fi
    rm -r "$stage_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_dir/Kinesis" "$staged_app/Contents/MacOS/Kinesis"
cp -R "$binary_dir/Kinesis_Kinesis.bundle" "$staged_app/Contents/Resources/"
cp Packaging/Info.plist "$staged_app/Contents/Info.plist"
# A dev build keeps the bundle ID, so it shares settings and the band's pairing,
# and shows as "Kinesis Dev" in Spotlight and the menu bar.
if [ "${KINESIS_DEV:-}" = 1 ]; then
    plutil -replace CFBundleName -string "Kinesis Dev" "$staged_app/Contents/Info.plist"
    plutil -replace CFBundleDisplayName -string "Kinesis Dev" "$staged_app/Contents/Info.plist"
fi
cp LICENSE "$staged_app/Contents/Resources/LICENSE"
swiftc -parse-as-library scripts/export-icon.swift -o .build/tools/export-icon
.build/tools/export-icon "$stage_dir/Kinesis.iconset" Sources/Kinesis/Resources/axo-mark.png
iconutil -c icns "$stage_dir/Kinesis.iconset" -o "$staged_app/Contents/Resources/Kinesis.icns"

signing_identity="${KINESIS_SIGNING_IDENTITY:-}"
if [ -z "$signing_identity" ]; then
    if $local_build; then
        signing_identity="-"
    else
        signing_identity=$(security find-identity -v -p codesigning | awk '
            /"Apple Development:/ { count++; identity = $2 }
            END { print (count == 1 ? identity : "-") }
        ')
    fi
fi
# File Provider-backed folders can attach Finder metadata to copied bundles.
# That metadata is not app content and prevents code signing on those Macs.
xattr -dr com.apple.FinderInfo "$staged_app" 2>/dev/null || true
codesign --force --options runtime --sign "$signing_identity" "$staged_app"
codesign --verify --deep --strict "$staged_app"
if $local_build; then
    lipo "$staged_app/Contents/MacOS/Kinesis" -verify_arch "$(uname -m)"
else
    lipo "$staged_app/Contents/MacOS/Kinesis" -verify_arch arm64 x86_64
fi
plutil -lint "$staged_app/Contents/Info.plist"

if [ -e "$app_path" ]; then mv "$app_path" "$stage_dir/previous.app"; fi
mv "$staged_app" "$app_path"
printf '\nBuilt %s\n' "$app_path"
