import { expect, test } from 'bun:test';
import { join } from 'node:path';
import { isGateNeeded } from './is-gate-needed.ts';
import { loadGateManifest } from './load-gate-manifest.ts';
import { runProcess } from './run-process.ts';

// The manifest's own suite: it reads the real .github/gates.yml, so a change to a gate's paths
// shows here as a changed answer.

test.each([
  ['full', ['README.md', 'docs/runbooks/prod-apply.md'], false],
  ['full', ['README.md', 'scripts/lint.sh'], true],
  ['full', ['.github/workflows/ci.yml'], true],
  ['provider', ['provider/main.go'], true],
  ['provider', ['sdk/onidel/index.ts'], true],
  ['provider', ['scripts/check-sdk.sh'], true],
  ['provider', ['.github/gates.yml'], true],
  ['provider', ['infra/index.ts', 'package.json'], false],
  ['nixos', ['nixos/flake.nix'], true],
  ['nixos', ['packages/preview/src/serve.ts'], true],
  ['nixos', ['bun.lock'], true],
  ['nixos', ['test-support/shell/wait-for.sh'], true],
  ['nixos', ['scripts/find-nixos-check-run.sh'], true],
  ['nixos', ['test-support/shell/create-stub-gh.sh', 'package.json'], false],
  ['nixos', ['docs/runbooks/workflows.md'], false],
  ['prod-apply', ['README.md', 'docs/runbooks/prod-apply.md'], false],
  ['prod-apply', ['.github/workflows/deploy-prod.yml', 'scripts/lint.sh'], false],
  ['prod-apply', ['infra/index.ts'], true],
  ['prod-apply', ['deploy/nixie/values.yaml'], true],
  ['prod-apply', ['provider/main.go'], true],
  ['prod-apply', ['sdk/onidel/index.ts'], true],
  ['prod-apply', ['packages/topology/src/ports.ts'], true],
])('it decides the %s gate for a change to %p as %p', async (name, paths, expected) => {
  const manifest = await loadGateManifest(join(import.meta.dir, '..', '.github', 'gates.yml'));

  const gate = manifest.get(name);

  if (gate === undefined) {
    throw new Error(`the manifest has no gate ${name}`);
  }

  expect(isGateNeeded(gate, paths)).toBe(expected);
});

test('it holds the gates that CI, the NixOS checks and the prod apply read', async () => {
  const manifest = await loadGateManifest(join(import.meta.dir, '..', '.github', 'gates.yml'));

  expect([...manifest.keys()]).toStrictEqual(['full', 'provider', 'nixos', 'prod-apply']);
});

// a glob that matches no file, such as a path with a typo, would skip its check silently
test('it names only globs that match a file in the checkout', async () => {
  const manifest = await loadGateManifest(join(import.meta.dir, '..', '.github', 'gates.yml'));

  const listed = await runProcess(
    ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'],
    {
      cwd: join(import.meta.dir, '..'),
    },
  );

  const files = listed.stdout.toString().split('\0');

  const unmatched = [...manifest.values()].flatMap((gate) =>
    [...gate.paths, ...gate.ignore]
      .filter((glob: string) => !files.some((path: string) => new Bun.Glob(glob).match(path)))
      .map((glob: string) => `${gate.name}: ${glob}`),
  );

  expect(listed.exitCode).toBe(0);
  expect(unmatched).toStrictEqual([]);
});

test('it skips a change whose every path an ignore glob matches', () => {
  expect(
    isGateNeeded({ name: 'lint', paths: ['**'], ignore: ['**/*.md'], skipped: undefined }, [
      'README.md',
      'docs/a.md',
    ]),
  ).toBeFalse();
});

test('it needs the check when one path matches and no ignore glob does', () => {
  expect(
    isGateNeeded({ name: 'lint', paths: ['**'], ignore: ['**/*.md'], skipped: undefined }, [
      'README.md',
      'src/a.ts',
    ]),
  ).toBeTrue();
});

test('it keeps a single star inside one directory', () => {
  expect(
    isGateNeeded({ name: 'go', paths: ['provider/*'], ignore: [], skipped: undefined }, [
      'provider/cmd/main.go',
    ]),
  ).toBeFalse();
});

test('it needs no check for a change with no path', () => {
  expect(
    isGateNeeded({ name: 'lint', paths: ['**'], ignore: [], skipped: undefined }, []),
  ).toBeFalse();
});
