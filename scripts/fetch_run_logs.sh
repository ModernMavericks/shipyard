#!/bin/sh
# Fetch the log of every FINISHED job in a workflow run, one file each, for scan-for-key.yml to scan:
#
#   fetch_run_logs.sh REPO RUN_ID DIR      ->  DIR/job-<id>.log ...
#
# Finished only: the job running this is still writing its own log, and it never touches the key.
# Needs gh with a token that can read the run's logs -- `actions: read`, which a public repo's logs
# still require (anonymous requests get 403). A run with no finished job is an error: nothing to scan
# is not a pass. CI-only.
set -eu
[ "$#" -eq 3 ] || { echo "usage: fetch_run_logs.sh REPO RUN_ID DIR" >&2; exit 2; }
REPO="$1"; RUN="$2"; DIR="$3"
mkdir -p "$DIR"

ids="$(gh api "repos/$REPO/actions/runs/$RUN/jobs" --paginate \
         --jq '.jobs[] | select(.status == "completed") | .id')" \
  || { echo "fetch_run_logs: cannot list the jobs of $REPO run $RUN" >&2; exit 1; }
[ -n "$ids" ] || { echo "fetch_run_logs: run $RUN has no finished job -- nothing to scan is not a pass" >&2; exit 1; }

# --allow-escape-sequences: a build log is colored, and without it gh refuses to print the response
# at all ("the response contains terminal escape sequences") -- which is how openssh's first scan died.
# On a failure, gh's own stderr says why; guessing a reason here once sent the diagnosis the wrong way.
for id in $ids; do
  gh api "repos/$REPO/actions/jobs/$id/logs" --allow-escape-sequences > "$DIR/job-$id.log" \
    || { echo "fetch_run_logs: cannot fetch job $id's log (gh's reason is above)" >&2; exit 1; }
done
echo "fetch_run_logs: $(echo "$ids" | wc -l | tr -d ' ') finished job log(s) from $REPO run $RUN" >&2
