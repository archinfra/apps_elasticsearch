[[ "$ACTION" =~ ^(install|status|uninstall|help)$ ]] || fail "Unknown action $ACTION"
[[ "$ACTION" != help ]] || { usage; exit 0; }
valid_name "$NAME" || fail "Invalid release name"
valid_name "$NAMESPACE" || fail "Invalid namespace"
valid_registry "$REGISTRY" || fail "Invalid registry"
[[ "$MODE" =~ ^(single|ha)$ ]] || fail "Mode must be single or ha"
[[ "$PROFILE" =~ ^(lite|standard|large)$ ]] || fail "Profile must be lite|standard|large"
[[ -z "$STORAGE_CLASS" ]] || valid_class "$STORAGE_CLASS" || fail "Invalid StorageClass"
[[ -z "$STORAGE_SIZE" ]] || valid_size "$STORAGE_SIZE" || fail "Invalid storage size"
[[ "$RETENTION" =~ ^[1-9][0-9]*$ ]] && ((RETENTION <= 3650)) || fail "retention-days must be 1..3650"
if [[ -n "$REGISTRY_USER" || -n "$REGISTRY_PASSWORD_FILE" ]]; then
  [[ -n "$REGISTRY_USER" && -r "$REGISTRY_PASSWORD_FILE" ]] || fail "Provide --registry-user and readable --registry-password-file"
fi
[[ "$MODE" != ha || "$PROFILE" != lite ]] || fail "HA with lite profile unsupported"
case "$PROFILE" in
  lite) REQUEST_CPU=500m; REQUEST_MEMORY=2Gi; LIMIT_CPU=1; LIMIT_MEMORY=4Gi; HEAP=2g; DEFAULT_STORAGE=30Gi ;;
  standard) REQUEST_CPU=1; REQUEST_MEMORY=4Gi; LIMIT_CPU=2; LIMIT_MEMORY=8Gi; HEAP=4g; DEFAULT_STORAGE=100Gi ;;
  large) REQUEST_CPU=2; REQUEST_MEMORY=8Gi; LIMIT_CPU=4; LIMIT_MEMORY=16Gi; HEAP=8g; DEFAULT_STORAGE=300Gi ;;
esac
STORAGE_SIZE="${STORAGE_SIZE:-$DEFAULT_STORAGE}"
COUNT=1
[[ "$MODE" != ha ]] || COUNT=3
command -v kubectl >/dev/null || fail "kubectl is required"
command -v helm >/dev/null || fail "helm is required"
confirm() {
 [[ "$YES" == true ]] && return
 local reply
 read -r -p "Proceed with $ACTION release $NAME in $NAMESPACE? [y/N] " reply
 [[ "$reply" == y || "$reply" == Y ]] || fail "Cancelled"
}
if [[ "$ACTION" == status ]]; then
 helm -n "$NAMESPACE" status "$NAME"
 kubectl -n "$NAMESPACE" get sts "$NAME-es"
 kubectl -n "$NAMESPACE" get deploy "$NAME-kibana" "$NAME-exporter" --ignore-not-found
 kubectl -n "$NAMESPACE" get ds "$NAME-fluent-bit" --ignore-not-found
 exit 0
fi
if [[ "$ACTION" == uninstall ]]; then
 confirm
 helm -n "$NAMESPACE" uninstall "$NAME" --wait
 info "PVCs, auth Secret and TLS Secret retained. No Operator."
 exit 0
fi
[[ -n "$STORAGE_CLASS" ]] || fail "install requires --storage-class; no implicit NFS"
for cmd in tar od base64; do command -v "$cmd" >/dev/null || fail "$cmd is required"; done
if [[ "$SKIP_IMAGES" == false ]]; then command -v docker >/dev/null || fail "Docker required for offline image import"; fi
kubectl config current-context >&2
kubectl get storageclass "$STORAGE_CLASS" >/dev/null || fail "StorageClass not found: $STORAGE_CLASS"
if [[ "$MODE" == ha ]]; then
 ready="$(kubectl get nodes --no-headers | awk '$2 ~ /^Ready$/ {n++} END {print n+0}')"
 ((ready >= 3)) || fail "HA requires 3 Ready nodes"
fi
if kubectl -n "$NAMESPACE" get sts "$NAME-es" >/dev/null 2>&1; then
 current_count="$(kubectl -n "$NAMESPACE" get sts "$NAME-es" -o jsonpath='{.spec.replicas}')"
 current_class="$(kubectl -n "$NAMESPACE" get sts "$NAME-es" -o jsonpath='{.spec.volumeClaimTemplates[0].spec.storageClassName}')"
 current_size="$(kubectl -n "$NAMESPACE" get sts "$NAME-es" -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}')"
 [[ "$current_count" == "$COUNT" ]] || fail "Topology change requires planned migration"
 [[ "$current_class" == "$STORAGE_CLASS" ]] || fail "StorageClass change requires data migration"
 [[ "$current_size" == "$STORAGE_SIZE" ]] || fail "PVC resizing requires separate workflow"
fi
confirm
