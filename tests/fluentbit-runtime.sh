#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ARCH="${1:?architecture required}"
VERSION="$(tr -d '\r\n' < VERSION)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
helm template es charts/elasticsearch -n logging --set elasticsearch.storageClass=test \
  --show-only templates/fluentbit.yaml > "$tmp/rendered.yaml"
python3 - "$tmp" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
rendered = (root / 'rendered.yaml').read_text()
config = rendered.split('  fluent-bit.conf: |\n', 1)[1].split('\n---', 1)[0]
config = '\n'.join(line[4:] for line in config.splitlines()) + '\n'
(root / 'fluent-bit.conf').write_text(config)
# Regression: the former INPUT placement must be rejected by the real binary.
bad = config.replace('    storage.total_limit_size 5G\n', '')
bad = bad.replace('[INPUT]\n', '[INPUT]\n    storage.total_limit_size 5G\n')
(root / 'invalid.conf').write_text(bad)
PY
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" \
  -out "$tmp/ca.crt" -days 1 -subj '/CN=runtime-test' >/dev/null 2>&1
chmod 755 "$tmp"
chmod 644 "$tmp/ca.crt" "$tmp/"*.conf
image="archinfra-payload/fluent-bit:$VERSION-$ARCH"
check_config() {
  docker run --rm --network none --entrypoint /fluent-bit/bin/fluent-bit \
    -e WRITER_PASSWORD=test-only \
    -v "$tmp:/test:ro" -v "$tmp/ca.crt:/tls/ca.crt:ro" \
    "$image" --dry-run -c "/test/$1"
}
if check_config invalid.conf > "$tmp/invalid.log" 2>&1; then
  echo 'ERROR: Fluent Bit accepted the invalid INPUT buffer setting' >&2
  cat "$tmp/invalid.log" >&2
  exit 1
fi
grep -qi 'storage.total_limit_size' "$tmp/invalid.log" || { cat "$tmp/invalid.log"; exit 1; }
check_config fluent-bit.conf
echo "PASS: $ARCH Fluent Bit validates rendered config and rejects the old buffer setting"
