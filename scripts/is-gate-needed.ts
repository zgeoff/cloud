import type { Gate } from './load-gate-manifest.ts';

export function isGateNeeded(gate: Readonly<Gate>, paths: readonly string[]): boolean {
  const matchers = gate.paths.map((glob: string) => new Bun.Glob(glob));
  const ignores = gate.ignore.map((glob: string) => new Bun.Glob(glob));

  return paths.some(
    (path: string) =>
      matchers.some((glob: Bun.Glob) => glob.match(path)) &&
      !ignores.some((glob: Bun.Glob) => glob.match(path)),
  );
}
