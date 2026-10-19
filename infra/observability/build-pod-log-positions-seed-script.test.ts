import { expect, test } from 'bun:test';
import { buildPodLogPositionsSeedScript } from './build-pod-log-positions-seed-script.ts';

test("it seeds each pod log file at its size when Alloy has no positions file, and otherwise resets each position past its file's size to 0 and drops the seeded entry of a file with a position of Alloy's own", () => {
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
else
  # Alloy saves a position only with a line it ships, and when it stops, so a log the kubelet
  # replaced can hold a position past its size, and Alloy would skip the new file's start: such a
  # position goes back to 0. An entry imported from the seed carries the labels {}, and Alloy falls
  # back to it for a position of 0: it stays for a file with no position of Alloy's own, and goes
  # for a file with one.
  : > /node/alloy/pods/positions.yml.own
  while IFS= read -r line; do
    case "$line" in
      '  ? path: '*) path="\${line#'  ? path: '}" ;;
      '    labels: '*) labels="\${line#'    labels: '}" ;;
      '  : '*) if [ "$labels" != "'{}'" ]; then printf '%s\\n' "$path" >> /node/alloy/pods/positions.yml.own; fi ;;
    esac
  done < /node/alloy/pods/positions.yml
  {
    while IFS= read -r line; do
      case "$line" in
        '  ? path: '*) path="\${line#'  ? path: '}" ;;
        '    labels: '*) labels="\${line#'    labels: '}" ;;
        '  : '*)
          position="\${line#'  : '}"
          position="\${position#'"'}"
          position="\${position%'"'}"
          if [ "$labels" = "'{}'" ] && grep -qxF "$path" /node/alloy/pods/positions.yml.own; then
            continue
          fi
          if [ -f "$path" ] && [ "$(stat -c %s "$path")" -lt "$position" ]; then
            position=0
          fi
          printf '  ? path: %s\\n    labels: %s\\n  : "%s"\\n' "$path" "$labels" "$position"
          ;;
        *) printf '%s\\n' "$line" ;;
      esac
    done < /node/alloy/pods/positions.yml
  } > /node/alloy/pods/positions.yml.new
  mv /node/alloy/pods/positions.yml.new /node/alloy/pods/positions.yml
  rm /node/alloy/pods/positions.yml.own
fi
`);
});
