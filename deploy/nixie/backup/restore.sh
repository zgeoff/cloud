#!/bin/sh
# nixie-restore restore|ls, run in the nixie-backup image (restic) by the restore Job's fetch
# container
#
# restore: restore keys.db from the key repo's newest snapshot and nixie.db from the data repo's
#          snapshot of the same backup set, or from the data snapshot of an older set that
#          $SNAPSHOT names, into an empty /tmp/nixie-backup, where the restore pod's
#          `nixie restore` reads them.
# ls:      list the snapshots of both repos.
#
# The nixie-backup job keeps one key snapshot, so a forgotten item's key leaves the key repo at the
# next set. An older nixie.db beside the newest keys.db therefore keeps every forget, and a newer
# one never exists. nixie's own restore command replaces nixie's databases (nixie's
# docs/architecture/deployment/host-commands.md), so this script never opens a file of nixie's.
#
# Environment: NIXIE_BACKUP_DATA_REPOSITORY, NIXIE_BACKUP_DATA_PASSWORD,
# NIXIE_BACKUP_KEY_REPOSITORY and NIXIE_BACKUP_KEY_PASSWORD, as the nixie-backup job reads them, and
# the repos' credentials (AWS_* for R2). Nothing here prints them.
set -eu

copy_dir=/tmp/nixie-backup

# each repo's password goes to restic in its environment, never in its arguments
data_restic() {
  RESTIC_REPOSITORY="$NIXIE_BACKUP_DATA_REPOSITORY" RESTIC_PASSWORD="$NIXIE_BACKUP_DATA_PASSWORD" \
    restic "$@"
}

key_restic() {
  RESTIC_REPOSITORY="$NIXIE_BACKUP_KEY_REPOSITORY" RESTIC_PASSWORD="$NIXIE_BACKUP_KEY_PASSWORD" \
    restic "$@"
}

# pick_newest_set: reads `restic snapshots --json` on stdin and prints the newest snapshot's tags as
# a --tag filter, set-<sequence>,publish-<n> or set-<sequence> for a snapshot from before publish
# numbers, or nothing when no snapshot carries a set tag, through bun, which the image runs the job
# with. It exits 1 on output that is no snapshot list.
pick_newest_set() {
  bun "$(dirname "$0")/pick-newest-set.ts"
}

# tag_number <filter> <prefix>: the number of the <prefix>-<n> tag in a pick's filter, or nothing
tag_number() {
  echo "$1" | tr ',' '\n' | sed -n "s/^$2-\([0-9][0-9]*\)\$/\1/p"
}

# is_newer <data filter> <key filter>: whether the data snapshot is newer than the key snapshot, by
# publish number when both have one, since a set number can repeat after a restore, else by set
is_newer() {
  data_publish="$(tag_number "$1" publish)"
  key_publish="$(tag_number "$2" publish)"
  if [ -n "$data_publish" ] && [ -n "$key_publish" ]; then
    [ "$data_publish" -gt "$key_publish" ]
  else
    [ "$(tag_number "$1" set)" -gt "$(tag_number "$2" set)" ]
  fi
}

case "${1:-}" in
  restore)
    [ -d "$copy_dir" ] || mkdir -m 0700 "$copy_dir"
    [ -z "$(ls -A "$copy_dir")" ] || {
      echo "$copy_dir is not empty" >&2
      exit 1
    }
    if [ -n "${SNAPSHOT:-}" ]; then
      data_snapshots="$(data_restic snapshots --json "$SNAPSHOT")"
      data_set="$(echo "$data_snapshots" | pick_newest_set)"
      [ -n "$data_set" ] || {
        echo "the data snapshot $SNAPSHOT holds no backup set" >&2
        exit 1
      }
    fi
    # A backup run removes the key snapshot this picks once it publishes a newer set, which can
    # land between the pick and the restore; the next pick then finds that newer set. keys.db goes
    # first, because restic's lock holds the removal off only while a restore runs.
    attempt=1
    while :; do
      # the job tags both snapshots of a publish with set-<sequence> and publish-<n>, and a key
      # snapshot whose removal failed stays beside the newest
      key_snapshots="$(key_restic snapshots --json)"
      set_tag="$(echo "$key_snapshots" | pick_newest_set)"
      [ -n "$set_tag" ] || {
        echo "the key repo holds no snapshot of a backup set" >&2
        exit 1
      }
      # a newer nixie.db holds records whose keys the key repo's set lacks
      [ -z "${SNAPSHOT:-}" ] || ! is_newer "$data_set" "$set_tag" || {
        echo "the data snapshot $SNAPSHOT holds $data_set, newer than the key repo's $set_tag" >&2
        exit 1
      }
      if key_restic restore latest --tag "$set_tag" --target "$copy_dir"; then
        break
      fi
      [ "$attempt" -lt 3 ] || exit 1
      attempt=$((attempt + 1))
    done
    if [ -n "${SNAPSHOT:-}" ]; then
      data_restic restore "$SNAPSHOT" --target "$copy_dir"
    else
      data_restic restore latest --tag "$set_tag" --target "$copy_dir"
    fi
    ;;
  ls)
    echo 'data repo:'
    data_restic snapshots
    echo 'key repo:'
    key_restic snapshots
    ;;
  *)
    echo "usage: nixie-restore restore|ls" >&2
    exit 2
    ;;
esac
