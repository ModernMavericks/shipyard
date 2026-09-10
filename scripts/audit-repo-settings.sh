#!/bin/sh
# The two family conventions the gate structurally CANNOT see.
#
# check-family-conventions.sh reads a checkout, so every rule it enforces is file-shaped. These two
# are not: they are GitHub repo state, reachable only through the API.
#
#   1. "Allow auto-merge" -- OFF by GitHub default on a new repo.
#   2. branch protection on main requiring the PR build check.
#
# Renovate's automerge needs BOTH. Neither can be set by a preset, so a renovate.json template that
# is identical across the org still leaves them wrong -- and they drifted exactly that way: four
# repos created 2026-08-02..08-04 had neither, so their bumps never merged. signal-desktop's Signal
# 8.26.0 sat green and unmerged for a MONTH, and nothing anywhere went red about it.
#
# Not a CI gate, deliberately: reading branch protection requires ADMIN, and a workflow's default
# GITHUB_TOKEN does not have it. This runs with a human's `gh` credentials instead. That makes it a
# thing someone must remember to run, which is weaker than a gate -- so it prints a verdict line and
# exits non-zero when anything is off, to be usable from a scheduled job with a PAT later.
#   usage: audit-repo-settings.sh [org]        (default: ModernMavericks)
set -eu
org="${1:-ModernMavericks}"
command -v gh >/dev/null 2>&1 || { echo "audit-repo-settings: needs the gh CLI" >&2; exit 1; }

bad=0
printf '%-28s %-10s %s\n' REPO AUTO-MERGE 'REQUIRED CHECKS ON main'
for repo in $(gh repo list "$org" --limit 100 --json name --jq '.[].name' | sort); do
  am="$(gh api "repos/$org/$repo" --jq '.allow_auto_merge' 2>/dev/null || echo '?')"

  # A repo with no release.yml is not a product repo and gates nothing; skip the protection half.
  if ! gh api "repos/$org/$repo/contents/.github/workflows/release.yml" --jq '.name' >/dev/null 2>&1; then
    printf '%-28s %-10s %s\n' "$repo" "$am" '(no release.yml — not a product repo)'
    continue
  fi

  # Take the EXIT STATUS, not the output. On a 404 (no protection) gh prints its error JSON to
  # STDOUT and exits non-zero; `|| true` kept that JSON as the value, so a repo with no protection
  # at all looked like a repo with a required check named `{"message":"Branch not protected"...}`
  # and the audit reported ok. An auditor that goes green when it cannot read is worse than none.
  if ctx="$(gh api "repos/$org/$repo/branches/main/protection" \
              --jq '.required_status_checks.contexts | join(",")' 2>/dev/null)"; then
    [ -n "$ctx" ] || ctx='NONE (protected, but no required check)'
  else
    ctx='NONE'
  fi

  printf '%-28s %-10s %s\n' "$repo" "$am" "$ctx"
  [ "$am" = true ] || { bad=$((bad + 1)); }
  case "$ctx" in NONE*) bad=$((bad + 1)) ;; esac
done

echo
if [ "$bad" -eq 0 ]; then
  echo "audit-repo-settings: ok — every product repo can automerge a green bump"
  exit 0
fi
echo "audit-repo-settings: $bad setting(s) would stop a green Renovate bump from merging" >&2
echo "    fix: gh api -X PATCH repos/$org/<repo> -F allow_auto_merge=true" >&2
echo "    fix: printf '{\"required_status_checks\":{\"strict\":false,\"contexts\":[\"<job>\"]},\"enforce_admins\":false,\"required_pull_request_reviews\":null,\"restrictions\":null}' | gh api -X PUT repos/$org/<repo>/branches/main/protection --input -" >&2
echo "    the context is the build JOB NAME; read it from a real run first:" >&2
echo "    gh api repos/$org/<repo>/commits/main/check-runs --jq '[.check_runs[].name]|unique'" >&2
exit 1
