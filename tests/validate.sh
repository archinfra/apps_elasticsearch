#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bash -n build.sh scripts/assemble-install.sh scripts/install/modules/*.sh tests/validate.sh
bash scripts/assemble-install.sh "$tmp/installer.run"
bash -n "$tmp/installer.run"
"$tmp/installer.run" help | grep -q 'DeleteOnScaledownOnly'
build_help="$(./build.sh --help)"
[[ "$build_help" == *amd64* ]]
if "$tmp/installer.run" install --mode bad >/dev/null 2>&1; then
  echo "Invalid mode must fail" >&2; exit 1
fi
if "$tmp/installer.run" install --enable-collector >/dev/null 2>&1; then
  echo "Collector without Secret must fail" >&2; exit 1
fi
python3 - <<'PY'
import json,pathlib
images=json.loads(pathlib.Path("images/image.json").read_text())
assert len(images)==4
assert len({row["target"] for row in images})==4
assert all(row["source"] and row["target"] for row in images)
for path in pathlib.Path("manifests").glob("*.tmpl"):
    text=path.read_text()
    assert "kind:" in text and "__NAMESPACE__" in text
es=pathlib.Path("manifests/elasticsearch.yaml.tmpl").read_text()
assert "DeleteOnScaledownOnly" in es
collector=pathlib.Path("manifests/fluent-bit.yaml.tmpl").read_text()
assert "secretKeyRef:" in collector and "TLS.Verify            On" in collector
print("BOM and manifest checks passed")
PY
mkdir -p "$tmp/payload/operator" "$tmp/payload/images" "$tmp/payload/manifests" "$tmp/mockbin" "$tmp/applied"
cp manifests/*.tmpl "$tmp/payload/manifests/"
printf 'amd64\n' > "$tmp/payload/ARCH"
printf 'operator mock\n' > "$tmp/payload/operator/crds.yaml"
printf 'image: docker.elastic.co/eck/eck-operator:3.5.0\n' > "$tmp/payload/operator/operator.yaml"
printf '# already-in-registry\n' > "$tmp/payload/images/index.tsv"
cat > "$tmp/mockbin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -e
case "$*" in
  *"get nodes -o jsonpath="*) printf 'amd64\namd64\namd64\n'; exit 0 ;;
  *"get nodes --no-headers"*) printf 'worker-a Ready\nworker-b Ready\nworker-c Ready\n'; exit 0 ;;
  *"create namespace "*)
    printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: logging\n'; exit 0 ;;
  *"get crd elasticsearches.elasticsearch.k8s.elastic.co"*) exit 0 ;;
  *"get secret "*) exit 0 ;;
  *"apply -f "*) 
    path="${!#}"
    if [[ "$path" == - ]]; then cat >/dev/null; else cp "$path" "$TEST_APPLIED/$(basename "$path")"; fi
    exit 0 ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$tmp/mockbin/kubectl"
tar -C "$tmp/payload" -czf "$tmp/payload.tar.gz" .
printf '\n__ARCHINFRA_PAYLOAD_BELOW__\n' >> "$tmp/installer.run"
cat "$tmp/payload.tar.gz" >> "$tmp/installer.run"
PATH="$tmp/mockbin:$PATH" TEST_APPLIED="$tmp/applied" "$tmp/installer.run" install --namespace logging --storage-class mock-sc --mode ha --skip-image-prepare -y
grep -q 'count: 3' "$tmp/applied/elasticsearch.yaml"
grep -q 'elasticsearch:9.5.5-amd64' "$tmp/applied/elasticsearch.yaml"
grep -q 'kubernetes.io/arch: amd64' "$tmp/applied/elasticsearch.yaml"
test -f "$tmp/applied/kibana.yaml"
PATH="$tmp/mockbin:$PATH" "$tmp/installer.run" uninstall -n logging -y
echo "PASS: assembler, CLI guards, offline payload extraction, mock installation and uninstall"
