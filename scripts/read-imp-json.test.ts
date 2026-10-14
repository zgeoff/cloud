import { expect, test } from 'bun:test';
import { readImpJSON } from './read-imp-json.ts';
import { buildStubRunner } from './test-utils/build-stub-runner.ts';

test('it parses the listing imp prints', async () => {
  const stub = buildStubRunner(() => ({ stdout: '[{"name":"agent-check-abc1234"}]\n' }));

  const list = await readImpJSON({ run: stub.run, printOut: () => {}, printErr: () => {} }, [
    'ls',
    '--json',
  ]);

  expect(list).toStrictEqual([{ name: 'agent-check-abc1234' }]);
  expect(stub.calls.map((call) => call.argv)).toStrictEqual([['imp', 'ls', '--json']]);
});

test('it stops when imp prints no JSON', () => {
  const stub = buildStubRunner(() => ({ stdout: 'NAME  IMAGE\n' }));

  expect(
    readImpJSON({ run: stub.run, printOut: () => {}, printErr: () => {} }, [
      'image',
      'ls',
      '--json',
    ]),
  ).rejects.toMatchObject({ exitCode: 1, message: 'no JSON from imp image ls --json' });
});

test('it stops with imp’s exit code when the call fails', () => {
  const stub = buildStubRunner(() => ({ exitCode: 4, stderr: 'imp: UNAUTHORIZED\n' }));

  expect(
    readImpJSON({ run: stub.run, printOut: () => {}, printErr: () => {} }, ['ls', '--json']),
  ).rejects.toMatchObject({ exitCode: 4 });
});
