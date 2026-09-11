#!/bin/sh
# Two builds of one thing, differing ONLY by architecture, merge into one universal tree. Anything
# else differing means they are not two slices of one build -- refuse, unless the caller declared
# that one path legitimately differs (an app's Info.plist carries each slice's minimum OS).
#
# Uses i386 + x86_64 Mach-O, which this 10.9 box's clang can make; the merge logic is arch-agnostic.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
S="$here/../scripts/lipo-merge-tree.sh"
command -v clang >/dev/null 2>&1 || { echo "SKIP: no clang"; exit 77; }
w="$(mktemp -d "${TMPDIR:-/tmp}/lipo-merge-test.XXXXXX")"; trap 'rm -rf "$w"' EXIT
printf 'int main(void){return 0;}\n' > "$w/m.c"
clang -arch i386   -o "$w/m-i386"   "$w/m.c" 2>/dev/null || { echo "SKIP: cannot build i386 here"; exit 77; }
clang -arch x86_64 -o "$w/m-x86_64" "$w/m.c"

mk() {  # $1 = tree  $2 = the Mach-O to put at bin/tool
  mkdir -p "$1/bin" "$1/share/x" "$1/App.app/Contents"
  cp "$2" "$1/bin/tool"
  echo same > "$1/share/x/data.txt"
  ln -s tool "$1/bin/tool-link"
}
mk "$w/a" "$w/m-x86_64"; mk "$w/b" "$w/m-i386"
echo a > "$w/a/App.app/Contents/Info.plist"; echo b > "$w/b/App.app/Contents/Info.plist"

# A differing non-Mach-O file is refused...
if sh "$S" --a "$w/a" --b "$w/b" --out "$w/o1" >/dev/null 2>&1; then
  echo "FAIL: an undeclared difference in a non-Mach-O file must be refused"; exit 1
fi
# ...unless declared, and then A's copy wins.
sh "$S" --a "$w/a" --b "$w/b" --out "$w/o2" --allow-differ App.app/Contents/Info.plist >/dev/null
lipo -info "$w/o2/bin/tool" | grep -q 'i386' && lipo -info "$w/o2/bin/tool" | grep -q 'x86_64' \
  || { echo "FAIL: bin/tool is not universal: $(lipo -info "$w/o2/bin/tool")"; exit 1; }
[ "$(cat "$w/o2/App.app/Contents/Info.plist")" = a ] || { echo "FAIL: a declared difference must take A's copy"; exit 1; }
[ "$(cat "$w/o2/share/x/data.txt")" = same ] || { echo "FAIL: identical files must be copied"; exit 1; }
[ -L "$w/o2/bin/tool-link" ] || { echo "FAIL: symlinks must stay symlinks"; exit 1; }

# Identical Mach-O (e.g. an already-fat framework both builds embed) is copied, not re-lipo'd.
mk "$w/c" "$w/m-x86_64"; mk "$w/d" "$w/m-x86_64"
sh "$S" --a "$w/c" --b "$w/d" --out "$w/o3" >/dev/null \
  || { echo "FAIL: identical trees must merge"; exit 1; }

# A file in only one tree is refused.
mk "$w/e" "$w/m-x86_64"; mk "$w/f" "$w/m-i386"; echo extra > "$w/e/share/x/only-in-a"
if sh "$S" --a "$w/e" --b "$w/f" --out "$w/o4" >/dev/null 2>&1; then
  echo "FAIL: a file missing from one tree must be refused"; exit 1
fi

echo "PASS: lipo-merge-tree"
