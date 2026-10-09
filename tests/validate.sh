#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bash -n build.sh scripts/assemble-install.sh scripts/install/modules/*.sh
grep -Fq 'scripts/assemble-install.sh' build.sh
! grep -Eq 'eck|ECK|operator.yaml|crds.yaml' build.sh scripts/install/modules/*.sh
python3 - <<'PY'
import json, pathlib
images=json.loads(pathlib.Path("images/image.json").read_text())
assert len(images)==5 and len({i['target'] for i in images})==5, "Expected 5 unique offline images"
names={i['name'] for i in images}
assert names=={'elasticsearch','kibana','fluent-bit','curl','elasticsearch-exporter'}
chart=pathlib.Path("charts/elasticsearch")
assert (chart/"Chart.yaml").is_file()
assert len(list((chart/"templates").glob("*.yaml"))) >= 8
assert "volumeClaimTemplates" in (chart/"templates/es-statefulset.yaml").read_text()
assert "genSignedCert" in (chart/"templates/00-tls-secret.yaml").read_text()
print("PASS: offline BOM and Helm templates exist")
PY
helm lint charts/elasticsearch --set elasticsearch.storageClass=mock-sc
helm template es charts/elasticsearch -n logging \
  --set elasticsearch.storageClass=mock-sc \
  --set bootstrap.enabled=true > "$tmp/single.yaml"
helm template es charts/elasticsearch -n logging \
  --set elasticsearch.storageClass=mock-sc \
  --set elasticsearch.replicas=3 \
  --set elasticsearch.bootstrapCluster=true \
  --set bootstrap.enabled=true > "$tmp/ha.yaml"
grep -q 'kind: StatefulSet' "$tmp/single.yaml"
grep -q 'kind: Deployment' "$tmp/single.yaml"
grep -q 'kind: DaemonSet' "$tmp/single.yaml"
grep -q 'kind: Secret' "$tmp/single.yaml"
grep -q 'kind: Job' "$tmp/single.yaml"
grep -q 'cluster.initial_master_nodes:' "$tmp/ha.yaml"
! grep -Eq '^kind: (Elasticsearch|Kibana)$' "$tmp/single.yaml"
bash scripts/assemble-install.sh "$tmp/installer.run"
bash -n "$tmp/installer.run"
"$tmp/installer.run" help | grep -q 'NO Operator'
if "$tmp/installer.run" install --mode invalid > /dev/null 2>&1; then
  echo "invalid mode unexpectedly succeeded" >&2; exit 1
fi
mkdir -p "$tmp/payload/charts" "$tmp/payload/images" "$tmp/mockbin"
cp -R charts/elasticsearch "$tmp/payload/charts/"
printf 'amd64\n' > "$tmp/payload/ARCH"
printf '# mocked locally imported images\n' > "$tmp/payload/images/index.tsv"
cat > "$tmp/mockbin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -e
case " $* " in
  *" get nodes -l "*) printf 'worker1 Ready\nworker2 Ready\nworker3 Ready\n';;
  *" get nodes --no-headers "*) printf 'worker1 Ready\nworker2 Ready\nworker3 Ready\n';;
  *" create namespace "*) printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: logging\n';;
  *" apply -f - "*) cat >/dev/null ;;
  *" get sts "*) exit 1 ;;
  *" get secret "*) exit 1 ;;
  *) exit 0 ;;
esac
MOCK
cat > "$tmp/mockbin/helm" <<'MOCK'
#!/usr/bin/env bash
set -e
case " $* " in
  *" status "*) [[ -f "$MOCK_HELM_MARKER" ]] ;;
  *" upgrade --install "*) touch "$MOCK_HELM_MARKER"; printf 'helm-upgrade\n' >> "$MOCK_HELM_CALLS" ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$tmp/mockbin/"*
tar -C "$tmp/payload" -czf "$tmp/payload.tar.gz" .
printf '\n__ARCHINFRA_PAYLOAD_BELOW__\n' >> "$tmp/installer.run"
cat "$tmp/payload.tar.gz" >> "$tmp/installer.run"
PATH="$tmp/mockbin:$PATH" MOCK_HELM_MARKER="$tmp/marker" MOCK_HELM_CALLS="$tmp/calls" \
  "$tmp/installer.run" install --namespace logging --mode ha --resource-profile standard \
    --storage-class mock-sc --skip-image-prepare -y
[[ "$(wc -l < "$tmp/calls")" == 2 ]] || { echo "Expected 2-stage Helm installation" >&2; exit 1; }
PATH="$tmp/mockbin:$PATH" MOCK_HELM_MARKER="$tmp/marker" \
  "$tmp/installer.run" uninstall -n logging -y
echo "PASS: lint, single+HA Helm rendering, CLI guards, self-extraction, two-stage mocked install"
