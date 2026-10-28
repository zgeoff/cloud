import { expect, mock, test } from 'bun:test';
import { checkCIProfiles } from './check-ci-profiles.ts';

function setupTest() {
  const printOut = mock<(text: string) => void>();
  const printErr = mock<(text: string) => void>();

  return { printOut, printErr };
}

test('it accepts a checks job that runs every parallel step once private', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/ci.yml',
      `jobs:
  lint:
    steps:
      - uses: actions/checkout@aaaa
      - run: bun run lint
      - uses: actions/setup-go@bbbb
  checks:
    steps:
      - uses: actions/checkout@aaaa
      - run: bun run ci:check-needs
      - if: \${{ github.event.repository.private }}
        run: bun run lint
      - if: \${{ github.event.repository.private }}
        uses: actions/setup-go@bbbb
`,
    ],
  ]);

  const exitCode = await checkCIProfiles({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(0);

  expect(ctx.printOut).toHaveBeenCalledExactlyOnceWith(
    "check-ci-profiles: the private checks job runs every parallel job's steps\n",
  );

  expect(ctx.printErr).not.toHaveBeenCalled();
});

test('it reports a parallel step that the checks job lacks', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/ci.yml',
      `jobs:
  lint:
    steps:
      - run: bun run lint
      - run: bun run lint:sh
  checks:
    steps:
      - run: bun run ci:check-needs
      - run: bun run lint
`,
    ],
  ]);

  const exitCode = await checkCIProfiles({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'ci.yml: the checks job has no private-profile step for `run: bun run lint:sh`\n',
  );

  expect(ctx.printOut).not.toHaveBeenCalled();
});

test('it reports a checks job step that no parallel job runs', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/ci.yml',
      `jobs:
  lint:
    steps:
      - run: bun run lint
  checks:
    steps:
      - run: bun run lint
      - run: bun run lint:py
`,
    ],
  ]);

  const exitCode = await checkCIProfiles({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    "ci.yml: no parallel job runs the checks job's step `run: bun run lint:py`\n",
  );
});

test('it reports a secret scan step that waits on the reuse decision', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/ci.yml',
      `jobs:
  lint:
    steps:
      - uses: gitleaks/gitleaks-action@cccc
  checks:
    steps:
      - if: \${{ github.event.repository.private && steps.decide.outputs.reused != 'true' }}
        uses: gitleaks/gitleaks-action@cccc
`,
    ],
  ]);

  const exitCode = await checkCIProfiles({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'ci.yml: the checks job skips its secret scan on a reused push, whose history no pull request run scanned\n',
  );
});

test('it reports a secret scan in a job that waits on the reuse decision', async () => {
  const ctx = setupTest();

  const files = new Map([
    [
      '/repo/.github/workflows/ci.yml',
      `jobs:
  lint:
    if: \${{ needs.decide.outputs.reused != 'true' }}
    steps:
      - uses: gitleaks/gitleaks-action@cccc
  checks:
    steps:
      - if: \${{ github.event.repository.private }}
        uses: gitleaks/gitleaks-action@cccc
`,
    ],
  ]);

  const exitCode = await checkCIProfiles({
    args: ['/repo'],
    readText: (path) => Promise.resolve(files.get(path) ?? ''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(1);

  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith(
    'ci.yml: the lint job skips its secret scan on a reused push, whose history no pull request run scanned\n',
  );
});

test('it rejects more than one argument with its usage', async () => {
  const ctx = setupTest();

  const exitCode = await checkCIProfiles({
    args: ['/repo', '/other'],
    readText: () => Promise.resolve(''),
    printOut: ctx.printOut,
    printErr: ctx.printErr,
  });

  expect(exitCode).toBe(2);
  expect(ctx.printErr).toHaveBeenCalledExactlyOnceWith('usage: check-ci-profiles.ts [repo root]\n');
});
