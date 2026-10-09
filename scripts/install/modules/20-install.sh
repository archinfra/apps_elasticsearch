marker="$(LC_ALL=C grep -an '^__ARCHINFRA_PAYLOAD_BELOW__$' "$0" | tail -n 1 | cut -d: -f1 || true)"
[[ -n "$marker" ]] || fail "No embedded payload: use .run from build.sh, not bare source"
WORKDIR="$(mktemp -d)"
tail -n "+$((marker+1))" "$0" | tar -xz -C "$WORKDIR"
[[ -s "$WORKDIR/operator/crds.yaml" && -s "$WORKDIR/operator/operator.yaml" ]] || fail "Incomplete ECK payload"
[[ -s "$WORKDIR/images/index.tsv" ]] || fail "Missing image index"
[[ -s "$WORKDIR/ARCH" ]] || fail "Missing architecture manifest"
ARCH="$(cat "$WORKDIR/ARCH")"
[[ "$ARCH" == amd64 || "$ARCH" == arm64 ]] || fail "Invalid embedded architecture"
node_arches="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}')"
matching="$(printf '%s\n' "$node_arches" | awk -v a="$ARCH" '$1==a {n++} END{print n+0}')"
[[ "$matching" -ge "$COUNT" ]] || fail "This $ARCH package needs at least $COUNT $ARCH nodes; found $matching"
if [[ "$SKIP_IMAGES" == false ]]; then
  if [[ -n "$REGISTRY_USER" ]]; then docker login "${REGISTRY%%/*}" -u "$REGISTRY_USER" --password-stdin < "$REGISTRY_PASSWORD_FILE" >/dev/null; fi
  while IFS=$'\t' read -r archive source target; do
    [[ -f "$WORKDIR/images/$archive" ]] || fail "Missing offline image: $archive"
    docker load -i "$WORKDIR/images/$archive" >/dev/null
    docker tag "$source" "$REGISTRY/$target-$ARCH"
    docker push "$REGISTRY/$target-$ARCH" >/dev/null
  done < "$WORKDIR/images/index.tsv"
fi
if kubectl get crd elasticsearches.elasticsearch.k8s.elastic.co >/dev/null 2>&1; then
  info "Existing ECK CRD found; retaining shared Operator/CRDs"
else
  [[ "$SKIP_OPERATOR" == false ]] || fail "--skip-operator-install set, but ECK CRDs missing"
  sed "s|docker.elastic.co/eck/eck-operator:3.5.0|$REGISTRY/eck-operator:3.5.0-$ARCH|g" \
    "$WORKDIR/operator/operator.yaml" > "$WORKDIR/operator/operator-internal.yaml"
  grep -Fq "$REGISTRY/eck-operator:3.5.0-$ARCH" "$WORKDIR/operator/operator-internal.yaml" || fail "Failed to rewrite ECK image"
  kubectl apply -f "$WORKDIR/operator/crds.yaml"
  kubectl wait --for=condition=Established crd/elasticsearches.elasticsearch.k8s.elastic.co --timeout=180s
  kubectl apply -f "$WORKDIR/operator/operator-internal.yaml"
  kubectl -n elastic-system patch deployment elastic-operator --type=merge -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/arch\":\"$ARCH\"}}}}}"
  kubectl -n elastic-system rollout status deployment/elastic-operator --timeout=300s
fi
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
render() {
  local src="$1" out="$2"
  sed \
    -e "s|__NAME__|$NAME|g" -e "s|__ES_NAME__|$NAME|g" \
    -e "s|__NAMESPACE__|$NAMESPACE|g" -e "s|__ARCH__|$ARCH|g" \
    -e "s|__COUNT__|$COUNT|g" \
    -e "s|__REQUEST_CPU__|$REQUEST_CPU|g" -e "s|__REQUEST_MEMORY__|$REQUEST_MEMORY|g" \
    -e "s|__LIMIT_CPU__|$LIMIT_CPU|g" -e "s|__LIMIT_MEMORY__|$LIMIT_MEMORY|g" \
    -e "s|__STORAGE_CLASS__|$STORAGE_CLASS|g" -e "s|__STORAGE_SIZE__|$STORAGE_SIZE|g" \
    -e "s|__ES_IMAGE__|$REGISTRY/elasticsearch:$ES_VERSION-$ARCH|g" \
    -e "s|__KIBANA_IMAGE__|$REGISTRY/kibana:$ES_VERSION-$ARCH|g" \
    -e "s|__FLUENT_IMAGE__|$REGISTRY/fluent-bit:5.1.3-$ARCH|g" \
    -e "s|__WRITER_SECRET__|$COLLECTOR_SECRET|g" "$src" > "$out"
}
render "$WORKDIR/manifests/elasticsearch.yaml.tmpl" "$WORKDIR/elasticsearch.yaml"
kubectl apply -f "$WORKDIR/elasticsearch.yaml"
if [[ "$KIBANA" == true ]]; then
  render "$WORKDIR/manifests/kibana.yaml.tmpl" "$WORKDIR/kibana.yaml"
  kubectl apply -f "$WORKDIR/kibana.yaml"
fi
if [[ "$COLLECTOR" == true ]]; then
  render "$WORKDIR/manifests/fluent-bit.yaml.tmpl" "$WORKDIR/fluent-bit.yaml"
  kubectl apply -f "$WORKDIR/fluent-bit.yaml"
fi
info "Resources submitted; ECK provisioning may take several minutes."
kubectl -n "$NAMESPACE" get elasticsearch "$NAME"
if [[ "$KIBANA" == true ]]; then kubectl -n "$NAMESPACE" get kibana "$NAME"; fi
info "Status: $0 status -n $NAMESPACE --name $NAME"
info "Kibana: kubectl -n $NAMESPACE port-forward svc/$NAME-kb-http 5601:5601"
info "Password: kubectl -n $NAMESPACE get secret $NAME-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d"
exit 0  # Do not interpret the embedded binary payload as shell source.
