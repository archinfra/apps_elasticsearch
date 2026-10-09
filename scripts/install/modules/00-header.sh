#!/usr/bin/env bash
set -Eeuo pipefail
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
KIBANA=true
FLUENTBIT=true
MONITORING=true
RETENTION=14
YES=false
WORKDIR=""
ACTION="${1:-help}"
if (($#)); then shift; fi
[[ "$ACTION" != -h && "$ACTION" != --help ]] || ACTION=help
cleanup() { [[ -z "$WORKDIR" ]] || rm -rf "$WORKDIR"; }
trap cleanup EXIT
fail() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[archinfra/es] $*" >&2; }
usage() {
cat <<'EOF'
Archinfra Elasticsearch Offline Toolkit 0.2.0 (Helm / NO Operator)
Usage: elasticsearch-installer-v0.2.0-ARCH.run <install|status|uninstall|help> [options]
 -n, --namespace NS           default logging
     --name NAME              Helm release default elasticsearch
     --mode single|ha         1 or 3 nodes; default single
     --resource-profile P     lite|standard|large; default standard
     --storage-class SC       required for install, prefer block storage
     --storage-size SIZE      default 30Gi/100Gi/300Gi depending on profile
     --registry PREFIX        default sealos.hub:5000/kube4
     --registry-user USER     optional
     --registry-password-file PATH optional
     --skip-image-prepare     images already in private registry
     --enable-kibana / --disable-kibana      enabled by default
     --enable-fluent-bit / --disable-fluent-bit enabled by default
     --enable-monitoring / --disable-monitoring enabled by default
     --retention-days N       1..3650; default 14
 -y, --yes                    skip confirmation
 -h, --help                   show help
Requires helm, kubectl, bash, tar, od. Docker only when preparing images.
PVC, generated credentials and TLS certificate retained on uninstall.
EOF
}
valid_name() { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && ((${#1} <= 40)); }
valid_class() { [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] && ((${#1} <= 253)); }
valid_registry() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] && [[ "$1" != */ ]] && [[ "$1" != *..* ]]; }
valid_size() { [[ "$1" =~ ^[1-9][0-9]*(Gi|Ti)$ ]]; }
while (($#)); do
 case "$1" in
   -n|--namespace) NAMESPACE="${2:?missing namespace}"; shift 2 ;;
   --name) NAME="${2:?missing name}"; shift 2 ;;
   --mode) MODE="${2:?missing mode}"; shift 2 ;;
   --resource-profile) PROFILE="${2:?missing profile}"; shift 2 ;;
   --storage-class) STORAGE_CLASS="${2:?missing class}"; shift 2 ;;
   --storage-size) STORAGE_SIZE="${2:?missing size}"; shift 2 ;;
   --registry) REGISTRY="${2:?missing registry}"; shift 2 ;;
   --registry-user) REGISTRY_USER="${2:?missing user}"; shift 2 ;;
   --registry-password-file) REGISTRY_PASSWORD_FILE="${2:?missing file}"; shift 2 ;;
   --skip-image-prepare) SKIP_IMAGES=true; shift ;;
   --enable-kibana) KIBANA=true; shift ;;
   --disable-kibana) KIBANA=false; shift ;;
   --enable-fluent-bit) FLUENTBIT=true; shift ;;
   --disable-fluent-bit) FLUENTBIT=false; shift ;;
   --enable-monitoring) MONITORING=true; shift ;;
   --disable-monitoring) MONITORING=false; shift ;;
   --retention-days) RETENTION="${2:?missing retention}"; shift 2 ;;
   -y|--yes) YES=true; shift ;;
   -h|--help) usage; exit 0 ;;
   *) fail "Unknown option $1" ;;
 esac
done
