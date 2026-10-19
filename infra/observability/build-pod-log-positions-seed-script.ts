interface PodLogPositionsSeedScriptOptions {
  // the directory that holds the kubelet's pod log directories
  podLogRoot: string;

  // the file the script writes, in the legacy positions format Alloy imports
  seedFile: string;

  // the positions file of Alloy's pod-log source, in the format Alloy writes it
  positionsFile: string;
}

// A POSIX shell script for before each Alloy start. With no positions file, it records every pod log
// file under podLogRoot at its current size as seedFile, which Alloy imports. Otherwise it repairs
// the positions file, as the comments in the script say.
export function buildPodLogPositionsSeedScript(options: PodLogPositionsSeedScriptOptions): string {
  return `set -eu
if [ ! -s ${options.positionsFile} ]; then
  {
    echo 'positions:'
    for file in ${options.podLogRoot}/*/*/*.log; do
      if [ -f "$file" ]; then
        printf '  "%s": "%s"\\n' "$file" "$(stat -c %s "$file")"
      fi
    done
  } > ${options.seedFile}.new
  mv ${options.seedFile}.new ${options.seedFile}
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
  done < ${options.positionsFile}
} > ${options.positionsFile}.new
mv ${options.positionsFile}.new ${options.positionsFile}
`;
}
