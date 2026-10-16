#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
dir=$ROOT/_out/private
mkdir -p "$ROOT/_out"
exec 9>"$ROOT/_out/.secrets.lock"
flock -n 9 || {
  printf 'Secrets preparation already running\n' >&2
  exit 1
}
trap 'flock -u 9' EXIT
# Give this installation its own secrets and recovery files.
archive=$ROOT/_out/installations/$(date -u +%Y%m%dT%H%M%S)-$$
for name in private recovery; do
  if [[ -e $ROOT/_out/$name ]]; then
    mkdir -p "$archive"
    mv "$ROOT/_out/$name" "$archive/$name"
  fi
done
mkdir -p "$dir" "$ROOT/_out/recovery"
# Passwords
gitea=$(openssl rand -hex 24)
argocd=$(openssl rand -hex 24)
jq -n --arg gitea "$gitea" --arg argocd "$argocd" '{gitea:$gitea,argocd:$argocd}' >"$dir/gitops-passwords.json.tmp"
mv "$dir/gitops-passwords.json.tmp" "$dir/gitops-passwords.json"
hash=$(jq -r .argocd "$dir/gitops-passwords.json" | htpasswd -niBC 10 admin | cut -d: -f2 | tr -d '\n')
jq --arg hash "$hash" '{package: {deploy: {set: {
  GITEA_ADMIN_USERNAME: "admin",
  GITEA_ADMIN_PASSWORD: .gitea,
  GITEA_ARGOCD_USERNAME: "admin",
  GITEA_ARGOCD_PASSWORD: .gitea,
  ARGOCD_ADMIN_PASSWORD_HASH: $hash
}}}}' "$dir/gitops-passwords.json" >"$dir/gitops-zarf-config.yaml.tmp"
mv "$dir/gitops-zarf-config.yaml.tmp" "$dir/gitops-zarf-config.yaml"
printf 'GitOps bootstrap credentials prepared in %s\n' "$dir"
