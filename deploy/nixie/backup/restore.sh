#!/bin/sh
# nixie-restore restore|ls, run in the nixie-backup image (restic) by the restore Job's fetch
# container
#
# restore: restore keys.db from the key repo's newest snapshot and nixie.db from the data repo's
#          snapshot of the same backup set, or from the data snapshot that $SNAPSHOT names, into an
#          empty /tmp/nixie-backup, where the restore pod's `nixie restore` reads them.
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
    set_tag="$(echo "$key_snapshots" | grep -o '"set-[0-9]*"' | tr -d '"' | sort -t- -k2 -n | tail -n 1)"
    [ -n "$set_tag" ] || {
      echo "the key repo holds no snapshot of a backup set" >&2
      exit 1
    }
    if [ -n "${SNAPSHOT:-}" ]; then
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
