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
clang -arch x86_64h -o "$w/m-x86_64h" "$w/m.c" 2>/dev/null || true  # x86_64h is optional for this test

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

# Identical thin x86_64 is refused when --require-archs demands both.
mk "$w/c" "$w/m-x86_64"; mk "$w/d" "$w/m-x86_64"
if sh "$S" --a "$w/c" --b "$w/d" --out "$w/o3" --require-archs "i386 x86_64" >/dev/null 2>&1; then
  echo "FAIL: identical thin x86_64 with --require-archs \"i386 x86_64\" must be refused"; exit 1
fi
[ ! -d "$w/o3" ] || { echo "FAIL: failed merge must not leave OUT dir"; exit 1; }

# i386+x86_64 merge with --require-archs passes.
sh "$S" --a "$w/a" --b "$w/b" --out "$w/o4" --allow-differ App.app/Contents/Info.plist --require-archs "i386 x86_64" >/dev/null
lipo -info "$w/o4/bin/tool" | grep -q 'i386' && lipo -info "$w/o4/bin/tool" | grep -q 'x86_64' \
  || { echo "FAIL: o4/bin/tool is not universal: $(lipo -info "$w/o4/bin/tool")"; exit 1; }

# Genuinely fat identical file (created with lipo -create) passes --require-archs.
lipo -create "$w/m-i386" "$w/m-x86_64" -output "$w/m-fat"
mk "$w/e" "$w/m-fat"; mk "$w/f" "$w/m-fat"
sh "$S" --a "$w/e" --b "$w/f" --out "$w/o5" --require-archs "i386 x86_64" >/dev/null \
  || { echo "FAIL: identical fat frameworks must merge"; exit 1; }
lipo -info "$w/o5/bin/tool" | grep -q 'i386' && lipo -info "$w/o5/bin/tool" | grep -q 'x86_64' \
  || { echo "FAIL: o5/bin/tool is not universal: $(lipo -info "$w/o5/bin/tool")"; exit 1; }

# Two different same-arch Mach-O files fail and leave no OUT.
printf 'int main(void){return 1;}\n' > "$w/m2.c"
clang -arch x86_64 -o "$w/m2-x86_64" "$w/m2.c"
mk "$w/g" "$w/m-x86_64"; mk "$w/h" "$w/m2-x86_64"
if sh "$S" --a "$w/g" --b "$w/h" --out "$w/o6" >/dev/null 2>&1; then
  echo "FAIL: different x86_64 files must fail lipo"; exit 1
fi
[ ! -d "$w/o6" ] || { echo "FAIL: failed lipo must not leave OUT dir"; exit 1; }

# x86_64h does NOT satisfy --require-archs "x86_64": the arch requirement is exact-token, not substring.
if [ -f "$w/m-x86_64h" ]; then
  lipo -create "$w/m-i386" "$w/m-x86_64h" -output "$w/m-i386-x86_64h"
  mk "$w/k" "$w/m-i386-x86_64h"; mk "$w/l" "$w/m-i386-x86_64h"
  if sh "$S" --a "$w/k" --b "$w/l" --out "$w/o8" --require-archs "i386 x86_64" >/dev/null 2>&1; then
    echo "FAIL: i386+x86_64h must not satisfy --require-archs \"i386 x86_64\""; exit 1
  fi
  [ ! -d "$w/o8" ] || { echo "FAIL: failed arch validation must not leave OUT dir"; exit 1; }
fi

# Path name must not be confused with architecture list: a file under a directory named
# x86_64h with architecture i386+x86_64 must NOT satisfy --require-archs "i386 x86_64h".
mkdir -p "$w/x86_64h-dir"
lipo -create "$w/m-i386" "$w/m-x86_64" -output "$w/x86_64h-dir/fat-binary"
mkdir -p "$w/m-path-a/x86_64h-dir" "$w/m-path-b/x86_64h-dir"
cp "$w/x86_64h-dir/fat-binary" "$w/m-path-a/x86_64h-dir/bin"
cp "$w/x86_64h-dir/fat-binary" "$w/m-path-b/x86_64h-dir/bin"
if sh "$S" --a "$w/m-path-a" --b "$w/m-path-b" --out "$w/o9" --require-archs "i386 x86_64h" >/dev/null 2>&1; then
  echo "FAIL: x86_64h in path must not satisfy --require-archs for x86_64h architecture"; exit 1
fi
[ ! -d "$w/o9" ] || { echo "FAIL: failed arch validation must not leave OUT dir"; exit 1; }

# A file in only one tree is refused.
mk "$w/i" "$w/m-x86_64"; mk "$w/j" "$w/m-i386"; echo extra > "$w/i/share/x/only-in-a"
if sh "$S" --a "$w/i" --b "$w/j" --out "$w/o7" >/dev/null 2>&1; then
  echo "FAIL: a file missing from one tree must be refused"; exit 1
fi

echo "PASS: lipo-merge-tree"
