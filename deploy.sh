#!/usr/bin/env bash
# Install Talos, infrastructure packages, and the dissertation applications.
set -euo pipefail
umask 077
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/lab-env.sh"
case ${1:---help} in
  --help | -h)
    printf '%s\n' 'Usage: ./deploy.sh --execute | --packages-only' \
      'Talos validation: ./bootstrap.sh --dry-run' \
      'Complete setup on reset nodes: ./deploy-all.sh' \
      'Infrastructure package order: scripts/zarf-deployer.sh' \
      'Portal/experiment installation stage: ./deploy-experiments.sh'
    exit 0
    ;;
  --execute | --packages-only) mode=$1 ;;
  *)
    printf 'Unknown option: %s\n' "$1" >&2
    exit 1
    ;;
esac
[[ $# == 1 ]] || {
  printf 'Expected one option\n' >&2
  exit 1
}
mkdir -p "$LAB_ROOT/_out/logs" "$LAB_RECOVERY_DIR"
exec 8>"$LAB_ROOT/_out/.deploy.lock"
flock -n 8 || {
  printf 'Another deployment is running\n' >&2
  exit 1
}
trap 'flock -u 8' EXIT
if [[ $mode == --execute ]]; then
  "$LAB_ROOT/bootstrap.sh" --apply
fi
[[ -s $KUBECONFIG && -s $TALOSCONFIG ]] || {
  printf 'Bootstrap this instance first\n' >&2
  exit 1
}
kubectl --request-timeout=15s get --raw /readyz >/dev/null
"$LAB_ROOT/scripts/prepare-bash-secrets.sh"
"$LAB_ROOT/scripts/zarf-deployer.sh"
if [[ $mode == --execute ]]; then
  "$LAB_ROOT/deploy-experiments.sh"
fi
printf 'Deployment complete. Credentials: %s\n' "$LAB_ROOT/_out"
