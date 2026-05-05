#!/bin/sh
set -eu

state_file="${VERSION_STATE_FILE:-${SRCROOT:?}/version/version.env}"
info_plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"

if [ ! -f "$state_file" ]; then
  printf 'error: missing version state file: %s\n' "$state_file" >&2
  exit 1
fi

major_version="$(awk -F= '$1 == "MAJOR_VERSION" { print $2 }' "$state_file")"
build_count="$(awk -F= '$1 == "BUILD_COUNT" { print $2 }' "$state_file")"

case "$major_version" in
  ''|*[!0-9]*)
    printf 'error: MAJOR_VERSION must be a non-negative integer in %s\n' "$state_file" >&2
    exit 1
    ;;
esac

case "$build_count" in
  ''|*[!0-9]*)
    printf 'error: BUILD_COUNT must be a non-negative integer in %s\n' "$state_file" >&2
    exit 1
    ;;
esac

build_count=$((build_count + 1))
year="$(date +%Y)"
month="$(date +%-m)"
day="$(date +%-d)"
marketing_version="${major_version}.${year}.${month}.${day}"

tmp_file="${state_file}.tmp"
{
  printf 'MAJOR_VERSION=%s\n' "$major_version"
  printf 'BUILD_COUNT=%s\n' "$build_count"
} > "$tmp_file"
mv "$tmp_file" "$state_file"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_count" "$info_plist"

printf 'Updated version to %s (%s)\n' "$marketing_version" "$build_count"
