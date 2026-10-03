#!/usr/bin/env bash
# Install imp's Cloudflare DNS token and ACME contact email on geoffcloud, for HTTPS on
# imps.geoff.cloud (imp #16). The token goes to its own file (services.imp.dnsApiTokenFile,
# imp #135); the email goes to the imp-host env file. Run it yourself; it never prints
# either value. The email stays out of the public repo, so it lives here too.
# Also the rotation path: impd re-reads the token file, so a new token needs no restart.
#
#   bash scripts/install-imp-dns-token.sh
#
# - Reads the token with `op read` into a shell variable. The token never appears in
#   argv, stdout or shell history, and it reaches the host on SSH's stdin only.
# - On the host, it writes the token file and rewrites the env file, each atomically (a
#   temp file in the same directory, then a rename), mode 0400 root. The env file keeps
#   every other line, replaces IMP_ACME_EMAIL and drops any IMP_DNS_API_TOKEN line:
#   impd refuses to start with both the variable and the file set.
# - It restarts nothing. The module re-stages the token file on change; the email takes
#   effect at impd's next start.
set -euo pipefail

host="${IMP_HOST:-root@geoffcloud}"
ref="${IMP_DNS_TOKEN_REF:-op://cloud/imp-dns-cloudflare/credential}"
email_ref="${IMP_ACME_EMAIL_REF:-op://cloud/imp-dns-cloudflare/acme-email}"
env_file="${IMP_ENV_FILE:-/var/lib/imp-host/secrets/imp-host.env}"
token_file="${IMP_DNS_TOKEN_FILE:-/var/lib/imp-host/secrets/dns-api-token}"

# runs on the host; reads the token, then the email, from stdin; takes the env file and the
# token file paths as $1 and $2
# shellcheck disable=SC2016 # expanded on the host, not here
remote='set -euo pipefail
env_file=$1
token_file=$2
IFS= read -r token
IFS= read -r email
umask 077
tmp_token=$(mktemp "$token_file.XXXXXX")
tmp_env=$(mktemp "$env_file.XXXXXX")
trap "rm -f \"$tmp_token\" \"$tmp_env\"" EXIT
printf "%s" "$token" > "$tmp_token"
{ grep -vE "^(IMP_DNS_API_TOKEN|IMP_ACME_EMAIL)=" "$env_file" || true; printf "IMP_ACME_EMAIL=%s\n" "$email"; } > "$tmp_env"
unset token email
chmod 0400 "$tmp_token" "$tmp_env"
chown 0:0 "$tmp_token" "$tmp_env" 2>/dev/null || true
mv -f "$tmp_token" "$token_file"
mv -f "$tmp_env" "$env_file"
trap - EXIT
echo "installed: token file $token_file ($(stat -c %s "$token_file") bytes, mode $(stat -c %a "$token_file")); $env_file has $(grep -c "^IMP_ACME_EMAIL=" "$env_file") email line, $(grep -c "^IMP_DNS_API_TOKEN=" "$env_file") token lines, mode $(stat -c %a "$env_file")"'

token="$(op read --no-newline "$ref")"
if [[ ! "$token" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
  unset token
  echo "the value at $ref does not look like a Cloudflare API token; nothing changed" >&2
  exit 1
fi
email="$(op read --no-newline "$email_ref")"
if [[ ! "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
  unset token email
  echo "the value at $email_ref does not look like an email address; nothing changed" >&2
  exit 1
fi

if [ "$host" = local ]; then
  # test mode: run the host side here, against IMP_ENV_FILE
  printf '%s\n%s\n' "$token" "$email" | bash -c "$remote" _ "$env_file" "$token_file"
else
  printf '%s\n%s\n' "$token" "$email" | ssh -o BatchMode=yes "$host" "bash -c $(printf '%q' "$remote") _ $(printf '%q' "$env_file") $(printf '%q' "$token_file")"
fi
unset token email
