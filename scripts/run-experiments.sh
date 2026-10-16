#!/usr/bin/env bash
set -euo pipefail
umask 077
source "$(dirname -- "${BASH_SOURCE[0]}")/lab-env.sh"
[[ $# == 1 && ($1 == normal || $1 == extended) ]] || {
  printf 'Usage: scripts/run-experiments.sh normal | extended\n' >&2
  exit 1
}
mkdir -p "$LAB_ROOT/_out/logs"
exec 6>"$LAB_ROOT/_out/.suite.lock"
flock -n 6 || {
  printf 'Another suite command is running\n' >&2
  exit 1
}
# Deployments start from a resetted cluster..
job=lab-test-security
kubectl -n welcome create job "$job" --from="cronjob/welcome-suite-$1"
printf 'Suite started: %s\n' "$job"
deadline=$((SECONDS + 1860))
while ((SECONDS < deadline)); do
  state=$(kubectl -n welcome get job "$job" -o json |
    jq -r '[.status.conditions[]? | select(.status == "True") | .type] | if index("Failed") then "Failed" elif index("Complete") then "Complete" else "Running" end')
  if [[ $state == Complete || $state == Failed ]]; then
    kubectl -n welcome logs "job/$job" >"$LAB_ROOT/_out/logs/$job.log"
    printf 'Suite %s. Log: %s/_out/logs/%s.log\nRefresh portal results.\n' "$state" "$LAB_ROOT" "$job"
    [[ $state == Complete ]]
    exit
  fi
  sleep 5
done
printf 'Suite wait timed out %s\n' "$job" >&2
exit 1
