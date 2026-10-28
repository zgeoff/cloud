#!/usr/bin/env bash
# The operator verbs: one stable name for each action that an agent session takes on cloud, so a
# change to a script, a workflow or an address changes this file and not the callers. Each verb
# runs the script or command it wraps unchanged, with that script's own checks, and passes its
# exit code through. docs/runbooks/ops.md lists each verb, what it wraps and its preconditions.
# Run a verb through its root package script:
#
#   bun run ops:switch-host [-- --build-only | --allow-k3s-restart]
#   bun run ops:deploy-prod -- <full commit>
#   bun run ops:nixos-checks [-- [--force] <branch>]
#   bun run ops:preview [-- <pulumi preview flag>…]
#   bun run ops:up [-- <pulumi up flag>…]
#   bun run ops:switch-agent-image -- <image> [<atc config file>]
#   bun run ops:host -- '<remote command>'
#   bun run ops:cancel-prod-lock [-- <pulumi cancel flag>…]
#
# --dry-run, as the first argument after the verb, prints the command and any check the verb runs
# before it, then exits 0 without running either. `up` and `cancel-prod-lock` first refuse, with
# exit 1, while a Deploy prod run is queued or in progress, since either would fight that run for
# the prod stack. A usage error exits 2.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
slug=zgeoff/cloud
host="${GEOFFCLOUD_HOST:-root@geoffcloud}"
verbs=(switch-host deploy-prod nixos-checks preview up switch-agent-image host cancel-prod-lock)

usage() {
  echo "usage: ops.sh <verb> [--dry-run] [<argument>…], where <verb> is one of: ${verbs[*]}" >&2
  exit 2
}

# require_no_deploy_prod_run: exits 1 naming each Deploy prod run that has not completed. It asks
# GitHub for each status a run holds before it completes, rather than reading the newest runs,
# because each CI run of a pull request starts a Deploy prod run that ends skipped, and those can
# push a live run out of any window. The deploy-prod group keeps at most 100 waiting runs.
require_no_deploy_prod_run() {
  local status runs found active=
  for status in in_progress queued waiting pending requested; do
    runs="$(gh run list -R "$slug" --workflow deploy-prod.yml --status "$status" -L 100 --json status,url)"
    found="$(jq -r '.[] | "\(.status) \(.url)"' <<< "$runs")"
    active+="${found:+$found$'\n'}"
  done
  active="${active%$'\n'}"
  if [ -n "$active" ]; then
    echo "ops: a Deploy prod run has not completed; wait for it, then run the verb again:" >&2
    echo "  ${active//$'\n'/$'\n'  }" >&2
    exit 1
  fi
}

verb="${1:-}"
[ "$#" -gt 0 ] && shift
dry_run=false
if [ "${1:-}" = --dry-run ]; then
  dry_run=true
  shift
fi

guard=
dir="$repo"
case "$verb" in
  switch-host)
    command=(bash "$repo/scripts/switch-geoffcloud.sh" "$@")
    ;;
  deploy-prod)
    if [ "$#" -ne 1 ] || [[ ! "$1" =~ ^[0-9a-f]{40}$ ]]; then
      echo "usage: ops.sh deploy-prod <the full 40-character commit of main's tip>" >&2
      exit 2
    fi
    command=(gh workflow run deploy-prod.yml -R "$slug" --ref main -f "revision=$1")
    ;;
  nixos-checks)
    force=()
    if [ "${1:-}" = --force ]; then
      force=(-f force=true)
      shift
    fi
    if [ "$#" -gt 1 ] || [ "${1-main}" = "" ]; then
      echo "usage: ops.sh nixos-checks [--force] [<branch>]" >&2
      exit 2
    fi
    command=(gh workflow run nixos-checks.yml -R "$slug" --ref "${1:-main}" "${force[@]}")
    ;;
  preview)
    command=(bun run preview -- "$@")
    ;;
  up)
    guard=require_no_deploy_prod_run
    command=(bun run up -- "$@")
    ;;
  switch-agent-image)
    command=(bun "$repo/scripts/switch-agent-image.ts" "$@")
    ;;
  host)
    if [ "$#" -ne 1 ] || [ -z "$1" ]; then
      echo "usage: ops.sh host '<remote command>'" >&2
      exit 2
    fi
    command=(ssh -o BatchMode=yes "$host" "$1")
    ;;
  cancel-prod-lock)
    guard=require_no_deploy_prod_run
    dir="$repo/infra"
    command=(op run --env-file=../.env -- pulumi cancel --stack prod "$@")
    ;;
  *) usage ;;
esac

if [ "$dry_run" = true ]; then
  if [ -n "$guard" ]; then
    echo "check: no Deploy prod run of $slug is queued or in progress"
  fi
  printf 'run in %s:' "$dir"
  printf ' %q' "${command[@]}"
  printf '\n'
  exit 0
fi

if [ -n "$guard" ]; then "$guard"; fi
cd "$dir"
exec "${command[@]}"
