#!/usr/bin/env bash
# Required by the OpenBao chart's static seal configuration.
set -euo pipefail
umask 077
: "${CLUSTER_BAO_SEAL_KEY:?Set CLUSTER_BAO_SEAL_KEY to a private recovery file}"
key=$CLUSTER_BAO_SEAL_KEY
mkdir -p "$(dirname -- "$key")"
kubectl create namespace openbao --dry-run=client -o yaml | kubectl apply -f -
if [[ -n $(kubectl -n openbao get secret openbao-unseal --ignore-not-found -o name) ]]; then
  # Preserve the existing seal key
  temp=$(mktemp "$(dirname -- "$key")/.seal.XXXXXX")
  trap 'rm -f -- "$temp"' EXIT
  kubectl -n openbao get secret openbao-unseal -o jsonpath='{.data.key}' | base64 -d >"$temp"
  [[ $(wc -c <"$temp") == 32 ]] || {
    printf 'Existing seal key has invalid length\n' >&2
    exit 1
  }
  if [[ -e $key ]]; then
    cmp -s "$key" "$temp" || {
      printf 'Recovery key differs from cluster seal key\n' >&2
      exit 1
    }
  else ln "$temp" "$key"; fi
  exit 0
fi
if [[ ! -e $key ]]; then
  [[ -z $(kubectl -n openbao get pvc -o name) ]] || {
    printf 'Restore the original seal key for existing OpenBao storage\n' >&2
    exit 1
  }
  temp=$(mktemp "$(dirname -- "$key")/.seal.XXXXXX")
  trap 'rm -f -- "$temp"' EXIT
  openssl rand 32 >"$temp"
  ln "$temp" "$key"
fi
[[ $(wc -c <"$key") == 32 ]] || {
  printf 'Seal key must contain 32 bytes\n' >&2
  exit 1
}
kubectl -n openbao create secret generic openbao-unseal --from-file="key=$key"
