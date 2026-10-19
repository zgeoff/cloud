interface PodLogPositionsSeedScriptOptions {
  // the directory that holds the kubelet's pod log directories
  podLogRoot: string;

  // the file the script writes, in the legacy positions format Alloy imports
  seedFile: string;

  // the positions file of Alloy's pod-log source, in the format Alloy writes it
  positionsFile: string;
}

// A POSIX shell script for the entry point of Alloy's container, before each Alloy start. With no
// positions file, it records every pod log file under podLogRoot at its current size as seedFile,
// which Alloy imports; the comments in the script cover a start with a positions file.
export function buildPodLogPositionsSeedScript(options: PodLogPositionsSeedScriptOptions): string {
  const positions = options.positionsFile;

  return `set -eu
if [ ! -s ${positions} ]; then
  {
    echo 'positions:'
    for file in ${options.podLogRoot}/*/*/*.log; do
      if [ -f "$file" ]; then
        printf '  "%s": "%s"\\n' "$file" "$(stat -c %s "$file")"
      fi
    done
  } > ${options.seedFile}.new
  mv ${options.seedFile}.new ${options.seedFile}
else
  # Alloy saves a position only with a line it ships, and when it stops, so a log the kubelet
  # replaced can hold a position past its size, and Alloy would skip the new file's start: such a
  # position goes back to 0. An entry imported from the seed carries the labels {}, and Alloy falls
  # back to it for a position of 0: it stays for a file with no position of Alloy's own, and goes
  # for a file with one.
  : > ${positions}.own
  while IFS= read -r line; do
    case "$line" in
      '  ? path: '*) path="\${line#'  ? path: '}" ;;
      '    labels: '*) labels="\${line#'    labels: '}" ;;
      '  : '*) if [ "$labels" != "'{}'" ]; then printf '%s\\n' "$path" >> ${positions}.own; fi ;;
    esac
  done < ${positions}
  {
    while IFS= read -r line; do
      case "$line" in
        '  ? path: '*) path="\${line#'  ? path: '}" ;;
        '    labels: '*) labels="\${line#'    labels: '}" ;;
        '  : '*)
          position="\${line#'  : '}"
          position="\${position#'"'}"
          position="\${position%'"'}"
          if [ "$labels" = "'{}'" ] && grep -qxF "$path" ${positions}.own; then
            continue
          fi
          if [ -f "$path" ] && [ "$(stat -c %s "$path")" -lt "$position" ]; then
            position=0
          fi
          printf '  ? path: %s\\n    labels: %s\\n  : "%s"\\n' "$path" "$labels" "$position"
          ;;
        *) printf '%s\\n' "$line" ;;
      esac
    done < ${positions}
  } > ${positions}.new
  mv ${positions}.new ${positions}
  rm ${positions}.own
fi
`;
}
