#!/usr/bin/env bash
# Fresh installation, requires three resetted nodes in maintenance mode.
set -Eeuo pipefail
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

mode=dry-run
inventory=$ROOT/Infrastructure/talos/bash.env
out=$ROOT/_out/talos

while (($#)); do
  case $1 in
    --apply)
      mode=apply
      shift
      ;;
    --dry-run)
      mode=dry-run
      shift
      ;;
    --inventory | --output-dir)
      (($# >= 2)) || fail "Missing value for $1"
      case $1 in
        --inventory) inventory=$2 ;;
        --output-dir) out=$2 ;;
      esac
      shift 2
      ;;
    -h | --help)
      printf '%s\n' 'Usage: bootstrap.sh [--dry-run | --apply] [--inventory FILE] [--output-dir DIR]' \
        'Default: local generation/validation. --apply installs to the three maintenance nodes.'
      exit 0
      ;;
    *) fail "Unknown option: $1" ;;
  esac
done

for tool in talosctl kubectl jq timeout flock rg; do
  command -v "$tool" >/dev/null || fail "Missing $tool"
done
[[ -r $inventory ]] || fail "Missing inventory: $inventory"
source "$inventory"
[[ ${#NODES[@]} == 3 ]] || fail 'This lab requires exactly three control-plane nodes'
[[ $BOOTSTRAP_TIMEOUT =~ ^[1-9][0-9]*$ ]] || fail 'Invalid timeout'
[[ $INSTALL_DISK =~ ^/dev/[a-zA-Z0-9/_-]+$ ]] || fail 'Invalid install disk'
[[ $CLUSTER_NAME =~ ^[a-zA-Z0-9_-]+$ && $VIP =~ ^[0-9.]+$ ]] || fail 'Invalid cluster name or VIP'
[[ $INSTALL_IMAGE =~ ^[a-zA-Z0-9./:@_-]+$ ]] || fail 'Invalid installer image'
declare -A seen_name=() seen_address=() seen_mac=()
addresses=()
names=()
for entry in "${NODES[@]}"; do
  IFS='|' read -r name address mac vendor label extra <<<"$entry"
  [[ -z $extra && $name =~ ^[a-zA-Z0-9-]+$ && $address =~ ^[0-9.]+$ && $mac =~ ^([a-f0-9]{2}:){5}[a-f0-9]{2}$ && $vendor =~ ^[a-z]+$ && $label =~ ^[a-z0-9-]+$ ]] || fail "Invalid node entry: $entry"
  [[ ! ${seen_name[$name]:-} && ! ${seen_address[$address]:-} && ! ${seen_mac[$mac]:-} ]] || fail 'Duplicate node identity'
  seen_name[$name]=1
  seen_address[$address]=1
  seen_mac[$mac]=1
  addresses+=("$address")
  names+=("$name")
done

common=$ROOT/Infrastructure/talos/bash-common.yaml
# Extract the root CA, used for generating the CAs for Gitea on the provisioner.
ca=$ROOT/lab-internal-root-ca.crt
[[ -s $common && -s $ca ]] || fail 'Missing common patch or registry CA'
temp=$(mktemp -d)
lock_held=false
cleanup() {
  [[ $lock_held == false ]] || flock -u 9
  rm -rf -- "$temp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

generated=$temp/config
mkdir "$generated"
if [[ $mode == apply ]]; then
  mkdir -p "$out"
  out=$(cd "$out" && pwd)
  exec 9>"$out/.lock"
  flock -n 9 || fail 'Another bootstrap is using this output directory'
  lock_held=true
  # Check every target before applying anything. Verify the physical NIC and installation disk in maintenance.
  for entry in "${NODES[@]}"; do
    IFS='|' read -r name address mac _ <<<"$entry"
    timeout 15 talosctl -n "$address" get links --insecure -o json >"$temp/links" || fail "$name is not reachable in maintenance mode"
    jq -se --arg mac "$mac" 'any(.[]; ((.spec.permanentAddr // .spec.hardwareAddr // "") | ascii_downcase) == $mac)' "$temp/links" >/dev/null || fail "MAC mismatch on $name ($address)"
    timeout 15 talosctl -n "$address" get disks --insecure -o json >"$temp/disks"
    jq -se --arg disk "$INSTALL_DISK" 'any(.[]; .spec.dev_path == $disk)' "$temp/disks" >/dev/null || fail "$INSTALL_DISK is missing on $name"
    printf 'Verified maintenance identity and disk: %s (%s)\n' "$name" "$address"
  done
fi

talosctl gen secrets --talos-version "$TALOS_VERSION" -o "$generated/secrets.yaml"
{
  cat "$common"
  cat <<EOF
---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: $INSTALL_IMAGE
provisioning:
  diskSelector:
    match: disk.dev_path == '$INSTALL_DISK'
  wipe: true
reboot: true
---
apiVersion: v1alpha1
kind: Layer2VIPConfig
name: $VIP
link: workload
---
apiVersion: v1alpha1
kind: TrustedRootsConfig
name: lab-ca
certificates: |
EOF
  sed 's/^/  /' "$ca"
  for registry in registry.k8s.io ghcr.io quay.io docker.io docker.gitea.com ecr-public.aws.com reg.kyverno.io; do
    cat <<EOF
---
apiVersion: v1alpha1
kind: RegistryMirrorConfig
name: $registry
skipFallback: true
endpoints:
  - url: https://gitea.lab.internal/v2/talos
    overridePath: true
EOF
  done
} >"$generated/common.yaml"
for entry in "${NODES[@]}"; do
  IFS='|' read -r name address mac vendor label <<<"$entry"
  cat >"$generated/$name.patch.yaml" <<EOF
apiVersion: v1alpha1
kind: HostnameConfig
auto: off
hostname: $name
---
apiVersion: v1alpha1
kind: LinkAliasConfig
name: workload
selector:
  match: mac(link.permanent_addr) == "$mac"
---
apiVersion: v1alpha1
kind: KubeNodeConfig
taints:
  \$patch: delete
labels:
  hardware.lab.internal/cpu-vendor: $vendor
  hardware.lab.internal/node: $label
EOF
  talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" \
    --talos-version "$TALOS_VERSION" --kubernetes-version "$KUBERNETES_VERSION" \
    --dns-domain "$DNS_DOMAIN" --install-disk "$INSTALL_DISK" --install-image "$INSTALL_IMAGE" \
    --with-cluster-discovery=false --with-docs=false --with-examples=false \
    --with-secrets "$generated/secrets.yaml" --config-patch "@$generated/common.yaml" \
    --config-patch "@$generated/$name.patch.yaml" --output-types controlplane -o "$generated/$name.yaml"
  talosctl validate --config "$generated/$name.yaml" --mode metal --strict
done
talosctl gen config "$CLUSTER_NAME" "$CLUSTER_ENDPOINT" --talos-version "$TALOS_VERSION" \
  --kubernetes-version "$KUBERNETES_VERSION" --with-secrets "$generated/secrets.yaml" \
  --output-types talosconfig -o "$generated/talosconfig"
talosctl --talosconfig "$generated/talosconfig" config endpoint "${addresses[@]}"
talosctl --talosconfig "$generated/talosconfig" config node "${addresses[@]}"

if [[ $mode == dry-run ]]; then
  printf 'All three Talos configurations validated. No node contacted; temporary credentials removed.\n'
  exit 0
fi

retry() {
  local deadline=$((SECONDS + BOOTSTRAP_TIMEOUT))
  until "$@" >"$temp/retry.log" 2>&1; do
    if ((SECONDS >= deadline)); then
      cat "$temp/retry.log" >&2
      fail 'Timed out waiting for Talos or Kubernetes readiness'
    fi
    sleep 5
  done
}

# Publish the fresh credentials only after all preflights and validations pass.
install -m 600 -- "$generated/"* "$out/"
for entry in "${NODES[@]}"; do
  IFS='|' read -r name address _ <<<"$entry"
  talosctl -n "$address" apply-config --insecure --file "$out/$name.yaml"
done

first=${addresses[0]}
printf 'Waiting for authenticated Talos access on %s\n' "$first"
retry timeout 15 talosctl --talosconfig "$out/talosconfig" -e "$first" -n "$first" version

deadline=$((SECONDS + BOOTSTRAP_TIMEOUT))
until timeout 30 talosctl --talosconfig "$out/talosconfig" -e "$first" -n "$first" bootstrap >"$temp/bootstrap.log" 2>&1; do
  if timeout 15 talosctl --talosconfig "$out/talosconfig" -e "$first" -n "$first" etcd members >"$temp/etcd" 2>&1 && rg -Fqi -- "${names[0]}" "$temp/etcd"; then
    break
  fi
  ((SECONDS < deadline)) || {
    cat "$temp/bootstrap.log" >&2
    fail 'Bootstrap timed out'
  }
  sleep 5
done
retry timeout 30 talosctl --talosconfig "$out/talosconfig" -e "$first" -n "$first" kubeconfig "$out/kubeconfig" --merge=false --force
retry kubectl --kubeconfig "$out/kubeconfig" --request-timeout=15s get --raw /readyz
retry kubectl --kubeconfig "$out/kubeconfig" --request-timeout=15s get nodes "${names[@],,}" -o name
chmod 600 "$out/kubeconfig"
printf 'Talos bootstrap complete; Kubernetes API ready and all three nodes registered. Kubeconfig: %s/kubeconfig\n' "$out"
printf 'Nodes become Ready only after the virtualised-networking Zarf package installs Cilium.\n'
