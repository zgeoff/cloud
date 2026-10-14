import { expect, test } from 'bun:test';
import { readFile } from 'node:fs/promises';
import { checkImpdHealth } from './check-impd-health.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it sends read-impd-health.sh on ssh’s stdin with impd’s port, and passes a ready impd', async () => {
  const script = await readFile(new URL('host/read-impd-health.sh', import.meta.url), 'utf8');

  const stub = buildStubRunner(() => ({ stdout: '200 1\n' }));

  const line = await checkImpdHealth({ run: stub.run, host: 'geoffcloud' });

  expect(line).toStrictEqual({ status: 'ok', text: "impd is ready on geoffcloud's loopback" });
  expect(stub.calls.map((call) => call.argv.at(-1))).toStrictEqual(["'bash' '-s' '--' '7070'"]);
  expect(stub.calls[0]?.stdin).toBe(script);
});

test.each([
  { label: 'a 200 whose body is not ready', exitCode: 0, stdout: '200 0\n', shown: '200' },
  { label: 'another status', exitCode: 0, stdout: '503 0\n', shown: '503' },
  { label: 'no answer on the port', exitCode: 0, stdout: '000 0\n', shown: '000' },
  { label: 'an ssh failure', exitCode: 255, stdout: '', shown: '000' },
])('it fails the check for $label', async (row) => {
  const stub = buildStubRunner(() => ({ exitCode: row.exitCode, stdout: row.stdout }));

  const line = await checkImpdHealth({ run: stub.run, host: 'geoffcloud' });

  expect(line).toStrictEqual({
    status: 'FAIL',
    text: `impd is not ready on geoffcloud's loopback: ${row.shown}`,
  });
});
