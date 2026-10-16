#!/usr/bin/env bash
# Publish only the experiment chart and child Application to the cluster's internal Gitea.
set -euo pipefail
set +x
umask 077
source "$(dirname -- "${BASH_SOURCE[0]}")/lab-env.sh"
mkdir -p "$LAB_ROOT/_out/private" "$LAB_ROOT/_out/logs"
private=$(mktemp -d "$LAB_ROOT/_out/private/gitops.XXXXXX")
forward=''
cleanup() {
  if [[ -n $forward ]]; then
    kill "$forward" 2>/dev/null || true
  fi
  rm -rf -- "$private"
}
trap cleanup EXIT
kubectl -n gitea get secret gitea-admin -o json >"$private/credentials.json"
for key in username password; do
  jq -er --arg key "$key" '.data[$key]' "$private/credentials.json" | base64 -d >"$private/$key"
done
kubectl -n gitea port-forward --address 127.0.0.1 service/gitea-http :3000 >"$private/forward.log" 2>&1 &
forward=$!
for attempt in $(seq 1 30); do
  kill -0 "$forward" || {
    cat "$private/forward.log" >&2
    exit 1
  }
  port=$(sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) -> .*/\1/p' "$private/forward.log" | head -1)
  if [[ -n $port ]] && curl --silent --fail "http://127.0.0.1:$port/api/healthz" >/dev/null; then
    break
  fi
  [[ $attempt != 30 ]] || {
    printf 'Gitea port-forward did not become ready\n' >&2
    exit 1
  }
  sleep 1
done
cat >"$private/askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
  *Username*) cat "$LAB_GIT_AUTH/username" ;;
  *) cat "$LAB_GIT_AUTH/password" ;;
esac
ASKPASS
chmod 700 "$private/askpass"
export LAB_GIT_AUTH=$private GIT_ASKPASS=$private/askpass GIT_TERMINAL_PROMPT=0
git -c credential.helper= clone --quiet --branch main "http://127.0.0.1:$port/infrastructure/infrastructure.git" "$private/repo"
git -C "$private/repo" rm -r --quiet --ignore-unmatch charts/security-experiment
mkdir -p "$private/repo/charts/security-experiment" "$private/repo/apps"
cp -a Zarf-Packages/security-experiments/chart/. "$private/repo/charts/security-experiment/"
cp experiments/gitops/security-experiments.yaml "$private/repo/apps/security-experiments.yaml"
git -C "$private/repo" add charts/security-experiment apps/security-experiments.yaml
if ! git -C "$private/repo" diff --cached --quiet; then
  git -C "$private/repo" -c user.name='Bash Lab' -c user.email=bash-lab@lab.internal \
    commit --quiet -m 'Deploy dissertation experiment chart'
  git -C "$private/repo" -c credential.helper= push origin HEAD:main
fi
git -C "$private/repo" rev-parse HEAD >"$LAB_ROOT/_out/logs/experiments-git-revision"
kubectl -n argocd annotate application infrastructure argocd.argoproj.io/refresh=hard --overwrite
printf 'Published experiment chart and Application to the cluster repository.\n'
