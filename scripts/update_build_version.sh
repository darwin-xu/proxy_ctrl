#!/bin/sh
set -eu

state_file="${VERSION_STATE_FILE:-${SRCROOT:?}/version/latest_build.env}"
info_plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
resources_dir="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

major_version=1
build_count=0
if [ -f "$state_file" ]; then
  major_version="$(awk -F= '$1 == "MAJOR_VERSION" { print $2 }' "$state_file")"
  build_count="$(awk -F= '$1 == "BUILD_COUNT" { print $2 }' "$state_file")"
  major_version="${major_version:-1}"
  build_count="${build_count:-0}"
fi

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

year="$(date +%Y)"
month="$(date +%-m)"
day="$(date +%-d)"
build_count=$((build_count + 1))
marketing_version="${major_version}.${year}.${month}.${day}"
built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

tmp_file="${state_file}.tmp"
mkdir -p "$(dirname "$state_file")"
{
  printf 'MAJOR_VERSION=%s\n' "$major_version"
  printf 'MARKETING_VERSION=%s\n' "$marketing_version"
  printf 'BUILD_COUNT=%s\n' "$build_count"
  printf 'BUILT_AT=%s\n' "$built_at"
} > "$tmp_file"
mv "$tmp_file" "$state_file"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$info_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_count" "$info_plist"

mkdir -p "$resources_dir"
cp "$state_file" "$resources_dir/build_info.env"

printf 'Updated version to %s (%s)\n' "$marketing_version" "$build_count"
