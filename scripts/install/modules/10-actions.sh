[[ "$ACTION" =~ ^(install|status|uninstall|help)$ ]] || fail "Unknown action: $ACTION"
[[ "$ACTION" != help ]] || { usage; exit 0; }
valid_name "$NAMESPACE" || fail "Invalid namespace"
valid_name "$NAME" || fail "Invalid Elasticsearch name"
valid_registry "$REGISTRY" || fail "Invalid registry prefix"
[[ "$MODE" =~ ^(single|ha)$ ]] || fail "Mode must be single or ha"
[[ "$PROFILE" =~ ^(lite|standard|large)$ ]] || fail "Invalid profile"
[[ -z "$STORAGE_SIZE" ]] || valid_size "$STORAGE_SIZE" || fail "Invalid storage size"
[[ -z "$STORAGE_CLASS" ]] || valid_storage_class "$STORAGE_CLASS" || fail "Invalid StorageClass"
[[ -z "$COLLECTOR_SECRET" ]] || valid_name "$COLLECTOR_SECRET" || fail "Invalid collector Secret"
if [[ -n "$REGISTRY_USER" || -n "$REGISTRY_PASSWORD_FILE" ]]; then
  [[ -n "$REGISTRY_USER" && -r "$REGISTRY_PASSWORD_FILE" ]] || fail "Both --registry-user and readable --registry-password-file required"
fi
if [[ "$COLLECTOR" == true ]]; then
  [[ -n "$COLLECTOR_SECRET" ]] || fail "--enable-collector requires --collector-secret"
fi
if [[ "$MODE" == ha && "$PROFILE" == lite ]]; then fail "lite is a test profile and cannot be HA"; fi
case "$PROFILE" in
  lite) REQUEST_CPU=500m; REQUEST_MEMORY=2Gi; LIMIT_CPU=1; LIMIT_MEMORY=4Gi; DEFAULT_STORAGE=30Gi ;;
  standard) REQUEST_CPU=1; REQUEST_MEMORY=4Gi; LIMIT_CPU=2; LIMIT_MEMORY=8Gi; DEFAULT_STORAGE=100Gi ;;
  large) REQUEST_CPU=2; REQUEST_MEMORY=8Gi; LIMIT_CPU=4; LIMIT_MEMORY=16Gi; DEFAULT_STORAGE=300Gi ;;
esac
STORAGE_SIZE="${STORAGE_SIZE:-$DEFAULT_STORAGE}"
COUNT=1
[[ "$MODE" != ha ]] || COUNT=3
command -v kubectl >/dev/null || fail "kubectl is required"
if [[ "$ACTION" == status ]]; then
  kubectl -n "$NAMESPACE" get elasticsearch "$NAME"
  kubectl -n "$NAMESPACE" get kibana "$NAME" --ignore-not-found
  kubectl -n "$NAMESPACE" get daemonset archinfra-fluent-bit --ignore-not-found
  exit 0
fi
confirm() {
  [[ "$YES" == true ]] && return
  local answer
  read -r -p "Proceed with $ACTION in namespace $NAMESPACE (ES=$NAME)? [y/N] " answer
  [[ "$answer" == y || "$answer" == Y ]] || fail "Cancelled"
}
if [[ "$ACTION" == uninstall ]]; then
  confirm
  kubectl -n "$NAMESPACE" delete daemonset archinfra-fluent-bit --ignore-not-found
  kubectl -n "$NAMESPACE" delete configmap archinfra-fluent-bit --ignore-not-found
  kubectl -n "$NAMESPACE" delete serviceaccount archinfra-fluent-bit --ignore-not-found
  kubectl delete clusterrolebinding "$NAMESPACE-archinfra-fluent-bit" --ignore-not-found
  kubectl delete clusterrole "$NAMESPACE-archinfra-fluent-bit" --ignore-not-found
  kubectl -n "$NAMESPACE" delete kibana "$NAME" --ignore-not-found
  kubectl -n "$NAMESPACE" delete elasticsearch "$NAME" --ignore-not-found
  info "ECK Operator/CRDs retained. ES PVCs protected via DeleteOnScaledownOnly."
  exit 0
fi
[[ -n "$STORAGE_CLASS" ]] || fail "install requires --storage-class; no implicit NFS fallback"
command -v tar >/dev/null || fail "tar is required"
command -v sed >/dev/null || fail "sed is required"
if [[ "$SKIP_IMAGES" == false ]]; then command -v docker >/dev/null || fail "docker required without --skip-image-prepare"; fi
kubectl config current-context >&2
kubectl get storageclass "$STORAGE_CLASS" >/dev/null || fail "StorageClass $STORAGE_CLASS not found"
if [[ "$MODE" == ha ]]; then
  ready="$(kubectl get nodes --no-headers | awk '$2 ~ /^Ready$/ {n++} END {print n+0}')"
  [[ "$ready" -ge 3 ]] || fail "HA requires at least 3 Ready Kubernetes nodes"
fi
if [[ "$COLLECTOR" == true ]]; then
  kubectl -n "$NAMESPACE" get secret "$COLLECTOR_SECRET" >/dev/null || fail "Collector Secret missing in namespace $NAMESPACE"
  for key in username password; do
    value="$(kubectl -n "$NAMESPACE" get secret "$COLLECTOR_SECRET" -o "jsonpath={.data.$key}")"
    [[ -n "$value" ]] || fail "Collector Secret must contain $key"
  done
fi
confirm
