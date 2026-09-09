#!/bin/sh
# The replacement check 10 recommends for `lipo -archs` must actually be equivalent, on BOTH the
# platform that lacks -archs and the platform CI runs on. Asserting the rule's advice, not the rule:
# a lint that names a fix nobody verified is how the next 10.9 gap gets introduced by the fix for the
# last one.
#
#   10.9  -> -archs is fatal, so only the -info idiom is exercised (it must still yield real archs).
#   Tahoe -> both exist, so the idiom's output must EQUAL what -archs prints.
set -eu
command -v lipo >/dev/null 2>&1 || { echo "no lipo -- skipping"; exit 77; }

# A binary every macOS has, and a fat one where possible: the idiom must handle both the "Non-fat
# file: X is architecture: a" and "Architectures in the fat file: X are: a b" spellings.
bin=/bin/sh
[ -x "$bin" ] || { echo "no $bin -- skipping"; exit 77; }

idiom="$(lipo -info "$bin" 2>/dev/null | sed 's/.*: //')"
[ -n "$idiom" ] || { echo "FAIL: -info idiom produced nothing for $bin"; exit 1; }
case "$idiom" in
  *x86_64*|*arm64*|*i386*) : ;;
  *) echo "FAIL: -info idiom gave '$idiom', which names no architecture"; exit 1 ;;
esac

if lipo -archs "$bin" >/dev/null 2>&1; then
  archs="$(lipo -archs "$bin" 2>/dev/null)"
  # Compare as SETS: -info separates with spaces and can leave a trailing one, -archs need not agree
  # on order or padding, and neither promises a stable sequence.
  norm() { tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' '; }
  a="$(printf '%s' "$idiom" | norm)"; b="$(printf '%s' "$archs" | norm)"
  [ "$a" = "$b" ] || { echo "FAIL: idiom '$a' != lipo -archs '$b'"; exit 1; }
  echo "PASS: lipo-archs-idiom (-archs present; idiom matches: $a)"
else
  echo "PASS: lipo-archs-idiom (no -archs here, as on 10.9; idiom yields: $idiom)"
fi
