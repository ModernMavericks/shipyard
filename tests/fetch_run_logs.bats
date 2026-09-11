bats_require_minimum_version 1.5.0

# fetch_run_logs.sh REPO RUN_ID DIR: every FINISHED job's log in this run, one file each, for
# scan-for-key.yml to scan. A stand-in `gh` on PATH plays the GitHub API: it answers the jobs listing
# from $T/jobs.txt ("<id> <status> [<conclusion>]" per line; a completed job defaults to success) as
# the real JSON shape, run through the script's own --jq filter by real jq -- so the filter itself is
# under test, not a copy of it -- and each log from $T/logs/<id>. Like the real gh, it refuses to
# print a response carrying terminal escape sequences -- which every colored build log does -- unless
# given --allow-escape-sequences: openssh's first scan died exactly there.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  T="$BATS_TEST_TMPDIR"
  mkdir -p "$T/bin" "$T/logs"
  cat > "$T/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/gh-calls"
case "\$2" in
  repos/acme/widget/actions/runs/42/jobs)
    [ -f "$T/jobs.txt" ] || exit 1
    q=; prev=; for a in "\$@"; do [ "\$prev" = --jq ] && q="\$a"; prev="\$a"; done
    awk 'BEGIN { printf "{\"jobs\":[" }
         { c = \$3 != "" ? "\"" \$3 "\"" : (\$2 == "completed" ? "\"success\"" : "null")
           printf "%s{\"id\":%s,\"status\":\"%s\",\"conclusion\":%s}", (NR > 1 ? "," : ""), \$1, \$2, c }
         END { print "]}" }' "$T/jobs.txt" | jq -r "\$q" ;;
  repos/acme/widget/actions/jobs/*/logs)
    id="\${2#repos/acme/widget/actions/jobs/}"; id="\${id%/logs}"
    [ -f "$T/logs/\$id" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    case " \$* " in
      *" --allow-escape-sequences "*) ;;
      *) if grep -q "\$(printf '\\033')" "$T/logs/\$id"; then
           echo "the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway" >&2
           exit 1
         fi ;;
    esac
    cat "$T/logs/\$id" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$T/bin/gh"
  PATH="$T/bin:$PATH"
}

fetch() { sh "$ROOT/scripts/fetch_run_logs.sh" acme/widget 42 "$T/out"; }

@test "fetches the log of every finished job, and only those" {
  printf '101 completed\n102 completed\n103 in_progress\n' > "$T/jobs.txt"
  echo 'build log' > "$T/logs/101"; echo 'iso log' > "$T/logs/102"
  run --separate-stderr fetch
  [ "$status" -eq 0 ]
  [ "$(cat "$T/out/job-101.log")" = 'build log' ]
  [ "$(cat "$T/out/job-102.log")" = 'iso log' ]
  [ ! -e "$T/out/job-103.log" ]
}

@test "a skipped job is not fetched: it never ran, so it has no log (GitHub 404s it) and no key" {
  # container-tools: build-iso failed, so package was skipped -- and the scan, which runs always(),
  # died fetching package's log, turning one real failure into two red jobs.
  printf '101 completed success\n102 completed skipped\n103 completed failure\n' > "$T/jobs.txt"
  echo 'build log' > "$T/logs/101"; echo 'failed build log' > "$T/logs/103"   # no $T/logs/102
  run --separate-stderr fetch
  [ "$status" -eq 0 ]
  [ -e "$T/out/job-101.log" ]
  [ -e "$T/out/job-103.log" ]
  [ ! -e "$T/out/job-102.log" ]
}

@test "a colored build log (terminal escape sequences) is fetched whole" {
  printf '101 completed\n' > "$T/jobs.txt"
  printf '\033[36;1mcolored\033[0m build log\n' > "$T/logs/101"
  run --separate-stderr fetch
  [ "$status" -eq 0 ]
  [ "$(cat "$T/out/job-101.log")" = "$(printf '\033[36;1mcolored\033[0m build log')" ]
}

@test "asks for every page of jobs, not just the first" {
  printf '101 completed\n' > "$T/jobs.txt"; echo x > "$T/logs/101"
  run --separate-stderr fetch
  [ "$status" -eq 0 ]
  grep -q -- '--paginate' "$T/gh-calls"
}

@test "a run with no finished job is an error: nothing to scan is not a pass" {
  printf '103 in_progress\n' > "$T/jobs.txt"
  run --separate-stderr fetch
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"nothing to scan"* ]] || false
}

@test "a log it cannot fetch is an error, passing on gh's own reason rather than guessing one" {
  printf '101 completed\n' > "$T/jobs.txt"      # and no $T/logs/101
  run --separate-stderr fetch
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"HTTP 404: Not Found"* ]] || false
}

@test "a jobs listing it cannot fetch is an error" {
  run --separate-stderr fetch                     # no $T/jobs.txt
  [ "$status" -eq 1 ]
}
