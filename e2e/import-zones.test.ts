import { expect, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, realpath, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Lints a temp tree with the zgeoff/import-zones options from the repo's own .oxlintrc.json, so
// each boundary the config declares fails a real import.
async function setupTest() {
  const root = join(import.meta.dir, '..');

  const created = await mkdtemp(join(tmpdir(), 'cloud-import-zones-'));

  onTestFinished(() => rm(created, { recursive: true, force: true }));

  const dir = await realpath(created);
  const configText = await Bun.file(join(root, '.oxlintrc.json')).text();

  const parsed: unknown = Bun.JSONC.parse(configText);

  if (
    typeof parsed !== 'object' ||
    parsed === null ||
    !('rules' in parsed) ||
    typeof parsed.rules !== 'object' ||
    parsed.rules === null
  ) {
    throw new Error('.oxlintrc.json holds no rules');
  }

  const lintConfig = {
    jsPlugins: [join(root, 'node_modules', '@zgeoff', 'oxlint-config', 'plugin.js')],
    rules: { 'zgeoff/import-zones': Reflect.get(parsed.rules, 'zgeoff/import-zones') },
  };

  // the rule roots its globs at the nearest .git, so the tree is a repository of its own
  await mkdir(join(dir, '.git'));
  await writeFile(join(dir, '.oxlintrc.json'), JSON.stringify(lintConfig));
  await writeFile(join(dir, 'package.json'), JSON.stringify({ name: '@zgeoff/cloud' }));

  return {
    dir,
    lint: async (target: string) => {
      const args = [
        join(root, 'node_modules', '.bin', 'oxlint'),
        '-c',
        '.oxlintrc.json',

        // under GITHUB_ACTIONS oxlint would print annotations instead
        '--format',
        'default',
        target,
      ];

      const proc = Bun.spawn(args, { cwd: dir, stdout: 'pipe', stderr: 'pipe' });

      const [exitCode, stdout] = await Promise.all([proc.exited, new Response(proc.stdout).text()]);

      return { exitCode, stdout };
    },
  };
}

interface ImportCase {
  readonly label: string;
  readonly file: string;
  readonly source: string;
  readonly other: string;
}

test.each<ImportCase & { readonly rule: string }>([
  {
    rule: 'relative-import-into-another-package',
    label: "infra into the generated SDK's built files",
    file: 'infra/edge/index.ts',
    source: "import { vm } from '../../sdk/onidel/bin/index.js';\n",
    other: 'sdk/onidel/bin/index.js',
  },
  {
    rule: 'relative-import-into-another-package',
    label: 'one package into another',
    file: 'packages/preview/src/serve.ts',
    source: "import { port } from '../../topology/index.ts';\n",
    other: 'packages/topology/index.ts',
  },
  {
    rule: 'relative-import-into-another-package',
    label: 'a worker into a package',
    file: 'workers/health-check/index.ts',
    source: "import { port } from '../../packages/topology/index.ts';\n",
    other: 'packages/topology/index.ts',
  },
  {
    rule: 'relative-import-into-another-package',
    label: 'a package into infra',
    file: 'packages/topology/index.ts',
    source: "import { port } from '../../infra/inputs/index.ts';\n",
    other: 'infra/inputs/index.ts',
  },
  {
    rule: 'relative-import-into-another-package',
    label: 'infra into the root package',
    file: 'infra/inputs/index.ts',
    source: "import { run } from '../../scripts/run-process.ts';\n",
    other: 'scripts/run-process.ts',
  },
  {
    rule: 'relative-import-from-the-root-package',
    label: 'a script into a package',
    file: 'scripts/check-topology.ts',
    source: "import { port } from '../packages/topology/index.ts';\n",
    other: 'packages/topology/index.ts',
  },
  {
    rule: 'relative-import-from-the-root-package',
    label: 'an e2e suite into infra',
    file: 'e2e/deploy.test.ts',
    source: "import { port } from '../infra/inputs/index.ts';\n",
    other: 'infra/inputs/index.ts',
  },
  {
    rule: 'infra-shared-imports-no-group',
    label: 'shared into the inputs group',
    file: 'infra/shared/names.ts',
    source: "import { port } from '../inputs/index.ts';\n",
    other: 'infra/inputs/index.ts',
  },
  {
    rule: 'infra-inputs-imports-no-group',
    label: 'inputs into the cluster group',
    file: 'infra/inputs/index.ts',
    source: "import { node } from '../cluster/index.ts';\n",
    other: 'infra/cluster/index.ts',
  },
  {
    rule: 'infra-inputs-imports-no-group',
    label: 'a type nested in another type from inputs into the cluster group',
    file: 'infra/inputs/index.ts',
    source: "export type Nodes = Array<import('../cluster/index.ts').Node>;\n",
    other: 'infra/cluster/index.ts',
  },
  {
    rule: 'infra-group-imports-only-lower-layers',
    label: 'the cluster group into the edge group',
    file: 'infra/cluster/index.ts',
    source: "import { zone } from '../edge/index.ts';\n",
    other: 'infra/edge/index.ts',
  },
  {
    rule: 'infra-observability-imports-only-lower-layers',
    label: 'observability into the cluster group',
    file: 'infra/observability/index.ts',
    source: "import { node } from '../cluster/index.ts';\n",
    other: 'infra/cluster/index.ts',
  },
  {
    rule: 'infra-cross-group-import-through-the-entry-module',
    label: "the cluster group past the inputs group's entry module",
    file: 'infra/cluster/index.ts',
    source: "import { readEnv } from '../inputs/read-env.ts';\n",
    other: 'infra/inputs/read-env.ts',
  },
  {
    rule: 'infra-root-imports-only-entry-modules',
    label: "the composition root past the cluster group's entry module",
    file: 'infra/index.ts',
    source: "import { buildNode } from './cluster/build-node.ts';\n",
    other: 'infra/cluster/build-node.ts',
  },
  {
    rule: 'infra-test-utils-only-in-tests',
    label: 'the Pulumi program into the test utils',
    file: 'infra/cluster/index.ts',
    source: "import { buildMockVm } from '../test-utils/build-mock-vm.ts';\n",
    other: 'infra/test-utils/build-mock-vm.ts',
  },
  {
    rule: 'unresolved',
    label: 'a relative import of a missing file',
    file: 'infra/cluster/index.ts',
    source: "import { gone } from './gone.ts';\n",
    other: 'infra/cluster/build-node.ts',
  },
  {
    rule: 'unresolved',
    label: 'a computed dynamic import',
    file: 'scripts/load-step.ts',
    source: "const step = './steps/' + (process.argv[2] ?? 'apply');\nawait import(step);\n",
    other: 'scripts/steps/apply.ts',
  },
])('it fails lint on a $rule import: $label', async (row) => {
  const ctx = await setupTest();

  await Bun.write(join(ctx.dir, row.other), 'export const value = 1;\n');
  await Bun.write(join(ctx.dir, row.file), row.source);

  const result = await ctx.lint(row.file);

  expect(result.exitCode).toBe(1);
  expect(result.stdout).toInclude(`zgeoff(import-zones): ${row.rule}: `);
});

test.each<ImportCase>([
  {
    label: "a group that imports a lower group's entry module",
    file: 'infra/cluster/index.ts',
    source: "import { port } from '../inputs/index.ts';\n",
    other: 'infra/inputs/index.ts',
  },
  {
    label: 'a group that imports a file of its own',
    file: 'infra/cluster/index.ts',
    source: "import { buildNode } from './build-node.ts';\n",
    other: 'infra/cluster/build-node.ts',
  },
  {
    label: "observability that imports the ingress group's entry module",
    file: 'infra/observability/index.ts',
    source: "import { tunnel } from '../ingress/index.ts';\n",
    other: 'infra/ingress/index.ts',
  },
  {
    label: "the composition root that imports a group's entry module",
    file: 'infra/index.ts',
    source: "import { node } from './cluster/index.ts';\n",
    other: 'infra/cluster/index.ts',
  },
  {
    label: 'a test that imports the test utils',
    file: 'infra/cluster/build-node.test.ts',
    source: "import { buildMockVm } from '../test-utils/build-mock-vm.ts';\n",
    other: 'infra/test-utils/build-mock-vm.ts',
  },
  {
    label: 'a package that imports a file of its own',
    file: 'packages/preview/src/serve.ts',
    source: "import { route } from './route.ts';\n",
    other: 'packages/preview/src/route.ts',
  },
  {
    label: 'a script that imports another script',
    file: 'scripts/check-topology.ts',
    source: "import { run } from './run-process.ts';\n",
    other: 'scripts/run-process.ts',
  },
  {
    label: 'a script that imports a workspace package by its name',
    file: 'scripts/check-topology.ts',
    source: "import { port } from '@zgeoff/cloud-topology';\n",
    other: 'packages/topology/index.ts',
  },
])('it passes $label', async (row) => {
  const ctx = await setupTest();

  await Bun.write(join(ctx.dir, row.other), 'export const value = 1;\n');
  await Bun.write(join(ctx.dir, row.file), row.source);

  const result = await ctx.lint(row.file);

  expect(result.exitCode).toBe(0);
});
