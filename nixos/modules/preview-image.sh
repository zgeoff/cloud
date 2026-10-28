# shellcheck shell=bash
# Make impd hold the image that every preview imp boots: the image named $PREVIEW_IMAGE_NAME,
# added from the digest-pinned registry reference $PREVIEW_IMAGE_REF. impd answers some time after
# imp-host starts, so the script lists impd's images until it answers, pausing 2 s between
# PREVIEW_IMAGE_WAIT_TRIES tries (default 60). When the name already holds the reference, it adds
# nothing, because an add boots a builder imp and pulls the image again. Otherwise it adds the
# reference under the name, which impd points at the new image in place of any older one. It then
# pins the name, unless the name already holds a pin, so that impd's image eviction keeps the
# image while no preview imp runs; an add under a name that exists keeps the name's pin. DOCKER
# and SLEEP name the docker and sleep it runs (default: the ones on PATH, the package's own), so
# nixos/checks/preview.nix can swap in stand-ins.
docker="${DOCKER:-docker}"
pause="${SLEEP:-sleep}"
tries="${PREVIEW_IMAGE_WAIT_TRIES:-60}"
name="$PREVIEW_IMAGE_NAME"
ref="$PREVIEW_IMAGE_REF"

err=$(mktemp)
trap 'rm -f "$err"' EXIT

try=1
until images=$("$docker" exec imp-host impz image ls --json 2> "$err"); do
  if [ "$try" -ge "$tries" ]; then
    echo "preview-image: impd listed no images after $tries tries: $(cat "$err")" >&2
    exit 1
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
  "$docker" exec imp-host impz image add "$ref" --name "$name" --json > /dev/null
fi

if [ "$pinned" != true ]; then
  echo "preview-image: pinning $name"
  "$docker" exec imp-host impz image pin "$name"
fi
echo "preview-image: impd holds $name at $ref, pinned"
