#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
ARCH=amd64
usage() {
  cat <<'EOF'
Usage: ./build.sh --arch amd64|arm64|all
Build prerequisites: docker, curl, python3, tar, sha256sum.
The finished .run needs bash, kubectl, tar, sed and (unless --skip-image-prepare) docker.
EOF
}
while (($#)); do
  case "$1" in
    --arch|-a) ARCH="${2:?missing architecture}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$ARCH" =~ ^(amd64|arm64|all)$ ]] || { echo "Invalid architecture: $ARCH" >&2; exit 2; }
for cmd in docker curl python3 tar sha256sum; do command -v "$cmd" >/dev/null || { echo "Missing build tool: $cmd" >&2; exit 1; }; done
mkdir -p "$ROOT/dist" "$ROOT/.build"
build_one() {
  local arch="$1" tmp out payload name upstream target ref archive
  tmp="$(mktemp -d "$ROOT/.build/payload.XXXXXX")"
  mkdir -p "$tmp/operator" "$tmp/images" "$tmp/manifests"
  cp "$ROOT"/manifests/*.tmpl "$tmp/manifests/"
  printf '%s\n' "$VERSION" > "$tmp/VERSION"
  curl -fsSL --retry 3 -o "$tmp/operator/crds.yaml" https://download.elastic.co/downloads/eck/3.5.0/crds.yaml
  curl -fsSL --retry 3 -o "$tmp/operator/operator.yaml" https://download.elastic.co/downloads/eck/3.5.0/operator.yaml
  grep -Fq 'docker.elastic.co/eck/eck-operator:3.5.0' "$tmp/operator/operator.yaml" || {
    echo 'Operator manifest image reference changed; review upstream before packaging' >&2
    rm -rf "$tmp"; exit 1
  }
  python3 - "$ROOT/images/image.json" "$tmp/images/bom.tsv" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as f:
    rows=json.load(f)
assert len(rows)==4 and len({r["target"] for r in rows})==4
with open(sys.argv[2],"w",encoding="utf-8") as o:
    for row in rows:
        assert all("\t" not in row[k] and "\n" not in row[k] for k in ("name","source","target"))
        o.write("\t".join((row["name"],row["source"],row["target"]))+"\n")
PY
  : > "$tmp/images/index.tsv"
  while IFS=$'\t' read -r name upstream target; do
    ref="archinfra-payload/$name:$VERSION-$arch"
    archive="$name-$arch.tar"
    echo "[build/$arch] docker pull $upstream"
    docker pull --platform "linux/$arch" "$upstream"
    docker tag "$upstream" "$ref"
    docker save -o "$tmp/images/$archive" "$ref"
    printf '%s\t%s\t%s\n' "$archive" "$ref" "$target" >> "$tmp/images/index.tsv"
  done < "$tmp/images/bom.tsv"
  rm "$tmp/images/bom.tsv"
  out="$ROOT/dist/elasticsearch-installer-v$VERSION-$arch.run"
  payload="$ROOT/.build/payload-$arch.tar.gz"
  tar -C "$tmp" -czf "$payload" .
  cat "$ROOT/install.sh" > "$out"
  printf '\n__ARCHINFRA_PAYLOAD_BELOW__\n' >> "$out"
  cat "$payload" >> "$out"
  chmod +x "$out"
  (cd "$ROOT/dist" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
  rm -rf "$tmp" "$payload"
  echo "Created: $out"
}
if [[ "$ARCH" == all ]]; then build_one amd64; build_one arm64; else build_one "$ARCH"; fi
