#!/bin/sh
# Print the version mode for THIS run: "local" (a repackage, N+1) or "auto" (the shipped N).
#
#   VER="$(sh "$SHIPYARD_SCRIPTS/resolve-version.sh" "$(sh "$SHIPYARD_SCRIPTS/release-mode.sh")")"
#
# Exists because EVERY JOB IN ONE RUN MUST ANSWER THIS IDENTICALLY, and container-tools proved that
# per-job reasoning does not: build-macos knew a repackage was in progress and resolved N+1 (.15),
# while build-iso -- a separate job with no such knowledge -- resolved the shipped N (.14). Two halves
# of one .pkg, built in one run, reporting different versions.
#
# The alternative was making every job depend on the one that decides, which serialises builds that
# have no reason to wait for each other. This is the same decision made from the same event, so
# parallel jobs land on the same answer without a dependency between them.
#
#   env in: GITHUB_EVENT_NAME, LOCAL_RELEASE (the workflow's local_release input, as a string)
set -eu

# A repackage is only ever DISPATCHED. A push -- even one carrying the input by accident -- must not
# invent a new N: that would publish a release nobody asked for.
if [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] && [ "${LOCAL_RELEASE:-}" = true ]; then
  echo local
else
  echo auto
fi
