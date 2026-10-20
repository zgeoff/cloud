import type { Gate } from './load-gate-manifest.ts';

// Whether a change to these repo-relative paths needs the gate's check: true when any path
// matches one of the gate's paths and none of its ignore globs. No path needs no check.
export function isGateNeeded(gate: Readonly<Gate>, paths: readonly string[]): boolean {
  const matchers = gate.paths.map((glob: string) => new Bun.Glob(glob));
  const ignores = gate.ignore.map((glob: string) => new Bun.Glob(glob));

  return paths.some(
    (path: string) =>
      matchers.some((glob: Bun.Glob) => glob.match(path)) &&
      !ignores.some((glob: Bun.Glob) => glob.match(path)),
  );
}
