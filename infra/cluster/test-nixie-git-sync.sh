#!/usr/bin/env bash
# Test for nixie's git-sync container in its real engine: the pinned git-sync image runs with the
# env, the port and the readiness probe that build-nixie-spec.ts builds, as production runs it, and
# syncs a local origin in the case tree in place of GitHub. A sync every 1 s stands in for
# production's 60 s, and the SSH settings drop out because a file origin needs none. Each case
# checks that git-sync keeps running, what its readiness probe answers, and the sync counters that
# NixieDefinitionsStale reads (infra/observability/test-nixie-definitions-alert.sh).
#
#   bash scripts/run-shell-suites.sh alert-rules
#   CASE='origin goes away' bash infra/cluster/test-nixie-git-sync.sh
#
# shell-suite: alert-rules
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# fixed, so the files the cases write do not depend on the caller's umask
umask 022
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/run-cases.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/wait-for.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/assert-equals.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../test-support/shell/has-metric.sh"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
run_id="$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"

# setup_test <tree>: git-sync's image, env, port and probe path as the repo's builder writes them
setup_test() {
  mkdir -p "$1/config" "$1/srv"
  (cd "$repo/infra" && TREE="$1" bun -e "
    import { output } from '@pulumi/pulumi';
    import { buildNixieSpec } from './cluster/build-nixie-spec.ts';
    const tree = process.env.TREE ?? '';
    const spec = buildNixieSpec({ image: 'nixie', serviceName: output('nixie'), configMap: output('config'), secret: output('secrets'), definitionsSecret: output('key') });
    const gitSync = spec.template.spec.containers.find((container) => container.name === 'git-sync');
    const overrides = { GITSYNC_REPO: 'file:///srv/origin.git', GITSYNC_ROOT: '/git', GITSYNC_PERIOD: '1s' };
    const env = gitSync.env.filter((entry) => !entry.name.startsWith('GITSYNC_SSH')).map((entry) => entry.name + '=' + (overrides[entry.name] ?? entry.value));
    const port = gitSync.ports.find((candidate) => candidate.name === gitSync.readinessProbe.httpGet.port);
    await Bun.write(tree + '/config/env.list', env.join('\n') + '\n');
    await Bun.write(tree + '/config/image', gitSync.image);
    await Bun.write(tree + '/config/port', String(port.containerPort));
    await Bun.write(tree + '/config/probe-path', gitSync.readinessProbe.httpGet.path);
  ")
}

# create_origin <tree>: a bare origin with one commit on live, readable by git-sync's user
create_origin() {
  local git=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git)
  "${git[@]}" init -q --bare -b live "$1/srv/origin.git"
  "${git[@]}" -C "$1/srv/origin.git" config maintenance.auto false
  "${git[@]}" init -q -b live "$1/work"
  "${git[@]}" -C "$1/work" config maintenance.auto false
  "${git[@]}" -C "$1/work" -c user.name=Builder -c user.email=builder@example.invalid commit -q --allow-empty -m 'first definitions'
  "${git[@]}" -C "$1/work" push -q "$1/srv/origin.git" live
  chmod -R a+rX "$1/srv"
}

# start_git_sync <tree>: git-sync as production runs it, as uid 65533 on a read-only root with no
# capabilities, with its HTTP port published on a loopback port; sets the global url
start_git_sync() {
  local port
  port="$(cat "$1/config/port")"
  container="nixie-git-sync-$run_id-$BASHPID"
  docker run -d --name "$container" --user 65533:65533 --read-only --cap-drop ALL \
    --security-opt no-new-privileges --env-file "$1/config/env.list" -p "127.0.0.1::$port" \
    -v "$1/srv:/srv:ro" --tmpfs /git:uid=65533,gid=65533 --tmpfs /tmp:uid=65533,gid=65533 \
    "$(cat "$1/config/image")" > /dev/null
  url="http://$(docker port "$container" "$port" | head -n 1)"
}

# has_failed_once_or_stopped: git-sync counts a failed sync, or its container is no longer
# running, so a git-sync that exits on the failure fails the case at its state, not at a timeout
has_failed_once_or_stopped() {
  has_metric "$url" '^git_sync_count_total{status="error"} [1-9]' ||
    [ "$(docker inspect -f '{{.State.Running}}' "$container")" = false ]
}

# teardown: each step safe when the case stopped before it
teardown() {
  if [ -n "${container:-}" ]; then docker rm -f "$container" > /dev/null 2>&1 || true; fi
  rm -rf "$tree" || true
}

it_keeps_git_sync_running_and_ready_and_counts_the_failed_sync_after_its_origin_goes_away() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  create_origin "$tree"
  start_git_sync "$tree"
  wait_for 60 "git-sync's first good sync" has_metric "$url" '^git_sync_count_total{status="success"} 1$'

  mv "$tree/srv/origin.git" "$tree/srv/gone.git"
  wait_for 60 "git-sync's first failed sync" has_failed_once_or_stopped

  assert_equals running "$(docker inspect -f '{{.State.Status}}' "$container")" "git-sync's state"
  assert_equals 200 "$(curl -s -o /dev/null -w '%{http_code}' "$url$(cat "$tree/config/probe-path")")" "the readiness probe"
  assert_equals 1 "$(docker logs "$container" 2>&1 | grep -c '"msg":"error syncing repo, will retry".*"failCount":1}$')" "the first retry's log lines"
}

it_holds_git_sync_unready_and_running_until_its_first_good_sync() {
  tree="$(mktemp -d)"
  trap teardown EXIT
  setup_test "$tree"
  start_git_sync "$tree"
  wait_for 60 "git-sync's first failed sync" has_failed_once_or_stopped

  assert_equals running "$(docker inspect -f '{{.State.Status}}' "$container")" "git-sync's state"
  assert_equals 503 "$(curl -s -o /dev/null -w '%{http_code}' "$url$(cat "$tree/config/probe-path")")" "the readiness probe"
}

# pulled once before the cases, so a cold image cache never slows a case
docker pull -q "$(cd "$repo/infra" && bun -e "
  import { output } from '@pulumi/pulumi';
  import { buildNixieSpec } from './cluster/build-nixie-spec.ts';
  const spec = buildNixieSpec({ image: 'nixie', serviceName: output('nixie'), configMap: output('config'), secret: output('secrets'), definitionsSecret: output('key') });
  console.log(spec.template.spec.containers.find((container) => container.name === 'git-sync').image);
")" > /dev/null

run_cases
