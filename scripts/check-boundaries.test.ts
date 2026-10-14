import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkBoundaries } from './check-boundaries.ts';

async function setupTest() {
  const root = await mkdtemp(join(tmpdir(), 'check-boundaries-'));

  onTestFinished(() => rm(root, { recursive: true, force: true }));

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { root, printOut, printErr };
}

test('it passes a tree whose groups import a lower group through its entry module', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.root, 'infra', 'inputs'), { recursive: true });
  await mkdir(join(ctx.root, 'infra', 'cluster'), { recursive: true });
  await writeFile(join(ctx.root, 'infra', 'inputs', 'index.ts'), 'export const port = 1;\n');

  await writeFile(
    join(ctx.root, 'infra', 'cluster', 'index.ts'),
    "import { port } from '../inputs/index.ts';\nexport const url = port + 1;\n",
  );

  const status = await checkBoundaries({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    '\n✔ no dependency violations found (2 modules, 1 dependencies cruised)\n\n',
  );
});

test("it fails a relative import into the generated SDK's built files", async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.root, 'infra', 'edge'), { recursive: true });
  await mkdir(join(ctx.root, 'sdk', 'onidel', 'bin'), { recursive: true });
  await writeFile(join(ctx.root, 'sdk', 'onidel', 'bin', 'index.js'), 'export const vm = 1;\n');

  await writeFile(
    join(ctx.root, 'infra', 'edge', 'index.ts'),
    "import { vm } from '../../sdk/onidel/bin/index.js';\nexport const id = vm;\n",
  );

  const status = await checkBoundaries({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toMatchInlineSnapshot(`
    [
      [
        
    "
      error no-relative-import-into-another-package: infra/edge/index.ts → sdk/onidel/bin/index.js

    x 1 dependency violations (1 errors, 0 warnings). 2 modules, 1 dependencies cruised.

    "
    ,
      ],
    ]
  `);
});

test('it fails an upward import from inputs into the cluster group', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.root, 'infra', 'inputs'), { recursive: true });
  await mkdir(join(ctx.root, 'infra', 'cluster'), { recursive: true });
  await writeFile(join(ctx.root, 'infra', 'cluster', 'index.ts'), 'export const name = "c";\n');

  await writeFile(
    join(ctx.root, 'infra', 'inputs', 'index.ts'),
    "import type { name } from '../cluster/index.ts';\nexport type Name = typeof name;\n",
  );

  const status = await checkBoundaries({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toMatchInlineSnapshot(`
    [
      [
        
    "
      error infra-inputs-imports-no-group: infra/inputs/index.ts → infra/cluster/index.ts

    x 1 dependency violations (1 errors, 0 warnings). 2 modules, 1 dependencies cruised.

    "
    ,
      ],
    ]
  `);
});

test.each([
  [
    'a variable annotation',
    "export const items: Array<import('../cluster/index.ts').Thing> = [];\n",
  ],
  ['a type alias', "export type Things = Array<import('../cluster/index.ts').Thing>;\n"],
  ['an as expression', "export const items = [] as Array<import('../cluster/index.ts').Thing>;\n"],
  ['a typeof type query', "export const cluster: typeof import('../cluster/index.ts') = null!;\n"],
])('it fails an upward import type from inputs nested in %s', async (_, source) => {
  const ctx = await setupTest();

  await mkdir(join(ctx.root, 'infra', 'inputs'), { recursive: true });
  await mkdir(join(ctx.root, 'infra', 'cluster'), { recursive: true });
  await writeFile(join(ctx.root, 'infra', 'cluster', 'index.ts'), 'export type Thing = number;\n');
  await writeFile(join(ctx.root, 'infra', 'inputs', 'index.ts'), source);

  const status = await checkBoundaries({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    '\n  error infra-inputs-imports-no-group: infra/inputs/index.ts → infra/cluster/index.ts\n\nx 1 dependency violations (1 errors, 0 warnings). 2 modules, 1 dependencies cruised.\n\n',
  );
});

test('it passes an import type nested in a variable annotation that points down a layer', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.root, 'infra', 'inputs'), { recursive: true });
  await mkdir(join(ctx.root, 'infra', 'cluster'), { recursive: true });
  await writeFile(join(ctx.root, 'infra', 'inputs', 'index.ts'), 'export type Port = number;\n');

  await writeFile(
    join(ctx.root, 'infra', 'cluster', 'index.ts'),
    "export const ports: Array<import('../inputs/index.ts').Port> = [];\n",
  );

  const status = await checkBoundaries({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    '\n✔ no dependency violations found (2 modules, 1 dependencies cruised)\n\n',
  );
});

test('it fails a relative import into another workspace package', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.root, 'infra', 'edge'), { recursive: true });
  await mkdir(join(ctx.root, 'packages', 'topology'), { recursive: true });
  await writeFile(join(ctx.root, 'packages', 'topology', 'index.ts'), 'export const vm = 1;\n');

  await writeFile(
    join(ctx.root, 'infra', 'edge', 'index.ts'),
    "import { vm } from '../../packages/topology/index.ts';\nexport const id = vm;\n",
  );

  const status = await checkBoundaries({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toMatchInlineSnapshot(`
    [
      [
        
    "
      error no-relative-import-into-another-package: infra/edge/index.ts → packages/topology/index.ts

    x 1 dependency violations (1 errors, 0 warnings). 2 modules, 1 dependencies cruised.

    "
    ,
      ],
    ]
  `);
});

test('it fails a relative import from the root package into a workspace package', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.root, 'scripts'), { recursive: true });
  await mkdir(join(ctx.root, 'infra', 'inputs'), { recursive: true });
  await writeFile(join(ctx.root, 'infra', 'inputs', 'index.ts'), 'export const port = 1;\n');

  await writeFile(
    join(ctx.root, 'scripts', 'read-port.ts'),
    "import { port } from '../infra/inputs/index.ts';\nexport const read = port;\n",
  );

  const status = await checkBoundaries({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toMatchInlineSnapshot(`
    [
      [
        
    "
      error no-relative-import-from-the-root-package: scripts/read-port.ts → infra/inputs/index.ts

    x 1 dependency violations (1 errors, 0 warnings). 2 modules, 1 dependencies cruised.

    "
    ,
      ],
    ]
  `);
});

test('it fails an import of a module inside another group', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.root, 'infra', 'inputs'), { recursive: true });
  await mkdir(join(ctx.root, 'infra', 'cluster'), { recursive: true });
  await writeFile(join(ctx.root, 'infra', 'inputs', 'find-port.ts'), 'export const port = 1;\n');

  await writeFile(
    join(ctx.root, 'infra', 'cluster', 'index.ts'),
    "import { port } from '../inputs/find-port.ts';\nexport const url = port + 1;\n",
  );

  const status = await checkBoundaries({
    args: [ctx.root],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  expect(ctx.printErr.mock.calls).toMatchInlineSnapshot(`
    [
      [
        
    "
      error infra-cross-group-import-through-the-entry-module: infra/cluster/index.ts → infra/inputs/find-port.ts

    x 1 dependency violations (1 errors, 0 warnings). 2 modules, 1 dependencies cruised.

    "
    ,
      ],
    ]
  `);
});

test('it prints the usage and exits 2 for a second argument', async () => {
  const ctx = await setupTest();

  const status = await checkBoundaries({
    args: [ctx.root, 'extra'],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(2);
  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith('usage: check-boundaries.ts [repo root]\n');
});
