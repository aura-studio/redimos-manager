#!/bin/bash
# Preserve the complete v2.3 visual baseline before Codex restyling begins.
# The archive is immutable: this script refuses to replace an existing copy.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
archive_root="$repo_root/tool/pixel-diff/v2.3-archive"
out_root="$repo_root/tool/pixel-diff/out"

if [[ -e "$archive_root" ]]; then
  echo "[archive-v23] refusing to overwrite existing archive: $archive_root" >&2
  exit 1
fi

require_count() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" -ne "$expected" ]]; then
    echo "[archive-v23] $label: expected $expected files, found $actual" >&2
    exit 1
  fi
}

require_count "goldens" 16 "$(find "$repo_root/test/goldens" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
require_count "Flutter captures" 8 "$(find "$out_root/flutter" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
require_count "mockup captures" 8 "$(find "$out_root/mockup" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
require_count "diff diagnostics" 40 "$(find "$out_root/diff" -maxdepth 1 -type f -name '*.png' | wc -l | tr -d ' ')"
require_count "reports" 4 "$(find "$out_root" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"

mkdir -p \
  "$archive_root/goldens" \
  "$archive_root/captures/flutter" \
  "$archive_root/captures/mockup" \
  "$archive_root/diagnostics/diff" \
  "$archive_root/reports" \
  "$archive_root/history"

cp "$repo_root"/test/goldens/*.png "$archive_root/goldens/"
cp "$out_root"/flutter/*.png "$archive_root/captures/flutter/"
cp "$out_root"/mockup/*.png "$archive_root/captures/mockup/"
cp "$out_root"/diff/*.png "$archive_root/diagnostics/diff/"
cp "$out_root"/*.md "$archive_root/reports/"
cp "$repo_root/tool/pixel-diff/README.md" "$archive_root/history/README.md"
cp "$repo_root/tool/pixel-diff/config.js" "$archive_root/history/config.js"

branch="$(git -C "$repo_root" branch --show-current)"
revision="$(git -C "$repo_root" rev-parse HEAD)"
cat > "$archive_root/ARCHIVE-METADATA.txt" <<EOF
archive: v2.3 pre-Codex visual evidence
source-branch: $branch
source-revision: $revision
viewport-logical: 1280x800
capture-dpr: 2
capture-physical: 2560x1600
contents: 16 goldens, 8 Flutter captures, 8 mockup captures, 40 diff diagnostics, 4 reports
policy: historical evidence only; excluded from active reference discovery and comparison
EOF

: > "$archive_root/SHA256SUMS"
while IFS= read -r file; do
  relative="${file#"$archive_root"/}"
  hash="$(shasum -a 256 "$file" | awk '{print $1}')"
  printf '%s  %s\n' "$hash" "$relative" >> "$archive_root/SHA256SUMS"
done < <(find "$archive_root" -type f ! -name SHA256SUMS | sort)

expected_hashes=79
actual_hashes="$(wc -l < "$archive_root/SHA256SUMS" | tr -d ' ')"
require_count "hash manifest entries" "$expected_hashes" "$actual_hashes"

while IFS= read -r line; do
  expected="${line%%  *}"
  relative="${line#*  }"
  actual="$(shasum -a 256 "$archive_root/$relative" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "[archive-v23] checksum mismatch: $relative" >&2
    exit 1
  fi
done < "$archive_root/SHA256SUMS"

chmod -R a-w "$archive_root"
echo "[archive-v23] archived and verified $actual_hashes files at $archive_root"
