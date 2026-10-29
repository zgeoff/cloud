#!/usr/bin/env bash
# Stop every imp whose guest runs or sleeps on 4 KiB pages, so it boots cold on the hugetlb pool at
# its next use. switch-geoffcloud.sh runs it after the pool check when --stop-ordinary-page-imps
# names the pool's switch window:
#
#   bash scripts/stop-ordinary-page-imps.sh <host>          # stop each imp on 4 KiB pages
#   bash scripts/stop-ordinary-page-imps.sh --plan <host>   # print the stop order, stop nothing
#   bash scripts/stop-ordinary-page-imps.sh --check <host>  # fail naming each one, stop nothing
#
# The stop order is the names in IMP_STOP_ORDER, then the other imps' names sorted, then the names
# in IMP_STOP_LAST, each list separated by spaces or commas and kept in its own order. A name in
# both lists goes first, and a name that is on 2 MiB pages or not on the host is skipped. Each mode
# prints the order first.
#
# impd 6.1.0 wakes a snapshot on the pages its guest ran on (pickWakeHugePages in zgeoff/impz
# packages/daemon/src/imps/imps/pick-wake-huge-pages.ts), and its one RAM budget never counts the
# pool's unused pages, so a guest on 4 KiB pages takes ordinary memory beside the reserved pool.
# `impz stop` frees the imp's memory and its snapshot, and keeps its disk; the guest's processes
# and sessions end. impd records the page size as `"hugePages": "2M"` in the imp's vm.json at each
# cold boot and in each snapshot/meta.json it writes, under /var/lib/imp/imps/<id>/ in imp-host
# (buildImpPaths in packages/daemon/src/vm/storage/data-layout.ts, both written with
# JSON.stringify(…, null, 2)). A running or sleeping imp counts as on 2 MiB pages when either file
# says so, because a wake between the listing and the read removes the snapshot's file; with
# neither, it is on 4 KiB pages. An imp in another state has no guest. The script lists the imps
# with `impz ls --json` and reads the files with one `podman exec`, both over ssh.
# --check exits 1 when it finds an imp on 4 KiB pages, and an ssh failure stops every mode with
# ssh's exit code. impd's names hold only lowercase letters, digits and hyphens (NameSchema in
# packages/api/src/schemas/name-schema.ts), and the script checks each before it puts one in a
# remote command.
set -euo pipefail

mode=stop
case "${1:-}" in
  --plan | --check)
    mode="${1#--}"
    shift
    ;;
esac
if [ "$#" -ne 1 ]; then
  echo "usage: stop-ordinary-page-imps.sh [--plan | --check] <host>" >&2
  exit 2
fi
host="$1"
imps_dir=/var/lib/imp/imps

records="$(ssh -o BatchMode=yes "$host" "podman exec imp-host impz ls --json")"
# one `<id> <name> <state>` line per imp
imps="$(jq -r '.[] | "\(.id) \(.name) \(.state)"' <<< "$records")"
# one `<id> <snapshot pages> <vm pages>` line per imp folder, each 2M or 4K
sizes="$(ssh -o BatchMode=yes "$host" "podman exec imp-host sh -c 'cd $imps_dir && for d in *; do s=4K; v=4K; grep -qs \"\\\"hugePages\\\": \\\"2M\\\"\" \"\$d/snapshot/meta.json\" && s=2M; grep -qs \"\\\"hugePages\\\": \\\"2M\\\"\" \"\$d/vm.json\" && v=2M; echo \"\$d \$s \$v\"; done'")"

# `<name> <state>` of each imp whose guest is on 4 KiB pages
declare -A states=()
while read -r id name state; do
  [ -n "${id:-}" ] || continue
  case "$state" in
    sleeping | running) ;;
    *) continue ;;
  esac
  # either file, since a wake between the two reads removes the snapshot's
  if awk -v id="$id" '$1 == id && ($2 == "2M" || $3 == "2M") { found = 1 } END { exit !found }' \
    <<< "$sizes"; then
    continue
  fi
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "impd's imp '$name' has a name that is not a plain impd name; stop it by hand" >&2
    exit 1
  fi
  states["$name"]="$state"
done <<< "$imps"

order=()
last=()
declare -A ordered=()
first_names="${IMP_STOP_ORDER:-}"
for name in ${first_names//,/ }; do
  if [ -n "${states[$name]+set}" ] && [ -z "${ordered[$name]+set}" ]; then
    order+=("$name")
    ordered["$name"]=1
  fi
done
last_names="${IMP_STOP_LAST:-}"
for name in ${last_names//,/ }; do
  if [ -n "${states[$name]+set}" ] && [ -z "${ordered[$name]+set}" ]; then
    last+=("$name")
    ordered["$name"]=1
  fi
done
while read -r name; do
  if [ -n "$name" ] && [ -z "${ordered[$name]+set}" ]; then
    order+=("$name")
    ordered["$name"]=1
  fi
done < <(printf '%s\n' "${!states[@]}" | LC_ALL=C sort)
order+=("${last[@]}")

if [ "${#order[@]}" = 0 ]; then
  echo "== no imp on $host is on 4 KiB pages"
  exit 0
fi
listed="${order[*]}"
echo "== stop order on $host: ${listed// /, }"

for name in "${order[@]}"; do
  case "$mode" in
    check) echo "imp $name: its ${states[$name]} guest is on 4 KiB pages" >&2 ;;
    plan) echo "== would stop $name: its ${states[$name]} guest is on 4 KiB pages" ;;
    stop)
      echo "== stop $name: its ${states[$name]} guest is on 4 KiB pages"
      ssh -o BatchMode=yes "$host" "podman exec imp-host impz stop $name" > /dev/null
      ;;
  esac
done

case "$mode" in
  check)
    echo "stop each with \`bash scripts/stop-ordinary-page-imps.sh <host>\`, so it boots cold on" \
      "the pool" >&2
    exit 1
    ;;
  stop) echo "== stopped ${#order[@]} imps; each keeps its disk and boots cold on the pool at its next use" ;;
esac
