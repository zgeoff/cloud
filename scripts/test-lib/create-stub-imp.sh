# shellcheck shell=bash
# create_stub_imp <bin>: writes <bin>/imp, a stand-in for the imp CLI calls that
# build-agent-image.sh and switch-agent-image.sh make. It logs each call's argv as a JSON line to
# STUB_TREE/calls, and keeps the host's images and imps in STUB_TREE/imp-state.json as
# {"images":[{"name","digest"}],"imps":[{"name","image"}]}, which a test writes first; a missing
# file is an empty host.
#
# - `image ls --json` prints each image as {"name","ref","digest"}, the fields of the real
#   output the scripts read, with ref imp/<name>:latest.
# - `image build <dir> --name <n>` copies <dir> to STUB_TREE/build-saw, then sleeps
#   STUB_IMP_BUILD_SECONDS when it is set, then, when STUB_IMP_BUILD_ERROR is set, prints it on
#   stderr and exits 1; otherwise it adds image <n> with digest imp-build-stub-<n> and prints
#   nothing.
# - `image rm <n>` removes the image, or fails when no image has that name or an imp uses it.
# - `new <n> --image <i>` adds imp <n> on image <i> and prints its name, or fails when the image
#   is missing or the name is taken.
# - `ls --json` prints each imp as {"name","image"}.
# - `rm <n>` removes the imp, or fails when none has that name.
# - Any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# The NOT_FOUND messages and exit 1 match imp 0.38.1's answers to `imp image rm` and `imp rm` for
# a missing name, checked on 2026-10-10 against the geoffcloud host. The CONFLICT messages for an
# image in use and a taken imp name were not reproduced against the real imp, and no script reads
# their text: the scripts check exit codes only.
create_stub_imp() {
  local bin="$1"
  cat > "$bin/imp" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' imp "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
state="$STUB_TREE/imp-state.json"
[ -f "$state" ] || echo '{"images":[],"imps":[]}' > "$state"
update() {
  jq "$@" "$state" > "$state.new" && mv "$state.new" "$state"
}
case "$*" in
  "image ls --json")
    jq -c '[.images[] | {name, ref: "imp/\(.name):latest", digest}]' "$state"
    ;;
  "image build "*" --name "*)
    cp -R "$3" "$STUB_TREE/build-saw"
    if [ -n "${STUB_IMP_BUILD_SECONDS:-}" ]; then sleep "$STUB_IMP_BUILD_SECONDS"; fi
    if [ -n "${STUB_IMP_BUILD_ERROR:-}" ]; then echo "$STUB_IMP_BUILD_ERROR" >&2; exit 1; fi
    update --arg n "$5" '.images += [{name: $n, digest: "imp-build-stub-\($n)"}]'
    ;;
  "image rm "*)
    if ! jq -e --arg n "$3" 'any(.images[]; .name == $n)' "$state" > /dev/null; then
      echo "imp: NOT_FOUND: image $3 not found" >&2; exit 1
    fi
    if jq -e --arg n "$3" 'any(.imps[]; .image == $n)' "$state" > /dev/null; then
      echo "imp: CONFLICT: image $3 is in use" >&2; exit 1
    fi
    update --arg n "$3" '.images |= map(select(.name != $n))'
    ;;
  "new "*" --image "*)
    if ! jq -e --arg i "$4" 'any(.images[]; .name == $i)' "$state" > /dev/null; then
      echo "imp: NOT_FOUND: image $4 not found" >&2; exit 1
    fi
    if jq -e --arg n "$2" 'any(.imps[]; .name == $n)' "$state" > /dev/null; then
      echo "imp: CONFLICT: imp $2 already exists" >&2; exit 1
    fi
    update --arg n "$2" --arg i "$4" '.imps += [{name: $n, image: $i}]'
    echo "$2"
    ;;
  "ls --json")
    jq -c '.imps' "$state"
    ;;
  "rm "*)
    if ! jq -e --arg n "$2" 'any(.imps[]; .name == $n)' "$state" > /dev/null; then
      echo "imp: NOT_FOUND: imp $2 not found" >&2; exit 1
    fi
    update --arg n "$2" '.imps |= map(select(.name != $n))'
    ;;
  *) echo "unexpected: $*" >&2; exit 97 ;;
esac
STUB
  chmod +x "$bin/imp"
}
