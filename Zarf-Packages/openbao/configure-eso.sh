#!/usr/bin/env bash
set -euo pipefail
set +x
command -v jq >/dev/null
read -r -s -p "OpenBao administrator token: " token
printf '\n'
bao_read() {
  printf '%s\n' "$token" | kubectl -n openbao exec -i openbao-0 -- sh -ec '
    read -r BAO_TOKEN
    export BAO_TOKEN
    exec bao "$@"
  ' -- "$@"
}
mounts=$(bao_read secrets list -format=json)
auth=$(bao_read auth list -format=json)
has_kv=$(jq -r 'has("secret/")' <<<"$mounts")
has_auth=$(jq -r 'has("kubernetes/")' <<<"$auth")
if [[ "$has_kv" == true ]]; then
  jq -e '."secret/".type == "kv" and ."secret/".options.version == "2"' <<<"$mounts" >/dev/null
fi
if [[ "$has_auth" == true ]]; then
  jq -e '."kubernetes/".type == "kubernetes"' <<<"$auth" >/dev/null
fi
printf '%s\n' "$token" | kubectl -n openbao exec -i openbao-0 -- sh -ec '
  read -r BAO_TOKEN
  export BAO_TOKEN
  if [ "$1" = false ]; then
    bao secrets enable -path=secret -version=2 kv
  fi
  if [ "$2" = false ]; then
    bao auth enable kubernetes
  fi
  bao write auth/kubernetes/config \
    kubernetes_host=https://kubernetes.default.svc:443
  bao policy write eso-applications - <<POLICY
path "secret/data/gitea/admin" {
  capabilities = ["read"]
}
path "secret/data/argocd/admin" {
  capabilities = ["read"]
}
POLICY
  bao write auth/kubernetes/role/eso-applications \
    bound_service_account_names=eso-openbao \
    bound_service_account_namespaces=external-secrets \
    audience=openbao \
    policies=eso-applications ttl=1h
  bao write sys/policies/password/application policy=- <<POLICY
length = 32
rule "charset" {
  charset = "abcdefghijklmnopqrstuvwxyz"
  min-chars = 1
}
rule "charset" {
  charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  min-chars = 1
}
rule "charset" {
  charset = "0123456789"
  min-chars = 1
}
POLICY
' -- "$has_kv" "$has_auth"
unset token
