#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(uname -m)" != "arm64" ]]; then
    echo 'This build requires an Apple silicon Mac.' >&2
    exit 1
fi

driver='TT-NTFS-Native-0.4.2.dmg'
driver_sha='e4c1af51a1a1f38250fc9e226cf571be771655ef99b5deabb40dd02e230fa8c7'
build_dir="$PWD/Build"
mkdir -p "$build_dir"
staging=$(mktemp -d "${TMPDIR:-/tmp}/ntfs-writer-build.XXXXXX")
trap 'rm -rf "$staging"' EXIT

if [[ ! -f "$build_dir/$driver" ]]; then
    curl --fail --location --silent --show-error --retry 2 \
        "https://github.com/dr-kbadawi/ttntfs/releases/download/v0.4.2/$driver" \
        -o "$staging/$driver"
    printf '%s  %s\n' "$driver_sha" "$staging/$driver" | shasum -a 256 --check
    mv "$staging/$driver" "$build_dir/$driver"
fi
printf '%s  %s\n' "$driver_sha" "$build_dir/$driver" | shasum -a 256 --check

app="$staging/NTFS Writer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$build_dir/$driver" "$app/Contents/Resources/"
xcrun swiftc -target arm64-apple-macosx27.0 -swift-version 5 -O -whole-module-optimization \
    Sources/*.swift -o "$app/Contents/MacOS/NTFSWriter"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/ditto "$app" "$build_dir/NTFS Writer.app"
printf '\n%s\n' "$build_dir/NTFS Writer.app"
