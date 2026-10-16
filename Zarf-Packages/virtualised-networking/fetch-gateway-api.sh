#!/usr/bin/env bash
set -euo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
URL=https://gitea.lab.internal/api/packages/talos/generic/gateway-api/v1.6.1/standard-install.yaml
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl --fail --silent --show-error --max-time 60 --cacert "${LAB_CA_FILE:-$DIR/../../lab-internal-root-ca.crt}" "$URL" >"$tmp"
echo "$(cat "$DIR/gateway-api.sha256")  $tmp" | sha256sum -c - >/dev/null
mkdir -p "$DIR/manifests"
cp "$tmp" "$DIR/manifests/gateway-api.yaml"
echo "Fetched pinned Gateway API v1.6.1 from gitea.lab.internal"
