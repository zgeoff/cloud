import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { checkImpdHealth } from './check-impd-health.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it sends read-impd-health.sh on ssh’s stdin with impd’s port, and passes a 200 whose JSON body says ready', async () => {
  const script = await readFile(new URL('host/read-impd-health.sh', import.meta.url), 'utf8');

  const stub = buildStubRunner(() => ({
    stdout: '200\n{"status":"ok","ready":true,"warnings":[]}',
  }));

  const line = await checkImpdHealth({ run: stub.run, host: 'geoffcloud' });

  expect(line).toStrictEqual({ status: 'ok', text: "impd is ready on geoffcloud's loopback" });
  expect(stub.calls.map((call) => call.argv.at(-1))).toStrictEqual(["'bash' '-s' '--' '7070'"]);
  expect(stub.calls[0]?.stdin).toBe(script);
});

test('it passes a ready body that JSON spaces out over several lines', async () => {
  const stub = buildStubRunner(() => ({
    stdout: '200\n{\n  "status": "ok",\n  "ready": true\n}\n',
  }));

  const line = await checkImpdHealth({ run: stub.run, host: 'geoffcloud' });

  expect(line).toStrictEqual({ status: 'ok', text: "impd is ready on geoffcloud's loopback" });
});

test.each([
  {
    label: 'a not-ready body',
    stdout: '200\n{"status":"ok","ready":false}',
    shown: 'a 200 whose body has ready false',
  },
  {
    label: 'a body without ready',
    stdout: '200\n{"status":"ok"}',
    shown: 'a 200 whose body has ready missing',
  },
  {
    label: 'a ready that is a string',
    stdout: '200\n{"ready":"true"}',
    shown: 'a 200 whose body has ready that is not a boolean',
  },
  {
    label: 'a body that only names ready true in text',
    stdout: '200\n<p>"ready":true</p>',
    shown: 'a 200 whose body is not JSON',
  },
  { label: 'an empty 200', stdout: '200\n', shown: 'a 200 whose body is not JSON' },
  { label: 'another status with a ready body', stdout: '503\n{"ready":true}', shown: 'status 503' },
  { label: 'no answer on the port', stdout: '000\n', shown: 'no answer (000)' },
])('it fails the check for $label', async (row) => {
  const stub = buildStubRunner(() => ({ stdout: row.stdout }));

  const line = await checkImpdHealth({ run: stub.run, host: 'geoffcloud' });

  expect(line).toStrictEqual({
    status: 'FAIL',
    text: `impd is not ready on geoffcloud's loopback: ${row.shown}`,
  });
});

test('it fails the check as no answer when ssh fails', async () => {
  const stub = buildStubRunner(() => ({ exitCode: 255, stdout: '' }));

  const line = await checkImpdHealth({ run: stub.run, host: 'geoffcloud' });

  expect(line).toStrictEqual({
    status: 'FAIL',
    text: "impd is not ready on geoffcloud's loopback: no answer (000)",
  });
});
