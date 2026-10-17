import { expect, test } from 'bun:test';
import { toRunOptions } from './to-run-options.ts';

test('it runs in the clone with the bump environment and no stdin', () => {
  expect(
    toRunOptions({
      cwd: '/work/clone',
      env: { PATH: '/usr/bin' },
      run: () => Promise.reject(new Error('not run')),
      printOut: () => {},
      printErr: () => {},
    }),
  ).toStrictEqual({ cwd: '/work/clone', env: { PATH: '/usr/bin' } });
});

test('it sends the given text on stdin', () => {
  expect(
    toRunOptions(
      {
        cwd: '/work/clone',
        env: { PATH: '/usr/bin' },
        run: () => Promise.reject(new Error('not run')),
        printOut: () => {},
        printErr: () => {},
      },
      'Bumps imp to 1.0.1.\n',
    ),
  ).toStrictEqual({
    cwd: '/work/clone',
    env: { PATH: '/usr/bin' },
    stdin: Buffer.from('Bumps imp to 1.0.1.\n'),
  });
});
