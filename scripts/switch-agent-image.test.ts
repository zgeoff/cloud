// each test asserts the output, the config, the backup and the calls on their own, so its body is long
/* oxlint-disable max-lines-per-function, max-statements */
import { expect, mock, onTestFinished, test } from 'bun:test';
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { switchAgentImage } from './switch-agent-image.ts';
import { buildStubImp } from './test-utils/build-stub-imp.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

// a home with the atc config directory the default config path names
async function setupTest() {
  const home = await mkdtemp(join(tmpdir(), 'switch-agent-image-'));

  onTestFinished(() => rm(home, { recursive: true, force: true }));

  await mkdir(join(home, '.config/atc'), { recursive: true });

  return { home, configDir: join(home, '.config/atc') };
}

test('it backs up the config, then points the cloud target at the image and keeps the rest', async () => {
  const ctx = await setupTest();

  const config = join(ctx.configDir, 'config.json');

  const before =
    '{\n  "port": 8415,\n  "targets": {\n    "local": { "provider": "local" },\n    "cloud": { "provider": "imp", "image": "agent-14d3c9d", "guestATC": "/usr/local/bin/atc", "host": "geoffcloud" }\n  }\n}\n';

  await writeFile(config, before);
  await chmod(config, 0o600);

  const imp = buildStubImp({
    images: [
      { name: 'agent-14d3c9d', digest: 'imp-build-1' },
      { name: 'agent-abc1234', digest: 'imp-build-2' },
    ],
  });

  const stub = buildStubRunner(imp.handler);
  const printOut = mock();
  const printErr = mock();

  const exitCode = await switchAgentImage({
    args: ['agent-abc1234', config],
    home: ctx.home,
    now: () => new Date('2026-10-10T05:06:07.123Z'),
    run: stub.run,
    printOut,
    printErr,
  });

  const backup = join(ctx.configDir, 'config.json.bak-20261010T050607Z-pre-agent-abc1234');

  const after = await readFile(config, 'utf8');
  const saved = await readFile(backup, 'utf8');
  const configInfo = await stat(config);
  const backupInfo = await stat(backup);

  expect(exitCode).toBe(0);

  expect(printOut.mock.calls).toStrictEqual([
    [
      `backed up ${config} to ${backup}\n` +
        'set targets.cloud.image to agent-abc1234 (was agent-14d3c9d)\n' +
        'the daemon reads its targets at startup: restart it when no session needs it, with\n' +
        '  atc daemon restart\n',
    ],
  ]);

  expect(printErr.mock.calls).toStrictEqual([]);
  expect(saved).toBe(before);

  expect(after).toBe(
    '{\n  "port": 8415,\n  "targets": {\n    "local": {\n      "provider": "local"\n    },\n    "cloud": {\n      "provider": "imp",\n      "image": "agent-abc1234",\n      "guestATC": "/usr/local/bin/atc",\n      "host": "geoffcloud"\n    }\n  }\n}\n',
  );

  expect(configInfo.mode & 0o777).toBe(0o600);
  expect(backupInfo.mode & 0o777).toBe(0o600);
  expect(stub.calls.map((call) => call.argv)).toStrictEqual([['imp', 'image', 'ls', '--json']]);
});

test('it switches the config in its home by default', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.configDir, 'config.json'),
    '{"targets":{"cloud":{"provider":"imp","image":"agent-14d3c9d"}}}\n',
  );

  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler);

  const exitCode = await switchAgentImage({
    args: ['agent-abc1234'],
    home: ctx.home,
    now: () => new Date('2026-10-10T05:06:07Z'),
    run: stub.run,
    printOut: () => {},
    printErr: () => {},
  });

  const after = await readFile(join(ctx.configDir, 'config.json'), 'utf8');

  expect(exitCode).toBe(0);

  expect(JSON.parse(after)).toStrictEqual({
    targets: {
      cloud: { provider: 'imp', image: 'agent-abc1234', guestATC: '/usr/local/bin/atc' },
    },
  });
});

test('it leaves a config that already runs the image alone, without asking the imp host', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.configDir, 'config.json'),
    '{"targets":{"cloud":{"image":"agent-abc1234","guestATC":"/usr/local/bin/atc"}}}\n',
  );

  const stub = buildStubRunner();
  const printOut = mock();

  const exitCode = await switchAgentImage({
    args: ['agent-abc1234'],
    home: ctx.home,
    now: () => new Date('2026-10-10T05:06:07Z'),
    run: stub.run,
    printOut,
    printErr: () => {},
  });

  const files = await readdir(ctx.configDir);

  expect(exitCode).toBe(0);
  expect(printOut.mock.calls).toStrictEqual([['the cloud target already runs agent-abc1234\n']]);
  expect(files).toStrictEqual(['config.json']);
  expect(stub.calls).toStrictEqual([]);
});

test('it sets guestATC when the config names the image without it', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.configDir, 'config.json'),
    '{"targets":{"cloud":{"provider":"imp","image":"agent-abc1234"}}}\n',
  );

  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler);
  const printOut = mock();

  const exitCode = await switchAgentImage({
    args: ['agent-abc1234'],
    home: ctx.home,
    now: () => new Date('2026-10-10T05:06:07Z'),
    run: stub.run,
    printOut,
    printErr: () => {},
  });

  const after = await readFile(join(ctx.configDir, 'config.json'), 'utf8');

  expect(exitCode).toBe(0);

  expect(printOut.mock.calls).toStrictEqual([
    [
      `backed up ${join(ctx.configDir, 'config.json')} to ${join(ctx.configDir, 'config.json.bak-20261010T050607Z-pre-agent-abc1234')}\n` +
        'set targets.cloud.image to agent-abc1234 (was agent-abc1234)\n' +
        'the daemon reads its targets at startup: restart it when no session needs it, with\n' +
        '  atc daemon restart\n',
    ],
  ]);

  expect(JSON.parse(after)).toStrictEqual({
    targets: {
      cloud: { provider: 'imp', image: 'agent-abc1234', guestATC: '/usr/local/bin/atc' },
    },
  });
});

test('it says the cloud target had no image before', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.configDir, 'config.json'), '{"targets":{"cloud":{"provider":"imp"}}}\n');

  const imp = buildStubImp({ images: [{ name: 'agent-abc1234', digest: 'imp-build-2' }] });
  const stub = buildStubRunner(imp.handler);
  const printOut = mock();

  await switchAgentImage({
    args: ['agent-abc1234'],
    home: ctx.home,
    now: () => new Date('2026-10-10T05:06:07Z'),
    run: stub.run,
    printOut,
    printErr: () => {},
  });

  expect(printOut.mock.calls[0]?.[0]).toInclude(
    'set targets.cloud.image to agent-abc1234 (was unset)\n',
  );
});

test('it refuses an image the imp host lacks, and changes nothing', async () => {
  const ctx = await setupTest();

  await writeFile(
    join(ctx.configDir, 'config.json'),
    '{"targets":{"cloud":{"provider":"imp","image":"agent-14d3c9d"}}}\n',
  );

  const imp = buildStubImp({ images: [{ name: 'agent-14d3c9d', digest: 'imp-build-1' }] });
  const stub = buildStubRunner(imp.handler);
  const printErr = mock();

  const exitCode = await switchAgentImage({
    args: ['agent-abc1234'],
    home: ctx.home,
    now: () => new Date('2026-10-10T05:06:07Z'),
    run: stub.run,
    printOut: () => {},
    printErr,
  });

  const files = await readdir(ctx.configDir);

  expect(exitCode).toBe(1);

  expect(printErr.mock.calls).toStrictEqual([
    ['the imp host has no image agent-abc1234: build it with scripts/build-agent-image.ts first\n'],
  ]);

  expect(files).toStrictEqual(['config.json']);
});

test('it stops with imp’s own exit code when the imp host cannot list its images', async () => {
  const ctx = await setupTest();

  await writeFile(join(ctx.configDir, 'config.json'), '{"targets":{"cloud":{}}}\n');

  const stub = buildStubRunner(() => ({ exitCode: 4, stderr: 'imp: UNAUTHORIZED\n' }));
  const printErr = mock();

  const exitCode = await switchAgentImage({
    args: ['agent-abc1234'],
    home: ctx.home,
    now: () => new Date('2026-10-10T05:06:07Z'),
    run: stub.run,
    printOut: () => {},
    printErr,
  });

  const files = await readdir(ctx.configDir);

  expect(exitCode).toBe(4);
  expect(printErr.mock.calls).toStrictEqual([['imp: UNAUTHORIZED\n']]);
  expect(files).toStrictEqual(['config.json']);
});

test.each([
  ['a config without a cloud target', '{"targets":{"local":{"provider":"local"}}}\n'],
  ['a config whose cloud target is not an object', '{"targets":{"cloud":"imp"}}\n'],
  ['a config that is not JSON', 'port = 8415\n'],
])('it refuses %s, and changes nothing', async (_label, text) => {
  const ctx = await setupTest();

  await writeFile(join(ctx.configDir, 'config.json'), text);

  const stub = buildStubRunner();
  const printErr = mock();

  const exitCode = await switchAgentImage({
    args: ['agent-abc1234'],
    home: ctx.home,
    now: () => new Date('2026-10-10T05:06:07Z'),
    run: stub.run,
    printOut: () => {},
    printErr,
  });

  const files = await readdir(ctx.configDir);

  expect(exitCode).toBe(1);

  expect(printErr.mock.calls).toStrictEqual([
    [`${join(ctx.configDir, 'config.json')} has no targets.cloud object\n`],
  ]);

  expect(files).toStrictEqual(['config.json']);
  expect(stub.calls).toStrictEqual([]);
});

test('it refuses a missing config', async () => {
  const ctx = await setupTest();

  const stub = buildStubRunner();
  const printErr = mock();

  const exitCode = await switchAgentImage({
    args: ['agent-abc1234'],
    home: ctx.home,
    now: () => new Date('2026-10-10T05:06:07Z'),
    run: stub.run,
    printOut: () => {},
    printErr,
  });

  expect(exitCode).toBe(1);

  expect(printErr.mock.calls).toStrictEqual([
    [`${join(ctx.configDir, 'config.json')} has no targets.cloud object\n`],
  ]);
});

test.each([
  ['no image', []],
  ['an empty image', ['']],
  ['an extra argument', ['agent-abc1234', 'config.json', 'more']],
])('it prints its usage and exits 2 for %s', async (_label, args) => {
  const ctx = await setupTest();

  const stub = buildStubRunner();
  const printErr = mock();

  const exitCode = await switchAgentImage({
    args,
    home: ctx.home,
    now: () => new Date('2026-10-10T05:06:07Z'),
    run: stub.run,
    printOut: () => {},
    printErr,
  });

  expect(exitCode).toBe(2);

  expect(printErr.mock.calls).toStrictEqual([
    ['usage: switch-agent-image.ts <image> [<atc config file>]\n'],
  ]);

  expect(stub.calls).toStrictEqual([]);
});
