#!/usr/bin/env bash
# Add the dissertation experiments and results portal to an installed Bash lab.
set -euo pipefail
set +x
umask 077
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/lab-env.sh"
[[ $# == 0 ]] || {
  printf 'Usage: ./deploy-experiments.sh\n' >&2
  exit 1
}
mkdir -p "$LAB_ROOT/_out/logs" "$LAB_RECOVERY_DIR"
exec 7>"$LAB_ROOT/_out/.experiments.lock"
flock -n 7 || {
  printf 'Another experiment deployment is running\n' >&2
  exit 1
}
trap 'flock -u 7' EXIT
for package in \
  Zarf-Packages/welcome/zarf-package-welcome-amd64-1.0.0.tar.zst \
  Zarf-Packages/security-experiments/zarf-package-security-experiments-amd64-1.0.0.tar.zst; do
  [[ -s $package ]] || {
    printf 'Build the missing package first: %s\n' "$package" >&2
    exit 1
  }
done
kubectl --request-timeout=15s get --raw /readyz >/dev/null

kubectl -n web-gateway wait --for=condition=Programmed gateway/web --timeout=180s
kubectl -n cert-manager get secret lab-ingress-root -o json |
  jq -er '.data["tls.crt"]' | base64 -d >"$LAB_RECOVERY_DIR/lab-root.crt"
zarf package deploy Zarf-Packages/welcome/zarf-package-welcome-amd64-1.0.0.tar.zst --confirm --connected

kubectl label node cp-node-01 security-experiments.io/target=true --overwrite
kubectl apply -f experiments/policies/kyverno/experiment-policy.yaml
kubectl apply -f experiments/policies/gatekeeper/template.yaml
for attempt in $(seq 1 60); do
  if kubectl get crd k8sexperimentlabel.constraints.gatekeeper.sh >/dev/null 2>&1; then
    break
  fi
  [[ $attempt != 60 ]] || {
    printf 'Gatekeeper constraint CRD was not created\n' >&2
    exit 1
  }
  sleep 2
done
kubectl wait --for=condition=Established crd/k8sexperimentlabel.constraints.gatekeeper.sh --timeout=120s
kubectl apply -f experiments/policies/gatekeeper/constraint.yaml
kubectl apply -f experiments/policies/tetragon/experiment-tracing.yaml
kubectl -n falco get configmap falco-rules -o json | jq -e '
  .data["security-experiments.yaml"] |
  contains("rule: Experiment Shell Spawn") and contains("rule: Experiment Service Account Credential Read")' >/dev/null || {
  printf 'Deploy the Falco package with its experiment rules before running experiments.\n' >&2
  exit 1
}

zarf package deploy Zarf-Packages/security-experiments/zarf-package-security-experiments-amd64-1.0.0.tar.zst --confirm --connected
"$LAB_ROOT/scripts/publish-experiments.sh"
for attempt in $(seq 1 120); do
  if kubectl -n argocd get application security-experiments -o json 2>/dev/null |
    jq -e '.status.sync.status == "Synced" and .status.health.status == "Healthy"' >/dev/null; then break; fi
  [[ $attempt != 120 ]] || {
    printf 'Experiment GitOps application did not become Healthy/Synced\n' >&2
    exit 1
  }
  sleep 5
done
for ns in security-test-helm security-test-gitops; do
  deployments=$(kubectl -n "$ns" get deployments -o name)
  [[ -n $deployments ]] || {
    printf 'No experiment deployments in %s\n' "$ns" >&2
    exit 1
  }
  while IFS= read -r deployment; do
    kubectl -n "$ns" rollout status "$deployment" --timeout=300s
  done <<<"$deployments"
done
kubectl -n welcome rollout status deployment/welcome --timeout=300s
printf 'Experiments and results portal ready: https://home.cluster.lab\nRun a suite: ./scripts/run-experiments.sh extended\n'
