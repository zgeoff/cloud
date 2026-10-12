// each test states its stand-in and the whole output inline, so its body is long
/* oxlint-disable max-lines-per-function, max-statements */
import { expect, mock, test } from 'bun:test';
import { checkNixieStream } from './check-nixie-stream.ts';
import { startStubNixieAPI } from './test-utils/start-stub-nixie-api.ts';

test('it holds the stream open, reads the same record count before and after, and revokes its session', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: ['ABCD-2345'],
    sequences: [1, 2, 3],
    keepaliveMs: 50,
    closeAfterMs: null,
  });

  const runRemote = mock<
    (command: string) => Promise<{ exitCode: number; stdout: string; stderr: string }>
  >(() =>
    Promise.resolve({
      exitCode: 0,
      stdout: 'ABCD-2345\nworks until 2026-10-12T10:15:00Z\n',
      stderr: '',
    }),
  );

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieStream({
    url: 'https://nixie.test',
    holdMs: 400,
    maxGapMs: 200,
    runRemote,
    printOut,
    printErr,
  });

  const [session] = stub.sessions;

  expect(exitCode).toBe(0);
  expect(printErr).not.toHaveBeenCalled();

  expect(runRemote.mock.calls).toStrictEqual([
    ['k3s kubectl -n nixie exec nixie-0 -c nixie -- bun /app/main.js enrol-code'],
  ]);

  expect(stub.sessions).toStrictEqual([{ sessionID: expect.toBeString(), revoked: true }]);

  expect(stub.calls).toStrictEqual([
    'sessions/enrol',
    'conversation/read',
    'log/follow',
    'conversation/read',
    'sessions/revoke',
  ]);

  expect(printOut.mock.calls).toStrictEqual([
    [`enrolled check session ${session?.sessionID}\n`],
    ['conversation records before: 3\n'],
    [
      expect.toSatisfy((line: string) =>
        /^stream held for 0\.\d s: \d+ keepalives, longest wait 0\.\d s, 0 records\n$/u.test(line),
      ),
    ],
    ['conversation records after: 3\n'],
    [`revoked check session ${session?.sessionID}\n`],
    ['stream check passed\n'],
  ]);
});

test('it fails when a record arrives during the hold, and still revokes its session', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: ['ABCD-2345'],
    sequences: [1, 2, 3],
    keepaliveMs: 50,
    closeAfterMs: null,
  });

  const printErr = mock<(text: string) => void>();

  const running = checkNixieStream({
    url: 'https://nixie.test',
    holdMs: 400,
    maxGapMs: 200,
    runRemote: () => Promise.resolve({ exitCode: 0, stdout: 'ABCD-2345\n', stderr: '' }),
    printOut: mock(),
    printErr,
  });

  await stub.waitForStream();

  stub.appendRecord();

  const exitCode = await running;

  expect(exitCode).toBe(1);
  expect(stub.sessions).toStrictEqual([{ sessionID: expect.toBeString(), revoked: true }]);

  expect(printErr.mock.calls).toStrictEqual([
    ['check-nixie-stream: the stream carried 1 new records\n'],
    ['check-nixie-stream: the conversation went from 3 to 4 records\n'],
  ]);
});

test('it fails when nixie closes the stream before the hold ends', async () => {
  startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: ['ABCD-2345'],
    sequences: [1],
    keepaliveMs: 50,
    closeAfterMs: 100,
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieStream({
    url: 'https://nixie.test',
    holdMs: 400,
    maxGapMs: 200,
    runRemote: () => Promise.resolve({ exitCode: 0, stdout: 'ABCD-2345\n', stderr: '' }),
    printOut: mock(),
    printErr,
  });

  expect(exitCode).toBe(1);

  expect(printErr.mock.calls).toStrictEqual([
    ['check-nixie-stream: the stream did not stay open: closed\n'],
  ]);
});

test('it fails when the stream waits longer than the allowed wait for a keepalive', async () => {
  startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: ['ABCD-2345'],
    sequences: [1],
    keepaliveMs: null,
    closeAfterMs: null,
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieStream({
    url: 'https://nixie.test',
    holdMs: 400,
    maxGapMs: 200,
    runRemote: () => Promise.resolve({ exitCode: 0, stdout: 'ABCD-2345\n', stderr: '' }),
    printOut: mock(),
    printErr,
  });

  expect(exitCode).toBe(1);

  expect(printErr.mock.calls).toStrictEqual([
    ['check-nixie-stream: the stream went more than 0.2 s without a keepalive\n'],
  ]);
});

test('it calls nixie nowhere when the pod gives no enrolment code', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: ['ABCD-2345'],
    sequences: [1],
    keepaliveMs: 50,
    closeAfterMs: null,
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieStream({
    url: 'https://nixie.test',
    holdMs: 400,
    maxGapMs: 200,
    runRemote: () =>
      Promise.resolve({ exitCode: 1, stdout: '', stderr: 'error: pod nixie-0 not found\n' }),
    printOut: mock(),
    printErr,
  });

  expect(exitCode).toBe(1);
  expect(stub.calls).toStrictEqual([]);

  expect(printErr.mock.calls).toStrictEqual([
    ['check-nixie-stream: cannot get an enrolment code (exit 1): error: pod nixie-0 not found\n'],
  ]);
});

test('it stops with no session when nixie refuses the enrolment code', async () => {
  const stub = startStubNixieAPI({
    url: 'https://nixie.test',
    enrolCodes: ['ABCD-2345'],
    sequences: [1],
    keepaliveMs: 50,
    closeAfterMs: null,
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await checkNixieStream({
    url: 'https://nixie.test',
    holdMs: 400,
    maxGapMs: 200,
    runRemote: () => Promise.resolve({ exitCode: 0, stdout: 'WXYZ-6789\n', stderr: '' }),
    printOut: mock(),
    printErr,
  });

  expect(exitCode).toBe(1);
  expect(stub.calls).toStrictEqual(['sessions/enrol']);
  expect(stub.sessions).toStrictEqual([]);

  expect(printErr.mock.calls).toStrictEqual([
    [
      'check-nixie-stream: cannot enrol a check session: sessions/enrol answered 400 ENROLMENT_CODE_INVALID\n',
    ],
  ]);
});
