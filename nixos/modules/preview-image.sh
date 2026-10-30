# shellcheck shell=bash
# Make impd hold the image that every preview imp boots: the image named $PREVIEW_IMAGE_NAME,
# added from the digest-pinned registry reference $PREVIEW_IMAGE_REF. impd answers some time after
# imp-host starts, and reports ready on /health some time after that. So the script first asks
# impd's /health, from inside imp-host, until it reports ready, then lists impd's images until the
# list succeeds. It pauses 2 s between PREVIEW_IMAGE_WAIT_TRIES tries (default 300, about 10 min),
# and prints a failed try's error only when it differs from the one before. After each try that
# impd refuses with 401, it adds to the try's error the exec's HOME, what the exec sees of impd's
# token file, and impd's start time, from $PREVIEW_IMAGE_TOKEN_FACTS (preview-image-token-facts.sh),
# never the token. So a run of refusals prints one line, and another line only when the token file
# or impd's start changes. When the name already holds the reference, it adds nothing, because an
# add boots a builder imp and pulls the image again. Otherwise it adds the reference under the
# name, which impd points at the new image in place of any older one. It then pins the name, unless
# the name already holds a pin, so that impd's image eviction keeps the image while no preview imp
# runs; an add under a name that exists keeps the name's pin. PODMAN and SLEEP name the podman and
# sleep it runs (default: the ones on PATH, the package's own), so nixos/checks/preview.nix can
# swap in stand-ins.
podman="${PODMAN:-podman}"
pause="${SLEEP:-sleep}"
tries="${PREVIEW_IMAGE_WAIT_TRIES:-300}"
name="$PREVIEW_IMAGE_NAME"
ref="$PREVIEW_IMAGE_REF"
token_facts="$PREVIEW_IMAGE_TOKEN_FACTS"

err=$(mktemp)
trap 'rm -f "$err"' EXIT

# impd's API port inside imp-host, where impz's default URL points too
health_url=http://127.0.0.1:7070/health

check_ready() {
  local health
  health=$("$podman" exec imp-host curl -sS --max-time 5 "$health_url" 2> "$err") || return 1
  if ! jq -e '.ready == true' <<< "$health" > /dev/null 2>&1; then
    echo "impd is not ready: /health answered $health" > "$err"
    return 1
  fi
}

# Each impz call names root's home in imp-host, where impz finds impd's token. Podman sets a
# default HOME from the container's /etc/passwd as this unit's mounts show it, and a mount
# namespace made before imp-host's container started shows no such file, so HOME would be empty.
try=1
last=
ready=
while :; do
  if [ -z "$ready" ] && check_ready; then
    ready=1
  fi
  if [ -n "$ready" ] && images=$("$podman" exec -e HOME=/root imp-host impz image ls --json 2> "$err"); then
    break
  fi
  error=$(cat "$err")
  if [[ $error == "impz: unauthorized: "* ]]; then
    # a failed check, such as one that imp-host's stop cuts short, names its failure in the try's
    # error and leaves the wait running
    facts=$("$podman" exec -i imp-host sh -s -- /root/.config/impz/token /proc < "$token_facts" 2>&1) ||
      facts="the token-file check failed: $facts"
    error="$error; $facts"
  fi
  if [ "$try" -ge "$tries" ]; then
    echo "preview-image: impd listed no images after $tries tries: $error" >&2
    exit 1
  fi
  if [ "$error" != "$last" ]; then
    last=$error
    echo "preview-image: try $try: $error" >&2
  fi
  try=$((try + 1))
  "$pause" 2
done

current=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .ref' <<< "$images")
pinned=$(jq -r --arg name "$name" '.[] | select(.name == $name) | .pinned == true' <<< "$images")
if [ "$current" != "$ref" ]; then
  if [ -z "$current" ]; then
    echo "preview-image: adding $ref to impd as $name"
  else
    echo "preview-image: adding $ref to impd as $name, in place of $current"
  fi
  "$podman" exec -e HOME=/root imp-host impz image add "$ref" --name "$name" --json > /dev/null
fi

if [ "$pinned" != true ]; then
  echo "preview-image: pinning $name"
  "$podman" exec -e HOME=/root imp-host impz image pin "$name"
fi
echo "preview-image: impd holds $name at $ref, pinned"
