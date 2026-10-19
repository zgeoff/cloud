import { expect, mock, test } from 'bun:test';
import { resetNixie } from './reset-nixie.ts';

test('it refuses without a confirmation flag and never reaches the host', async () => {
  const runRemote = mock((command: string) =>
    Promise.resolve({ exitCode: 97, stdout: '', stderr: `unexpected: ${command}` }),
  );

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await resetNixie({ args: [], runRemote, printOut, printErr });

  expect(exitCode).toBe(1);
  expect(runRemote).not.toHaveBeenCalled();
  expect(printOut).not.toHaveBeenCalled();

  expect(printErr.mock.calls).toStrictEqual([
    [
      'reset-nixie: refusing to reset nixie without --confirm; --dry-run lists what it keeps\nusage: bun run nixie:reset --dry-run | --confirm\n',
    ],
  ]);
});

test.each([
  ['both flags', ['--dry-run', '--confirm']],
  ['an unknown flag', ['--yes']],
  ['a misspelt confirmation flag', ['--confirmed']],
])('it rejects %s and never reaches the host', async (_label: string, args: readonly string[]) => {
  const runRemote = mock((command: string) =>
    Promise.resolve({ exitCode: 97, stdout: '', stderr: `unexpected: ${command}` }),
  );

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await resetNixie({ args, runRemote, printOut, printErr });

  expect(exitCode).toBe(2);
  expect(runRemote).not.toHaveBeenCalled();

  expect(printErr.mock.calls).toStrictEqual([
    ['usage: bun run nixie:reset --dry-run | --confirm\n'],
  ]);
});

const sessionsCommand = 'k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie sessions';

const resetCommand =
  'k3s kubectl -n nixie exec nixie-0 -c nixie -- nixie reset --keep-sessions --yes';

const plan = `nixie reset on geoffcloud: this removes every record, every memory, the conversation and every sandbox; only a restore from a backup undoes it
device sessions kept signed in: 2
steps:
  1. ${resetCommand}
`;

const sessions = JSON.stringify([{ sessionID: 'a' }, { sessionID: 'b' }]);

test('it lists the kept sessions and the step on a dry run and runs only the session list', async () => {
  const runRemote = mock((command: string) => {
    const result =
      command === sessionsCommand
        ? { exitCode: 0, stdout: `${sessions}\n`, stderr: '' }
        : { exitCode: 97, stdout: '', stderr: `unexpected: ${command}` };

    return Promise.resolve(result);
  });

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await resetNixie({ args: ['--dry-run'], runRemote, printOut, printErr });

  expect(exitCode).toBe(0);
  expect(runRemote.mock.calls).toStrictEqual([[sessionsCommand]]);
  expect(printErr).not.toHaveBeenCalled();

  expect(printOut.mock.calls).toStrictEqual([
    [plan],
    ['dry run: nothing changed; run again with --confirm to reset\n'],
  ]);
});

test('it resets through nixie reset and prints what nixie answered', async () => {
  const answers: Record<string, string> = {
    [sessionsCommand]: sessions,
    [resetCommand]:
      'nixie removed the log up to sequence 412 at 2026-10-14T09:30:00.000Z and kept 2 device sessions signed in.\n',
  };

  const runRemote = mock((command: string) =>
    Promise.resolve({ exitCode: 0, stdout: answers[command] ?? '', stderr: '' }),
  );

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await resetNixie({ args: ['--confirm'], runRemote, printOut, printErr });

  expect(exitCode).toBe(0);
  expect(runRemote.mock.calls).toStrictEqual([[sessionsCommand], [resetCommand]]);
  expect(printErr).not.toHaveBeenCalled();

  expect(printOut.mock.calls).toStrictEqual([
    [plan],
    [`==> 1. ${resetCommand}\n`],
    [
      'nixie removed the log up to sequence 412 at 2026-10-14T09:30:00.000Z and kept 2 device sessions signed in.\n',
    ],
    [
      'reset done: nixie restarts now; bash scripts/check-nixie-ready.sh root@geoffcloud reports when it is ready\n',
    ],
  ]);
});

test("it exits 1 with nixie's answer when the reset fails", async () => {
  const runRemote = mock((command: string) => {
    const result =
      command === sessionsCommand
        ? { exitCode: 0, stdout: sessions, stderr: '' }
        : {
            exitCode: 1,
            stdout: '{"event":"command.failed","command":"reset"}\n',
            stderr: 'command terminated with exit code 1\n',
          };

    return Promise.resolve(result);
  });

  const printErr = mock<(text: string) => void>();

  const exitCode = await resetNixie({
    args: ['--confirm'],
    runRemote,
    printOut: () => {},
    printErr,
  });

  expect(exitCode).toBe(1);

  expect(printErr.mock.calls).toStrictEqual([
    [
      'reset-nixie: the reset failed (exit 1): {"event":"command.failed","command":"reset"} command terminated with exit code 1\nnixie\'s log holds the reason; run again with --confirm once the cause is fixed\n',
    ],
  ]);
});

test('it stops before any change when nixie does not list its sessions', async () => {
  const runRemote = mock((command: string) => {
    const result =
      command === sessionsCommand
        ? {
            exitCode: 1,
            stdout: '',
            stderr: 'error: unable to upgrade connection: container not found\n',
          }
        : { exitCode: 97, stdout: '', stderr: `unexpected: ${command}` };

    return Promise.resolve(result);
  });

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await resetNixie({ args: ['--confirm'], runRemote, printOut, printErr });

  expect(exitCode).toBe(1);
  expect(runRemote.mock.calls).toStrictEqual([[sessionsCommand]]);
  expect(printOut).not.toHaveBeenCalled();

  expect(printErr.mock.calls).toStrictEqual([
    [
      "reset-nixie: cannot list nixie's device sessions (exit 1): error: unable to upgrade connection: container not found\n",
    ],
  ]);
});
