#!/usr/bin/env bash
# Runs as root on geoffcloud. It moves k3s's data, /var/lib/rancher and /etc/rancher, from the root
# disk onto the encrypted zvol tank/cloud/rancher (docs/runbooks/move-rancher.md). Send it on ssh's
# stdin, with the mode as its argument:
#
#   ssh root@geoffcloud bash -s -- copy < scripts/host/move-rancher.sh
#
# Both modes run after the switch to the config that mounts the zvol at /var/lib/rancher and binds
# its directory etc-rancher at /etc/rancher. k3s's unit asserts that /var/lib/rancher/k3s exists, so
# k3s stays stopped on the empty zvol instead of making a new cluster, and the copy puts that
# directory in place last. The old trees on the root disk lie under the zvol's mounts, so the script
# reads them through a non-recursive bind of /.
#
#   copy        stop k3s and kill its containers, which outlive it (KillMode=process); copy the old
#               /var/lib/rancher into a staging directory on the zvol and the old /etc/rancher into
#               the bind with cp -a, keeping owners, modes, times, xattrs, ACLs and hard links;
#               check that each copy has every entry of its old tree with the same type, mode,
#               owner, size, link count, time, link target, hard-link group and xattrs; then move
#               the staged entries into /var/lib/rancher, k3s last, and start k3s. A copy that
#               stopped part-way left no k3s directory, so the next run clears what it left and
#               copies again.
#   remove-old  only while the zvol is mounted at /var/lib/rancher and its etc-rancher at
#               /etc/rancher, and the zvol holds the cluster CA that the root disk holds: delete the
#               old trees' contents on the root disk, through the bind of /. The directories stay,
#               as the mount points.
#
# Its manifest code repeats the idea of move-host-secrets.sh's, because a script sent on ssh's
# stdin cannot source a library. It never prints a file's content.
set -euo pipefail

zvol=tank/cloud/rancher
device_link="/dev/zvol/$zvol"
data=/var/lib/rancher
etc=/etc/rancher
# the copy of the old /var/lib/rancher on the zvol until it is checked
staging="$data/.move-rancher"
ca=k3s/server/tls/server-ca.crt
# where the processes of k3s's containerd and its shims run from: the nixpkgs build's own
# containerd, or the binaries k3s unpacks into its data directory
shim_pattern='^(/nix/store/[^/]*k3s-containerd[^/]*/bin/containerd|/var/lib/rancher/k3s/data/)'
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
  echo "move-rancher: $*" >&2
  exit 1
}

# the root disk's view of / without the mounts above it
ensure_bind() {
  if [ -z "$bind_dir" ]; then
    bind_dir="$(mktemp -d /run/move-rancher.XXXXXX)"
    mount --bind / "$bind_dir"
  fi
}

zvol_device() {
  readlink -f "$device_link"
}

# fails unless the zvol's ext4 is mounted at /var/lib/rancher and its etc-rancher at /etc/rancher
require_mounts() {
  local device source
  [ -b "$device_link" ] || die "refusing: $device_link does not exist; is the key of tank/cloud loaded?"
  device="$(zvol_device)"
  source="$(findmnt -rn -o SOURCE --mountpoint "$data" || true)"
  [ "$source" = "$device" ] || die "refusing: $data is not the mount of $zvol ($device), so the switch has not run"
  source="$(findmnt -rn -o SOURCE --mountpoint "$etc" || true)"
  [ "$source" = "${device}[/etc-rancher]" ] || die "refusing: $etc is not the bind of $data/etc-rancher"
}

# prints the pids of k3s's containerd and shims, and of every process in k3s.service's cgroup
list_k3s_pids() {
  local pid exe cgroup
  cgroup="$(systemctl show -p ControlGroup --value k3s.service)"
  if [ -n "$cgroup" ] && [ -d "/sys/fs/cgroup$cgroup" ]; then
    find "/sys/fs/cgroup$cgroup" -name cgroup.procs -exec cat {} +
  fi
  for pid in /proc/[0-9]*; do
    exe="$(readlink "$pid/exe" 2> /dev/null || true)"
    if [[ "$exe" =~ $shim_pattern ]]; then
      echo "${pid#/proc/}"
    fi
  done
}

# prints the pids given and all their descendants: a container's processes are children of its shim
list_trees() {
  local -A children=()
  local ppid pid queue=("$@")
  while read -r ppid pid; do
    children["$ppid"]+=" $pid"
  done < <(ps -e -o ppid= -o pid=)
  while [ "${#queue[@]}" -gt 0 ]; do
    pid="${queue[0]}"
    queue=("${queue[@]:1}")
    echo "$pid"
    # shellcheck disable=SC2206 # the list is pids, split on spaces
    queue+=(${children[$pid]:-})
  done
}

# stops k3s and kills every process it left: containerd, the shims and the containers, which hold
# the PVCs and the datastore open. It never runs k3s-killall.sh, which also clears Tailscale's
# advertised routes and rewrites iptables on a host that runs Docker.
stop_k3s() {
  local pids=() mounts=() tries
  systemctl stop k3s.service
  mapfile -t pids < <(list_k3s_pids | sort -u)
  if [ "${#pids[@]}" -gt 0 ]; then
    mapfile -t pids < <(list_trees "${pids[@]}" | sort -u)
    kill -9 "${pids[@]}" 2> /dev/null || true
  fi
  for tries in $(seq 1 30); do
    [ -z "$(list_k3s_pids)" ] && break
    [ "$tries" -lt 30 ] || die "refusing to copy: k3s's processes still run: $(list_k3s_pids | sort -u | tr '\n' ' ')"
    sleep 1
  done
  echo "stopped k3s: killed ${#pids[@]} processes"
  # the containers' root filesystems and volumes, which k3s mounts again when it starts
  mapfile -t mounts < <(awk '$2 ~ "^(/run/k3s/|/var/lib/kubelet/pods/|/var/lib/kubelet/plugins/)" { print $2 }' /proc/self/mounts | sort -r)
  if [ "${#mounts[@]}" -gt 0 ]; then
    umount "${mounts[@]}"
  fi
  echo "unmounted ${#mounts[@]} container mounts"
}

# one NUL-separated record per entry of the tree, sorted by path: path, type, mode, owner:group,
# size, link count, time, link target, and the first path of its hard-link group. A directory's
# size and link count, and the root's time, depend on the filesystem and on the zvol's own entries,
# so they read "-".
write_manifest() {
  local dir="$1" out="$2"
  (cd "$dir" && find . -printf '%p\t%y\t%m\t%u:%g\t%s\t%n\t%T@\t%l\t%i\0') > "$work_dir/listing" || return 1
  LC_ALL=C sort -z "$work_dir/listing" | LC_ALL=C awk 'BEGIN { RS = "\0"; ORS = "\0"; FS = OFS = "\t" }
    {
      group = "-"
      if ($2 != "d" && $6 > 1) {
        if (!($9 in first)) first[$9] = $1
        group = first[$9]
      }
      if ($2 == "d") { $5 = "-"; $6 = "-" }
      if ($1 == ".") $7 = "-"
      print $1, $2, $3, $4, $5, $6, $7, $8, group
    }' > "$out"
}

# every xattr of the tree's entries, ACLs and security labels included, one sorted line per name
write_xattrs() {
  local dir="$1" out="$2"
  (cd "$dir" && find . -print0 | xargs -0 -r getfattr -h -d -m - -e hex --) > "$work_dir/xattrs" || return 1
  LC_ALL=C awk '/^# file: / { file = substr($0, 9); next } /=/ { print file "\t" $0 }' "$work_dir/xattrs" |
    LC_ALL=C sort > "$out"
}

# checks that the copy matches its old tree; prints the result, and the first differences on a
# mismatch
compare_tree() {
  local name="$1" old="$2" new="$3"
  write_manifest "$old" "$work_dir/old.manifest" || die "cannot read the tree of $name in full"
  write_manifest "$new" "$work_dir/new.manifest" || die "cannot read the copy of $name in full"
  write_xattrs "$old" "$work_dir/old.xattrs" || die "cannot read the xattrs of $name"
  write_xattrs "$new" "$work_dir/new.xattrs" || die "cannot read the xattrs of the copy of $name"
  if ! cmp -s "$work_dir/old.manifest" "$work_dir/new.manifest"; then
    echo "MISMATCH $name:"
    diff <(tr '\0' '\n' < "$work_dir/old.manifest") <(tr '\0' '\n' < "$work_dir/new.manifest") | head -20 || true
    return 1
  fi
  if ! cmp -s "$work_dir/old.xattrs" "$work_dir/new.xattrs"; then
    echo "MISMATCH $name xattrs:"
    diff "$work_dir/old.xattrs" "$work_dir/new.xattrs" | head -20 || true
    return 1
  fi
  echo "match $name: $(($(tr -cd '\0' < "$work_dir/old.manifest" | wc -c) - 1)) entries, $(wc -l < "$work_dir/old.xattrs") xattrs"
}

# gives the zvol's root the mode, owner, xattrs and ACLs of the old /var/lib/rancher, which the
# staging directory held, and checks them
copy_root_attributes() {
  local old="$1" new="$2"
  chmod --reference="$old" "$new"
  chown --reference="$old" "$new"
  (cd "$old" && getfattr -h -d -m - -e hex .) > "$work_dir/root.old"
  (cd "$new" && setfattr -h --restore="$work_dir/root.old")
  (cd "$new" && getfattr -h -d -m - -e hex .) > "$work_dir/root.new"
  [ "$(stat -c '%a %u:%g' "$old")" = "$(stat -c '%a %u:%g' "$new")" ] && cmp -s "$work_dir/root.old" "$work_dir/root.new"
}

copy() {
  local reserved size old_data old_etc leftovers needed available entry
  require_mounts
  [ ! -e "$data/k3s" ] || die "refusing to copy: $data/k3s exists on the zvol, so the copy is done and k3s may have run on it"
  read -r size reserved < <(zfs get -Hp -o value volsize,refreservation "$zvol" | paste -s -d ' ')
  [ "$reserved" -ge "$size" ] || die "refusing to copy: $zvol is sparse (refreservation $reserved < volsize $size); a full pool would fail ext4's writes"

  stop_k3s

  ensure_bind
  old_data="$bind_dir$data"
  old_etc="$bind_dir$etc"
  [ -d "$old_data" ] && [ -d "$old_etc" ] || die "refusing to copy: $data or $etc is not a directory on the root disk"
  [ -e "$old_data/$ca" ] || die "refusing to copy: $data on the root disk holds no cluster CA"
  for entry in "$data" "$etc"; do
    if [ "$(stat -c %d "$bind_dir$entry")" = "$(stat -c %d "$entry")" ]; then
      die "refusing to copy: $entry through the bind of / is the mounted zvol"
    fi
  done

  # what an earlier copy left: it never moved k3s into place, so k3s never ran on it
  leftovers="$(find "$data" -mindepth 1 -maxdepth 1 ! -name lost+found ! -name etc-rancher | wc -l)"
  leftovers=$((leftovers + $(find "$etc" -mindepth 1 -maxdepth 1 | wc -l)))
  if [ "$leftovers" -gt 0 ]; then
    find "$data" -mindepth 1 -maxdepth 1 ! -name lost+found ! -name etc-rancher -exec rm -rf {} +
    find "$etc" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    echo "cleared $leftovers entries an earlier copy left on the zvol"
  fi

  needed="$(du -sx -B1 "$old_data" "$old_etc" | awk '{ sum += $1 } END { print sum }')"
  available="$(df -B1 --output=avail "$data" | tail -1 | tr -d ' ')"
  [ "$needed" -lt "$available" ] || die "refusing to copy: the trees need $needed bytes and the zvol has $available"

  install -d "$staging"
  cp -a "$old_data/." "$staging/"
  chmod --reference="$old_data" "$staging"
  chown --reference="$old_data" "$staging"
  cp -a "$old_etc/." "$etc/"
  chmod --reference="$old_etc" "$etc"
  chown --reference="$old_etc" "$etc"
  echo "copied $data and $etc: $needed bytes"

  compare_tree "$data" "$old_data" "$staging" || die "refusing to start k3s: the copy of $data differs"
  compare_tree "$etc" "$old_etc" "$etc" || die "refusing to start k3s: the copy of $etc differs"

  sync -f "$data"
  # k3s's data directory last: its presence lets k3s start
  find "$staging" -mindepth 1 -maxdepth 1 ! -name k3s -exec mv -t "$data" {} +
  mv "$staging/k3s" "$data/k3s"
  rmdir "$staging"
  copy_root_attributes "$old_data" "$data" || die "refusing to start k3s: $data does not have the old root's mode, owner and xattrs"
  sync -f "$data"
  systemctl reset-failed k3s.service || true
  systemctl start k3s.service
  echo "started k3s on $zvol"
}

remove_old() {
  local path dir count
  require_mounts
  ensure_bind
  [ -e "$data/$ca" ] || die "refusing to remove: the zvol holds no cluster CA"
  if [ -e "$bind_dir$data/$ca" ] && ! cmp -s "$bind_dir$data/$ca" "$data/$ca"; then
    die "refusing to remove: the cluster CA on the zvol differs from the one on the root disk"
  fi
  for path in "$data" "$etc"; do
    dir="$bind_dir$path"
    [ -d "$dir" ] || die "refusing to remove: $path is not a directory on the root disk"
    # the directory under the bind is the root disk's, so its device differs from the mounted one
    if [ "$(stat -c %d "$dir")" = "$(stat -c %d "$path")" ]; then
      die "refusing to remove: $path through the bind of / is the mounted zvol"
    fi
  done
  for path in "$data" "$etc"; do
    dir="$bind_dir$path"
    count="$(find "$dir" -xdev -mindepth 1 | wc -l)"
    find "$dir" -xdev -mindepth 1 -delete
    [ -z "$(ls -A "$dir")" ] || die "$path on the root disk is not empty after the removal"
    echo "removed $path: $count entries"
  done
  # the zvol's mount point before this move, empty on the root disk
  if [ -d /var/lib/tank-cloud/rancher ] && ! mountpoint -q /var/lib/tank-cloud/rancher &&
    [ -z "$(ls -A /var/lib/tank-cloud/rancher)" ]; then
    rmdir /var/lib/tank-cloud/rancher
    echo "removed /var/lib/tank-cloud/rancher"
  fi
}

case "${1:-}" in
  copy) copy ;;
  remove-old) remove_old ;;
  *) die "usage: move-rancher.sh copy|remove-old" ;;
esac
