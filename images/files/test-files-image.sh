#!/usr/bin/env bash
# Image test for the files service (images/files/Dockerfile), run locally with Docker. It touches no
# cluster, no tunnel and no cloud account.
#
# It runs the image as the cluster runs it: as its nonroot user, on a read-only root, with no
# capabilities and no privilege escalation, and its volume at /data owned by that user. What this
# proves: the compiled binary starts on the distroless base, takes an upload with a role token
# from a curl form, serves the file with the type rules and the security headers, refuses a write
# without a token, and keeps its files and metadata on the volume across a restart. What it does
# not prove: k3s, the tunnel, Cloudflare's own limits.
#
# images/files/run-image-tests.sh builds the image under a tag that carries a random per-run id,
# sets FILES_IMAGE and FILES_RUN, runs this suite, and removes the image. Each case starts its own
# container on its own volume and an ephemeral loopback port, named from that id.
#
#   bash images/files/run-image-tests.sh
#   CASE='restart' bash images/files/run-image-tests.sh
# shell-suite: files-image
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # each create_case_tree cleanup expands when its case exits
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/create-case-tree.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/wait-for.sh"

it_serves_an_uploaded_PNG_inline_with_nosniff_and_the_sandbox_policy() {
  local image="$1" restic_image="$2" run="$3" port id
  name="files-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  setup_test "$tree" "$name" "$image" "$restic_image"
  port="$(cat "$tree/port")"
  printf '\211PNG\r\n\032\n\000\000\000\015' > "$tree/shot.png"

  curl -q --noproxy '*' -sS -o "$tree/upload" -H "@$tree/agent.headers" \
    -F "file=@$tree/shot.png" "http://127.0.0.1:$port/api/files"
  id="$(jq -r .id "$tree/upload")"
  curl -q --noproxy '*' -sS -D "$tree/headers" -o "$tree/served" "http://127.0.0.1:$port/$id/shot.png"

  assert_equals image/png "$(jq -r .contentType "$tree/upload")" 'recorded type'
  assert_equals agent "$(jq -r .uploader "$tree/upload")" uploader
  cmp "$tree/shot.png" "$tree/served"
  grep -i -v '^date:' "$tree/headers" | tr -d '\r' | LC_ALL=C sort -f > "$tree/headers.sorted"
  diff - "$tree/headers.sorted" << 'EOF'

Cache-Control: no-store
Content-Disposition: inline; filename="shot.png"; filename*=UTF-8''shot.png
content-length: 12
Content-Security-Policy: default-src 'none'; sandbox
Content-Type: image/png
HTTP/1.1 200 OK
X-Content-Type-Options: nosniff
EOF
}

it_serves_an_uploaded_HTML_file_as_an_octet_stream_attachment() {
  local image="$1" restic_image="$2" run="$3" port id
  name="files-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  setup_test "$tree" "$name" "$image" "$restic_image"
  port="$(cat "$tree/port")"
  printf '<!doctype html><script>alert(1)</script>' > "$tree/page.html"

  curl -q --noproxy '*' -sS -o "$tree/upload" -H "@$tree/owner.headers" \
    -F "file=@$tree/page.html;type=image/png" "http://127.0.0.1:$port/api/files"
  id="$(jq -r .id "$tree/upload")"
  curl -q --noproxy '*' -sS -D "$tree/headers" -o /dev/null "http://127.0.0.1:$port/$id/page.html"

  assert_equals text/html "$(jq -r .contentType "$tree/upload")" 'recorded type'
  grep -i '^content-type:\|^content-disposition:' "$tree/headers" | tr -d '\r' | LC_ALL=C sort -f > "$tree/headers.sorted"
  diff - "$tree/headers.sorted" << 'EOF'
Content-Disposition: attachment; filename="page.html"; filename*=UTF-8''page.html
Content-Type: application/octet-stream
EOF
}

it_refuses_an_upload_without_a_token_with_401() {
  local image="$1" restic_image="$2" run="$3" port code
  name="files-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  setup_test "$tree" "$name" "$image" "$restic_image"
  port="$(cat "$tree/port")"
  echo 'no token' > "$tree/note.txt"

  code="$(curl -q --noproxy '*' -sS -o /dev/null -w '%{http_code}' -F "file=@$tree/note.txt" \
    "http://127.0.0.1:$port/api/files")"

  assert_equals 401 "$code" 'HTTP status'
  assert_equals '' "$(docker run --rm --entrypoint /bin/ls -v "$name-data:/data" "$restic_image" /data/files)" 'stored files'
}

it_keeps_an_upload_on_its_volume_across_a_restart() {
  local image="$1" restic_image="$2" run="$3" port id
  name="files-image-$run-$BASHPID"
  create_case_tree 'docker rm -f "$name" > /dev/null 2>&1 || true; docker volume rm -f "$name-data" > /dev/null || true'
  setup_test "$tree" "$name" "$image" "$restic_image"
  port="$(cat "$tree/port")"
  echo 'kept across a restart' > "$tree/note.txt"
  curl -q --noproxy '*' -sS -o "$tree/upload" -H "@$tree/owner.headers" \
    -F "file=@$tree/note.txt" "http://127.0.0.1:$port/api/files"
  id="$(jq -r .id "$tree/upload")"

  docker restart "$name" > /dev/null
  port="$(docker port "$name" 8080/tcp)"
  port="${port##*:}"
  wait_for 30 "$name to answer /healthz" curl -q --noproxy '*' -sf -o /dev/null "http://127.0.0.1:$port/healthz"
  curl -q --noproxy '*' -sS -o "$tree/served" "http://127.0.0.1:$port/$id/note.txt"

  cmp "$tree/note.txt" "$tree/served"
}

# What every case needs: a volume owned by the image's nonroot uid, as the pod's fsGroup leaves
# it, and the service on it with the hashes of two fixed test tokens, as the cluster runs it. It
# writes each token's header to $tree/<role>.headers for curl's -H @file, and the loopback port to
# $tree/port once /healthz answers.
setup_test() {
  local tree="$1" name="$2" image="$3" restic_image="$4" port
  printf 'Authorization: Bearer %s\n' agent-token-image-test > "$tree/agent.headers"
  printf 'Authorization: Bearer %s\n' owner-token-image-test > "$tree/owner.headers"
  docker volume create "$name-data" > /dev/null
  docker run --rm --user 0 --entrypoint /bin/sh -v "$name-data:/s" "$restic_image" -c 'chown 65532:65532 /s'
  docker run -d --name "$name" --read-only --cap-drop ALL --security-opt no-new-privileges \
    -v "$name-data:/data" -p 127.0.0.1::8080 \
    -e FILES_PUBLIC_URL=https://files.fixture.invalid \
    -e "FILES_AGENT_TOKEN_SHA256=$(printf %s agent-token-image-test | sha256sum | cut -d' ' -f1)" \
    -e "FILES_OWNER_TOKEN_SHA256=$(printf %s owner-token-image-test | sha256sum | cut -d' ' -f1)" \
    "$image" > /dev/null
  port="$(docker port "$name" 8080/tcp)"
  port="${port##*:}"
  if ! wait_for 30 "$name to answer /healthz" curl -q --noproxy '*' -sf -o /dev/null "http://127.0.0.1:$port/healthz"; then
    docker logs "$name" 2>&1 | tail -20 >&2
    return 1
  fi
  echo "$port" > "$tree/port"
}

# the image and the run id come from run-image-tests.sh; the pinned restic image, which has a
# shell, chowns each volume and lists it
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# sets RESTIC_IMAGE, among the pins
# shellcheck source=/dev/null
source "$repo/images/atc-gateway/versions.env"
: "${FILES_IMAGE:?is unset: run this through images/files/run-image-tests.sh}"
: "${FILES_RUN:?is unset: run this through images/files/run-image-tests.sh}"
# shellcheck disable=SC2153 # RESTIC_IMAGE comes from versions.env
run_cases "$FILES_IMAGE" "$RESTIC_IMAGE" "$FILES_RUN"
