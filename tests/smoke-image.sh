#!/usr/bin/env bash
# Exercise the published image itself on both Linux architectures before the
# release becomes public. The only test media is the synthetic local fixture.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo 'Usage: smoke-image.sh IMAGE_REPOSITORY IMAGE_TAG [SUMMARY_FILE [VERSION_TAG]]' >&2
  exit 2
fi
repository=$1
tag=$2
summary=${3:-}
version_tag=${4:-$tag}
[[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || {
  echo 'Invalid image tag' >&2; exit 2;
}
[[ $version_tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo 'Invalid release tag' >&2; exit 2;
}
image="$repository:$tag"
expected_version=${version_tag#v}
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fixture_dir="$script_dir/fixtures"
[[ -r "$fixture_dir/sample.mp4" ]] || { echo 'Missing synthetic fixture' >&2; exit 1; }
workspace=$(mktemp -d "${TMPDIR:-/tmp}/deemedia-image-smoke.XXXXXX")
container=
volume=
cleanup() {
  if [[ -n $container ]]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
  if [[ -n $volume ]]; then docker volume rm "$volume" >/dev/null 2>&1 || true; fi
  rm -rf "$workspace"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker buildx imagetools inspect --raw "$image" > "$workspace/index.json"
if [[ -n $summary ]]; then
  printf '\n### DeeMedia Link image smoke tests\n\n| Platform | Image size | Compressed layers |\n| --- | ---: | ---: |\n' >> "$summary"
fi
for arch in amd64 arm64; do
  digest=$(jq -er --arg arch "$arch" '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest] | if length == 1 then .[0] else error("expected one image for architecture") end' "$workspace/index.json")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Invalid $arch manifest digest" >&2; exit 1; }
  docker buildx imagetools inspect --raw "$repository@$digest" > "$workspace/manifest.json"
  compressed=$(jq -er '[.layers[].size] | add | select(type == "number" and . > 0)' "$workspace/manifest.json")
  docker pull --platform "linux/$arch" "$image" >/dev/null
  unpacked=$(docker image inspect --format '{{.Size}}' "$image")
  [[ $unpacked =~ ^[0-9]+$ ]] && (( unpacked > 0 )) || { echo "Invalid $arch image size" >&2; exit 1; }

  suffix="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$arch-$$"
  container="deemedia-link-smoke-$suffix"
  volume="deemedia-link-smoke-$suffix"
  docker volume create "$volume" >/dev/null
  # The image's /data is owned by UID 1000. A fresh named volume receives that
  # ownership from the image, letting the unprivileged container write state.
  docker run --rm -i --platform "linux/$arch" --mount "type=volume,src=$volume,dst=/data" \
    --entrypoint /bin/sh "$image" -c 'umask 077; cat > /data/state.json' <<'JSON'
{"config":{"name":"smoke","auto_discover":false,"roots":[{"id":"smoke","name":"smoke","kind":"local","path":"/media/smoke","storage_mode":"local","probe":true}]},"files":{},"sequence":0,"pending":[]}
JSON
  # Do not override DEEMEDIA_LINK_DATA, MEDIA_DIR, ADDR or PROBE_DIR: this
  # verifies the image defaults as well as read-only-root deployment.
  docker run -d --platform "linux/$arch" --name "$container" --read-only \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,exec,nosuid,nodev,size=128m \
    --mount "type=volume,src=$volume,dst=/data" \
    --mount "type=bind,src=$fixture_dir,dst=/media/smoke,readonly" "$image" >/dev/null

  passed=false
  for ((attempt=0; attempt<120; attempt++)); do
    if docker exec "$container" /usr/local/bin/deemedia-link --probe >/dev/null 2>&1 && \
       docker exec "$container" wget -qO- -T 3 http://127.0.0.1:8097/healthz 2>/dev/null | \
         python3 -c 'import json,sys; x=json.load(sys.stdin); sys.exit(0 if x.get("ok") is True and x.get("version") == sys.argv[1] else 1)' "$expected_version" 2>/dev/null && \
       docker exec "$container" cat /data/state.json 2>/dev/null | \
         python3 -c 'import json,sys; x=json.load(sys.stdin); fs=x.get("files",{}).values(); ok=any(f.get("path")=="sample.mp4" and any(s.get("type")=="video" and s.get("codec")=="mpeg4" and s.get("width")==16 and s.get("height")==16 for s in (f.get("media_info") or {}).get("streams",[])) for f in fs); sys.exit(0 if ok else 1)' 2>/dev/null; then
      passed=true
      break
    fi
    if [[ $(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null || true) != true ]]; then
      break
    fi
    sleep 1
  done
  if [[ $passed != true ]]; then
    echo "Image smoke test failed for linux/$arch" >&2
    docker logs --tail 80 "$container" >&2 || true
    exit 1
  fi
  # The cache exists only after the embedded ffprobe was extracted and ran.
  docker exec "$container" /bin/sh -c 'find /tmp/deemedia-link-tools -type f -name "ffprobe-*" | grep -q .' || {
    echo "Embedded ffprobe cache missing for linux/$arch" >&2; exit 1;
  }
  unpacked_mib=$(awk -v size="$unpacked" 'BEGIN {printf "%.2f MiB", size/1048576}')
  compressed_mib=$(awk -v size="$compressed" 'BEGIN {printf "%.2f MiB", size/1048576}')
  printf 'SMOKE_IMAGE_SIZE arch=%s unpacked_bytes=%s compressed_layer_bytes=%s\n' "$arch" "$unpacked" "$compressed"
  if [[ -n $summary ]]; then
    printf '| linux/%s | %s | %s |\n' "$arch" "$unpacked_mib" "$compressed_mib" >> "$summary"
  fi
  docker rm -f "$container" >/dev/null
  container=
  docker volume rm "$volume" >/dev/null
  volume=
done
