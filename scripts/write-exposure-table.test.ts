// the first test asserts a whole rendered page as one literal, so its body is long
/* oxlint-disable max-lines-per-function */
import { expect, mock, onTestFinished, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { writeExposureTable } from './write-exposure-table.ts';

async function setupTest() {
  const root = await mkdtemp(join(tmpdir(), 'write-exposure-table-'));

  onTestFinished(() => rm(root, { recursive: true, force: true }));

  // the page's directory, which every checkout has
  await mkdir(join(root, 'docs', 'reference'), { recursive: true });

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { root, printOut, printErr };
}

test('it writes one row per entry between the markers, and keeps the rest of the page', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'docs', 'reference', 'exposure.md'),
    '# Exposure\n\nThe prose.\n\n<!-- exposure:start -->\nstale\n<!-- exposure:end -->\n\nAfter.\n',
  );

  const status = await writeExposureTable({
    args: [ctx.root],
    entries: [
      {
        name: 'tailscale',
        kind: 'host-port',
        protocol: 'udp',
        port: 41_641,
        scope: 'public',
        edge: 'Tailscale direct connections',
        reason: 'direct | relayed',
      },
      {
        name: 'relay',
        kind: 'host-port',
        protocol: 'tcp',
        port: 18_081,
        scope: 'host',
        interface: 'docker0',
        admission: true,
        reason: 'the relay',
      },
      {
        name: 'icmp',
        kind: 'host-port',
        protocol: 'icmp',
        scope: 'public',
        edge: 'ICMP',
        reason: 'ping',
      },
      {
        name: 'imp',
        kind: 'tunnel-hostname',
        hostname: 'imp.example.org',
        scope: 'reserved',
        reason: 'held',
      },
      {
        name: 'funnel',
        kind: 'tailnet-capability',
        attr: 'funnel',
        scope: 'public',
        reason: 'f',
        auth: 'signed | keyed',
        ticket: 'GEO-425',
      },
      {
        name: 'worker',
        kind: 'worker-url',
        script: 'health-check',
        scope: 'closed',
        reason: 'cron',
      },
    ],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  const written = await readFile(join(ctx.root, 'docs', 'reference', 'exposure.md'), 'utf8');

  expect(written).toBe(
    `# Exposure

The prose.

<!-- exposure:start -->

| Name        | Kind               | Exposes                       | Scope    | Reason            | Auth            | Ticket  |
| ----------- | ------------------ | ----------------------------- | -------- | ----------------- | --------------- | ------- |
| \`tailscale\` | host-port          | udp 41641                     | public   | direct \\| relayed |                 |         |
| \`relay\`     | host-port          | tcp 18081 on \`docker0\`        | host     | the relay         |                 |         |
| \`icmp\`      | host-port          | icmp                          | public   | ping              |                 |         |
| \`imp\`       | tunnel-hostname    | \`imp.example.org\`             | reserved | held              |                 |         |
| \`funnel\`    | tailnet-capability | node attribute \`funnel\`       | public   | f                 | signed \\| keyed | GEO-425 |
| \`worker\`    | worker-url         | \`health-check\` on workers.dev | closed   | cron              |                 |         |

<!-- exposure:end -->

After.
`,
  );

  expect(status).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    'write-exposure-table: wrote docs/reference/exposure.md\n',
  );
});

test('it passes the check when the page holds the table of the registry', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'docs', 'reference', 'exposure.md'),
    `<!-- exposure:start -->

| Name   | Kind      | Exposes | Scope  | Reason | Auth | Ticket |
| ------ | --------- | ------- | ------ | ------ | ---- | ------ |
| \`icmp\` | host-port | icmp    | public | ping   |      |        |

<!-- exposure:end -->
`,
  );

  const status = await writeExposureTable({
    args: ['--check', ctx.root],
    entries: [
      {
        name: 'icmp',
        kind: 'host-port',
        protocol: 'icmp',
        scope: 'public',
        edge: 'ICMP',
        reason: 'ping',
      },
    ],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(0);
  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it fails the check and writes nothing when the page differs from the registry', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.root, 'docs', 'reference', 'exposure.md'),
    '<!-- exposure:start -->\nstale\n<!-- exposure:end -->\n',
  );

  const status = await writeExposureTable({
    args: ['--check', ctx.root],
    entries: [
      {
        name: 'icmp',
        kind: 'host-port',
        protocol: 'icmp',
        scope: 'public',
        edge: 'ICMP',
        reason: 'ping',
      },
    ],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'write-exposure-table: docs/reference/exposure.md differs from packages/topology/exposure.json; run bun run docs:exposure\n',
  );

  const written = await readFile(join(ctx.root, 'docs', 'reference', 'exposure.md'), 'utf8');

  expect(written).toBe('<!-- exposure:start -->\nstale\n<!-- exposure:end -->\n');
});

test('it fails on a page without its markers', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.root, 'docs', 'reference', 'exposure.md'), '# Exposure\n');

  const status = await writeExposureTable({
    args: [ctx.root],
    entries: [],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'write-exposure-table: cannot read docs/reference/exposure.md, or it lacks its <!-- exposure:start --> and <!-- exposure:end --> markers\n',
  );
});

test('it prints its usage for more than one root', async () => {
  const ctx = await setupTest();

  const status = await writeExposureTable({
    args: [ctx.root, ctx.root],
    entries: [],
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(status).toBe(2);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'usage: write-exposure-table.ts [--check] [repo root]\n',
  );
});
