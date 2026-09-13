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
#   notes-render <notes-file> <sha256>                    digest of gen_appcast.sh --render-notes
#   appcast-notes <appcast-file> [<sha256>]               digest of the appcast's <description> CDATA
#   deviation  <check> <reason...>                        a declared, reasoned departure
#   abort      <reason...>                                the producer gave up here, and why
#   end-of-facts                                          the producer ran to completion (LAST line)
#
# Facts rather than files so the agreement logic is testable without fabricating real .pkg files;
# extraction is thin and exercised for real at package time.
#   usage: artifact-facts.sh dist "$VER" | check-artifact-conformance.sh
set -eu

tmp="$(mktemp -d "${TMPDIR:-/tmp}/conformance.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT  # template: 10.9 BSD mktemp requires one
facts="$tmp/facts"; cat > "$facts"

# --- THE STREAM IS COMPLETE -----------------------------------------------------------------------
# FIRST, before anything is judged: every check below is a "stay quiet when there are no records"
# check, so a stream that simply STOPS passes them all.
#
# That is not hypothetical. artifact-facts.sh runs upstream of a pipe in every consumer, a pipeline's
# exit status is its LAST command's, and no consumer sets pipefail (GitHub's default `run:` shell is
# `bash -e {0}`: errexit WITHOUT pipefail). The producer's exit status is therefore DISCARDED, and
# dying merely truncates its output. RELEASE_NOTES.md sorts first in dist/*, so a truncation there
# lands before any pkg, appcast or enclosure-url record exists -- and a dist with an empty notes
# file, an appcast describing something else and an enclosure pointing at another release printed
# "conformance: ok" with everything switched off.
#
# So the producer ends a successful run with `end-of-facts` and we refuse a stream without it. This
# is structural: it catches truncation from ANY cause, not an enumerated list of known-bad exits.
#
# Deliberately NOT routed through fail(): a deviation must not be able to excuse it. Deviations are
# emitted EARLY (they come from INGREDIENTS.md, before dist/ is walked), so they SURVIVE a truncation
# -- `deviation end-of-facts ...` would switch off the very check that notices the switch-off. And
# exit, rather than accumulating: with no records there is nothing else worth reporting.
# An `abort` record means the producer gave up, so the stream is untrustworthy whatever else it says.
# Checked SEPARATELY from the sentinel, and first: normally the two cannot coexist, because a producer
# that aborts never reaches its sentinel -- so a stream carrying both has a completion marker that did
# not come from a completed run. One way to get there: a file in dist/ whose NAME contains a newline
# splits its own `asset` record and can forge a bare `end-of-facts` line. Keying only on the sentinel
# read that stream as "conformance: ok" while the producer was saying it had failed, which is the same
# quiet switch-off this whole guard exists to stop.
why="$(sed -n 's/^abort \(..*\)$/\1/p' "$facts" | head -1)"
if [ -n "$why" ]; then
  echo "conformance: artifact-facts.sh aborted: $why" >&2
  echo "conformance: the fact stream cannot be trusted; nothing was checked" >&2
  exit 2
fi

if ! grep -q '^end-of-facts$' "$facts"; then
  echo "conformance: the fact stream is incomplete -- artifact-facts.sh did not run to completion (no end-of-facts record); nothing was checked" >&2
  exit 2
fi

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
#
# Say what was compared, mirroring the ingredients check below: an "ok" that also means "there was
# nothing to look at" is a check nobody can trust the day the coupling actually breaks -- which is
# exactly how the ingredients check nearly went unnoticed once already.
#
# A missing notes-render fact is NOT quietly skipped when an appcast-notes fact exists: the notes
# file's basename is a per-repo INPUT (release-assets.sh's --notes-file defaults to RELEASE_NOTES.md
# but is not required to be it), while artifact-facts.sh's RELEASE_NOTES.md case matches only that
# default. A product staging its body under any other name would otherwise get a green run with this
# entire layer silently switched off -- an appcast carrying a description with nothing to compare it
# against is the same "records stopped shipping" shape the ingredients check refuses to pass through
# in silence, so this fails outright rather than merely announcing itself. (A repo with NO appcast at
# all, and so no appcast-notes fact either, has nothing to compare either way -- that is fine.)
render="$(sed -n 's/^notes-render [^ ]* \(..*\)$/\1/p' "$facts" | head -1)"
appcast_notes="$(grep '^appcast-notes ' "$facts" || true)"
if [ -n "$render" ]; then
  compared=0
  while read -r _ file digest; do
    [ -n "$file" ] || continue
    compared=$((compared + 1))
    if [ -z "$digest" ]; then
      fail notes "$file carries no <description>; that is what a 10.9 user reads in the update dialog" "$file"
    elif [ "$digest" != "$render" ]; then
      fail notes "$file's <description> is not the release body; Sparkle users and the Release page would read different notes" "$file"
    fi
  done <<EOF
$appcast_notes
EOF
  if [ "$compared" -gt 0 ]; then
    echo "conformance: notes: compared $compared appcast description(s) against the rendered release body"
  else
    echo "conformance: notes: no appcast in this release (nothing to compare)"
  fi
elif [ -n "$appcast_notes" ]; then
  while read -r _ file _digest; do
    [ -n "$file" ] || continue
    fail notes "$file carries a description, but no notes-render fact exists to compare it against -- the notes file may be staged under a name this check does not recognize" "$file"
  done <<EOF
$appcast_notes
EOF
else
  echo "conformance: notes: no notes file staged (nothing to compare)"
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
