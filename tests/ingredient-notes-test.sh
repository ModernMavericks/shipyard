#!/bin/sh
# ingredient-notes.sh: render which pins moved since the previous release, per pin shape.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/ingredient-notes.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
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
work2="$(mktemp -d)"; cd "$work2"
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

echo "PASS: ingredient-notes"
