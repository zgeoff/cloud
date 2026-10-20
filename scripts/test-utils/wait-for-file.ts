import { readFile } from 'node:fs/promises';

// polls until the file holds text, since a background writer gives no other signal
export async function waitForFile(path: string): Promise<void> {
  for (let text = ''; text === '';) {
    text = await readFile(path, 'utf8').catch(() => '');

    if (text === '') {
      await Bun.sleep(10);
    }
  }
}
