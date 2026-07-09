#!/usr/bin/env bash
# Build the two redimos Docker run-mode images the manager launches when a
# config's Run mode = Docker: redimos-v1:local and redimos-v2:local.
#
# The manager does NOT build these itself (locked design decision); run this
# once (and again whenever you bump a redimos version) on the machine whose
# Docker daemon the manager talks to.
#
# Usage:
#   scripts/build-images.sh [V1_CONTEXT] [V2_CONTEXT]
# Defaults resolve to sibling checkouts next to this repo. Override when your
# v1/v2 sources live elsewhere. Each context must contain a Dockerfile.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
parent="$(cd "$here/.." && pwd)"

# v1 lives on the redimo v1 line; v2 on the default line. Try the common
# checkout names in order.
pick() { for d in "$@"; do [ -f "$d/Dockerfile" ] && { echo "$d"; return; }; done; echo ""; }

V1="${1:-$(pick "$parent/redimos-v1-wt" "$parent/redimos-v1")}"
V2="${2:-$(pick "$parent/redimos" "$parent/redimos-v2-wt" "$parent/redimos-v2")}"

fail=0
if [ -z "$V1" ] || [ ! -f "$V1/Dockerfile" ]; then
  echo "!! v1 context not found (pass it as arg 1; needs a Dockerfile)"; fail=1
fi
if [ -z "$V2" ] || [ ! -f "$V2/Dockerfile" ]; then
  echo "!! v2 context not found (pass it as arg 2; needs a Dockerfile)"; fail=1
fi
[ "$fail" = 0 ] || exit 1

echo "==> building redimos-v1:local  (context: $V1)"
docker build -t redimos-v1:local "$V1"
echo "==> building redimos-v2:local  (context: $V2)"
docker build -t redimos-v2:local "$V2"

echo
echo "done. images:"
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E 'redimos-v[12]:local' || true
echo "Set custom image names in the app's Settings if you tag them differently."
