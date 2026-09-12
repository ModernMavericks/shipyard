#!/bin/sh
# ingredient-notes.sh: render which pins moved since the previous release, per pin shape.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/ingredient-notes.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
mkdir -p components/golang components/docker-cli vendor
printf '1.26.4-mavericks.3\n' > components/golang/version
printf '28.6.0\n'             > components/docker-cli/version
cat > versions.sh <<'SH'
export MLS_VERSION=1.5.1-mavericks.1   # mavericks-legacysupport
export CA_SHA256="3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91"
export MACOS_MIN="10.9"
export GO_SRC_SHA512="adacc6a34ad239d98277acd2ac8da867110da0b184dbbafb82e8a06d2b7fd234"
export GO_VERSION="$(upstream_version)"
export PKG_VERSION=`cat "$REPO_ROOT/UPSTREAM_VERSION"`
SH
printf 'line one\nline two\nline three\n' > vendor/cacert.pem
git add -A; git commit -qm base; git tag 20260727-mavericks.2

# nothing changed yet -> no section at all (callers append unconditionally)
out="$(sh "$S" 20260727-mavericks.2 components/golang/version versions.sh)"
[ -z "$out" ] || { echo "FAIL unchanged: got '$out'"; exit 1; }

# no previous tag -> nothing
out="$(sh "$S" "" components/golang/version)"
[ -z "$out" ] || { echo "FAIL no-prev: got '$out'"; exit 1; }

# now move every shape at once
printf '1.26.5-mavericks.1\n' > components/golang/version
printf '28.6.1\n'             > components/docker-cli/version
cat > versions.sh <<'SH'
export MLS_VERSION=1.5.2-mavericks.1   # mavericks-legacysupport
export CA_SHA256="9a1c72b4aa0f1e8d5c3b7e6f2d4a8091ccee5577bb33ff11aa99887766554433"
export MACOS_MIN="10.9"
export GO_VERSION="$(upstream_version_v2)"
export PKG_VERSION=`sh "$REPO_ROOT/build/version.sh" auto`
SH
printf 'line one\nline two\nline three\nline four\n' > vendor/cacert.pem
mkdir -p components/lazydocker
printf '0.24.1\n' > components/lazydocker/version   # a pin that did not exist at the prev tag

out="$(sh "$S" 20260727-mavericks.2 components/golang/version components/docker-cli/version \
        versions.sh vendor/cacert.pem components/lazydocker/version)"
printf '%s\n' "$out" | grep -q '^### Build ingredients$' \
  || { echo "FAIL header: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'Changed since 20260727-mavericks.2:' \
  || { echo "FAIL baseline: $out"; exit 1; }
# whole-file pins are named by component directory
printf '%s\n' "$out" | grep -qx -- '- \*\*golang\*\*: 1.26.4-mavericks.3 -> 1.26.5-mavericks.1' \
  || { echo "FAIL whole-file: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*docker-cli\*\*: 28.6.0 -> 28.6.1' \
  || { echo "FAIL second pin: $out"; exit 1; }
# shell assignments are named by key, matched by name not line number
printf '%s\n' "$out" | grep -qx -- '- \*\*MLS_VERSION\*\*: 1.5.1-mavericks.1 -> 1.5.2-mavericks.1' \
  || { echo "FAIL assignment: $out"; exit 1; }
# a 64-char hash pair communicates nothing: shorten it
printf '%s\n' "$out" | grep -qx -- '- \*\*CA_SHA256\*\*: 3ff344e30b9b... -> 9a1c72b4aa0f...' \
  || { echo "FAIL hash shortening: $out"; exit 1; }
# an unchanged assignment in a changed file is not mentioned
printf '%s\n' "$out" | grep -q 'MACOS_MIN' \
  && { echo "FAIL unchanged key leaked: $out"; exit 1; }
# COMPUTED assignments are derivations, not pinned inputs: a rewritten $(...) or `...` value is a
# code change, and reporting it as an ingredient change is noise (and misleading).
printf '%s\n' "$out" | grep -q 'GO_VERSION' \
  && { echo "FAIL computed \$() value reported as an ingredient: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'PKG_VERSION' \
  && { echo "FAIL computed backtick value reported as an ingredient: $out"; exit 1; }
# opaque multi-line blob: report that it moved, with sizes
printf '%s\n' "$out" | grep -q -- '- \*\*vendor/cacert.pem\*\*: updated (' \
  || { echo "FAIL opaque: $out"; exit 1; }
# a pin absent at the previous release
printf '%s\n' "$out" | grep -qx -- '- \*\*lazydocker\*\*: added (0.24.1)' \
  || { echo "FAIL added: $out"; exit 1; }
# a pin that STOPPED being pinned: an input no longer declared is a real change, and walking only the
# new file's keys would silently omit it (golang dropped GO_SRC_SHA512 exactly this way).
printf '%s\n' "$out" | grep -qx -- '- \*\*GO_SRC_SHA512\*\*: removed' \
  || { echo "FAIL removed key not reported: $out"; exit 1; }
# ASCII only -- these notes get embedded in appcast XML
printf '%s\n' "$out" | LC_ALL=C grep -q '[^ -~]' \
  && { echo "FAIL non-ASCII output: $out"; exit 1; }

# a missing pin path is skipped, not fatal
out="$(sh "$S" 20260727-mavericks.2 components/golang/version nosuch/file 2>/dev/null)"
printf '%s\n' "$out" | grep -q 'golang' || { echo "FAIL missing-path skip: $out"; exit 1; }

# --- patch pins ---------------------------------------------------------------------------------
# A .patch IS an ingredient (it is baked into the product), but "updated (N -> M bytes)" says nothing
# useful about one. Report what a reader can act on: the subject line, and how much moved.
work2="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; cd "$work2"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
mkdir -p patches
cat > patches/0001-keyserver.patch <<'PATCH'
From abc123 Mon Sep 17 00:00:00 2001
Subject: [PATCH] boot2docker: fetch kernel keys over HTTPS
---
 Dockerfile | 2 +-
@@ -1,2 +1,2 @@
-old line
+new line
PATCH
cat > patches/0002-plain.patch <<'PATCH'
--- a/x
+++ b/x
@@ -1 +1 @@
-a
+b
PATCH
git add -A; git commit -qm base; git tag 1.0.0-mavericks.1

# content moves, subject unchanged
printf '+another line\n' >> patches/0001-keyserver.patch
# a patch with no Subject: header still reports a line delta
printf '+extra\n' >> patches/0002-plain.patch
# a brand-new patch
cat > patches/0003-new.patch <<'PATCH'
Subject: [PATCH] modernize the tls stack
---
 y | 1 +
PATCH

out="$(sh "$S" 1.0.0-mavericks.1 patches/0001-keyserver.patch patches/0002-plain.patch patches/0003-new.patch)"
printf '%s\n' "$out" | grep -q -- '- \*\*0001-keyserver.patch\*\*: updated ("boot2docker: fetch kernel keys over HTTPS", +1/-0 lines)' \
  || { echo "FAIL patch updated: $out"; exit 1; }
printf '%s\n' "$out" | grep -q -- '- \*\*0002-plain.patch\*\*: updated (+1/-0 lines)' \
  || { echo "FAIL subject-less patch: $out"; exit 1; }
printf '%s\n' "$out" | grep -q -- '- \*\*0003-new.patch\*\*: added ("modernize the tls stack")' \
  || { echo "FAIL patch added: $out"; exit 1; }
# a patch is never reported as a byte-size delta
printf '%s\n' "$out" | grep -q 'bytes' \
  && { echo "FAIL patch reported as opaque bytes: $out"; exit 1; }

# a rewritten patch that changes what it DOES: say so, old subject -> new subject
cat > patches/0001-keyserver.patch <<'PATCH'
From abc123 Mon Sep 17 00:00:00 2001
Subject: [PATCH] boot2docker: import kernel keys from a pinned bundle
---
 Dockerfile | 2 +-
PATCH
out="$(sh "$S" 1.0.0-mavericks.1 patches/0001-keyserver.patch)"
printf '%s\n' "$out" | grep -q -- '- \*\*0001-keyserver.patch\*\*: "boot2docker: fetch kernel keys over HTTPS" -> "boot2docker: import kernel keys from a pinned bundle"' \
  || { echo "FAIL patch subject change: $out"; exit 1; }
cd "$work"; rm -rf "$work2"

# --- G1: rendering is decided by CONTENT, not by filename extension ------------------------------
# The swift-toolchain regression: pins.env holds the exact same KEY=VALUE shape as pins.sh under a
# different extension, but the dispatch was `case "$path" in *.sh)`, so pins.env fell through to the
# generic byte-delta branch. A rewritten DERIVED expression (VERSION="$(cat VERSION)" ->
# VERSION="$(sh resolve-version.sh)") is a code change, not an ingredient move -- assignments()'s
# literal-only rule already knows this for .sh, and pins.env must get exactly the same answer.
work3="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; cd "$work3"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
cat > pins.env <<'ENV'
SWIFT_VERSION="6.3.3"
VERSION="$(cat "$HERE/VERSION")"
ENV
cp pins.env pins.sh
git add -A; git commit -qm base; git tag base

# only the derived VERSION expression is rewritten -- no literal pin moved
cat > pins.env <<'ENV'
SWIFT_VERSION="6.3.3"
VERSION="$(MAVERICKS_ROOT="$HERE" sh "$SHIPYARD/resolve-version.sh")"
ENV
cp pins.env pins.sh

out_env="$(sh "$S" base pins.env)"
out_sh="$(sh "$S" base pins.sh)"
[ -z "$out_env" ] \
  || { echo "FAIL G1 pins.env: derived-only rewrite falsely reported as an ingredient move: $out_env"; exit 1; }
[ "$out_env" = "$out_sh" ] \
  || { echo "FAIL G1: identical bytes disagree by extension: env='$out_env' sh='$out_sh'"; exit 1; }

# a REAL literal key move in a .env file must still be reported, per key -- content dispatch must not
# just make everything opaque
cat > pins.env <<'ENV'
SWIFT_VERSION="6.3.4"
VERSION="$(MAVERICKS_ROOT="$HERE" sh "$SHIPYARD/resolve-version.sh")"
ENV
out_env2="$(sh "$S" base pins.env)"
printf '%s\n' "$out_env2" | grep -qx -- '- \*\*SWIFT_VERSION\*\*: 6.3.3 -> 6.3.4' \
  || { echo "FAIL G1 pins.env real move not reported per-key: $out_env2"; exit 1; }
printf '%s\n' "$out_env2" | grep -q 'bytes' \
  && { echo "FAIL G1 pins.env: still using the opaque byte-delta fallback: $out_env2"; exit 1; }
cd "$work"; rm -rf "$work3"

# --- G2: a "path:KEY" pin argument excludes just that KEY, not the whole file --------------------
# ingredient-pins.sh (fixed for G2) now emits "pins.env:SWIFT_VERSION" for a swift-shaped repo's own-
# upstream key. This script must honour that suffix: SWIFT_VERSION (the repo's own upstream) must
# never appear as a moved ingredient, while a real ingredient key in the SAME file still must.
work4="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; cd "$work4"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
printf 'SWIFT_VERSION="6.3.3"\nLLVM_SHA="aaaa"\n' > pins.env
git add -A; git commit -qm base; git tag base
# both the own-upstream key AND a real ingredient key move in the same release
printf 'SWIFT_VERSION="6.3.4"\nLLVM_SHA="bbbb"\n' > pins.env
out="$(sh "$S" base pins.env:SWIFT_VERSION)"
printf '%s\n' "$out" | grep -q 'SWIFT_VERSION' \
  && { echo "FAIL G2: own-upstream key SWIFT_VERSION leaked as an ingredient: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*LLVM_SHA\*\*: aaaa -> bbbb' \
  || { echo "FAIL G2: real ingredient key LLVM_SHA in the same file was dropped: $out"; exit 1; }
cd "$work"; rm -rf "$work4"

echo "PASS: ingredient-notes"
