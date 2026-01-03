#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: make_escalation_bundle.sh <create|claim>

Collects debugging artifacts for the specified flow from .build/ and packages
them into .build/<flow>_bundle_<timestamp>.tar.gz for sharing with the Charms team.
USAGE
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

FLOW="$1"
if [[ "$FLOW" != "create" && "$FLOW" != "claim" ]]; then
  echo "Unknown flow: $FLOW" >&2
  usage
  exit 1
fi

BUILD_DIR=".build"
if [[ ! -d "$BUILD_DIR" ]]; then
  echo "ERROR: $BUILD_DIR does not exist. Run the flow first." >&2
  exit 1
fi

FILES=(
  "$BUILD_DIR/${FLOW}.rendered.yaml"
  "$BUILD_DIR/${FLOW}.command.txt"
  "$BUILD_DIR/${FLOW}.raw"
  "$BUILD_DIR/${FLOW}.hex"
  "$BUILD_DIR/${FLOW}.prevtxs.txt"
  "$BUILD_DIR/${FLOW}.context.txt"
  "$BUILD_DIR/env.sh"
  "$BUILD_DIR/used_utxos.txt"
)

MISSING=()
PRESENT=()
for f in "${FILES[@]}"; do
  if [[ -f "$f" ]]; then
    PRESENT+=("$f")
  else
    MISSING+=("$f")
  fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "WARNING: some files are missing:"
  for m in "${MISSING[@]}"; do echo "  - $m"; done
fi

ts=$(date -u +"%Y%m%dT%H%M%SZ")
OUT="$BUILD_DIR/${FLOW}_bundle_${ts}.tar.gz"

if [[ ${#PRESENT[@]} -eq 0 ]]; then
  echo "ERROR: No artifacts found to bundle for flow=$FLOW under $BUILD_DIR" >&2
  exit 1
fi

# macOS bsdtar doesn't support GNU tar's --ignore-failed-read.
# We pre-filter missing files and archive only those that exist.
tar -czf "$OUT" "${PRESENT[@]}"

cat <<MSG
Bundle created: $OUT
Share this tarball with the Charms team along with a summary of the issue.
MSG
