// A repository pins Bun in `.bun-version`, the file the agent image's Bun shim follows, and in
// package.json's `packageManager`, and either can hold a release the run never installs. Bun reads
// the manifest from `/`, because Bun loads the `bunfig.toml` of the folder it starts in.
export function buildBunPinCheck(version: string): string {
  return `manifest="$PWD/package.json"
for pinned in "$(head -n 1 .bun-version 2>/dev/null || true)" "$(cd / && MANIFEST="$manifest" bun -e 'const pin = (await Bun.file(process.env.MANIFEST).json().catch(() => null))?.packageManager; if (typeof pin === "string" && pin.startsWith("bun@")) console.log(pin.slice(4));' 2>/dev/null || true)"; do
  pinned=$(printf '%s' "$pinned" | tr -d '[:space:]' | sed 's/^v//')
  if [ -n "$pinned" ] && [ "$pinned" != '${version}' ]; then
    echo "the repository pins Bun $pinned, but the run installs Bun ${version}" >&2
    exit 1
  fi
done`;
}
