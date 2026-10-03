#!/usr/bin/env bash
# Install imp's Cloudflare DNS token and ACME contact email into geoffcloud's imp-host
# env file, for HTTPS on imps.geoff.cloud (imp #16). Run it yourself; it never prints
# either value. The email stays out of the public repo, so it lives here too.
#
#   bash scripts/install-imp-dns-token.sh
#
# - Reads the token with `op read` into a shell variable. The token never appears in
#   argv, stdout or shell history, and it reaches the host on SSH's stdin only.
# - On the host, it rewrites /var/lib/imp-host/secrets/imp-host.env atomically. Every
#   other line is kept, any old IMP_DNS_API_TOKEN and IMP_ACME_EMAIL lines are replaced, and the mode stays
#   0400 root. The write is a temp file in the same directory, then a rename.
# - It restarts nothing. impd reads the file at its next start, and the token does
#   nothing until IMP_DOMAIN is set in the NixOS config. Run this before that config
#   reaches the host.
set -euo pipefail

host="${IMP_HOST:-root@geoffcloud}"
ref="${IMP_DNS_TOKEN_REF:-op://cloud/imp-dns-cloudflare/credential}"
email_ref="${IMP_ACME_EMAIL_REF:-op://cloud/imp-dns-cloudflare/acme-email}"
env_file="${IMP_ENV_FILE:-/var/lib/imp-host/secrets/imp-host.env}"

# runs on the host; reads the token, then the email, from stdin; takes the env file path as $1
# shellcheck disable=SC2016 # expanded on the host, not here
remote='set -euo pipefail
env_file=$1
IFS= read -r token
IFS= read -r email
umask 077
tmp=$(mktemp "$env_file.XXXXXX")
trap "rm -f \"$tmp\"" EXIT
{ grep -vE "^(IMP_DNS_API_TOKEN|IMP_ACME_EMAIL)=" "$env_file" || true; printf "IMP_DNS_API_TOKEN=%s\nIMP_ACME_EMAIL=%s\n" "$token" "$email"; } > "$tmp"
unset token email
chmod 0400 "$tmp"
chown 0:0 "$tmp" 2>/dev/null || true
mv -f "$tmp" "$env_file"
trap - EXIT
echo "installed: $(grep -cE "^(IMP_DNS_API_TOKEN|IMP_ACME_EMAIL)=" "$env_file") of 2 lines (token, email) in $env_file, $(wc -l < "$env_file") lines, mode $(stat -c %a "$env_file")"'

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
  printf '%s\n%s\n' "$token" "$email" | bash -c "$remote" _ "$env_file"
else
  printf '%s\n%s\n' "$token" "$email" | ssh -o BatchMode=yes "$host" "bash -c $(printf '%q' "$remote") _ $(printf '%q' "$env_file")"
fi
unset token email
