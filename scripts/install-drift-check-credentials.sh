#!/usr/bin/env bash
# Install the scheduled drift check's credentials on geoffcloud, as the one file that
# drift-check.service loads (nixos/modules/drift-check.nix). Run it yourself; it never prints a
# value. It is the rotation path too: the service reads the file at each run, so a new value
# needs no restart.
#
#   bash scripts/install-drift-check-credentials.sh
#
# - Reads each value with `op read` from the 1Password vault DRIFT_CHECK_VAULT (default cloud),
#   which no GitHub workflow reads, into a shell variable. A value never appears in argv, stdout
#   or shell history, and it reaches the host on SSH's stdin only. An empty value, or one with a
#   line break, stops the run before SSH.
# - On the host, it refuses to write unless DRIFT_CHECK_SECRETS_MOUNT (default the tank/cloud
#   host-secrets dataset) is a mount point, so a file never lands in the clear on the root disk.
#   Empty skips the check.
# - It writes DRIFT_CHECK_CREDENTIALS_FILE atomically (a temp file in the same directory, then a
#   rename), mode 0400 root, in a directory of mode 0700 that it creates when missing. The file
#   holds one KEY=VALUE line per variable that scripts/run-host-drift-check.sh reads.
# - DRIFT_CHECK_HOST=local runs the host side here, for the tests.
set -euo pipefail

host="${DRIFT_CHECK_HOST:-root@geoffcloud}"
vault="${DRIFT_CHECK_VAULT:-cloud}"
file="${DRIFT_CHECK_CREDENTIALS_FILE:-/var/lib/tank-cloud/host-secrets/drift-check/credentials}"
secrets_mount="${DRIFT_CHECK_SECRETS_MOUNT-/var/lib/tank-cloud/host-secrets}"

# each variable the check reads, and the item and field that hold it
fields=(
  PULUMI_BACKEND_URL=r2-pulumi-state-read/backend-url
  AWS_ACCESS_KEY_ID=r2-pulumi-state-read/access-key-id
  AWS_SECRET_ACCESS_KEY=r2-pulumi-state-read/secret-access-key
  PULUMI_CONFIG_PASSPHRASE=pulumi-passphrase/credential
  CLOUDFLARE_API_TOKEN=cloudflare-read/credential
  TAILSCALE_OAUTH_CLIENT_ID=tailscale-read/client-id
  TAILSCALE_OAUTH_CLIENT_SECRET=tailscale-read/client-secret
  TAILSCALE_TAILNET=tailscale-read/tailnet
  ALERT_WEBHOOK_URL=alert-webhook/credential
)

# runs on the host; reads the file's lines from stdin; takes the file and the required mount
# point (or "") as $1 and $2
# shellcheck disable=SC2016 # expanded on the host, not here
remote='set -euo pipefail
file=$1
if [ -n "$2" ] && ! mountpoint -q "$2"; then
  echo "$2 is not a mount point; nothing changed" >&2
  exit 1
fi
umask 077
mkdir -p "$(dirname "$file")"
tmp=$(mktemp "$file.XXXXXX")
trap "rm -f \"$tmp\"" EXIT
cat > "$tmp"
chmod 0400 "$tmp"
chown 0:0 "$tmp" 2>/dev/null || true
mv -f "$tmp" "$file"
trap - EXIT
echo "installed: $file ($(wc -l < "$file") lines, mode $(stat -c %a "$file"))"'

payload=""
for field in "${fields[@]}"; do
  name="${field%%=*}"
  ref="op://$vault/${field#*=}"
  value="$(op read --no-newline "$ref")"
  if [ -z "$value" ] || [[ "$value" == *$'\n'* ]] || [[ "$value" == *$'\r'* ]]; then
    unset value payload
    echo "the value at $ref is empty or holds a line break; nothing changed" >&2
    exit 1
  fi
  payload+="$name=$value"$'\n'
done
unset value

if [ "$host" = local ]; then
  printf '%s' "$payload" | bash -c "$remote" _ "$file" "$secrets_mount"
else
  printf '%s' "$payload" | ssh -o BatchMode=yes "$host" "bash -c $(printf '%q' "$remote") _ $(printf '%q' "$file") $(printf '%q' "$secrets_mount")"
fi
unset payload
