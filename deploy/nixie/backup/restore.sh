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

# pick_newest_set: reads `restic snapshots --json` on stdin and prints the newest set-<sequence> tag
# of its snapshots, by number, or nothing when no snapshot carries one. The image runs the job with
# bun, so bun parses the JSON; a sequence is a number, and set-10 sorts after set-9 only as one.
pick_newest_set() {
  bun -e '
    const snapshots = JSON.parse(await Bun.stdin.text());
    const sequences = snapshots.flatMap((snapshot) =>
      (snapshot.tags ?? []).flatMap((tag) => {
        const sequence = /^set-([0-9]+)$/.exec(tag)?.[1];
        return sequence === undefined ? [] : [Number(sequence)];
      }),
    );
    if (sequences.length > 0) console.log("set-" + Math.max(...sequences));
  '
}

case "${1:-}" in
  restore)
    [ -d "$copy_dir" ] || mkdir -m 0700 "$copy_dir"
    [ -z "$(ls -A "$copy_dir")" ] || {
      echo "$copy_dir is not empty" >&2
      exit 1
    }
    # the job tags both snapshots of a set with set-<sequence>, and a key snapshot whose removal
    # failed stays beside the newest
    key_snapshots="$(key_restic snapshots --json)"
    set_tag="$(echo "$key_snapshots" | pick_newest_set)"
    [ -n "$set_tag" ] || {
      echo "the key repo holds no snapshot of a backup set" >&2
      exit 1
    }
    if [ -n "${SNAPSHOT:-}" ]; then
      # a newer nixie.db holds records whose keys the key repo's set lacks
      data_snapshots="$(data_restic snapshots --json "$SNAPSHOT")"
      data_set="$(echo "$data_snapshots" | pick_newest_set)"
      [ -n "$data_set" ] || {
        echo "the data snapshot $SNAPSHOT holds no backup set" >&2
        exit 1
      }
      [ "${data_set#set-}" -le "${set_tag#set-}" ] || {
        echo "the data snapshot $SNAPSHOT holds $data_set, newer than the key repo's $set_tag" >&2
        exit 1
      }
      data_restic restore "$SNAPSHOT" --target "$copy_dir"
    else
      data_restic restore latest --tag "$set_tag" --target "$copy_dir"
    fi
    key_restic restore latest --tag "$set_tag" --target "$copy_dir"
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
