#!/bin/sh
# publish-release.yml's gate: a SIGNED release -- some file in it carries a sparkle:edSignature -- must
# come with scan-for-key.yml's record that this run's logs and release files were scanned for the
# signing key. An unsigned release needs no scan.
#
#   require_key_scan.sh DIST RECORD_DIR      (RECORD_DIR: where the sparkle-key-scan artifact landed)
#
# The scan cannot live in publish-release.yml itself: reading job logs needs `actions: read`, and a
# called workflow may not ask for more than its caller grants -- every product calls this one with
# `contents: write` alone, so asking would break every publish in the family at once. The signing
# products call scan-for-key.yml instead; this is where its absence becomes visible for all of them.
#
# A missing record is an ERROR: every signing product calls scan-for-key.yml (2026-09-11), and
# check-family-conventions.sh fails a repo that signs without it, so this should only ever fire on a
# scan that did not run or did not pass. It warned during the rollout. CI-only.
set -eu
[ "$#" -eq 2 ] || { echo "usage: require_key_scan.sh DIST RECORD_DIR" >&2; exit 2; }
DIST="$1"; RECORD="$2/sparkle-key-scan.txt"

grep -rlq 'sparkle:edSignature' "$DIST" 2>/dev/null || exit 0
if [ -s "$RECORD" ]; then
  echo "signing-key scan: $(cat "$RECORD")"
  exit 0
fi
echo "::error::this release is signed (it carries a sparkle:edSignature), but no scan-for-key.yml job scanned this run's logs and release files for the signing key -- refusing to publish. Add one between the job that signs and publish, under always() (see scan-for-key.yml), or find out why it did not run."
exit 1
