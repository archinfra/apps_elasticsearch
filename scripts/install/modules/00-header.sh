#!/usr/bin/env bash
set -Eeuo pipefail
ES_VERSION=9.5.5
NAMESPACE=logging
NAME=elasticsearch
MODE=single
PROFILE=standard
STORAGE_CLASS=""
STORAGE_SIZE=""
REGISTRY=sealos.hub:5000/kube4
REGISTRY_USER=""
REGISTRY_PASSWORD_FILE=""
SKIP_IMAGES=false
SKIP_OPERATOR=false
KIBANA=true
COLLECTOR=false
COLLECTOR_SECRET=""
YES=false
ACTION="${1:-help}"
[[ "$ACTION" != -h && "$ACTION" != --help ]] || ACTION=help
if (($#)); then shift; fi
WORKDIR=""
cleanup() { [[ -z "$WORKDIR" ]] || rm -rf "$WORKDIR"; }
trap cleanup EXIT
fail() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[archinfra/es] $*" >&2; }
usage() {
  cat <<'EOF'
Archinfra Elasticsearch 0.1.0 (ES/Kibana 9.5.5, ECK 3.5.0)
Usage: ./elasticsearch-installer-v0.1.0-ARCH.run <install|status|uninstall|help> [options]

  -n, --namespace NAME             Namespace (default: logging)
      --name NAME                  ES resource name (default: elasticsearch)
      --mode single|ha             1 node or 3 nodes (default: single; NOT HA)
      --resource-profile PROFILE   lite|standard|large (default: standard)
      --storage-class NAME         REQUIRED; use block storage
      --storage-size SIZE          PVC per node (defaults: 30Gi/100Gi/300Gi)
      --registry PREFIX            Internal registry (default: sealos.hub:5000/kube4)
      --registry-user USER         Optional Docker login username
      --registry-password-file F   Registry password file
      --skip-image-prepare         Images are in private registry already
      --skip-operator-install      Reuse ECK already installed
      --enable-kibana             Deploy Kibana (default)
      --disable-kibana            Skip Kibana
      --enable-collector          Deploy optional Fluent Bit DaemonSet
      --collector-secret NAME      Scoped writer Secret with username/password
      --disable-collector         Skip Fluent Bit (default)
  -y, --yes                        Skip interactive confirmation
  -h, --help                       Print usage

Defaults: ClusterIP/TLS; ECK shared and kept on uninstall;
Elasticsearch PVCs retained using DeleteOnScaledownOnly.
No jq, python, curl or helm required on offline target.
EOF
}
valid_name() { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && ((${#1} <= 50)); }
valid_registry() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] && [[ "$1" != */ ]] && [[ "$1" != *..* ]]; }
valid_storage_class() { [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] && ((+"#1"+ <= 253)); }
valid_size() { [[ "$1" =~ ^[1-9][0-9]*(Gi|Ti)$ ]]; }
while (($#)); do
  case "$1" in
    -n|--namespace) NAMESPACE="${2:?missing namespace}"; shift 2 ;;
    --name) NAME="${2:?missing name}"; shift 2 ;;
    --mode) MODE="${2:?missing mode}"; shift 2 ;;
    --resource-profile) PROFILE="${2:?missing profile}"; shift 2 ;;
    --storage-class) STORAGE_CLASS="${2:?missing storage class}"; shift 2 ;;
    --storage-size) STORAGE_SIZE="${2:?missing storage size}"; shift 2 ;;
    --registry) REGISTRY="${2:?missing registry}"; shift 2 ;;
    --registry-user) REGISTRY_USER="${2:?missing username}"; shift 2 ;;
    --registry-password-file) REGISTRY_PASSWORD_FILE="${2:?missing file}"; shift 2 ;;
    --skip-image-prepare) SKIP_IMAGES=true; shift ;;
    --skip-operator-install) SKIP_OPERATOR=true; shift ;;
    --enable-kibana) KIBANA=true; shift ;;
    --disable-kibana) KIBANA=false; shift ;;
    --enable-collector) COLLECTOR=true; shift ;;
    --disable-collector) COLLECTOR=false; shift ;;
    --collector-secret) COLLECTOR_SECRET="${2:?missing secret}"; shift 2 ;;
    -y|--yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
