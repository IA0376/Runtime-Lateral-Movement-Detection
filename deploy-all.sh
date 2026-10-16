#!/usr/bin/env bash
# Build every package, push its images to the provisioner Gitea, reset the
# three Talos nodes and deploy the whole lab from scratch.
set -euo pipefail
set +x
umask 077
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/lab-env.sh"

# Provisioner Gitea registry the packages' images are pushed to. The Talos
# registryMirrors (Infrastructure/talos/bootstrap.yaml) resolve every upstream
# registry to this path, so the nodes pull what is pushed here.
: "${LAB_REGISTRY:=gitea.lab.internal/talos}"
: "${LAB_REGISTRY_USER:=admin}"
: "${LAB_REGISTRY_PASSWORD:=}"

dry_run=false
suite=extended
do_reset=true
do_mirror=true
while (($#)); do
  case $1 in
    --dry-run)
      dry_run=true
      shift
      ;;
    --no-reset)
      do_reset=false
      shift
      ;;
    --skip-mirror)
      do_mirror=false
      shift
      ;;
    --skip-suite)
      suite=''
      shift
      ;;
    --run-suite)
      [[ $# -ge 2 && ($2 == normal || $2 == extended) ]] || {
        printf 'Expected --run-suite normal or extended\n' >&2
        exit 1
      }
      suite=$2
      shift 2
      ;;
    --help | -h)
      printf '%s\n' 'Usage: ./deploy-all.sh [--dry-run] [--skip-mirror] [--no-reset] [--run-suite normal|extended | --skip-suite]' \
        'Default: obtain the provisioner root CA, build all package archives, push their images to the provisioner Gitea, reset the three Talos nodes, bootstrap, install packages, verify workloads, run 60 trials, start Jetson feedback.' \
        '--dry-run validates Talos locally and prints the plan without contacting the cluster or the registry.' \
        'Every deployment creates all package archives from the checked-in definitions.' \
        '--skip-mirror does not push images to the provisioner Gitea (images must already be available there).' \
        '--no-reset does not reset the nodes; they must already be in maintenance mode.' \
        '--run-suite chooses normal (48 trials) or extended (60 trials, default).' \
        '--skip-suite installs and verifies the lab without running trials or starting Jetson feedback.' \
        'Jetson feedback runs in the background after the suite succeeds.' \
        'Pushing images needs LAB_REGISTRY_PASSWORD (and optionally LAB_REGISTRY, LAB_REGISTRY_USER) and the provisioner CA trusted by this host.'
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 1
      ;;
  esac
done
for tool in talosctl kubectl zarf jq curl git openssl htpasswd flock timeout rg sha256sum; do
  command -v "$tool" >/dev/null || {
    printf 'Missing required command: %s\n' "$tool" >&2
    exit 1
  }
done

# Node addresses for the reset, from the same inventory the bootstrap uses.
inventory=$LAB_ROOT/Infrastructure/talos/bash.env
[[ -r $inventory ]] || {
  printf 'Missing inventory: %s\n' "$inventory" >&2
  exit 1
}
# shellcheck source=/dev/null
source "$inventory"
node_addrs=()
for entry in "${NODES[@]}"; do
  IFS='|' read -r _ address _ <<<"$entry"
  node_addrs+=("$address")
done

# Use the same literal package paths as the maintained deployment commands.
mapfile -t archives < <(sed -nE 's|^[[:space:]]*zarf package deploy (Zarf-Packages/[^[:space:]]+\.tar\.zst).*|\1|p' \
  scripts/zarf-deployer.sh deploy-experiments.sh)
((${#archives[@]} > 0)) || {
  printf 'No package archives found in the deployment scripts\n' >&2
  exit 1
}
for archive in "${archives[@]}"; do
  [[ -s ${archive%/*}/zarf.yaml ]] || {
    printf 'Missing package definition: %s/zarf.yaml\n' "${archive%/*}" >&2
    exit 1
  }
done
if [[ $dry_run == true ]]; then
  printf 'Obtain provisioner root CA: lab-internal-root-ca.crt\n'
  [[ -s $LAB_ROOT/lab-internal-root-ca.crt ]] || "$LAB_ROOT/scripts/fetch-lab-ca.sh"
  "$LAB_ROOT/bootstrap.sh" --dry-run
  for archive in "${archives[@]}"; do
    printf 'Build: %s\n' "${archive%/*}"
  done
  if [[ $do_mirror == true ]]; then
    for archive in "${archives[@]}"; do
      printf 'Mirror images to %s: %s\n' "$LAB_REGISTRY" "${archive%/*}"
    done
  fi
  if [[ $do_reset == true ]]; then
    printf 'Reset nodes to maintenance: %s\n' "${node_addrs[*]}"
  fi
  printf '%s\n' 'Bootstrap: ./bootstrap.sh --apply'
  printf '%s\n' 'Deploy: ./deploy.sh --packages-only' 'Deploy: ./deploy-experiments.sh' 'Verify: ./scripts/verify-experiments.sh'
  if [[ -n $suite ]]; then
    printf 'Run: ./scripts/run-experiments.sh %s\n' "$suite"
    printf '%s\n' 'Annotate: ./scripts/annotate-experiments.sh'
  fi
  exit 0
fi

if [[ $do_mirror == true && -z $LAB_REGISTRY_PASSWORD ]]; then
  printf 'Set LAB_REGISTRY_PASSWORD to push images to %s, or pass --skip-mirror.\n' "$LAB_REGISTRY" >&2
  exit 1
fi

mkdir -p "$LAB_ROOT/_out/logs"
exec 5>"$LAB_ROOT/_out/.deploy-all.lock"
flock -n 5 || {
  printf 'Another complete deployment is running\n' >&2
  exit 1
}
log=$LAB_ROOT/_out/logs/deploy-all-$(date -u +%Y%m%dT%H%M%S)-$$.log
run_step() {
  local title=$1
  shift
  printf '\n%s\n' "$title" | tee -a "$log"
  if "$@" 2>&1 | tee -a "$log"; then
    return 0
  else
    printf 'Stopped during %s. Inspect %s.\n' "$title" "$log" >&2
    return 1
  fi
}

mirror_package() {
  zarf package mirror-resources "$1" --images \
    --registry-url "$LAB_REGISTRY" \
    --registry-push-username "$LAB_REGISTRY_USER" \
    --registry-push-password "$LAB_REGISTRY_PASSWORD" \
    --confirm
}

reset_cluster() {
  local ip deadline ok
  if [[ -s $TALOSCONFIG ]]; then
    for ip in "${node_addrs[@]}"; do
      printf 'Resetting %s\n' "$ip"
      timeout 180 talosctl --talosconfig "$TALOSCONFIG" -e "$ip" -n "$ip" \
        reset --graceful=false --reboot --wipe-mode all 2>&1 ||
        printf 'Reset request to %s did not complete; it may already be in maintenance mode.\n' "$ip"
    done
  else
    printf 'No talosconfig; assuming nodes are already in maintenance mode.\n'
  fi
  printf 'Waiting for all nodes to enter maintenance mode\n'
  sleep 10
  deadline=$((SECONDS + 900))
  while true; do
    ok=true
    for ip in "${node_addrs[@]}"; do
      timeout 15 talosctl -e "$ip" -n "$ip" get links --insecure >/dev/null 2>&1 || {
        ok=false
        break
      }
    done
    [[ $ok == true ]] && break
    ((SECONDS < deadline)) || {
      printf 'Nodes did not return to maintenance mode within the timeout.\n' >&2
      return 1
    }
    sleep 10
  done
  printf 'All three nodes are in maintenance mode.\n'
}

run_step 'Obtain provisioner root CA' "$LAB_ROOT/scripts/fetch-lab-ca.sh"
run_step 'Validate Talos configuration' "$LAB_ROOT/bootstrap.sh" --dry-run
for archive in "${archives[@]}"; do
  rm -f -- "$archive"
  run_step "Build ${archive%/*}" zarf package create "${archive%/*}" --output "${archive%/*}" --confirm --architecture amd64
  [[ -s $archive ]] || {
    printf 'Package did not produce %s; check the version in its definition and deployment command.\n' "$archive" >&2
    exit 1
  }
done
if [[ $do_mirror == true ]]; then
  for archive in "${archives[@]}"; do
    run_step "Push images to $LAB_REGISTRY: ${archive%/*}" mirror_package "$archive"
  done
fi
if [[ $do_reset == true ]]; then
  run_step 'Reset cluster to maintenance mode' reset_cluster
fi
run_step 'Bootstrap reset Talos nodes' "$LAB_ROOT/bootstrap.sh" --apply
run_step 'Deploy infrastructure' "$LAB_ROOT/deploy.sh" --packages-only
run_step 'Deploy portal and experiment workloads' "$LAB_ROOT/deploy-experiments.sh"
run_step 'Verify Helm/GitOps workload equivalence' "$LAB_ROOT/scripts/verify-experiments.sh"
if [[ -n $suite ]]; then
  run_step 'Run experiment suite' "$LAB_ROOT/scripts/run-experiments.sh" "$suite"
  run_step 'Start Jetson advisory generation' "$LAB_ROOT/scripts/annotate-experiments.sh"
fi
printf '\nComplete. Results: https://home.cluster.lab\nMap home.cluster.lab to 10.0.0.37 on the client and trust %s/lab-root.crt.\nLog: %s\n' "$LAB_RECOVERY_DIR" "$log"

if [[ -z $suite ]]; then
  printf 'No experiment suite was run. Populate results with:\n  %s/scripts/run-experiments.sh extended\n' "$LAB_ROOT"
fi
