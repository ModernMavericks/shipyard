#!/usr/bin/env bats
# Unit tests for scripts/assert_binary_compatible.sh. Builds tiny x86_64/10.9 fixture Mach-Os
# with controlled symbols. If the host clang cannot emit an x86_64/10.9 slice, the
# arch/min-OS-dependent cases skip, but the symbol logic still runs.

setup() {
  GUARD="$BATS_TEST_DIRNAME/../scripts/assert_binary_compatible.sh"
  WORK="$(mktemp -d -t compat_guard_test)"
  CC=$(command -v clang || command -v cc)
  printf 'int main(void){return 0;}\n' > "$WORK/clean.c"
  if ! "$CC" -arch x86_64 -mmacosx-version-min=10.9 "$WORK/clean.c" -o "$WORK/clean" 2>/dev/null; then
    HAVE_X8609=0
  else
    HAVE_X8609=1
  fi
  printf 'int mav_test_shim(void){return 0;}\nint main(void){return mav_test_shim();}\n' > "$WORK/shim.c"
  "$CC" -arch x86_64 -mmacosx-version-min=10.9 "$WORK/shim.c" -o "$WORK/shim" 2>/dev/null || true
  printf 'extern int mav_test_post109(void);\nint main(void){return mav_test_post109();}\n' > "$WORK/leak.c"
  "$CC" -arch x86_64 -mmacosx-version-min=10.9 -Wl,-undefined,dynamic_lookup "$WORK/leak.c" -o "$WORK/leak" 2>/dev/null || true
  # ObjC fixtures: a post-10.9 selector (labelColor, 10.10+) vs a 10.9-safe one (blackColor). These
  # dispatch via objc_msgSend, so nm can't see them -- the selector scan must catch labelColor.
  printf '#import <AppKit/AppKit.h>\nint main(void){(void)[NSColor labelColor];return 0;}\n' > "$WORK/sel_bad.m"
  "$CC" -arch x86_64 -mmacosx-version-min=10.9 -framework AppKit "$WORK/sel_bad.m" -o "$WORK/sel_bad" 2>/dev/null || true
  printf '#import <AppKit/AppKit.h>\nint main(void){(void)[NSColor blackColor];return 0;}\n' > "$WORK/sel_ok.m"
  "$CC" -arch x86_64 -mmacosx-version-min=10.9 -framework AppKit "$WORK/sel_ok.m" -o "$WORK/sel_ok" 2>/dev/null || true
}
teardown() { rm -rf "$WORK"; }

@test "clean binary passes" {
  [ "$HAVE_X8609" = 1 ] || skip "host cannot emit x86_64/10.9"
  run sh "$GUARD" "$WORK/clean"
  [ "$status" -eq 0 ]
}

@test "post-10.9 undefined import is caught via MAVERICKS_POST_10_9_SYMBOLS" {
  [ -f "$WORK/leak" ] || skip "leak fixture did not build"
  run env MAVERICKS_POST_10_9_SYMBOLS='_mav_test_post109' sh "$GUARD" "$WORK/leak"
  [ "$status" -ne 0 ]
}

@test "MAVERICKS_REQUIRE_DEFINED_SYMBOLS passes when the symbol is defined" {
  [ -f "$WORK/shim" ] || skip "shim fixture did not build"
  run env MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_mav_test_shim' sh "$GUARD" "$WORK/shim"
  [ "$status" -eq 0 ]
}

@test "MAVERICKS_REQUIRE_DEFINED_SYMBOLS fails when the symbol is absent" {
  [ "$HAVE_X8609" = 1 ] || skip "host cannot emit x86_64/10.9"
  run env MAVERICKS_REQUIRE_DEFINED_SYMBOLS='_mav_test_shim' sh "$GUARD" "$WORK/clean"
  [ "$status" -ne 0 ]
}

@test "post-10.9 ObjC selector (labelColor) is caught -- nm can't see it" {
  [ -f "$WORK/sel_bad" ] || skip "sel_bad fixture did not build (no AppKit?)"
  run sh "$GUARD" "$WORK/sel_bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *labelColor* ]] || false
}

@test "a 10.9-safe selector (blackColor) passes the selector scan" {
  [ -f "$WORK/sel_ok" ] || skip "sel_ok fixture did not build"
  run sh "$GUARD" "$WORK/sel_ok"
  [ "$status" -eq 0 ]
}

@test "MAVERICKS_ALLOW_SELECTORS allowlists a respondsToSelector-guarded selector" {
  [ -f "$WORK/sel_bad" ] || skip "sel_bad fixture did not build"
  run env MAVERICKS_ALLOW_SELECTORS=labelColor sh "$GUARD" "$WORK/sel_bad"
  [ "$status" -eq 0 ]
}
