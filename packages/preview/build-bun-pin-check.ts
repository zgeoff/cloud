// A repository pins Bun in `.bun-version`, the file the agent image's Bun shim follows, and in
// package.json's `packageManager`, and either can hold a release the run never installs
export function buildBunPinCheck(version: string): string {
  return `for pinned in "$(cat .bun-version 2>/dev/null || true)" "$(sed -n 's/^.*"packageManager": *"bun@\\([^"]*\\)".*$/\\1/p' package.json 2>/dev/null || true)"; do
  pinned=$(printf '%s' "$pinned" | tr -d '[:space:]' | sed 's/^v//')
  if [ -n "$pinned" ] && [ "$pinned" != '${version}' ]; then
    echo "the repository pins Bun $pinned, but the run installs Bun ${version}" >&2
    exit 1
  fi
done`;
}
