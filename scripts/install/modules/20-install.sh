marker="$(LC_ALL=C grep -anm1 '^__ARCHINFRA_PAYLOAD_BELOW__$' "$0" | cut -d: -f1 || true)"
[[ -n "$marker" ]] || fail "Missing embedded payload; use dist .run, not source modules"
WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR"
tail -n "+$((marker+1))" "$0" | tar -xz -C "$WORKDIR"
[[ -s "$WORKDIR/ARCH" && -f "$WORKDIR/charts/elasticsearch/Chart.yaml" ]] || fail "Corrupt chart payload"
[[ -s "$WORKDIR/images/index.tsv" ]] || fail "Missing offline image manifest"
ARCH="$(cat "$WORKDIR/ARCH")"
[[ "$ARCH" == amd64 || "$ARCH" == arm64 ]] || fail "Invalid payload architecture"
arch_nodes="$(kubectl get nodes -l "kubernetes.io/arch=$ARCH" --no-headers | awk '$2 ~ /^Ready$/ {n++} END {print n+0}')"
((arch_nodes >= COUNT)) || fail "Package $ARCH requires at least $COUNT Ready nodes of that architecture; found $arch_nodes"
if [[ "$SKIP_IMAGES" == false ]]; then
  if [[ -n "$REGISTRY_USER" ]]; then
    docker login "${REGISTRY%%/*}" -u "$REGISTRY_USER" --password-stdin < "$REGISTRY_PASSWORD_FILE" >/dev/null
  fi
  while IFS=$'\t' read -r archive ref target; do
    [[ -f "$WORKDIR/images/$archive" ]] || fail "Missing embedded image $archive"
    docker load -i "$WORKDIR/images/$archive" >/dev/null
    docker tag "$ref" "$REGISTRY/$target-$ARCH"
    docker push "$REGISTRY/$target-$ARCH" >/dev/null
  done < "$WORKDIR/images/index.tsv"
fi
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
SECRET="$NAME-auth"
if kubectl -n "$NAMESPACE" get secret "$SECRET" >/dev/null 2>&1; then
  for field in elastic-password kibana-password writer-password metrics-password kibana-encryption-key; do
    encoded="$(kubectl -n "$NAMESPACE" get secret "$SECRET" -o "jsonpath={.data.$field}")"
    [[ -n "$encoded" ]] || fail "Existing Secret $SECRET is missing $field; refusing auto-rotation"
  done
  info "Reusing managed authentication Secret $SECRET"
else
  mkdir -p "$WORKDIR/creds"
  chmod 700 "$WORKDIR/creds"
  for field in elastic-password kibana-password writer-password metrics-password kibana-encryption-key; do
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$WORKDIR/creds/$field"
    chmod 600 "$WORKDIR/creds/$field"
  done
  kubectl -n "$NAMESPACE" create secret generic "$SECRET" \
    --from-file="elastic-password=$WORKDIR/creds/elastic-password" \
    --from-file="kibana-password=$WORKDIR/creds/kibana-password" \
    --from-file="writer-password=$WORKDIR/creds/writer-password" \
    --from-file="metrics-password=$WORKDIR/creds/metrics-password" \
    --from-file="kibana-encryption-key=$WORKDIR/creds/kibana-encryption-key"
fi
CHART="$WORKDIR/charts/elasticsearch"
HELM_ARGS=(
  --namespace "$NAMESPACE" --timeout 20m --wait --history-max 5
  --set-string "image.registry=$REGISTRY"
  --set-string "image.tagElasticsearch=9.5.5-$ARCH"
  --set-string "image.tagKibana=9.5.5-$ARCH"
  --set-string "image.tagFluentBit=5.1.3-$ARCH"
  --set-string "image.tagCurl=8.16.0-$ARCH"
  --set-string "image.tagExporter=1.11.0-$ARCH"
  --set-string "arch=$ARCH"
  --set-string "auth.existingSecret=$SECRET"
  --set-string "elasticsearch.storageClass=$STORAGE_CLASS"
  --set-string "elasticsearch.storageSize=$STORAGE_SIZE"
  --set-string "elasticsearch.heap=$HEAP"
  --set "elasticsearch.replicas=$COUNT"
  --set-string "elasticsearch.resources.requests.cpu=$REQUEST_CPU"
  --set-string "elasticsearch.resources.requests.memory=$REQUEST_MEMORY"
  --set-string "elasticsearch.resources.limits.cpu=$LIMIT_CPU"
  --set-string "elasticsearch.resources.limits.memory=$LIMIT_MEMORY"
  --set "lifecycle.retentionDays=$RETENTION"
)
if helm -n "$NAMESPACE" status "$NAME" >/dev/null 2>&1; then
  INITIAL=false
else
  INITIAL=true
fi
if [[ "$INITIAL" == true ]]; then
  info "Stage 1: create native Elasticsearch StatefulSet and TLS, then wait for readiness"
  helm upgrade --install "$NAME" "$CHART" "${HELM_ARGS[@]}" \
    --set elasticsearch.bootstrapCluster=true \
    --set bootstrap.enabled=false \
    --set kibana.enabled=false \
    --set fluentBit.enabled=false \
    --set observability.enabled=false
else
  info "Existing Helm release detected: preserving cluster coordination state"
fi
info "Stage 2: configure scoped accounts/ILM and reconcile Kibana, Fluent Bit and metrics"
helm upgrade --install "$NAME" "$CHART" "${HELM_ARGS[@]}" \
  --set elasticsearch.bootstrapCluster=false \
  --set bootstrap.enabled=true \
  --set "kibana.enabled=$KIBANA" \
  --set "fluentBit.enabled=$FLUENTBIT" \
  --set "observability.enabled=$MONITORING"
kubectl -n "$NAMESPACE" rollout status sts/"$NAME-es" --timeout=5m
if [[ "$KIBANA" == true ]]; then
  kubectl -n "$NAMESPACE" rollout status deploy/"$NAME-kibana" --timeout=5m
fi
if [[ "$FLUENTBIT" == true ]]; then
  kubectl -n "$NAMESPACE" rollout status ds/"$NAME-fluent-bit" --timeout=5m
fi
info "Elasticsearch and supporting components submitted through Helm."
info "Read status: $0 status --namespace $NAMESPACE --name $NAME"
info "Kibana local access: kubectl -n $NAMESPACE port-forward svc/$NAME-kibana 5601:5601"
info "Password: kubectl -n $NAMESPACE get secret $SECRET -o jsonpath='{.data.elastic-password}' | base64 -d"
exit 0
