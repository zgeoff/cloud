import { expect, test } from 'bun:test';
import { readNixieRestoreScripts } from './read-nixie-restore-scripts.ts';

test('it ships restore.sh and the parser it runs from its own folder, as the files hold them', async () => {
  const folder = new URL('../../deploy/nixie/backup/', import.meta.url);

  expect(readNixieRestoreScripts()).toStrictEqual({
    'restore.sh': await Bun.file(new URL('restore.sh', folder)).text(),
    'pick-newest-set.ts': await Bun.file(new URL('pick-newest-set.ts', folder)).text(),
  });
});
