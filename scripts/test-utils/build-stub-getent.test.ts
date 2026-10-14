import { expect, test } from 'bun:test';
import { runProcess } from '../run-process.ts';
import { buildStubGetent } from './build-stub-getent.ts';
import { buildStubRunner } from './build-stub-runner.ts';

test('it prints a host it holds as glibc’s getent prints a hosts entry', async () => {
  const stub = buildStubRunner(buildStubGetent({ 'atc.geoff.cloud': '104.21.32.1' }));

  const result = await stub.run(['getent', 'hosts', 'atc.geoff.cloud']);

  expect(result).toStrictEqual({
    exitCode: 0,
    stdout: Buffer.from('104.21.32.1     atc.geoff.cloud\n'),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('its print matches the real getent’s for a hosts-file entry', async () => {
  const stub = buildStubRunner(buildStubGetent({ localhost: '127.0.0.1' }));

  const stand = await stub.run(['getent', 'hosts', 'localhost']);
  const real = await runProcess(['getent', '-s', 'files', 'hosts', '127.0.0.1']);

  expect(real.stdout.toString().split('\n')[0]?.slice(0, 16)).toBe(
    stand.stdout.toString().slice(0, 16),
  );
});

test('it exits 2 with no output for a name it lacks, as getent does for a missing key', async () => {
  const stub = buildStubRunner(buildStubGetent({}));

  const result = await stub.run(['getent', 'hosts', 'atc.geoff.cloud']);

  expect(result).toStrictEqual({
    exitCode: 2,
    stdout: Buffer.from(''),
    stderr: Buffer.from(''),
    timedOut: false,
  });
});

test('it fails closed for another database, and leaves other programs alone', async () => {
  const stub = buildStubRunner(buildStubGetent({}));

  const passwd = await stub.run(['getent', 'passwd', 'root']);
  const other = await stub.run(['dig', 'atc.geoff.cloud']);

  expect(passwd.stderr.toString()).toBe('unexpected: ["getent","passwd","root"]\n');
  expect(other.stderr.toString()).toBe('unexpected: ["dig","atc.geoff.cloud"]\n');
});
