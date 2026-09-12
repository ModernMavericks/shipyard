#!/bin/sh
# Assert that a release's artifacts match ITSELF, its NEIGHBOURS, and its SIBLINGS.
#
# This constrains OUTPUTS, not methods. Products here build in genuinely different ways -- a Go
# toolchain, a boot2docker iso, libswiftCore, an openssh -- and making those look alike would buy
# uniformity by inventing a bespoke "kind" per product. What must not vary is what comes out:
# a release whose .pkg, appcast, checksums and tag disagree is incoherent no matter how it was built.
#
# Every piece here already exists somewhere -- the compat guard checks binaries, set_install_floor
# stamps a floor, sign_and_appcast signs, publish-release checksums -- but nothing asserted they agree
# WITH EACH OTHER. That gap is where a release can be internally wrong while every step is green.
#
# Reads a FACT STREAM on stdin (see artifact-facts.sh), one record per line:
#   expected   <version>                                  the version this release claims to be
#   pkg        <file> <version> <floor> <identifier>      one per shipped .pkg
#   appcast    <file> <version> <enclosure> <length>      one per Sparkle appcast
#   asset      <file> <bytes>                             one per file that will be published
#   notes-render <notes-file> <sha256>                     digest of gen_appcast.sh --render-notes
#   appcast-notes <appcast-file> [<sha256>]                digest of the appcast's <description> CDATA
#   deviation  <check> <reason...>                        a declared, reasoned departure
#
# Facts rather than files so the agreement logic is testable without fabricating real .pkg files;
# extraction is thin and exercised for real at package time.
#   usage: artifact-facts.sh dist "$VER" | check-artifact-conformance.sh
set -eu

tmp="$(mktemp -d "${TMPDIR:-/tmp}/conformance.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT  # template: 10.9 BSD mktemp requires one
facts="$tmp/facts"; cat > "$facts"

status=0
fail() {  # $1 = check name, $2 = message, $3 = the artifact it concerns (optional)
  # A deviation excuses only its OWN check, only for the artifacts it names, and only with a reason.
  # An unexplained departure is indistinguishable from a mistake, and an unscoped one silently covers
  # artifacts nobody meant to excuse: swift-toolchain republishes swift.org's .pkg verbatim, which must
  # not license the things it builds itself to drift.
  _c="$1"; _msg="$2"; _file="${3:-}"
  # exact-check deviation (applies to every artifact)
  reason="$(sed -n "s/^deviation ${_c} \(..*\)$/\1/p" "$facts" | head -1)"
  if [ -z "$reason" ] && [ -n "$_file" ]; then
    # scoped: deviation <check>:<glob>
    while IFS= read -r line; do
      # line: `deviation <check>:<glob> <reason...>` -- strip the fixed prefix first, then split the
      # glob from the reason. Taking the first WORD of the whole line yields "deviation".
      rest="${line#deviation ${_c}:}"
      glob="${rest%% *}"
      why="${rest#* }"
      [ "$why" = "$rest" ] && why=""      # no space => a glob with no reason, which is not a deviation
      case "$_file" in
        $glob) [ -n "$why" ] && reason="$why" && break ;;
      esac
    done <<EOF
$(grep "^deviation ${_c}:" "$facts" || true)
EOF
  fi
  if [ -n "$reason" ]; then
    echo "conformance: ${_c}: DECLARED DEVIATION${_file:+ (${_file})} -- $reason"
    return 0
  fi
  if grep -q "^deviation ${_c}\$" "$facts"; then
    echo "conformance: ${_c}: deviation declared with no reason -- state why, or fix the artifact" >&2
    status=1; return 0
  fi
  echo "conformance: ${_c}: ${_msg}" >&2
  status=1
}

expected="$(sed -n 's/^expected \(..*\)$/\1/p' "$facts" | head -1)"
[ -n "$expected" ] || { echo "conformance: no expected version in the fact stream" >&2; exit 2; }

# --- SIBLINGS: the family's version scheme --------------------------------------------------------
case "$expected" in
  *-mavericks.[0-9]*) : ;;
  *) fail scheme "version '$expected' is not <upstream>-mavericks.N" ;;
esac

# --- ITSELF / NEIGHBOURS: every .pkg agrees with the tag, the floor, and the identifier scheme -----
while read -r kind file ver floor ident; do
  [ "$kind" = pkg ] || continue
  [ "$ver" = "$expected" ] \
    || fail version "$file says version $ver, the release is $expected" "$file"
  # A PRODUCT ARCHIVE declares its floor in Distribution and it must be 10.9.5. A COMPONENT package
  # (PackageInfo, no Distribution) cannot declare one at all -- floors are a productbuild concept --
  # so its effective minimum lives in the appcast that ships it. golang's cross product is exactly
  # that case: it TARGETS 10.9 but RUNS on 11.0+, so demanding 10.9.5 of it would be wrong.
  if [ "$floor" = none ]; then
    grep -q "^appcast .* $file [0-9][0-9]* [0-9]" "$facts" \
      || fail floor "$file declares no install floor, and no appcast declares a minimum system version for it" "$file"
  else
    [ "$floor" = 10.9.5 ] \
      || fail floor "$file declares an install floor of $floor, not 10.9.5" "$file"
  fi
  case "$ident" in
    dev.modernmavericks.*) : ;;
    *) fail identifier "$file has identifier '$ident', outside dev.modernmavericks.*" "$file" ;;
  esac
done < "$facts"

# --- ITSELF: the appcast describes THIS release, and an asset that exists at the size it claims ----
while read -r kind file ver enclosure length minos; do
  [ "$kind" = appcast ] || continue
  [ "$ver" = "$expected" ] \
    || fail version "$file advertises version $ver, the release is $expected" "$file"
  actual="$(sed -n "s/^asset $enclosure \(..*\)$/\1/p" "$facts" | head -1)"
  if [ -z "$actual" ]; then
    fail enclosure "$file points at '$enclosure', which is not among the published assets" "$file"
  elif [ "$actual" != "$length" ]; then
    fail length "$file says '$enclosure' is $length bytes; it is $actual" "$file"
  fi
done < "$facts"

# --- ITSELF: the appcast points INTO this release --------------------------------------------------
# An enclosure URL carries the release tag. Naming another release makes the feed serve users a build
# other than the one just published -- and every other check still passes, because both artifacts are
# individually fine. Only the relationship between them is wrong.
while read -r kind file url; do
  [ "$kind" = enclosure-url ] || continue
  case "$url" in
    */download/"$expected"/*) : ;;
    *) fail enclosure-url "$file points outside this release: $url" "$file" ;;
  esac
done < "$facts"

# --- ITSELF: the Sparkle <description> and the GitHub Release body are the same notes rendered once -
# They are built from the same dist/RELEASE_NOTES.md today, which is what makes this assertion cheap --
# and what makes it worth having, because nothing else would notice the day that stops being true. A
# 10.9 user deciding whether to take an update reads the appcast; a maintainer reads the Release page.
# An appcast fact with no notes-render to compare against is left alone: a repo that does not stage a
# notes file into dist/ is caught by release-assets.sh at publish time, not here.
render="$(sed -n 's/^notes-render [^ ]* \(..*\)$/\1/p' "$facts" | head -1)"
if [ -n "$render" ]; then
  while read -r _ file digest; do
    [ -n "$file" ] || continue
    if [ -z "$digest" ]; then
      fail notes "$file carries no <description>; that is what a 10.9 user reads in the update dialog" "$file"
    elif [ "$digest" != "$render" ]; then
      fail notes "$file's <description> is not the release body; Sparkle users and the Release page would read different notes" "$file"
    fi
  done <<EOF
$(grep '^appcast-notes ' "$facts" || true)
EOF
fi

# --- SIBLINGS: where a repo ships parallel upstream lines, the line IS the product -----------------
# go126 and go127 must not share an identifier, or two products claim one install and an updater
# cannot tell which it is looking at.
line="$(sed -n 's/^line \(..*\)$/\1/p' "$facts" | head -1)"
if [ -n "$line" ]; then
  while read -r kind file ver floor ident; do
    [ "$kind" = pkg ] || continue
    case "$ident" in
      *"$line"*) : ;;
      *) fail line "$file has identifier '$ident', which does not carry line $line" "$file" ;;
    esac
  done < "$facts"
fi

# --- NEIGHBOURS: variants of one release were built from the same ingredients ----------------------
# The artifacts cannot answer this. golang's native .pkg carries the CA bundle and the shim; its cross
# .pkg legitimately does not, because cross-built apps look at the native prefix. "Same shim, same CA"
# is a claim about INPUTS, which no payload inspection can settle -- so each variant records what it
# used and this compares the records. Keys that SHOULD differ per variant are named, not guessed:
# treating every difference as a fault would make the check unusable and then ignored.
# Say what was compared. "ok" that also means "there were no records" is a check you cannot trust the
# day the records stop shipping -- which is exactly how this one nearly went unnoticed.
bi_files="$(sed -n 's/^build-info \([^ ][^ ]*\) .*/\1/p' "$facts" | sort -u | wc -l | tr -d ' ')"
if [ "$bi_files" -gt 0 ]; then
  echo "conformance: ingredients: compared $bi_files build records"
else
  echo "conformance: ingredients: no build records in this release (nothing to compare)"
fi

per_variant=" variant arch prefix pkg identifier "
for key in $(sed -n 's/^build-info [^ ][^ ]* \([^ ][^ ]*\) .*/\1/p' "$facts" | sort -u); do
  case "$per_variant" in *" $key "*) continue ;; esac
  vals="$(sed -n "s/^build-info [^ ][^ ]* $key \(..*\)$/\1/p" "$facts" | sort -u)"
  [ "$(printf '%s\n' "$vals" | wc -l | tr -d ' ')" -le 1 ] && continue
  files="$(sed -n "s/^build-info \([^ ][^ ]*\) $key .*/\1/p" "$facts" | tr '\n' ' ')"
  fail ingredients "variants disagree about $key: $(printf '%s' "$vals" | tr '\n' '/') (from $files)"
done

[ "$status" -eq 0 ] && echo "conformance: ok — $expected"
exit "$status"
