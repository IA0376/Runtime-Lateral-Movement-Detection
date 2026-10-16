#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077
[[ $# == 0 ]] || {
  printf 'This script runs the package list.\n' >&2
  exit 1
}
source "$(dirname -- "${BASH_SOURCE[0]}")/lab-env.sh"
mkdir -p "$LAB_RECOVERY_DIR"

ZARF_CONFIG=Zarf-Packages/virtualised-networking/zarf-config.yaml \
  zarf package deploy Zarf-Packages/virtualised-networking/zarf-package-virtualised-networking-amd64-1.0.0.tar.zst --confirm --connected
kubectl wait --for=condition=Ready nodes --all --timeout=300s

ZARF_CONFIG=Zarf-Packages/infrastructure-storage/zarf-config.yaml \
  zarf package deploy Zarf-Packages/infrastructure-storage/zarf-package-infrastructure-storage-amd64-1.0.0.tar.zst --confirm --connected
kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s
kubectl -n longhorn-system wait --for=create daemonset/longhorn-csi-plugin --timeout=300s
kubectl -n longhorn-system rollout status daemonset/longhorn-csi-plugin --timeout=300s
deadline=$((SECONDS + 600))
until kubectl -n longhorn-system --request-timeout=15s get nodes.longhorn.io -o json |
  jq -e '
    def ready:
      any(.conditions[]?; .type == "Ready" and .status == "True") and
      any(.conditions[]?; .type == "Schedulable" and .status == "True");
    .items | length == 3 and all(.[];
      .spec.allowScheduling == true and (.status | ready) and
      any(.status.diskStatus[]?; ready))' >/dev/null; do
  ((SECONDS < deadline)) || {
    printf 'Longhorn disks did not become ready on all three nodes.\n' >&2
    exit 1
  }
  sleep 5
done

ZARF_CONFIG=Zarf-Packages/cert-manager/zarf-config.yaml \
  zarf package deploy Zarf-Packages/cert-manager/zarf-package-cert-manager-amd64-1.0.0.tar.zst --confirm --connected
kubectl wait --for=condition=Ready clusterissuer/lab-ca --timeout=180s

ZARF_CONFIG=Zarf-Packages/openbao/zarf-config.yaml \
  zarf package deploy Zarf-Packages/openbao/zarf-package-openbao-amd64-1.0.0.tar.zst --confirm --connected
bash "$LAB_ROOT/Zarf-Packages/openbao/initialize.sh" "$LAB_RECOVERY_DIR/openbao-init.json"
ZARF_CONFIG=Zarf-Packages/external-secrets/zarf-config.yaml \
  zarf package deploy Zarf-Packages/external-secrets/zarf-package-external-secrets-amd64-1.0.0.tar.zst --confirm --connected
if ! jq -e '.root_token | type == "string" and length > 0' "$LAB_RECOVERY_DIR/openbao-init.json" >/dev/null 2>&1; then
  printf 'OpenBao initialization did not produce a valid token in %s/openbao-init.json.\n' "$LAB_RECOVERY_DIR" >&2
  exit 1
fi
jq -er '.root_token' "$LAB_RECOVERY_DIR/openbao-init.json" |
  bash "$LAB_ROOT/Zarf-Packages/openbao/configure-eso.sh"
kubectl wait --for=condition=Ready clustersecretstore/openbao --timeout=180s

ZARF_CONFIG=_out/private/gitops-zarf-config.yaml \
  zarf package deploy Zarf-Packages/gitops/zarf-package-gitops-amd64-1.0.0.tar.zst --confirm --connected
ZARF_CONFIG=Zarf-Packages/web-gateway/zarf-config.yaml \
  zarf package deploy Zarf-Packages/web-gateway/zarf-package-web-gateway-amd64-1.0.0.tar.zst --confirm --connected

ZARF_CONFIG=Zarf-Packages/falco/zarf-config.yaml \
  zarf package deploy Zarf-Packages/falco/zarf-package-falco-amd64-1.0.0.tar.zst --confirm --connected
ZARF_CONFIG=Zarf-Packages/tetragon/zarf-config.yaml \
  zarf package deploy Zarf-Packages/tetragon/zarf-package-tetragon-amd64-1.0.0.tar.zst --confirm --connected
ZARF_CONFIG=Zarf-Packages/kyverno/zarf-config.yaml \
  zarf package deploy Zarf-Packages/kyverno/zarf-package-kyverno-amd64-1.0.0.tar.zst --confirm --connected
ZARF_CONFIG=Zarf-Packages/opa/zarf-config.yaml \
  zarf package deploy Zarf-Packages/opa/zarf-package-opa-amd64-1.0.0.tar.zst --confirm --connected
ZARF_CONFIG=Zarf-Packages/tracee/zarf-config.yaml \
  zarf package deploy Zarf-Packages/tracee/zarf-package-tracee-amd64-1.0.0.tar.zst --confirm --connected
ZARF_CONFIG=Zarf-Packages/kubearmor/zarf-config.yaml \
  zarf package deploy Zarf-Packages/kubearmor/zarf-package-kubearmor-amd64-1.0.0.tar.zst --confirm --connected
