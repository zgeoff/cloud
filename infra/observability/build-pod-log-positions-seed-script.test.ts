import { expect, test } from 'bun:test';
import { buildPodLogPositionsSeedScript } from './build-pod-log-positions-seed-script.ts';

test('it writes each pod log file at its size to the seed file in the legacy positions format, replacing the seed whole', () => {
  expect(
    buildPodLogPositionsSeedScript({
      podLogRoot: '/node/log/pods',
      seedFile: '/node/alloy/seed.yml',
    }),
  ).toBe(`set -eu
{
  echo 'positions:'
  for file in /node/log/pods/*/*/*.log; do
    if [ -f "$file" ]; then
      printf '  "%s": "%s"\\n' "$file" "$(stat -c %s "$file")"
    fi
  done
} > /node/alloy/seed.yml.new
mv /node/alloy/seed.yml.new /node/alloy/seed.yml
`);
});
