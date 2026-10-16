#!/usr/bin/env bash
# Trigger immediate annotation; the scheduled worker runs every five minutes.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/lab-env.sh"
[[ $# == 0 ]] || {
  printf 'Usage: scripts/annotate-experiments.sh\n' >&2
  exit 1
}
kubectl -n welcome create job --from=cronjob/welcome-jetson "welcome-jetson-manual-$(date +%s)"
printf 'Watch progress: kubectl -n welcome logs -l app=welcome-jetson --tail=20 -f\nRefresh portal results as annotations finish.\n'
