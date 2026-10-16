#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
OUTPUT=${1:?Usage: initialize.sh /secure/backup/openbao-init.json}
command -v jq >/dev/null
kubectl -n openbao wait --for=create pod/openbao-0 --timeout=300s
kubectl -n openbao wait --for=jsonpath='{.status.phase}'=Running pod/openbao-0 --timeout=300s
for attempt in $(seq 1 60); do
  code=0
  status=$(kubectl -n openbao exec openbao-0 -- bao status -format=json 2>/dev/null) || code=$?
  if [[ $code == 0 || $code == 2 ]] && jq -e 'has("initialized") and has("sealed")' <<<"$status" >/dev/null 2>&1; then
    break
  fi
  [[ $attempt != 60 ]] || {
    echo "OpenBao HTTPS status did not become available" >&2
    exit 1
  }
  sleep 2
done
if [[ $(jq -r .initialized <<<"$status") == true ]]; then
  echo "OpenBao is already initialized; no new recovery keys were created."
else
  (
    set -o noclobber
    kubectl -n openbao exec openbao-0 -- bao operator init \
      -recovery-shares=5 -recovery-threshold=3 -format=json >"$OUTPUT"
  )
  echo "Recovery keys and initial root token written to $OUTPUT. Back up securely."
fi
replicas=$(kubectl -n openbao get statefulset openbao -o jsonpath='{.spec.replicas}')
for ((ordinal = 0; ordinal < replicas; ordinal++)); do
  kubectl -n openbao wait --for=condition=Ready "pod/openbao-$ordinal" --timeout=300s
  kubectl -n openbao exec "openbao-$ordinal" -- bao status -format=json |
    jq -e '.initialized == true and .sealed == false' >/dev/null
done
