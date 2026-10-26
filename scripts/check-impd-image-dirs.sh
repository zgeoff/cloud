#!/usr/bin/env bash
# Check that each image record impd holds on the host has its build folder. switch-geoffcloud.sh
# runs it after nixie reports ready, so impd answers, and before it moves deployed/host:
#
#   bash scripts/check-impd-image-dirs.sh <host>
#
# impd keeps each image in /var/lib/imp/images/<folder>/rootfs.ext4 inside imp-host, where the
# folder is the record's digest without a leading `sha256:` (buildImagePaths and toDigestHex in
# zgeoff/impz packages/daemon/src/vm/storage/data-layout.ts, the same at v4.2.4 and v5.0.0). Each
# kind of record has its own digest form, at both releases: `sha256:<hex>` for an OCI image,
# `imp-build-<hex>` for an image a builder imp adds or builds
# (packages/daemon/src/imps/images/build/guest-build.ts), and `imp-<uuid>` for a template made
# from an imp (packages/daemon/src/imps/images/template-service.ts). A database restored across a preview-image change can name an image whose folder a
# later impd removed, and the preview-image unit sees the name at its reference and adds nothing,
# so every imp boot from it fails with ENOENT on rootfs.ext4. The check lists the records with
# `impz image ls --json` and the folders that hold a rootfs.ext4 with one `docker exec`, both over
# ssh.
# It prints one line and exits 0 when every record has its folder. It exits 1 and names each record
# without one, or a record whose digest names no folder name, such as one that holds a `/`; an ssh
# failure stops it with ssh's exit code.
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
  if [[ ! "$digest" =~ ^(sha256:)?([A-Za-z0-9][A-Za-z0-9._-]*)$ ]]; then
    problems+=("impd's image $name has the digest '$digest', which names no image folder")
  elif ! grep -qxF "${BASH_REMATCH[2]}" <<< "$dirs"; then
    problems+=("impd's image $name points at $images_dir/${BASH_REMATCH[2]}, which holds no rootfs.ext4")
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
