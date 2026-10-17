/* oxlint-disable max-statements, max-lines-per-function */
import { expect, onTestFinished, test } from 'bun:test';
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { runProcess } from '../run-process.ts';

// The script runs under real bash against a temp tree that MOVE_ROOT prefixes, as the host runs it
// with an empty prefix. The mounts and the bind of / need root and a real pool: the NixOS check
// tank-cloud-host-secrets covers them.
async function setupTest() {
  const dir = await mkdtemp(join(tmpdir(), 'move-host-secrets-'));

  onTestFinished(() => rm(dir, { recursive: true, force: true }));

  const script = new URL('move-host-secrets.sh', import.meta.url).pathname;

  const env = { PATH: process.env['PATH'] ?? '/usr/bin:/bin', HOME: dir, MOVE_ROOT: dir };

  // the owner and group the script prints, as `find -printf %u:%g` names them
  const user = await runProcess(['id', '-un']);
  const group = await runProcess(['id', '-gn']);

  return {
    dir,
    owner: `${user.stdout.toString().trim()}:${group.stdout.toString().trim()}`,
    run: (mode: string) => runProcess(['bash', script, mode], { env }),
  };
}

test('it seeds each directory on tank/cloud with the modes, owners and content of the old one', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.dir, 'var/lib/imp-host/secrets'), { recursive: true, mode: 0o700 });
  await chmod(join(ctx.dir, 'var/lib/imp-host/secrets'), 0o700);

  await writeFile(join(ctx.dir, 'var/lib/imp-host/secrets/tailscale-authkey'), 'key-one', {
    mode: 0o400,
  });

  await writeFile(join(ctx.dir, 'var/lib/imp-host/secrets/imp-host.env'), 'IMP_A=1\n', {
    mode: 0o600,
  });

  await mkdir(join(ctx.dir, 'var/lib/atc-daemon-secrets'), { recursive: true });
  await chmod(join(ctx.dir, 'var/lib/atc-daemon-secrets'), 0o700);

  await writeFile(join(ctx.dir, 'var/lib/atc-daemon-secrets/gateway-token'), 'bearer-one\n', {
    mode: 0o400,
  });

  await mkdir(join(ctx.dir, 'root/imp-db-backups/imp-2.1.0-20260101T000000'), { recursive: true });
  await chmod(join(ctx.dir, 'root/imp-db-backups'), 0o700);
  await chmod(join(ctx.dir, 'root/imp-db-backups/imp-2.1.0-20260101T000000'), 0o755);

  await writeFile(join(ctx.dir, 'root/imp-db-backups/imp-2.1.0-20260101T000000/imp.sqlite'), 'db', {
    mode: 0o600,
  });

  await writeFile(join(ctx.dir, 'root/imp-db-backups/loose.sqlite'), 'loose', { mode: 0o600 });

  const result = await ctx.run('seed');

  expect(result.exitCode).toBe(0);
  expect(result.stderr.toString()).toBe('');

  expect(result.stdout.toString()).toBe(
    [
      'seeded /var/lib/imp-host/secrets -> /var/lib/tank-cloud/host-secrets/imp-host: 2 entries',
      'seeded /var/lib/atc-daemon-secrets -> /var/lib/tank-cloud/host-secrets/atc-daemon: 1 entries',
      'seeded /root/imp-db-backups -> /var/lib/tank-cloud/imp-db-backups: 3 entries',
      '',
    ].join('\n'),
  );

  const modes = await Promise.all(
    [
      'var/lib/tank-cloud/host-secrets/imp-host',
      'var/lib/tank-cloud/host-secrets/imp-host/tailscale-authkey',
      'var/lib/tank-cloud/host-secrets/imp-host/imp-host.env',
      'var/lib/tank-cloud/host-secrets/atc-daemon',
      'var/lib/tank-cloud/host-secrets/atc-daemon/gateway-token',
      'var/lib/tank-cloud/imp-db-backups',
      'var/lib/tank-cloud/imp-db-backups/imp-2.1.0-20260101T000000',
      'var/lib/tank-cloud/imp-db-backups/imp-2.1.0-20260101T000000/imp.sqlite',
      'var/lib/tank-cloud/imp-db-backups/loose.sqlite',
    ].map(async (path) => {
      const status = await stat(join(ctx.dir, path));

      return status.mode & 0o7777;
    }),
  );

  const oldOwner = await stat(join(ctx.dir, 'var/lib/imp-host/secrets'));
  const newOwner = await stat(join(ctx.dir, 'var/lib/tank-cloud/host-secrets/imp-host'));

  const token = await readFile(
    join(ctx.dir, 'var/lib/tank-cloud/host-secrets/atc-daemon/gateway-token'),
    'utf8',
  );

  expect(modes).toStrictEqual([0o700, 0o400, 0o600, 0o700, 0o400, 0o700, 0o755, 0o600, 0o600]);
  expect([newOwner.uid, newOwner.gid]).toStrictEqual([oldOwner.uid, oldOwner.gid]);
  expect(token).toBe('bearer-one\n');
});

test('it refuses to seed into a directory on tank/cloud that holds a file, and copies nothing', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.dir, 'var/lib/imp-host/secrets'), { recursive: true });
  await mkdir(join(ctx.dir, 'var/lib/atc-daemon-secrets'), { recursive: true });
  await mkdir(join(ctx.dir, 'root/imp-db-backups'), { recursive: true });
  await writeFile(join(ctx.dir, 'var/lib/imp-host/secrets/imp-host.env'), 'IMP_A=1\n');
  await mkdir(join(ctx.dir, 'var/lib/tank-cloud/host-secrets/atc-daemon'), { recursive: true });
  await writeFile(join(ctx.dir, 'var/lib/tank-cloud/host-secrets/atc-daemon/gateway-token'), 'x');

  const result = await ctx.run('seed');

  expect(result.exitCode).toBe(1);
  expect(result.stdout.toString()).toBe('');

  expect(result.stderr.toString()).toBe(
    'move-host-secrets: refusing to seed /var/lib/tank-cloud/host-secrets/atc-daemon: it is not empty\n',
  );

  expect(
    Bun.file(join(ctx.dir, 'var/lib/tank-cloud/host-secrets/imp-host')).exists(),
  ).resolves.toBe(false);
});

test('it matches trees that hold the same entries, and counts the entries only on tank/cloud', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.dir, 'var/lib/imp-host/secrets'), { recursive: true });
  await chmod(join(ctx.dir, 'var/lib/imp-host/secrets'), 0o700);
  await mkdir(join(ctx.dir, 'var/lib/atc-daemon-secrets'), { recursive: true });
  await mkdir(join(ctx.dir, 'root/imp-db-backups'), { recursive: true });
  await chmod(join(ctx.dir, 'root/imp-db-backups'), 0o700);

  await writeFile(join(ctx.dir, 'var/lib/imp-host/secrets/imp-host.env'), 'IMP_A=1\n', {
    mode: 0o600,
  });

  await ctx.run('seed');

  await mkdir(join(ctx.dir, 'var/lib/tank-cloud/imp-db-backups/imp-2.1.0-20260102T000000'));

  await writeFile(
    join(ctx.dir, 'var/lib/tank-cloud/imp-db-backups/imp-2.1.0-20260102T000000/imp.sqlite'),
    'copy',
  );

  const result = await ctx.run('compare');

  expect(result.exitCode).toBe(0);
  expect(result.stderr.toString()).toBe('');

  expect(result.stdout.toString()).toBe(
    [
      'match /var/lib/imp-host/secrets: 1 entries, 0 only on tank/cloud',
      `root /var/lib/imp-host/secrets: mode 700, owner ${ctx.owner}`,
      'match /var/lib/atc-daemon-secrets: 0 entries, 0 only on tank/cloud',
      `root /var/lib/atc-daemon-secrets: mode 755, owner ${ctx.owner}`,
      'match /root/imp-db-backups: 0 entries, 2 only on tank/cloud',
      `root /root/imp-db-backups: mode 700, owner ${ctx.owner}`,
      '',
    ].join('\n'),
  );
});

test('it reports a changed mode, a changed content and a missing file by path and field, and never prints content', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.dir, 'var/lib/imp-host/secrets'), { recursive: true });
  await mkdir(join(ctx.dir, 'var/lib/atc-daemon-secrets'), { recursive: true });
  await mkdir(join(ctx.dir, 'root/imp-db-backups'), { recursive: true });

  await writeFile(join(ctx.dir, 'var/lib/imp-host/secrets/imp-host.env'), 'SECRET-ONE', {
    mode: 0o600,
  });

  await writeFile(join(ctx.dir, 'var/lib/imp-host/secrets/backup-password'), 'SECRET-TWO', {
    mode: 0o400,
  });

  await writeFile(join(ctx.dir, 'var/lib/atc-daemon-secrets/gateway-token'), 'SECRET-THREE', {
    mode: 0o400,
  });

  await ctx.run('seed');

  await chmod(join(ctx.dir, 'var/lib/tank-cloud/host-secrets/imp-host/imp-host.env'), 0o644);
  await rm(join(ctx.dir, 'var/lib/tank-cloud/host-secrets/imp-host/backup-password'));

  await writeFile(
    join(ctx.dir, 'var/lib/tank-cloud/host-secrets/imp-host/backup-password'),
    'SECRET-TWX',
    { mode: 0o400 },
  );

  await rm(join(ctx.dir, 'var/lib/tank-cloud/host-secrets/atc-daemon/gateway-token'));

  const result = await ctx.run('compare');

  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toBe('');

  expect(result.stdout.toString()).toBe(
    [
      'MISMATCH /var/lib/imp-host/secrets:',
      '  ./backup-password: content differs',
      '  ./imp-host.env: mode differs',
      'MISMATCH /var/lib/atc-daemon-secrets:',
      '  ./gateway-token: missing',
      'match /root/imp-db-backups: 0 entries, 0 only on tank/cloud',
      `root /root/imp-db-backups: mode 755, owner ${ctx.owner}`,
      '',
    ].join('\n'),
  );
});

test('it refuses to remove the old copies while an old path is not a mount point, and deletes nothing', async () => {
  const ctx = await setupTest();

  await mkdir(join(ctx.dir, 'var/lib/imp-host/secrets'), { recursive: true });
  await mkdir(join(ctx.dir, 'var/lib/atc-daemon-secrets'), { recursive: true });
  await mkdir(join(ctx.dir, 'root/imp-db-backups'), { recursive: true });
  await writeFile(join(ctx.dir, 'var/lib/imp-host/secrets/imp-host.env'), 'IMP_A=1\n');

  await ctx.run('seed');

  const result = await ctx.run('remove-old');

  expect(result.exitCode).toBe(1);
  expect(result.stdout.toString()).toBe('');

  expect(result.stderr.toString()).toBe(
    'move-host-secrets: refusing to remove: /var/lib/imp-host/secrets is not a mount point, so the switch has not run\n',
  );

  expect(readFile(join(ctx.dir, 'var/lib/imp-host/secrets/imp-host.env'), 'utf8')).resolves.toBe(
    'IMP_A=1\n',
  );
});
