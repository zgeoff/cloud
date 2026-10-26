#!/usr/bin/env bash
# Check that each image record impd holds on the host has its build folder. switch-geoffcloud.sh
# runs it after nixie reports ready, so impd answers, and before it moves deployed/host:
#
#   bash scripts/check-impd-image-dirs.sh <host>
#
# impd keeps each image in /var/lib/imp/images/<digest hex>/rootfs.ext4 inside imp-host
# (buildImagePaths in zgeoff/impz packages/daemon/src/vm/storage/data-layout.ts, the same at v4.2.4
# and v5.0.0). A database restored across a preview-image change can name an image whose folder a
# later impd removed, and the preview-image unit sees the name at its reference and adds nothing,
# so every imp boot from it fails with ENOENT on rootfs.ext4. The check lists the records with
# `impz image ls --json` and the folders that hold a rootfs.ext4 with one `docker exec`, both over
# ssh.
# It prints one line and exits 0 when every record has its folder. It exits 1 and names each record
# without one, or a record whose digest is no sha256 digest; an ssh failure stops it with ssh's
# exit code.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: check-impd-image-dirs.sh <host>" >&2
  exit 2
fi
host="$1"
images_dir=/var/lib/imp/images

records="$(ssh -o BatchMode=yes "$host" "docker exec imp-host impz image ls --json")"
# one `<name> <digest>` line per record
pairs="$(jq -r '.[] | "\(.name) \(.digest)"' <<< "$records")"
if [ -z "$pairs" ]; then
  echo "== impd holds no image"
  exit 0
fi
# the folders that hold a rootfs.ext4, one digest hex a line
dirs="$(ssh -o BatchMode=yes "$host" "docker exec imp-host sh -c 'cd $images_dir && for d in *; do if [ -f \"\$d/rootfs.ext4\" ]; then echo \"\$d\"; fi; done'")"

problems=()
names=()
while read -r name digest; do
  if [[ ! "$digest" =~ ^sha256:([0-9a-f]{64})$ ]]; then
    problems+=("impd's image $name has the digest '$digest', which is no sha256 digest")
  elif ! grep -qxF "${BASH_REMATCH[1]}" <<< "$dirs"; then
    problems+=("impd's image $name points at $images_dir/${BASH_REMATCH[1]}, which holds no rootfs.ext4")
  fi
  names+=("$name")
done <<< "$pairs"
if [ "${#problems[@]}" != 0 ]; then
  printf '%s\n' "${problems[@]}" >&2
  echo "re-add each image from its reference with \`impz image add <ref> --name <name>\`" \
    "(docs/runbooks/restore-geoff-cloud.md, Roll impd's database back)" >&2
  exit 1
fi
listed="${names[*]}"
echo "== impd's images have their build folders: ${listed// /, }"
