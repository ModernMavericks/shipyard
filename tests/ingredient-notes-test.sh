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

# --- G1 review round, CRITICAL 1: a real blob (base64 padding) must not false-positive as KV ------
# is_kv_pins()'s first cut allowed a lowercase-tolerant key class, which matches base64 PADDING lines
# in a real vendor/cacert.pem ("dZWAUWpLMKawYqGT8ZvYzsRjdT9ZR7E=", "MrY=", "IhNzbM8m9Yop5w==") as
# one-line "assignments" -- reported as build ingredients (with the key itself as a bogus "added"
# value, since oldv is always empty) on the next CA-bundle refresh. Uppercase-only NARROWED but did
# not CLOSE this class: an all-caps-and-digit padding line ("MK9=") still matches an uppercase-only
# key with an empty value -- the reviewer measured ~0.46 expected such lines per real CA-bundle
# refresh, i.e. even odds of resurrecting this exact false claim a third time. The value must hold
# at least one non-"=" character (padding is only ever "=" characters, at the end; no real pin's
# value is empty or all-"=").
work5="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; cd "$work5"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
mkdir -p vendor
cat > vendor/cacert.pem <<'PEM'
-----BEGIN CERTIFICATE-----
MIIDdZWAUWpLMKawYqGT8ZvYzsRjdT9ZR7E=
rJgWVqA=
IhNzbM8m9Yop5w==
MrY=
MK9=
-----END CERTIFICATE-----
PEM
git add -A; git commit -qm base; git tag base
printf '\n' >> vendor/cacert.pem   # a genuine, tiny change: a real CA-bundle refresh looks like this
out="$(sh "$S" base vendor/cacert.pem)"
printf '%s\n' "$out" | grep -q -- '- \*\*vendor/cacert.pem\*\*: updated (' \
  || { echo "FAIL CRITICAL1: base64 blob no longer treated as opaque: $out"; exit 1; }
printf '%s\n' "$out" | grep -qi 'MrY\|dZWAUWpL\|IhNzbM8m9Yop5w\|MK9\|added\b' \
  && { echo "FAIL CRITICAL1: base64 padding line(s) leaked as a bogus ingredient bullet: $out"; exit 1; }
cd "$work"; rm -rf "$work5"

# ...and the other direction: the value-must-have-content guard must not cost a single real pin.
# Every real family KV pin the reviewer's table names must still render per-key.
work5b="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; cd "$work5b"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
mkdir -p build components/tailscale
cat > build/versions.sh <<'SH'
export MLS_VERSION=1.5.2-mavericks.3
export CA_SHA256="3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91"
export GO_SRC_SHA512="adacc6a34ad239d98277acd2ac8da867110da0b184dbbafb82e8a06d2b7fd234"
SH
cat > pins.env <<'ENV'
SWIFT_VERSION="6.3.3"
LLVM_SHA="aaaa"
ENV
cat > build.sh <<'SH'
SWIFT_TAG="swift-6.3.3-RELEASE"
TOOLCHAIN_SHA="cccc"
SH
printf 'REPO=https://github.com/tailscale/tailscale.git\nREF=v1.102.4\nDIGEST=deadbeef\n' \
  > components/tailscale/version
git add -A; git commit -qm base; git tag base
cat > build/versions.sh <<'SH'
export MLS_VERSION=1.5.2-mavericks.4
export CA_SHA256="9a1c72b4aa0f1e8d5c3b7e6f2d4a8091ccee5577bb33ff11aa99887766554433"
export GO_SRC_SHA512="adacc6a34ad239d98277acd2ac8da867110da0b184dbbafb82e8a06d2b7fd234"
SH
printf 'SWIFT_VERSION="6.3.4"\nLLVM_SHA="bbbb"\n' > pins.env
printf 'SWIFT_TAG="swift-6.3.4-RELEASE"\nTOOLCHAIN_SHA="dddd"\n' > build.sh
printf 'REPO=https://github.com/tailscale/tailscale.git\nREF=v1.102.5\nDIGEST=cafebabe\n' \
  > components/tailscale/version
out="$(sh "$S" base build/versions.sh pins.env build.sh components/tailscale/version)"
printf '%s\n' "$out" | grep -qx -- '- \*\*MLS_VERSION\*\*: 1.5.2-mavericks.3 -> 1.5.2-mavericks.4' \
  || { echo "FAIL both-directions: build/versions.sh MLS_VERSION dropped: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*CA_SHA256\*\*: 3ff344e30b9b... -> 9a1c72b4aa0f...' \
  || { echo "FAIL both-directions: build/versions.sh CA_SHA256 dropped: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*SWIFT_VERSION\*\*: 6.3.3 -> 6.3.4' \
  || { echo "FAIL both-directions: pins.env SWIFT_VERSION dropped: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*LLVM_SHA\*\*: aaaa -> bbbb' \
  || { echo "FAIL both-directions: pins.env LLVM_SHA dropped: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*SWIFT_TAG\*\*: swift-6.3.3-RELEASE -> swift-6.3.4-RELEASE' \
  || { echo "FAIL both-directions: build.sh SWIFT_TAG dropped: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*TOOLCHAIN_SHA\*\*: cccc -> dddd' \
  || { echo "FAIL both-directions: build.sh TOOLCHAIN_SHA dropped: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*tailscale / REF\*\*: v1.102.4 -> v1.102.5' \
  || { echo "FAIL both-directions: tailscale component REF dropped: $out"; exit 1; }
printf '%s\n' "$out" | grep -q -- 'updated (' \
  && { echo "FAIL both-directions: a real KV pin fell through to the opaque byte-delta fallback: $out"; exit 1; }
cd "$work"; rm -rf "$work5b"

# --- G1 review round, CRITICAL 2: components/*/version bullets must always carry the component name
# container-tools' real shape: SIX components share the same REPO=/REF=/DIGEST=/BASE= key names.
# Renovate can bump two components in the same release (docker-cli + docker-compose): a bare "REF"/
# "DIGEST" bullet with no component identity is ambiguous at best and misattributed at worst.
# Prefix ALWAYS for this pin shape, not only when this run happens to be ambiguous -- an unprefixed
# bullet that reads fine today silently becomes wrong the day a second component moves.
work6="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; cd "$work6"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
mkdir -p components/docker-cli components/docker-compose
printf 'REPO=https://github.com/docker/cli.git\nREF=v29.8.0\nDIGEST=88096ef00576baf72a9cb45caa45c0544c40e0a7\n' \
  > components/docker-cli/version
printf 'REPO=https://github.com/docker/compose.git\nREF=v5.5.1\nDIGEST=5f94fb0aa42a2cd1248c6e6c7fafb87546b9c8de\n' \
  > components/docker-compose/version
git add -A; git commit -qm base; git tag base
printf 'REPO=https://github.com/docker/cli.git\nREF=v29.9.0\nDIGEST=111111111111111111111111111111111111111\n' \
  > components/docker-cli/version
printf 'REPO=https://github.com/docker/compose.git\nREF=v2.40.0\nDIGEST=222222222222222222222222222222222222222\n' \
  > components/docker-compose/version
out="$(sh "$S" base components/docker-cli/version components/docker-compose/version)"
printf '%s\n' "$out" | grep -qx -- '- \*\*docker-cli / REF\*\*: v29.8.0 -> v29.9.0' \
  || { echo "FAIL CRITICAL2: docker-cli REF not prefixed with its component name: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*docker-compose / REF\*\*: v5.5.1 -> v2.40.0' \
  || { echo "FAIL CRITICAL2: docker-compose REF not prefixed with its component name: $out"; exit 1; }
printf '%s\n' "$out" | grep -q -- '- \*\*REF\*\*:' \
  && { echo "FAIL CRITICAL2: an unprefixed, ambiguous REF bullet leaked: $out"; exit 1; }
printf '%s\n' "$out" | grep -q -- '- \*\*DIGEST\*\*:' \
  && { echo "FAIL CRITICAL2: an unprefixed, ambiguous DIGEST bullet leaked: $out"; exit 1; }
cd "$work"; rm -rf "$work6"

# --- G1 review round, ALSO FIX: exclkey uses the LONGEST match, like pins.sh and repackage-decision.sh
# ${arg#*:} (shortest) would leave the own-upstream KEY itself carrying a stray colon undetected if a
# path ever had one; ${arg##*:} (longest) is what pins.sh and repackage-decision.sh both use.
work7="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; cd "$work7"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
printf 'SWIFT_VERSION="6.3.3"\nLLVM_SHA="aaaa"\n' > pins.env
git add -A; git commit -qm base; git tag base
printf 'SWIFT_VERSION="6.3.4"\nLLVM_SHA="bbbb"\n' > pins.env
out="$(sh "$S" base "pins.env:SWIFT_VERSION")"
printf '%s\n' "$out" | grep -q 'SWIFT_VERSION' \
  && { echo "FAIL longest-match exclkey: SWIFT_VERSION leaked: $out"; exit 1; }
cd "$work"; rm -rf "$work7"

# --- G1 review round, ALSO FIX: a brand-new KV pin file must also honour exclkey -----------------
# A first-time pins.env (absent at the previous release) used to print a single "added" bullet with
# the file's first line as its value -- which could BE the own-upstream key's own literal value. A
# newly-introduced KV file must render per-key, excluding $exclkey, exactly like an existing one.
work8="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; cd "$work8"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
git commit -q --allow-empty -m base; git tag base
printf 'SWIFT_VERSION="6.3.3"\nLLVM_SHA="aaaa"\n' > pins.env
out="$(sh "$S" base "pins.env:SWIFT_VERSION")"
printf '%s\n' "$out" | grep -q 'SWIFT_VERSION' \
  && { echo "FAIL new-file exclkey: SWIFT_VERSION leaked on a brand-new pins.env: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*LLVM_SHA\*\*: added (aaaa)' \
  || { echo "FAIL new-file exclkey: the real ingredient key LLVM_SHA was dropped: $out"; exit 1; }
cd "$work"; rm -rf "$work8"

# --- G1 review round: a .sh pin with NO assignment lines at all -- DELIBERATE CHOICE --------------
# Before content-based dispatch, EVERY .sh file always took the per-key branch regardless of content,
# so a .sh with zero KEY=VALUE lines produced NO bullet at all when its bytes changed (assignments()
# extracts nothing from either side, so the diff is empty). Content-based dispatch now falls through
# such a file to the opaque byte-delta branch instead. DECISION: prefer the byte delta. This whole fix
# exists because release-notes.sh's own doctrine is "a release that says less than the truth is the
# defect this removes" (see its header) -- a file explicitly watched as a pin that changed and says
# NOTHING is the same silent-gap shape, just through dispatch instead of a broken hook. A vague-but-
# honest "updated (N -> M bytes)" is strictly more truthful than silence.
work9="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; cd "$work9"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
printf '#!/bin/sh\necho hello\n' > noop.sh
git add -A; git commit -qm base; git tag base
printf '#!/bin/sh\necho hello world\n' > noop.sh
out="$(sh "$S" base noop.sh)"
printf '%s\n' "$out" | grep -q -- '- \*\*noop.sh\*\*: updated (' \
  || { echo "FAIL .sh-no-assignments: expected a byte delta (deliberate choice), got: $out"; exit 1; }
cd "$work"; rm -rf "$work9"

# --- a pin that became DERIVED must not be announced as removed ---------------------------------
# assignments() deliberately drops any value carrying $ or a backtick -- rewriting a derivation is a
# code change, not an ingredient move -- but the removal walk used to read "absent from the literal
# set" as "removed": SWIFT_TAG going from swift-6.3.3-RELEASE to "swift-${SWIFT_VERSION}-RELEASE"
# (exactly the family's derive-never-repeat convention) was reported as a removed pin, which is
# false -- the build still uses SWIFT_TAG, just no longer as a literal. GONE, which really does stop
# being assigned, must still say "removed"; LLVM_BRANCH, unchanged, must produce no bullet at all.
work10="$(mktemp -d "${TMPDIR:-/tmp}/ingredient-notes-tes.XXXXXX")"; cd "$work10"
git init -q -b main .
git config user.email t@example.com; git config user.name tester
cat > versions.sh <<'SH'
SWIFT_VERSION=6.3.3
SWIFT_TAG=swift-6.3.3-RELEASE
LLVM_BRANCH=swift/release/6.3
GONE=1.2.3
SH
git add -A; git commit -qm base; git tag base
cat > versions.sh <<'SH'
SWIFT_VERSION=6.3.4
SWIFT_TAG="swift-${SWIFT_VERSION}-RELEASE"
LLVM_BRANCH=swift/release/6.3
SH
out="$(sh "$S" base versions.sh)"
printf '%s\n' "$out" | grep -qx -- '- \*\*SWIFT_VERSION\*\*: 6.3.3 -> 6.3.4' \
  || { echo "FAIL derived: a moved literal is still reported as a move: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*SWIFT_TAG\*\*: now derived (was swift-6.3.3-RELEASE)' \
  || { echo "FAIL derived: literal -> derived must say derived, not removed: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'SWIFT_TAG.*removed' \
  && { echo "FAIL derived: SWIFT_TAG is still assigned; calling it removed is false: $out"; exit 1; }
printf '%s\n' "$out" | grep -qx -- '- \*\*GONE\*\*: removed' \
  || { echo "FAIL derived: a key that is genuinely gone is still reported as removed: $out"; exit 1; }
printf '%s\n' "$out" | grep -q 'LLVM_BRANCH' \
  && { echo "FAIL derived: an unchanged key must produce no bullet: $out"; exit 1; }
cd "$work"; rm -rf "$work10"

echo "PASS: ingredient-notes"
