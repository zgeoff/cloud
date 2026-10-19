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
      "reset-nixie: refusing to delete nixie's data without --confirm; --dry-run lists what it deletes\nusage: bun run nixie:reset --dry-run | --confirm\n",
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

test('it lists the files and the steps on a dry run and runs only read-only commands', async () => {
  const directory = '/var/lib/rancher/k3s/storage/pvc-0f1e2d3c_nixie_data-nixie-0';

  const answers: Record<string, string> = {
    'k3s kubectl -n nixie get pvc data-nixie-0 -o jsonpath={.spec.volumeName}': 'pvc-0f1e2d3c',
    'k3s kubectl get pv pvc-0f1e2d3c -o jsonpath={.spec.hostPath.path}': `${directory}\n`,
    [`find ${directory} -maxdepth 1 -type f \\( -name nixie.db-wal -o -name nixie.db-shm -o -name nixie.db -o -name keys.db-wal -o -name keys.db-shm -o -name keys.db \\) -printf '%f %s bytes\\n'`]:
      'nixie.db 258048 bytes\nkeys.db 12288 bytes\n',
  };

  const runRemote = mock((command: string) => {
    const result =
      command in answers
        ? { exitCode: 0, stdout: answers[command] ?? '', stderr: '' }
        : { exitCode: 97, stdout: '', stderr: `unexpected: ${command}` };

    return Promise.resolve(result);
  });

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await resetNixie({ args: ['--dry-run'], runRemote, printOut, printErr });

  expect(exitCode).toBe(0);
  expect(runRemote.mock.calls).toStrictEqual(Object.keys(answers).map((command) => [command]));
  expect(printErr).not.toHaveBeenCalled();

  expect(printOut.mock.calls).toStrictEqual([
    [
      `nixie reset on geoffcloud: this deletes all of nixie's state and every device enrolment, and cannot be undone
data volume: ${directory}
files to delete:
  keys.db 12288 bytes
  nixie.db 258048 bytes
steps:
  1. scale statefulset/nixie to 0
  2. wait for pod nixie-0 to stop
  3. remove nixie.db-wal, nixie.db-shm, nixie.db, keys.db-wal, keys.db-shm, keys.db from ${directory}
  4. scale statefulset/nixie to 1
  5. wait for nixie to be ready
  6. print a fresh enrolment code
`,
    ],
    ['dry run: nothing changed; run again with --confirm to reset\n'],
  ]);
});

test('it stops nixie before it removes the data, then restarts it and asks for a code', async () => {
  const directory = '/var/lib/rancher/k3s/storage/pvc-0f1e2d3c_nixie_data-nixie-0';

  const answers: Record<string, string> = {
    'k3s kubectl -n nixie get pvc data-nixie-0 -o jsonpath={.spec.volumeName}': 'pvc-0f1e2d3c',
    'k3s kubectl get pv pvc-0f1e2d3c -o jsonpath={.spec.hostPath.path}': directory,
  };

  const runRemote = mock((command: string) =>
    Promise.resolve({ exitCode: 0, stdout: answers[command] ?? '', stderr: '' }),
  );

  const exitCode = await resetNixie({
    args: ['--confirm'],
    runRemote,
    printOut: () => {},
    printErr: () => {},
  });

  expect(exitCode).toBe(0);

  expect(runRemote.mock.calls).toStrictEqual([
    ['k3s kubectl -n nixie get pvc data-nixie-0 -o jsonpath={.spec.volumeName}'],
    ['k3s kubectl get pv pvc-0f1e2d3c -o jsonpath={.spec.hostPath.path}'],
    [
      `find ${directory} -maxdepth 1 -type f \\( -name nixie.db-wal -o -name nixie.db-shm -o -name nixie.db -o -name keys.db-wal -o -name keys.db-shm -o -name keys.db \\) -printf '%f %s bytes\\n'`,
    ],
    ['k3s kubectl -n nixie scale statefulset nixie --replicas=0'],
    ['k3s kubectl -n nixie wait --for=delete pod/nixie-0 --timeout=180s'],
    [
      `rm -f -- ${directory}/nixie.db-wal ${directory}/nixie.db-shm ${directory}/nixie.db ${directory}/keys.db-wal ${directory}/keys.db-shm ${directory}/keys.db`,
    ],
    ['k3s kubectl -n nixie scale statefulset nixie --replicas=1'],
    ['k3s kubectl -n nixie rollout status statefulset/nixie --timeout=600s'],
    ['k3s kubectl -n nixie exec nixie-0 -c nixie -- bun /app/main.js enrol-code'],
  ]);
});

test('it prints the plan and each step before it runs it, then the enrolment code', async () => {
  const directory = '/var/lib/rancher/k3s/storage/pvc-0f1e2d3c_nixie_data-nixie-0';

  const answers: Record<string, string> = {
    'k3s kubectl -n nixie get pvc data-nixie-0 -o jsonpath={.spec.volumeName}': 'pvc-0f1e2d3c',
    'k3s kubectl get pv pvc-0f1e2d3c -o jsonpath={.spec.hostPath.path}': directory,
    'k3s kubectl -n nixie exec nixie-0 -c nixie -- bun /app/main.js enrol-code': 'ABCD-EFGH\n',
  };

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  await resetNixie({
    args: ['--confirm'],
    runRemote: (command: string) =>
      Promise.resolve({ exitCode: 0, stdout: answers[command] ?? '', stderr: '' }),
    printOut,
    printErr,
  });

  expect(printErr).not.toHaveBeenCalled();

  expect(printOut.mock.calls).toStrictEqual([
    [
      `nixie reset on geoffcloud: this deletes all of nixie's state and every device enrolment, and cannot be undone
data volume: ${directory}
files to delete:
  (none: the volume holds no data file)
steps:
  1. scale statefulset/nixie to 0
  2. wait for pod nixie-0 to stop
  3. remove nixie.db-wal, nixie.db-shm, nixie.db, keys.db-wal, keys.db-shm, keys.db from ${directory}
  4. scale statefulset/nixie to 1
  5. wait for nixie to be ready
  6. print a fresh enrolment code
`,
    ],
    ['==> 1. scale statefulset/nixie to 0\n'],
    ['==> 2. wait for pod nixie-0 to stop\n'],
    [
      `==> 3. remove nixie.db-wal, nixie.db-shm, nixie.db, keys.db-wal, keys.db-shm, keys.db from ${directory}\n`,
    ],
    ['==> 4. scale statefulset/nixie to 1\n'],
    ['==> 5. wait for nixie to be ready\n'],
    ['==> 6. print a fresh enrolment code\n'],
    ['ABCD-EFGH\n'],
    ['reset done: enter the code above at https://nixie.geoff.cloud\n'],
  ]);
});

test('it never removes the data when the pod does not stop', async () => {
  const directory = '/var/lib/rancher/k3s/storage/pvc-0f1e2d3c_nixie_data-nixie-0';

  const answers: Record<string, string> = {
    'k3s kubectl -n nixie get pvc data-nixie-0 -o jsonpath={.spec.volumeName}': 'pvc-0f1e2d3c',
    'k3s kubectl get pv pvc-0f1e2d3c -o jsonpath={.spec.hostPath.path}': directory,
  };

  const runRemote = mock((command: string) => {
    const result = command.includes('wait --for=delete')
      ? {
          exitCode: 1,
          stdout: '',
          stderr: 'error: timed out waiting for the condition on pods/nixie-0\n',
        }
      : { exitCode: 0, stdout: answers[command] ?? '', stderr: '' };

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

  expect(runRemote.mock.calls.slice(3)).toStrictEqual([
    ['k3s kubectl -n nixie scale statefulset nixie --replicas=0'],
    ['k3s kubectl -n nixie wait --for=delete pod/nixie-0 --timeout=180s'],
  ]);

  expect(printErr.mock.calls).toStrictEqual([
    [
      'reset-nixie: step 2 failed (exit 1): error: timed out waiting for the condition on pods/nixie-0\nnixie may be stopped; run again with --confirm once the cause is fixed\n',
    ],
  ]);
});

test('it refuses a data volume path outside the storage directory and changes nothing', async () => {
  const answers: Record<string, string> = {
    'k3s kubectl -n nixie get pvc data-nixie-0 -o jsonpath={.spec.volumeName}': 'pvc-0f1e2d3c',
    'k3s kubectl get pv pvc-0f1e2d3c -o jsonpath={.spec.hostPath.path}': '/var/lib/rancher',
  };

  const runRemote = mock((command: string) =>
    Promise.resolve({ exitCode: 0, stdout: answers[command] ?? '', stderr: '' }),
  );

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await resetNixie({ args: ['--confirm'], runRemote, printOut, printErr });

  expect(exitCode).toBe(1);
  expect(runRemote.mock.calls).toStrictEqual(Object.keys(answers).map((command) => [command]));
  expect(printOut).not.toHaveBeenCalled();

  expect(printErr.mock.calls).toStrictEqual([
    [
      `reset-nixie: refusing the data volume path "/var/lib/rancher": not nixie's local-path directory\n`,
    ],
  ]);
});

test('it stops before any change when the data volume cannot be listed', async () => {
  const directory = '/var/lib/rancher/k3s/storage/pvc-0f1e2d3c_nixie_data-nixie-0';

  const answers: Record<string, string> = {
    'k3s kubectl -n nixie get pvc data-nixie-0 -o jsonpath={.spec.volumeName}': 'pvc-0f1e2d3c',
    'k3s kubectl get pv pvc-0f1e2d3c -o jsonpath={.spec.hostPath.path}': directory,
  };

  const runRemote = mock((command: string) => {
    const result = command.startsWith('find ')
      ? { exitCode: 1, stdout: '', stderr: `find: '${directory}': No such file or directory\n` }
      : { exitCode: 0, stdout: answers[command] ?? '', stderr: '' };

    return Promise.resolve(result);
  });

  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  const exitCode = await resetNixie({ args: ['--confirm'], runRemote, printOut, printErr });

  expect(exitCode).toBe(1);
  expect(runRemote).toHaveBeenCalledTimes(3);
  expect(printOut).not.toHaveBeenCalled();

  expect(printErr.mock.calls).toStrictEqual([
    [`reset-nixie: cannot list the data volume: find: '${directory}': No such file or directory\n`],
  ]);
});
