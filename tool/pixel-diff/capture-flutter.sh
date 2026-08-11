#!/bin/bash
# pixel-fidelity-v23 (CP 2.8) — Flutter-side capture for the pixel-diff
# pipeline. Writes tool/pixel-diff/out/flutter/<screen>.png (2560×1600).
set -euo pipefail

export PATH="$HOME/flutter/bin:$PATH"
cd "$(dirname "$0")/../.." # repo root

mkdir -p tool/pixel-diff/out/flutter
exec flutter test test/pixel_capture_test.dart
