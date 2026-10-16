#!/usr/bin/env bash
# Obtain the provisioner's OpenBao PKI root into the repository root as
# lab-internal-root-ca.crt. The bootstrap and the image mirror need this root
# to trust the provisioner's services, so it is fetched from the running
# provisioner rather than committed to the repository.
set -euo pipefail
set +x
umask 077
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=$ROOT/lab-internal-root-ca.crt
subject='CN=lab.internal Root CA'

force=false
[[ ${1:-} == --force ]] && force=true

valid() {
  [[ -s $1 ]] || return 1
  local s
  s=$(openssl x509 -in "$1" -noout -subject 2>/dev/null) || return 1
  [[ $s == *"$subject"* ]]
}

if [[ $force == false ]] && valid "$out"; then
  printf 'lab-internal-root-ca.crt already present (%s)\n' "$subject"
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# 1. OpenBao's PKI endpoint is the authoritative source.
# 2. Otherwise take the root from the TLS chain NGINX serves for Gitea.
# 3. Otherwise copy an issued bundle from the provisioner filesystem.
if curl --fail --silent --show-error --max-time 30 \
  http://bao.lab.internal:8200/v1/pki/ca/pem -o "$tmp" && valid "$tmp"; then
  src='OpenBao PKI endpoint'
elif openssl s_client -connect gitea.lab.internal:443 -servername gitea.lab.internal \
  -showcerts </dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/{n++} n==2{print} /END CERTIFICATE/ && n==2{exit}' >"$tmp" && valid "$tmp"; then
  src='Gitea TLS chain'
elif [[ -s /opt/containers/gitea/certs/gitea.lab.internal/issuing_ca.pem ]] &&
  cp /opt/containers/gitea/certs/gitea.lab.internal/issuing_ca.pem "$tmp" && valid "$tmp"; then
  src='provisioner filesystem'
else
  printf 'Could not obtain the root CA. Resolve *.lab.internal to the provisioner and ensure it is running, or supply lab-internal-root-ca.crt manually.\n' >&2
  exit 1
fi

cp "$tmp" "$out"
chmod 644 "$out"
printf 'Wrote lab-internal-root-ca.crt from %s (%s)\n' "$src" "$subject"
