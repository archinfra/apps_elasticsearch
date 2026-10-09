#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(tr -d '\r\n' < "$ROOT/VERSION")"
ARCH=amd64
usage() {
  cat <<'EOF'
Usage: ./build.sh --arch amd64|arm64|all
Build host: docker, python3, bash, tar, sha256sum
Target host: helm, kubectl, bash, tar; Docker only when preparing images.
All image layers and the self-maintained Helm chart are embedded. No Operator/CRD.
EOF
}
while (($#)); do
  case "$1" in
    --arch|-a) ARCH="${2:?missing architecture}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$ARCH" =~ ^(amd64|arm64|all)$ ]] || { echo "Unsupported arch" >&2; exit 2; }
for cmd in docker python3 tar sha256sum; do command -v "$cmd" >/dev/null || { echo "Missing build tool: $cmd" >&2; exit 1; }; done
mkdir -p "$ROOT/dist" "$ROOT/.build"

build_one() {
  local arch="$1" tmp out payload name upstream target ref archive
  tmp="$(mktemp -d "$ROOT/.build/payload.XXXXXX")"
  mkdir -p "$tmp/charts" "$tmp/images"
  cp -R "$ROOT/charts/elasticsearch" "$tmp/charts/"
  printf '%s\n' "$VERSION" > "$tmp/VERSION"
  printf '%s\n' "$arch" > "$tmp/ARCH"
  python3 - "$ROOT/images/image.json" "$tmp/images/bom.tsv" <<'PY'
import json,sys
rows=json.load(open(sys.argv[1], encoding="utf8"))
assert len(rows)==5 and len({r["target"] for r in rows})==5
with open(sys.argv[2],"w",encoding="utf8") as out:
    for r in rows:
        assert all("\t" not in r[k] and "\n" not in r[k] for k in ("name","source","target"))
        out.write("\t".join((r["name"],r["source"],r["target"]))+"\n")
PY
  : > "$tmp/images/index.tsv"
  while IFS=$'\t' read -r name upstream target; do
    ref="archinfra-payload/$name:$VERSION-$arch"
    archive="$name-$arch.tar"
    echo "[build/$arch] pulling $upstream"
    docker pull --platform "linux/$arch" "$upstream"
    docker tag "$upstream" "$ref"
    docker save -o "$tmp/images/$archive" "$ref"
    printf '%s\t%s\t%s\n' "$archive" "$ref" "$target" >> "$tmp/images/index.tsv"
  done < "$tmp/images/bom.tsv"
  rm "$tmp/images/bom.tsv"
  payload="$ROOT/.build/archinfra-$arch.tar.gz"
  tar -C "$tmp" -czf "$payload" .
  out="$ROOT/dist/elasticsearch-installer-v$VERSION-$arch.run"
  bash "$ROOT/scripts/assemble-install.sh" "$out"
  printf '\n__ARCHINFRA_PAYLOAD_BELOW__\n' >> "$out"
  cat "$payload" >> "$out"
  chmod +x "$out"
  (cd "$ROOT/dist" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256")
  rm -rf "$tmp" "$payload"
  echo "Created $out"
}
if [[ "$ARCH" == all ]]; then build_one amd64; build_one arm64; else build_one "$ARCH"; fi
