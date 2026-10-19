# shellcheck shell=bash
# print_op_error <error> <arg>…: prints the 1Password CLI's error line for <error> on stderr and
# exits 1, as op does. The op stand-ins source this file in the script they write, so they share
# one copy of each text. op frames an error as "[ERROR] <date> <time> <message>"; the date here
# is fixed. The errors:
#
# - missing-vault <vault>: "\"<vault>\" isn't a vault in this account. Specify the vault with
#   its ID or name.";
# - missing-item <item> <vault>: "\"<item>\" isn't an item in the \"<vault>\" vault. Specify the
#   item with its UUID, name, or domain.";
# - unreadable-secret <reference> <vault> <item>: "could not read secret <reference>: could not
#   get item <vault>/<item>: \"<item>\" isn't an item in the \"<vault>\" vault.";
# - rate-limit: "(429) Too Many Requests: You've reached … Please retry in 59 minutes or try
#   other requests.".
#
# Any other error ends with exit 97 and "unexpected: print_op_error <args>" on stderr.
#
# Checked on 2026-10-08 against 1Password's CLI documentation, not a real op (no 1Password
# account runs in a test). op 2.40.0 (https://app-updates.agilebits.com/product_history/CLI2)
# was current then and is the version images/agent/Dockerfile pins. The rate-limit text is
# https://www.1password.dev/service-accounts/rate-limits/ 's, which prints it without a
# timestamp and after "Error: ". The documentation does not settle, so they stay as they were
# and need a real op sample: the other texts, taken from community reports of op 2; the
# "[ERROR] <date> <time>" frame; the retry time in the rate-limit text; and the exit code, 1
# for every error, as 1Password community answers describe.
print_op_error() {
  local frame='[ERROR] 2026/10/07 12:00:00'
  case "$#:$1" in
    2:missing-vault)
      echo "$frame \"$2\" isn't a vault in this account. Specify the vault with its ID or name." >&2
      ;;
    3:missing-item)
      echo "$frame \"$2\" isn't an item in the \"$3\" vault. Specify the item with its UUID, name, or domain." >&2
      ;;
    4:unreadable-secret)
      echo "$frame could not read secret $2: could not get item $3/$4: \"$4\" isn't an item in the \"$3\" vault." >&2
      ;;
    1:rate-limit)
      echo "$frame (429) Too Many Requests: You've reached the maximum number of this type of requests this service account is allowed to make. Please retry in 59 minutes or try other requests." >&2
      ;;
    *)
      echo "unexpected: print_op_error $*" >&2
      exit 97
      ;;
  esac
  exit 1
}
