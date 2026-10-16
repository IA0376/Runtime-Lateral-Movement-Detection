#!/usr/bin/env bash
# Compare live workload content before interpreting Helm/GitOps experiment results.
set -euo pipefail
if (($# != 0)); then
  cat >&2 <<'USAGE'
Usage: verify-experiments.sh
USAGE
  printf 'Use: bash %q extended\n' "$(dirname -- "${BASH_SOURCE[0]}")/run-experiments.sh" >&2
  exit 2
fi
umask 077
source "$(dirname -- "${BASH_SOURCE[0]}")/lab-env.sh"
mkdir -p "$LAB_ROOT/_out/logs"
for mode in helm gitops; do
  ns=security-test-$mode
  kubectl -n "$ns" get deployments,services,configmaps,roles,rolebindings,ciliumnetworkpolicies -o json |
    jq -S --arg ns "$ns" '[.items[] |
      select(.metadata.name != "kube-root-ca.crt") |
      select((.metadata.name == "lab-test-experiments" and (.kind == "Role" or .kind == "RoleBinding")) | not) |
      .metadata = {name:.metadata.name} | del(.status) |
      if .kind == "Deployment" then
        del(.spec.template.metadata.labels["zarf.dev/package"], .spec.template.metadata.annotations["checksum/scripts"]) |
        if .spec.template.metadata.annotations == {} then del(.spec.template.metadata.annotations) else . end
      elif .kind == "Service" then
        del(.spec.clusterIP,.spec.clusterIPs,.spec.ipFamilies,.spec.ipFamilyPolicy,.spec.internalTrafficPolicy)
      else . end |
      walk(if type == "string" then gsub($ns; "EXPERIMENT_NAMESPACE") else . end)
    ] | sort_by(.kind,.metadata.name)' >"$LAB_ROOT/_out/logs/experiment-$mode.json"
done
helm_snapshot=$LAB_ROOT/_out/logs/experiment-helm.json
gitops_snapshot=$LAB_ROOT/_out/logs/experiment-gitops.json
equivalent=false
if diff -u "$helm_snapshot" "$gitops_snapshot" >"$LAB_ROOT/_out/logs/experiment-diff.txt"; then
  equivalent=true
fi
jq -n --arg testedAt "$(date -u +%FT%TZ)" --argjson equivalent "$equivalent" \
  --argjson objects "$(jq length "$helm_snapshot")" \
  --arg helm "$(sha256sum "$helm_snapshot" | cut -d ' ' -f 1)" \
  --arg gitops "$(sha256sum "$gitops_snapshot" | cut -d ' ' -f 1)" \
  '{testedAt:$testedAt,equivalent:$equivalent,objectsPerDeployment:$objects,sha256:{helm:$helm,gitops:$gitops},
    scope:"Live application specs, network policies and workload RBAC. Excludes namespace identities, allocated service IPs, controller status, deployment-manager metadata, scripts rollout checksum and portal-runner management RBAC. Does not test reconciliation or drift."}' \
  >"$LAB_ROOT/_out/logs/experiment-equivalence.json"
cat "$LAB_ROOT/_out/logs/experiment-equivalence.json"
[[ $equivalent == true ]]
