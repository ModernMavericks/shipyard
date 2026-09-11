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
# PHASE 1 of the rollout: a missing record WARNS. It becomes an error once every signing product calls
# scan-for-key.yml (the exit task is in SKILL.md's backlog). CI-only.
set -eu
[ "$#" -eq 2 ] || { echo "usage: require_key_scan.sh DIST RECORD_DIR" >&2; exit 2; }
DIST="$1"; RECORD="$2/sparkle-key-scan.txt"

grep -rlq 'sparkle:edSignature' "$DIST" 2>/dev/null || exit 0
if [ -s "$RECORD" ]; then
  echo "signing-key scan: $(cat "$RECORD")"
  exit 0
fi
echo "::warning::this release is signed (it carries a sparkle:edSignature), but no scan-for-key.yml job scanned this run's logs and release files for the signing key. Add one between the job that signs and publish (see scan-for-key.yml). This warning becomes an error once every signing product has it."
