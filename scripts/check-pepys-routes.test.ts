import { expect, onTestFinished, test } from 'bun:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { checkPepysRoutes } from './check-pepys-routes.ts';

async function setupTest() {
  const folder = await mkdtemp(join(tmpdir(), 'check-pepys-routes-'));

  onTestFinished(async () => {
    await rm(folder, { recursive: true, force: true });
  });

  const errors: string[] = [];

  return {
    tableFile: join(folder, 'ingest-routes.json'),
    deploymentText: JSON.stringify({
      name: 'example',
      plugins: [
        {
          name: 'widgets',
          sources: [
            {
              name: 'widgets',
              live: {
                kind: 'receive',
                route: '/hooks/widgets',
                check: { kind: 'hmac-sha256', header: 'x-signature', secretEnv: 'WIDGET_SECRET' },
                reach: 'public',
              },
            },
          ],
        },
      ],
    }),
    errors,
    printErr: (text: string) => {
      errors.push(text);
    },
  };
}

test('it passes a table that matches the deployment', async () => {
  const fixture = await setupTest();

  await writeFile(
    fixture.tableFile,
    JSON.stringify({
      routes: [{ source: 'widgets', route: '/hooks/widgets', reach: 'public' }],
      secretVariables: ['WIDGET_SECRET'],
    }),
  );

  const code = await checkPepysRoutes({
    args: [fixture.tableFile],
    deploymentText: fixture.deploymentText,
    printErr: fixture.printErr,
  });

  expect(code).toBe(0);
  expect(fixture.errors).toStrictEqual([]);
});

test('it fails a table whose route differs, and prints the table it must hold', async () => {
  const fixture = await setupTest();

  await writeFile(
    fixture.tableFile,
    JSON.stringify({
      routes: [{ source: 'widgets', route: '/webhook', reach: 'public' }],
      secretVariables: ['WIDGET_SECRET'],
    }),
  );

  const code = await checkPepysRoutes({
    args: [fixture.tableFile],
    deploymentText: fixture.deploymentText,
    printErr: fixture.printErr,
  });

  expect(code).toBe(1);

  expect(fixture.errors).toStrictEqual([
    `check-pepys-routes: ${fixture.tableFile} differs from the deployment; it must hold:\n${JSON.stringify(
      {
        routes: [{ source: 'widgets', route: '/hooks/widgets', reach: 'public' }],
        secretVariables: ['WIDGET_SECRET'],
      },
      null,
      2,
    )}\n`,
  ]);
});

test('it prints the usage and exits 2 without the table file', async () => {
  const fixture = await setupTest();

  const code = await checkPepysRoutes({
    args: [],
    deploymentText: fixture.deploymentText,
    printErr: fixture.printErr,
  });

  expect(code).toBe(2);

  expect(fixture.errors).toStrictEqual([
    'usage: <deployment as JSON> | check-pepys-routes.ts <route table file>\n',
  ]);
});
