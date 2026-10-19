import { expect, test } from 'bun:test';
import { buildPodLogPositionsSeedScript } from './build-pod-log-positions-seed-script.ts';

test('it seeds each pod log file at its size when Alloy has no positions file, and otherwise drops the seeded entries and resets each position past its file size to 0', () => {
  expect(
    buildPodLogPositionsSeedScript({
      podLogRoot: '/node/log/pods',
      seedFile: '/node/alloy/seed.yml',
      positionsFile: '/node/alloy/pods/positions.yml',
    }),
  ).toBe(`set -eu
if [ ! -s /node/alloy/pods/positions.yml ]; then
  {
    echo 'positions:'
    for file in /node/log/pods/*/*/*.log; do
      if [ -f "$file" ]; then
        printf '  "%s": "%s"\\n' "$file" "$(stat -c %s "$file")"
      fi
    done
  } > /node/alloy/seed.yml.new
  mv /node/alloy/seed.yml.new /node/alloy/seed.yml
  exit 0
fi
# Alloy saves a position only with a line it ships, so a stop after the kubelet replaced a log leaves
# the old file's end, past the new file's size, and Alloy would skip the new file's start: such a
# position goes back to 0. The entries Alloy imported from the seed carry the labels {}, and Alloy
# falls back to them for a position of 0, so they go.
{
  while IFS= read -r line; do
    case "$line" in
      '  ? path: '*) path="\${line#'  ? path: '}" ;;
      '    labels: '*) labels="\${line#'    labels: '}" ;;
      '  : '*)
        position="\${line#'  : '}"
        position="\${position#'"'}"
        position="\${position%'"'}"
        if [ "$labels" != "'{}'" ]; then
          if [ -f "$path" ] && [ "$(stat -c %s "$path")" -lt "$position" ]; then
            position=0
          fi
          printf '  ? path: %s\\n    labels: %s\\n  : "%s"\\n' "$path" "$labels" "$position"
        fi
        ;;
      *) printf '%s\\n' "$line" ;;
    esac
  done < /node/alloy/pods/positions.yml
} > /node/alloy/pods/positions.yml.new
mv /node/alloy/pods/positions.yml.new /node/alloy/pods/positions.yml
`);
});
