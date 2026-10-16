#!/usr/bin/env bash
LAB_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export LAB_ROOT
export KUBECONFIG=$LAB_ROOT/_out/talos/kubeconfig
export TALOSCONFIG=$LAB_ROOT/_out/talos/talosconfig
export LAB_RECOVERY_DIR=$LAB_ROOT/_out/recovery
export CLUSTER_BAO_SEAL_KEY=$LAB_RECOVERY_DIR/openbao-unseal.key
cd "$LAB_ROOT" || return 1
