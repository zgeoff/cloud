# shellcheck shell=bash
# create_stub_webhook_curl <bin>: writes <bin>/curl, a stand-in for curl as alert-prod-apply.sh
# posts to a Discord webhook, `curl -fsS -H 'Content-Type: application/json' --data @- <url>`
# for an https URL, so no case reaches Discord. It logs each call's argv as a JSON line to
# STUB_TREE/calls and appends the body it reads from stdin, as it reads it, to
# STUB_TREE/webhook-body. By default the webhook takes the post as Discord does, with 204 and no
# body: nothing printed, exit 0. With STUB_WEBHOOK_STATUS=<code> (400 or above) it fails as
# curl -fsS does for an HTTP error answer: "curl: (22) The requested URL returned error: <code>"
# on stderr, exit 22. Any other call ends with exit 97 and "unexpected: <argv>" on stderr.
#
# Not checked against Discord or a real curl (no test reaches the internet). Checked on
# 2026-10-14 against https://discord.com/developers/docs/resources/webhook#execute-webhook (204
# No Content unless ?wait=true) and https://curl.se/docs/manpage.html, the same for curl 8.5.0
# (CI's ubuntu-24.04 runner image) and 8.22.0: -f fails an answer of 400 or above with exit 22,
# and -S keeps the error line that -s hides. The docs do not quote that line; the text here is
# the one curl 7.76 and later print, and needs a sample from each version.
create_stub_webhook_curl() {
  local bin="$1"
  cat > "$bin/curl" << 'STUB'
#!/usr/bin/env bash
printf '%s\0' curl "$@" | jq -cRs 'split("\u0000")[:-1]' >> "$STUB_TREE/calls"
if [ "$#" = 6 ] && [ "$1 $2 $3 $4 $5" = "-fsS -H Content-Type: application/json --data @-" ] &&
  [[ "$6" =~ ^https:// ]]; then
  cat >> "$STUB_TREE/webhook-body"
  if [ -n "${STUB_WEBHOOK_STATUS:-}" ]; then
    echo "curl: (22) The requested URL returned error: $STUB_WEBHOOK_STATUS" >&2
    exit 22
  fi
  exit 0
fi
echo "unexpected: $*" >&2
exit 97
STUB
  chmod +x "$bin/curl"
}
