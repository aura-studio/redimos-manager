#!/usr/bin/env bash
# Build — and, only when explicitly asked, publish — the redimos SERVER release
# matrix for one or more exact tags.
#
# Both redimos lines are branches of ONE repo (git@github.com:aura-studio/redimos.git):
#   v1 line = branch v1, tags v1.*   (redimo v1 format, String (S) pk/sk tables)
#   v2 line = branch v2, tags v2.*   (redimo v2 format, Binary (B) pk/sk tables)
# The lines ship in PARALLEL — v1 does not supersede v2 — so publishing a v1
# release must never move GitHub's "Latest" badge off the v2 line (--latest=false).
#
# Usage:
#   scripts/release.sh <tag>...                 build only -> dist/redimos-<tag>/
#   scripts/release.sh <tag>... --publish       build, then gh release create
#   scripts/release.sh <tag>... --with-readme   add README.txt to each archive
#   scripts/release.sh                          print each line's tag + drift, exit 1
#
# BUILD-ONLY IS THE DEFAULT. Without --publish nothing reaches the network: the
# gh command that would have run is printed verbatim instead, and we exit 0.
#
# Tags are REQUIRED and taken literally (vN.N.N); the line is inferred from the
# prefix. "latest" is never auto-resolved — guessing is how you ship a stale tag.
#
# Env overrides:
#   REDIMOS_REPO     default ../redimos  — both branches and every tag live here
#   REDIMOS_GH_REPO  default: derived from that repo's origin remote
#
# Every tag is built from a throwaway detached worktree, so no checkout you might
# have work in is ever touched — ../redimos-v1-wt in particular is a live
# user-pinned worktree, and the release must not depend on where its HEAD sits.
# dist/ is gitignored.
set -euo pipefail
cd "$(dirname "$0")/.."
export GOTOOLCHAIN=local

ROOT="$(pwd)"
REDIMOS_REPO=${REDIMOS_REPO:-../redimos}
PLATFORMS=(darwin/amd64 darwin/arm64 windows/amd64 linux/amd64 linux/arm64)

PUBLISH=0
WITH_README=0
TAGS=()
for a in "$@"; do
  case "$a" in
    --publish)     PUBLISH=1 ;;
    --with-readme) WITH_README=1 ;;
    -*)            echo "!! unknown flag: $a"; exit 1 ;;
    *)             TAGS+=("$a") ;;
  esac
done

usage() {
  echo "usage: scripts/release.sh <tag>... [--publish] [--with-readme]"
  echo "       tags are literal and required, e.g. v2.61.0 v1.59.0"
}

REPO="$(cd "$REDIMOS_REPO" 2>/dev/null && pwd)" \
  || { echo "!! REDIMOS_REPO not found: $REDIMOS_REPO"; exit 1; }

# No tag given: report, never guess. Exit 1 so a careless caller in a pipeline
# stops here instead of silently releasing nothing.
if [ ${#TAGS[@]} -eq 0 ]; then
  echo "==> no tag given — refusing to guess (that is how a stale tag ships)"
  for line in v1 v2; do
    tag=$(git -C "$REPO" describe --tags --abbrev=0 "$line")
    echo "  $line  latest tag $tag -> $(git -C "$REPO" rev-parse --short "$tag^{commit}")"
    drift=$(git -C "$REPO" log --oneline "$tag..$line")
    if [ -n "$drift" ]; then
      echo "$drift" | sed "s/^/        ahead on $line, NOT in $tag: /"
    fi
  done
  echo
  usage
  exit 1
fi

for tag in "${TAGS[@]}"; do
  [[ "$tag" =~ ^v(1|2)\.[0-9]+\.[0-9]+$ ]] \
    || { echo "!! not a redimos release tag: $tag (want v1.N.N or v2.N.N)"; exit 1; }
done

echo "==> preflight"
for t in go git tar zip shasum; do
  command -v "$t" >/dev/null || { echo "!! $t not found"; exit 1; }
done

# origin's URL doubles as the gh --repo target: gh runs with this repo (the
# manager) as its cwd, so without --repo it would resolve the wrong repository.
GH_URL="$(git -C "$REPO" remote get-url origin)"
GH_REPO=${REDIMOS_GH_REPO:-}
if [ -z "$GH_REPO" ]; then
  GH_REPO=${GH_URL%.git}
  GH_REPO=${GH_REPO#*github.com}
  GH_REPO=${GH_REPO#[:/]}
fi

if [ "$PUBLISH" = 1 ]; then
  command -v gh >/dev/null || { echo "!! gh not found"; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "!! gh is not authenticated — run: gh auth login"; exit 1; }
fi

for tag in "${TAGS[@]}"; do
  git -C "$REPO" rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null \
    || { echo "!! tag $tag does not exist in $REPO"; exit 1; }
done

# The remote-tag check needs the network, so it is gated on --publish: build-only
# must stay offline. It only guards publishing anyway — an unpushed tag is the
# worst failure mode there, because gh would invent the ref off the default
# branch and cut a release from v2's HEAD instead of the tag. Comparing SHAs (not
# just existence) also catches a tag that was re-pointed after being pushed.
if [ "$PUBLISH" = 1 ]; then
  for tag in "${TAGS[@]}"; do
    remote_sha=$(git -C "$REPO" ls-remote --tags origin "refs/tags/$tag" | awk '{print $1}')
    [ -n "$remote_sha" ] \
      || { echo "!! tag $tag is not on origin — push it first: git push origin $tag"; exit 1; }
    local_sha=$(git -C "$REPO" rev-parse "refs/tags/$tag")
    [ "$remote_sha" = "$local_sha" ] \
      || { echo "!! tag $tag differs from origin (local $local_sha, origin $remote_sha)"; exit 1; }
    echo "  $tag on origin ✓"
  done
else
  echo "  build-only: staying offline (the origin-tag check runs under --publish)"
fi

WT="$(mktemp -d "${TMPDIR:-/tmp}/redimos-release.XXXXXX")"
cleanup() {
  for d in "$WT"/*/; do
    [ -d "$d" ] || continue
    git -C "$REPO" worktree remove --force "$d" >/dev/null 2>&1 || true
  done
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
  rm -rf "$WT"
}
trap cleanup EXIT INT TERM

for tag in "${TAGS[@]}"; do
  line=${tag%%.*}
  commit=$(git -C "$REPO" rev-parse "$tag^{commit}")

  echo
  echo "==> $tag ($line line) -> $commit"
  drift=$(git -C "$REPO" log --oneline "$tag..$line")
  if [ -n "$drift" ]; then
    echo "!! branch $line is AHEAD of $tag — these commits are NOT in this release:"
    echo "$drift" | sed 's/^/!!     /'
  fi

  SRC="$WT/$tag"
  echo "==> worktree $SRC (detached at refs/tags/$tag)"
  git -C "$REPO" worktree add --detach "$SRC" "refs/tags/$tag" >/dev/null

  STAGE="dist/redimos-$tag"
  PAYLOAD="$STAGE/stage"
  rm -rf "$STAGE"
  mkdir -p "$PAYLOAD"

  for p in "${PLATFORMS[@]}"; do
    goos=${p%/*}
    goarch=${p#*/}
    stem="redimos-$tag-$goos-$goarch"
    if [ "$goos" = windows ]; then bin=redimos.exe; else bin=redimos; fi
    mkdir -p "$PAYLOAD/$stem"

    echo "==> build $stem"
    # Both lines are pure Go, so CGO_ENABLED=0 cross-compiles the whole matrix.
    #
    # -buildvcs=false pins the shipped binaries' "no vcs stamps" property. It is
    # redundant today only by accident: -buildvcs=auto silently skips stamping in
    # a linked worktree (.git is a file there, not a directory). The same build
    # from a normal checkout stamps vcs.revision and would not reproduce the
    # shipped artifacts, so state the requirement rather than inherit it.
    ( cd "$SRC" && CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
        go build -trimpath -buildvcs=false -ldflags "-s -w" \
          -o "$ROOT/$PAYLOAD/$stem/$bin" ./cmd/redimos )

    if [ "$WITH_README" = 1 ]; then
      cat > "$PAYLOAD/$stem/README.txt" <<EOF
redimos $tag ($line line) — $goos/$goarch

  ./$bin -h                     list every flag
  ./$bin -table <name> -addr :6379
      serve RESP2 on :6379 against a DynamoDB table (default credential chain)
  ./$bin -endpoint-url http://localhost:8000 -region us-east-1 -auto-create-table
      serve against dynamodb-local, creating the table if it is missing

The v1 and v2 lines use incompatible table formats: v1 keys are String (S), v2
keys are Binary (B). Give each line its own DynamoDB table.

Built from $commit.
EOF
    fi

    # Warn-only: the release must not hinge on this host. darwin/amd64 is the one
    # matrix entry this Intel Mac can execute, so it is the only real check; -help
    # exits non-zero by design (Go's flag package), hence the || true.
    if [ "$p" = darwin/amd64 ]; then
      help=$("$PAYLOAD/$stem/$bin" -help 2>&1 || true)
      for want in endpoint-url auto-create-table; do
        case "$help" in
          *"$want"*) echo "    smoke: -help mentions $want" ;;
          *)         echo "!!  smoke: -help does NOT mention $want" ;;
        esac
      done
    else
      echo "    smoke: $(file -b "$PAYLOAD/$stem/$bin")"
    fi

    if [ "$goos" = windows ]; then
      ( cd "$PAYLOAD" && zip -qr "../$stem.zip" "$stem" )
    else
      # One <stem> operand => exactly one top-level dir in the archive.
      # COPYFILE_DISABLE stops bsdtar from adding AppleDouble ._* members.
      ( cd "$PAYLOAD" && COPYFILE_DISABLE=1 tar -czf "../$stem.tar.gz" "$stem" )
    fi
  done

  echo "==> SHA256SUMS"
  ( cd "$STAGE" && shasum -a 256 *.tar.gz *.zip > "redimos-$tag-SHA256SUMS.txt" )

  notes="redimos $tag — $line line, built from $commit.

Binary-only archives for darwin/amd64, darwin/arm64, linux/amd64, linux/arm64
and windows/amd64. Verify against redimos-$tag-SHA256SUMS.txt."

  gh_cmd=(gh release create "$tag"
          --repo "$GH_REPO"
          --verify-tag
          --title "redimos $tag"
          --notes "$notes")
  if [ "$line" = v1 ]; then
    # v1 runs alongside v2, it does not follow it: without --latest=false gh dates
    # this release newest and hands the Latest badge to the older parallel line.
    gh_cmd+=(--latest=false)
  else
    gh_cmd+=(--latest)
  fi
  for f in "$STAGE"/*.tar.gz "$STAGE"/*.zip "$STAGE/redimos-$tag-SHA256SUMS.txt"; do
    gh_cmd+=("$f")
  done

  if [ "$PUBLISH" = 1 ]; then
    echo "==> publishing $tag to $GH_REPO"
    "${gh_cmd[@]}"
  else
    echo "==> NOT published (no --publish). Would have run:"
    printf '      '
    printf '%q ' "${gh_cmd[@]}"
    echo
  fi

  echo "==> done: $STAGE"
  ls -la "$STAGE" | sed 's/^/    /'
done
