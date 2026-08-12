#!/bin/bash
# Codex dual-theme Flutter capture driver. Creates one immutable run directory
# containing 8 screens × light/dark and writes metadata only after all 16 PNGs
# pass naming and 2560×1600 dimension validation.
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ ^[1-9][0-9]*$ ]]; then
  echo "Usage: $0 <positive-run-number>" >&2
  exit 2
fi

run_number="$1"
script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
capture_root="$script_dir/visual-evidence/active/codex-v1/captures"
run_dir="$capture_root/run-$run_number"

if [[ "$run_dir" == *"/references/"* || "$run_dir" == *"/v2.3-archive/"* ]]; then
  echo "Capture output must stay outside references and v2.3-archive: $run_dir" >&2
  exit 1
fi

mkdir -p "$capture_root"
if ! mkdir "$run_dir"; then
  echo "Refusing to reuse capture run directory: $run_dir" >&2
  exit 1
fi

export PATH="$HOME/flutter/bin:$PATH"
export REDIMOS_CAPTURE_DIR="$run_dir"
cd "$repo_root"

IFS= read -r flutter_version < <(flutter --version 2>/dev/null)
if [[ -z "$flutter_version" ]]; then
  echo "Unable to record Flutter version" >&2
  exit 1
fi

flutter test test/pixel_capture_test.dart
node tool/pixel-diff/finalize-capture-run.js \
  "$run_dir" \
  "$run_number" \
  "$flutter_version"

echo "[capture-flutter] completed run-$run_number: $run_dir"
