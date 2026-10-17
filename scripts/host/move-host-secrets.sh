#!/usr/bin/env bash
# Runs as root on geoffcloud. It moves the host's secret files and impd's database copies onto
# the encrypted datasets of tank/cloud (docs/runbooks/move-host-secrets.md). Send it on ssh's
# stdin, with the mode as its argument:
#
#   ssh root@geoffcloud bash -s -- seed < scripts/host/move-host-secrets.sh
#
# Each old path keeps its name: services.tank-cloud.binds mounts a directory of a dataset at it
# after the switch. The script knows the three pairs of an old path and its directory on tank/cloud.
# It never prints a file's content or a checksum.
#
#   seed        before the switch: copy each old directory into its directory on tank/cloud, which
#               must be absent or empty, and give the directory the old one's mode and owner
#   compare     read each old tree, through a bind of / once the old path is a mount point, and
#               check that the tank/cloud tree holds every entry of it with the same type, mode,
#               owner, group, size and content. Entries only on tank/cloud are allowed: a later
#               copy-impd-db-host copy is one.
#   remove-old  after the switch: run compare, and only if every tree matches, delete the contents
#               of the old directories on the root disk, through the bind of /. The directories
#               stay, as the mount points.
#
# MOVE_ROOT prefixes every path, for the script's own test only.
set -euo pipefail

root="${MOVE_ROOT:-}"
# old path, directory on tank/cloud, dataset of that directory
pairs=(
  "/var/lib/imp-host/secrets /var/lib/tank-cloud/host-secrets/imp-host host-secrets"
  "/var/lib/atc-daemon-secrets /var/lib/tank-cloud/host-secrets/atc-daemon host-secrets"
  "/root/imp-db-backups /var/lib/tank-cloud/imp-db-backups imp-db-backups"
)
# global, so the EXIT trap still reads them after a failure inside a function
bind_dir=""
work_dir="$(mktemp -d)"

clean_up() {
  if [ -n "$bind_dir" ]; then
    umount "$bind_dir" || true
    rmdir "$bind_dir" || true
  fi
  rm -rf "$work_dir"
}
trap clean_up EXIT

die() {
  echo "move-host-secrets: $*" >&2
  exit 1
}

# the root disk's view of / without the mounts above it: a non-recursive bind shows the
# directories that the datasets' mounts shadow
ensure_bind() {
  if [ -z "$bind_dir" ]; then
    bind_dir="$(mktemp -d /run/move-host-secrets.XXXXXX)"
    mount --bind / "$bind_dir"
  fi
}

# prints the directory that holds the old tree: the old path, or its view through the bind once
# the old path is a mount point
locate_old() {
  local old="$1"
  if mountpoint -q "$root$old"; then
    ensure_bind
    echo "$bind_dir$old"
  else
    echo "$root$old"
  fi
}

# one NUL-separated record of five fields per entry: path, type, mode, owner:group, size
# for a regular file, then the sha256 for it; "-" fills the fields a directory or link lacks
write_manifest() {
  local dir="$1" out="$2" path type mode owner size sum
  : > "$out"
  while IFS= read -r -d '' path && IFS= read -r -d '' type && IFS= read -r -d '' mode &&
    IFS= read -r -d '' owner && IFS= read -r -d '' size; do
    sum="-"
    if [ "$type" = f ]; then
      sum="$(sha256sum -- "$dir/$path" | cut -d' ' -f1)"
    else
      size="-"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$type" "$mode" "$owner" "$size" "$sum" >> "$out"
  done < <(cd "$dir" && find . -printf '%p\0%y\0%m\0%u:%g\0%s\0')
}

# prints the fields of two entries that differ, one name per line
diff_entries() {
  local old_entry="$1" new_entry="$2" old_fields new_fields
  IFS=$'\t' read -r -a old_fields <<< "$old_entry"
  IFS=$'\t' read -r -a new_fields <<< "$new_entry"
  [ "${old_fields[0]}" = "${new_fields[0]}" ] || echo type
  [ "${old_fields[1]}" = "${new_fields[1]}" ] || echo mode
  [ "${old_fields[2]}" = "${new_fields[2]}" ] || echo owner
  [ "${old_fields[3]}" = "${new_fields[3]}" ] || echo size
  [ "${old_fields[4]}" = "${new_fields[4]}" ] || echo content
}

# compares one pair; prints its result and returns 1 on a mismatch
compare_pair() {
  local old="$1" source="$2" old_dir
  local -A old_entries=() new_entries=()
  local path rest key lines=() only_new=0 count=0 root_line
  old_dir="$(locate_old "$old")"
  [ -d "$old_dir" ] || die "$old is not a directory"
  [ -d "$root$source" ] || die "$source is not a directory"
  write_manifest "$old_dir" "$work_dir/old"
  write_manifest "$root$source" "$work_dir/new"
  while IFS=$'\t' read -r path rest; do old_entries["$path"]="$rest"; done < "$work_dir/old"
  while IFS=$'\t' read -r path rest; do new_entries["$path"]="$rest"; done < "$work_dir/new"
  while IFS= read -r path; do
    [ "$path" = . ] || count=$((count + 1))
    if [ -z "${new_entries[$path]+set}" ]; then
      lines+=("  $path: missing")
      continue
    fi
    while IFS= read -r key; do
      lines+=("  $path: $key differs")
    done < <(diff_entries "${old_entries[$path]}" "${new_entries[$path]}")
  done < <(printf '%s\n' "${!old_entries[@]}" | LC_ALL=C sort)
  for path in "${!new_entries[@]}"; do
    [ -n "${old_entries[$path]+set}" ] || only_new=$((only_new + 1))
  done
  if [ "${#lines[@]}" -gt 0 ]; then
    echo "MISMATCH $old:"
    printf '%s\n' "${lines[@]}"
    return 1
  fi
  path=.
  IFS=$'\t' read -r -a root_line <<< "${old_entries[$path]}"
  echo "match $old: $count entries, $only_new only on tank/cloud"
  echo "root $old: mode ${root_line[1]}, owner ${root_line[2]}"
}

seed() {
  local pair old source dataset count
  for pair in "${pairs[@]}"; do
    read -r old source dataset <<< "$pair"
    if [ -z "$root" ] && ! mountpoint -q "/var/lib/tank-cloud/$dataset"; then
      die "refusing to seed $source: /var/lib/tank-cloud/$dataset is not mounted"
    fi
    if [ -e "$root$source" ] && [ -n "$(ls -A "$root$source")" ]; then
      die "refusing to seed $source: it is not empty"
    fi
    if [ ! -d "$root$old" ] || [ -L "$root$old" ] || mountpoint -q "$root$old"; then
      die "refusing to seed from $old: it is not a plain directory"
    fi
  done
  for pair in "${pairs[@]}"; do
    read -r old source dataset <<< "$pair"
    install -d "$root$source"
    cp -a "$root$old/." "$root$source/"
    chmod --reference="$root$old" "$root$source"
    chown --reference="$root$old" "$root$source"
    count="$(find "$root$source" -mindepth 1 | wc -l)"
    echo "seeded $old -> $source: $count entries"
  done
}

compare() {
  local pair old source dataset status=0
  for pair in "${pairs[@]}"; do
    read -r old source dataset <<< "$pair"
    compare_pair "$old" "$source" || status=1
  done
  return "$status"
}

remove_old() {
  local pair old source dataset dir count
  for pair in "${pairs[@]}"; do
    read -r old source dataset <<< "$pair"
    mountpoint -q "$root$old" || die "refusing to remove: $old is not a mount point, so the switch has not run"
  done
  compare || die "refusing to remove: the trees differ"
  ensure_bind
  for pair in "${pairs[@]}"; do
    read -r old source dataset <<< "$pair"
    dir="$bind_dir$old"
    # the directory under the bind is the root disk's, so its device differs from the mounted one
    if [ "$(stat -c %d "$dir")" = "$(stat -c %d "$root$old")" ]; then
      die "refusing to remove: $old through the bind of / is the mounted directory"
    fi
    count="$(find "$dir" -mindepth 1 | wc -l)"
    find "$dir" -mindepth 1 -delete
    [ -z "$(ls -A "$dir")" ] || die "$old on the root disk is not empty after the removal"
    echo "removed $old: $count entries"
  done
}

case "${1:-}" in
  seed) seed ;;
  compare) compare ;;
  remove-old) remove_old ;;
  *) die "usage: move-host-secrets.sh seed|compare|remove-old" ;;
esac
