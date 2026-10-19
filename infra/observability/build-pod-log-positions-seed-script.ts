interface PodLogPositionsSeedScriptOptions {
  // the directory that holds the kubelet's pod log directories
  podLogRoot: string;

  // the file the script writes, in the legacy positions format Alloy imports
  seedFile: string;
}

// A POSIX shell script that records every pod log file under podLogRoot at its current size as
// seedFile. Alloy imports it only when it has no positions file, so after a start with an empty store
// each existing file resumes at that size, and a file that appears later is read from line one.
export function buildPodLogPositionsSeedScript(options: PodLogPositionsSeedScriptOptions): string {
  return `set -eu
{
  echo 'positions:'
  for file in ${options.podLogRoot}/*/*/*.log; do
    if [ -f "$file" ]; then
      printf '  "%s": "%s"\\n' "$file" "$(stat -c %s "$file")"
    fi
  done
} > ${options.seedFile}.new
mv ${options.seedFile}.new ${options.seedFile}
`;
}
